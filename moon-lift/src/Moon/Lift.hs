{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE PackageImports             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeInType                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -Wextra -Wno-unused-binds -Wno-missing-fields -Wno-all-missed-specialisations -Wno-unused-imports #-}
{-# OPTIONS_GHC -Wno-partial-type-signatures #-}

module Moon.Lift
  ( main
  , defaultConfig
  , Config(..)
  , channelFromWebsocket
  )
where

import           Codec.Serialise
import qualified Data.ByteString                as BS
import qualified Data.ByteString.Lazy           as LBS
import qualified Data.Map                       as Map
import           Data.Map                         (Map)
import qualified Data.Set.Monad                 as Set
import           Data.Set.Monad                   (Set)
import           Data.Text
import           Data.Time
import           GHC.Generics                     (Generic)
import           Options.Applicative

import qualified Control.Concurrent.Chan.Unagi  as Unagi
import qualified Control.Concurrent             as Conc
import qualified Control.Concurrent.STM         as STM
import           Control.Concurrent.STM           (STM, TVar, atomically)
import           Control.Exception
import           Control.Monad                    (forever)
import           Control.Tracer
import           Data.Time
import qualified Network.WebSockets             as WS
import           Shelly
import           System.Environment
import qualified System.IO.Unsafe               as Unsafe          

import qualified Cardano.BM.Configuration       as BM
import qualified Cardano.BM.Configuration.Model as BM
import qualified Cardano.BM.Setup               as BM
import qualified Cardano.BM.Backend.Switchboard as BM
import qualified Cardano.BM.Trace               as BM

import qualified Network.TypedProtocol.Channel  as Net

import           Moon.Face
import           Moon.Face.Haskell
import           Moon.Protocol
import           Moon.Peer
import           Moon.Pipe
import           Moon.Lift.Hackage
import           Moon.Lift.Haskell


data ConfigPhase
  = Initial
  | Final

data Config a =
  Config
  { cfWSBindHost :: String
  , cfWSPortIn   :: Int
  , cfWSPortOut  :: Int
  , cfWSPingTime :: Int
  , cfMonitoring :: CFMonitoring a
  , cfGhcLibDir  :: CFGhcLibDir a
  , cfGitRoot    :: FileName
  , cfHackageTmo :: NominalDiffTime
  }
type family CFMonitoring (a :: ConfigPhase) where
  CFMonitoring Initial = IO BM.Configuration
  CFMonitoring Final   = BM.Configuration
type family CFGhcLibDir (a :: ConfigPhase) where
  CFGhcLibDir Initial  = Maybe FileName
  CFGhcLibDir Final    = FileName

defaultConfig :: Config Initial
defaultConfig = Config
  { cfWSBindHost = "127.0.0.1"
  , cfWSPortIn   = 29670
  , cfWSPortOut  = 29671
  , cfWSPingTime = 30
  , cfMonitoring = BM.empty
  , cfGhcLibDir  = Nothing
  , cfGitRoot    = "."
  , cfHackageTmo = fromInteger 3600
  }

main :: IO ()
main = do
  -- establish config
  let preConfig@Config{..} = defaultConfig
  monitoring <- cfMonitoring
  libDir <- case cfGhcLibDir of
    Just x  -> pure x
    Nothing -> (FileName <$>) <$> shelly $ run "ghc" ["--print-libdir"]
  let config :: Config Final = preConfig
        { cfMonitoring = monitoring
        , cfGhcLibDir  = libDir }

  wsServer =<< finalise config

data Env =
  Env
  { envConfig      :: !(Config Final)
  , envTrace       :: !(BM.Trace IO Text)
  , envSwitchboard :: !(BM.Switchboard Text)
  , envTracer      :: !(Tracer IO String)
  , envGetHackage  :: !(IO (Either Text (Set PackageName)))
  }

finalise :: Config Final -> IO Env
finalise envConfig@Config{..} = do
  (envTrace, envSwitchboard) <- BM.setupTrace_ cfMonitoring "moon"
  envGetHackage <- setupHackageCache cfHackageTmo
  let envTracer = stdoutTracer
  pure Env{..}

channelFromWebsocket :: WS.Connection -> Net.Channel IO LBS.ByteString
channelFromWebsocket conn =
  Net.Channel
  { recv = catch (Just <$> WS.receiveData conn) $
           (\(SomeException _x) -> pure Nothing)
  , send = WS.sendBinaryData conn
  }

wsServer :: Env -> IO ()
wsServer env@Env{envConfig=Config{..},..} = forever $ do
  -- (,) fromWebW fromWebR <- Unagi.newChan

  WS.runServer cfWSBindHost cfWSPortOut $
    \pending-> do
      conn <- WS.acceptRequest pending
      WS.forkPingThread conn cfWSPingTime

      let handleDisconnect :: WS.ConnectionException -> IO ()
          handleDisconnect x = putStrLn $ "Web disconnected: " <> show x
          tracer = stdoutTracer

      flip catch handleDisconnect $ forever $ do
        runServer tracer (haskellServer env) $ channelFromWebsocket conn

haskellServer
  :: forall rej m a
  . (rej ~ Text, m ~ IO, a ~ SomeReply)
  => Env
  -> Server rej m a
haskellServer env@Env{..} =
    server
  where
    server = Server {
      recvMsgRequest = \req -> do
        traceWith (showTracing envTracer) req
        r <- handleRequest env req
        pure (r, server)
    , recvMsgDone = ()
    }

handleRequest :: Env -> SomeRequest -> IO (Either Text SomeReply)
handleRequest Env{..} (SomeRequest x) = case x of
  RunPipe name vs -> do
    pipe <- atomically $ tryGetPipe name
    putStrLn "got pipe"
    case pipe of
      Nothing -> pure . Left . pack $ "Unknown pipe: " <> show name
      Just pipe -> do
        case apply vs pipe of
          Left e -> pure . Left $ "Pipe application error: " <> e
          Right runnable -> do
            res :: Either Text SomeValue <- runPipe runnable
            case res of
              Left e -> pure . Left $ "Pipe run error: " <> e
              Right x -> pure . Right . SomeReply . ReplyValue $ x
  -- x -> pure . Left . pack $ "Unhandled request: " <> show x

tryGetPipe :: PipeName -> STM (Maybe Pipe)
tryGetPipe name = Map.lookup name <$> STM.readTVar pipes

listPipeNames :: Result (Set PipeName)
listPipeNames = Right . Set.fromList . Map.keys <$> STM.readTVarIO pipes

pipeSig :: PipeName -> Result Sig
pipeSig name = do
  pipe <- atomically $ tryGetPipe name
  pure $ case pipe of
    Nothing -> Left $ "Missing: " <> pack (show name)
    Just (dSig . pDef -> d) -> Right d

defCompose :: PipeName -> PipeName -> PipeName -> Result Sig
defCompose newname lname rname = atomically $ do
  old <- tryGetPipe newname
  ml  <- tryGetPipe lname
  mr  <- tryGetPipe rname
  case (old, ml, mr) of
    (Just _, _, _)  -> pure . Left $ "Already exists: " <> pack (show newname)
    (_, Nothing, _) -> pure . Left $ "Missing: " <> pack (show lname)
    (_, _, Nothing) -> pure . Left $ "Missing: " <> pack (show rname)
    (Nothing, Just l, Just r) -> do
      case compose l r of
        Left err -> pure $ Left err
        Right new -> do
          STM.modifyTVar' pipes $
            \m -> Map.insert newname new m
          pure . Right . dSig . pDef $ new

pipes :: TVar Pipes
pipes = Unsafe.unsafePerformIO $ STM.newTVarIO $ Map.fromList
  [ p $ gen "haskell-indices" TSet $ pure $ Right $ Set.fromList
    [ IndexName "hackage" ]
  , p $ gen "pipes" TSet $ listPipeNames
  , p $ link "sig" TPoint TPoint $ pipeSig
  ]
  where p x = (pipeName x, x)
  -- Packages "hackage"  > do
  --   ret <- envGetHackage
  --   case ret of
  --     Left e -> pure $ Left e
  --     Right hackagePackages -> pure . Right . PlyPackages $ RSet hackagePackages
  -- Packages (IndexName ix) -> pure . Left $ "Unhandled index: " <> ix
