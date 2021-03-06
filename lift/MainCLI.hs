--{-# OPTIONS_GHC -dshow-passes -dppr-debug -ddump-rn -ddump-tc #-}
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wall -Wno-unticked-promoted-constructors -Wno-name-shadowing #-}

import Control.Concurrent                        (threadDelay)
import Control.Concurrent.Chan.Unagi qualified as Unagi
import Control.Concurrent.STM                    (TVar)
import Control.Concurrent.STM        qualified as STM
import Control.Exception                         (ErrorCall(..), Handler(..)
                                                 , SomeException (..)
                                                 , catches)
import Control.Monad
import Control.Monad.Fix
import Control.Monad.NodeId
import Control.Tracer
import Data.Char                                 (isDigit)
import Data.Dynamic                  qualified as Dyn
import Data.IntMap                   qualified as IMap
import Data.IORef                    qualified as IO
import Data.Monoid
import Data.Semialign                            (align)
import Data.Sequence                 qualified as Seq
import Data.IntUnique
import Data.Vector                   qualified as Vec

import Reflex                             hiding (Request)
import Reflex.Network
import Reflex.Vty                         hiding (Request)
import Data.Text                     qualified as T
import Graphics.Vty                  qualified as V
import System.IO.Unsafe              qualified as Unsafe

import Reflex.Vty.Widget.Extra
import Reflex.Vty.Widget.Selector

import Basis hiding (Dynamic)
import Debug.Reflex

import Dom.CTag
import Dom.Cap
import Dom.Cred
import Dom.Error
import Dom.Expr
import Dom.Located
import Dom.LTag
import Dom.Name
import Dom.Pipe
import Dom.Pipe.EPipe
import Dom.Pipe.Ops
import Dom.Pipe.Pipe
import Dom.RequestReply
import Dom.Scope
import Dom.Scope.SomePipe
import Dom.Sig
import Dom.SomePipe
import Dom.SomeType
import Dom.SomeValue
import Dom.Space.Pipe
import Dom.Space.SomePipe
import Dom.Value

import Ground.Table

import qualified Wire.MiniProtocols            as Wire
import qualified Wire.Peer                     as Wire
import qualified Wire.WSS                      as Wire

import Lift hiding (main)
import Lift.Pipe
import Lift.Server
import Execution

import Reflex.SomeValue



main :: IO ()
main = withDotTracing "trace.dot" $ do
  traceM $ pave '-' <> pave '=' <> " main " <> pave '=' <> pave '-'
  sealGround -- TODO:  fix the stupid names of init fns
  setupLLive
  mainWidget reflexVtyApp

pave :: Char -> String
pave c = take 21 $ repeat c

reflexVtyApp :: forall t m.
  (MonadIO (Performable m), ReflexVty t m, PerformEvent t m, PostBuild t m, TriggerEvent t m, MonadIO m)
  => VtyWidget t m (Event t ())
reflexVtyApp = do
  setupE <- getPostBuild <&> trevs
    ("// " <> pave '-' <> " reflexVtyApp: reflexVtyApp started " <> pave '-')
  let creds  = CredFile "server-certificate.pem" "server-key.pem"
      showTr = showTracing (contramap pack stderr)
      trs    =
        Wire.WireTracers
        { trMux         = showTr
        , trMuxRequests = showTr
        , trMuxReplies  = showTr
        , trWss         = showTr
        , trBearer      = nullTracer
        }
  r <- mkRemoteExecutionPort trs creds hostAddr setupE
  l <- mkLocalExecutionPort stderr setupE
  spaceInteraction r l
 where
   hostAddr = Wire.WSAddr "127.0.0.1" (cfWSPortOut defaultConfig) "/"

mkRemoteExecutionPort ::
  forall t m
  . (ReflexVty t m, PerformEvent t m, TriggerEvent t m, MonadIO m, MonadIO (Performable m))
  => Wire.WireTracers IO
  -> CredSpec
  -> Wire.WSAddr
  -> Event t ()
  -> VtyWidget t m (ExecutionPort t ())
mkRemoteExecutionPort trs cs wsa setupE = mdo
  ep <- mkExecutionPort
          (SP @() @Now @'[] @(CTagV Point (PipeSpace (SomePipe ()))) mempty capsT $
           Pipe (mkNullaryPipeDesc (Name @Pipe "space") LNow CPoint VPipeSpace) ())
          (\popExe ->
             selectEvents (selectExecutionReplies ep popExe) CPoint VPipeSpace
             <&> fmap stripCapValue)
          setupE $
    \_exeSendR fire -> do
      forever $
        catches
          (Wire.runWssClient trs cs wsa (liftClients (Wire.trWss trs) fire ep))
          [ Handler (\(ErrorCall e) -> do
                        let err = Error $ showT e
                        traceM (show err)
                        fire (unsafeCoerceUnique 1) . Left $ EExec err)
          , Handler (\(SomeException e) -> do
                        let err = Error $ "Uncaught SomeException: " <> showT e
                        traceM (show err)
                        fire (unsafeCoerceUnique 1) . Left $ EExec err)
          ]
  void $ makePostRemoteExecution ep CPoint VPipeSpace "space"
  pure ep

liftClients ::
  forall rej m a t
   . (rej ~ EPipe, m ~ IO, a ~ SomeValue)
  => Tracer m Text
  -> (Unique -> PFallible SomeValue -> IO ())
  -> ExecutionPort t ()
  -> m (Wire.RequestClient rej m (), Wire.RepliesClient rej m ())
liftClients tr fire ExecutionPort{..} = do
  pure $
    (,)
    (Wire.ClientRequesting (eRequest <$> Unagi.readChan epExecs))
    (Wire.ClientReplyWait $
      \(rid, rep) -> do
        epStreams <- IO.readIORef epStreamsR
        maybe
          (traceWith tr $ "No Execution for rid "<>showT rid<>" of reply "<>showT rep)
          (\exe -> fireMatchingReplies rid rep exe)
          (IMap.lookup (hashUnique rid) epStreams))
 where
   fireMatchingReplies ::
        Unique
     -> PFallible SomeValue
     -> Execution t p
     -> IO ()
   fireMatchingReplies unique reply Execution{..} = case reply of
     Right rep ->
       case withExpectedSomeValue eResCTag eResVTag rep stripValue of
         Right{} -> fire unique (Right rep)
         Left (Error e) -> traceWith tr $
           "Server response tags don not match Execution: " <> e
     Left err -> fire unique (Left err)

mkLocalExecutionPort ::
  forall t m
  . (ReflexVty t m, PerformEvent t m, TriggerEvent t m, MonadIO m, MonadIO (Performable m))
  => Tracer IO Text
  -> Event t ()
  -> VtyWidget t m (ExecutionPort t Dyn.Dynamic)
mkLocalExecutionPort _tr initE = mdo
  ep <- mkExecutionPort
          localSpacePipe
          (\popExe ->
             selectEvents (selectExecutionReplies ep popExe) CPoint VPipeSpaceDyn
             <&> fmap stripCapValue)
          initE $
    \ExecutionPort{..} fire -> do
      threadDelay 1000000
      forever $ do
        e@Execution{..} <- Unagi.readChan epExecs
        mapSomeResult (fire (eHandle e)) (runSomePipe ePipe)
        -- fire (eHandle e) =<< (left EExec <$> runSomePipe ePipe)
  pure ep

localPipeSpace :: TVar (SomePipeSpace Dyn.Dynamic)
localPipeSpace = Unsafe.unsafePerformIO $ STM.newTVarIO Main.initialPipeSpace
{-# NOINLINE localPipeSpace #-}

getLocalPipeSpace :: IO (PipeSpace (SomePipe Dyn.Dynamic))
getLocalPipeSpace = STM.readTVarIO localPipeSpace

localSpacePipe :: SomePipe Dyn.Dynamic
localSpacePipe =
  somePipe0  "local-space" LNow capsTS CVPoint (Right <$> getLocalPipeSpace)

initialPipeSpace :: SomePipeSpace Dyn.Dynamic
initialPipeSpace
  = emptySomePipeSpace "Root"
    & spsInsertScopeAt mempty
      (pipeScope ""
       -- Generators:
       --
        [ localSpacePipe
        ])

data Acceptable
  = APipe  !MixedPipe
  | AScope !(QName Scope)

instance Show Acceptable where
  show x = T.unpack $ case x of
    APipe{}  -> "Pipe "  <> acceptablePresent x
    AScope{} -> "Scope " <> acceptablePresent x

acceptablePresent :: Acceptable -> Text
acceptablePresent = \case
  APipe  x -> showQName . somePipeQName $ x
  AScope x -> showQName x

spaceInteraction ::
     forall    t m
  .  (ReflexVty t m, PerformEvent t m, TriggerEvent t m, MonadIO (Performable m), MonadIO m)
  => ExecutionPort t ()
  -> ExecutionPort t Dyn.Dynamic
  -> VtyWidget t m (Event t ())
spaceInteraction epRemote epLocal = mdo
  -- initE <- getPostBuild
  -- initExecutionE :: Event t (Execution t MixedPipeGuts) <-
  --   performEvent $
  --     initE $>
  --     makePostRemoteExecution epRemote
  --       -- "ground" CSet VText
  --       "Hackage.pkgNames" CSet VNameHaskPackage

  -- server + local -> spaceD
  let (,) remoteSpaceErrsE remoteSpaceE = fanEither $ epSpacE epRemote
      (,) localSpaceErrsE   localSpaceE = fanEither $ epSpacE epLocal
  remoteSpaceD :: Dynamic t (PipeSpace (SomePipe ())) <-
    holdDyn mempty remoteSpaceE
  localSpaceD :: Dynamic t (PipeSpace (SomePipe Dyn.Dynamic)) <-
    holdDyn mempty localSpaceE
  let spaceD :: Dynamic t (PipeSpace MixedPipe)
      spaceD = zipDynWith (<>)
                 ($(dev "spaceD" 'localSpaceD)  <&> fmap (fmap Right))
                 ($(dev "spaceD" 'remoteSpaceD) <&> fmap (fmap Left))

  spcFRunnableD ::
    Dynamic t (PipeSpace MixedPipe, PFallible (PreRunnable MixedPipeGuts, SeparatedPipe))
    <- pure $ (\spc pr -> (spc, compilePreRunnable spc pr))
               <$> $(dev "spcFRunnableD" 'spaceD)
               <*> $(dev "spcFRunnableD" 'fPreRunnableD)

  let compilePreRunnable ::
           SomePipeSpace MixedPipeGuts
        -> PFallible (PreRunnable MixedPipeGuts)
        -> PFallible (PreRunnable MixedPipeGuts, SeparatedPipe)
      compilePreRunnable spcMix fpr = do
         pr@PreRunnable{..} <- fpr
         _pexp <- prPExpr
         p <- if | preRunnableAllLeft pr
                 -> fmap Left  <$> compile opsDesc (join . fmap (either Just (const Nothing)) . fmap hoistMixedPipe . lookupSomePipe spcMix) prExpr
                 | preRunnableAllRight pr
                 -> fmap Right <$> compile opsFull (join . fmap (either (const Nothing) Just) . fmap hoistMixedPipe . lookupSomePipe spcMix) prExpr
                 | otherwise ->
                   Left . ECompile . Error $ "Inconsistent pipe locality: " <> showT prExpr
         -- traceM . mconcat $
         --   [ "preRunnable: ", show pr, ", "
         --   , "allLeft: ", show $ preRunnableAllLeft pr, ", "
         --   , "has CGround: ", show $ somePipeHasCap CGround p, ", "
         --   , "runnability issues: ", show $ checkPipeRunnability
         --                                      (preRunnableAllLeft pr) p, ", "
         --   ]
         void $ maybeLeft (checkPipeRunnability
                           -- $ (\x -> flip trace x $
                           --     "preRunnableAllLeft: " <> show x <> " " <> show p)
                           $ preRunnableAllLeft pr) p
         pure (pr, separateMixedPipe p)

      hoistMixedPipe :: SomePipe MixedPipeGuts -> Either (SomePipe ()) (SomePipe (Dyn.Dynamic))
      hoistMixedPipe = \case
        SP n c (Pipe d (Left  x)) -> Left  (SP n c (Pipe d x))
        SP n c (Pipe d (Right x)) -> Right (SP n c (Pipe d x))

      -- 1. Separate the syntactically valid requests from chaff.
      (spcRunnableFailE :: Event t (SomePipeSpace MixedPipeGuts, EPipe),
       runnablE         :: Event t (PreRunnable MixedPipeGuts, SeparatedPipe)) =
        ($(evl' "spcRunnableFailE" 'spcFRunnableD
                [e|show|]) ***
         $(evl' "runnablE"         'spcFRunnableD
                [e|unpack . preRunnableText . fst|]))
        $ fanEither (fstToLeftFst <$> updated spcFRunnableD)

      spcNextArgTypeE :: Event t (SomePipeSpace MixedPipeGuts, Maybe SomeTypeRep)
      spcNextArgTypeE =
        $(ev "spcNextArgTypeE" 'spcRunnableFailE)
          <&> \case
                (spc, EUnsat _ _ _ _ (x:_) _) -> (spc, Just $ tRep x)
                (spc, _) -> (spc, Nothing)
      spcErrorsE :: Event t (SomePipeSpace MixedPipeGuts, EPipe)
      spcErrorsE =
        leftmost
        [ $(ev "spcErrorsE" 'spcRunnableFailE)
        , attachPromptlyDyn spaceD remoteSpaceErrsE
          -- & trevs "remoteSpaceErrsE -> errorsE;"
        , attachPromptlyDyn spaceD localSpaceErrsE
          -- & trevs "localSpaceErrsE -> errorsE;"
        ]

  executionE ::
    Event t (Execution t MixedPipeGuts)
    <- performEvent $
        (attachPromptlyDyn
           $(dev "executionE" 'spaceD)
           $(ev  "executionE" 'runnablE)
           <&>) $
        liftIO .
        -- XXX: WTF?
        (\(_spc, (PreRunnable{..}, p)) -> do
           maybe (error "postMixedPipeRequest returned Nothing")
             id <$>
             (postMixedPipeRequest epRemote epLocal prText prReq p)
           )

  (spcConstraintE, fireSpcConstraintE) <- newTriggerEvent
  spcConstraintD :: Dynamic t (SomePipeSpace MixedPipeGuts, Maybe SomeTypeRep) <-
    holdDyn (mempty, Nothing) spcConstraintE

  let allExecutionsE = leftmost
        [ executionE
        -- , initExecutionE
        ]

  -- 0. UI provides syntactically valid requests, and also
  --    displays results of validation.
  fPreRunnableD ::
    Dynamic t (PFallible (PreRunnable MixedPipeGuts)) <-
    mainSceneWidget
      (pipeEditorWidget
        $(dev "fPreRunnableD" 'spcConstraintD)
        (summaryWidget
          $(ev "summaryWidget" 'executionE)
          $(ev "summaryWidget" 'spcErrorsE)))
      (presentExecution allExecutionsE
        >> pure ())
      (feedbackWidget
        $(dev  "feedbackWidget" 'pipesFromD)
        $(dev  "feedbackWidget" 'spcConstraintD)
        ($(dev "feedbackWidget" 'spcFRunnableD)
          <&> fmap fst . snd))

  void . performEvent $
    $(ev "spcConstraintD" 'spcNextArgTypeE) <&>
      liftIO . fireSpcConstraintE

  let -- spaceD + constraintD -> pipesFromD
      pipesFromD :: Dynamic t [MixedPipe] =
        ($(dev "pipesFromD" 'spcConstraintD)
         <&> uncurry pipesToCstr)
        <&> sortBy (compare `on` somePipeName)

  exitOnTheEndOf input

 where
   pipeEditorWidget ::
        Dynamic t (PipeSpace MixedPipe, Maybe SomeTypeRep)
     -> VtyWidget t m ()
     -> VtyWidget t m (Dynamic t (PFallible (PreRunnable MixedPipeGuts)))
   pipeEditorWidget spcConstraintD resultSummaryW = mdo
     selrWidthD :: Dynamic t Width <- fmap Width <$> displayWidth

     -- Input (selrInputOfftComplD) guides selection among pipes of the space.
     reqAnalysedAccbleD ::
       Dynamic t
       (PFallible ( PreRunnable MixedPipeGuts
                  , [Acceptable])) <-
       pure $
         (\(spc, constr) (prText, coln@(Column intColn)) ->
            parseGroundRequest (Just intColn) prText
            >>= \prReq@(reqExpr . snd -> prExpr) -> pure
             let prPExpr = analyse (lookupSomePipe spc) prExpr
             in  ( PreRunnable{..}
                 , either (const []) id $
                   let r = case prPExpr of
                             Right pExp -> Right (constr, pExp)
                             Left u@EUnsat{} ->
                               Right (Just $ tRep $ head $ epMiss u,
                                      -- XXX: ???
                                      undefined)
                             Left e -> Left e
                   in r <&>
                      inputCompletionsForExprAndColumn spc coln prExpr))
         <$> $(dev "reqAnalysedAccbleD" 'spcConstraintD)
         <*> $(dev "reqAnalysedAccbleD" 'selrInputOfftD)

     accbleRightsD :: Dynamic t [Acceptable] <-
       -- this ignores errors!
       holdDyn [] (fmap snd . snd . fanEither . updated $
                   $(dev "accbleRightsD" 'reqAnalysedAccbleD))
     -- XXX: why is this needed?
     uniqAccbleRightsD <- holdUniqDynBy ((==) `on` length)
                          $(dev "uniqAccbleRightsD" 'accbleRightsD)

     Selector{..} <- selector
       SelectorParams
       { spCompletep    = completion
       , spShow         = acceptablePresent
       , spPresent      = presentAcceptable $
                            zipDyn
                              selrWidthD
                              $(dev "spPresent" 'accbleRightsD)
                            <&> uncurry (mkPipePresentCtx " :: ")
       , spElemsE       = $(evl'' "spElemsE" "uniqAccbleRightsD"
                                  [e|show . Vec.length|]) $
                           fmap Vec.fromList $
                           updated uniqAccbleRightsD
       , spInsertW      = resultSummaryW
       , spConstituency = Dom.Name.nameConstituent
       }
     holdUniqDynBy
        eqFPreRunnable
        ($(dev "fPreRunnableD" 'reqAnalysedAccbleD)
         <&> fmap fst)

   eqFPreRunnable :: PFallible (PreRunnable MixedPipeGuts) -> PFallible (PreRunnable MixedPipeGuts) -> Bool
   eqFPreRunnable (Right l) (Right r) = ((==) `on` prText) l r
   eqFPreRunnable _ _ = False

   summaryWidget :: (Adjustable t m, PostBuild t m, MonadNodeId m, MonadHold t m, NotReady t m, MonadFix m)
     => Event t (Execution t MixedPipeGuts)
     -> Event t (SomePipeSpace MixedPipeGuts, EPipe)
     -> VtyWidget t m ()
   summaryWidget exE spcErrorsE =
     void $ networkHold (pres red "Pipe: " $ text $ pure "-- no valid pipe --") $
       align exE spcErrorsE <&> \case
         These _ _ -> error "summary -> align -> These exE frE -> Boom"
         This exe  -> pres blue "Result: " $ presentExecutionSummary exe
         That (_spc, err) ->
           case err of
             EParse     e -> presErr red "Parse"     e
             EAnal      e -> presErr red "Analysis"  e
             EName      e -> presErr red "Name"      e
             ECompile   e -> presErr red "Compile"   e

             ENonGround e -> presErr red "NonGround" e
             EUnsat name s o done _ _ ->
                             presUnsat (showName name) s o done

             EApply     e -> presErr red "Apply"     e
             ETrav      e -> presErr red "Traverse"  e
             EComp      e -> presErr red "Compose"   e

             EType      e -> presErr red "Type"      e
             EKind      e -> presErr red "Kind"      e
             EExec      e -> presErr red "Runtime"   e
          where
            presErr col pfx = pres col (pfx <> ": ") . text . pure . showError
            presUnsat desc args out done = row $ do
              let txt col t = fixed (pure $ T.length t) $
                                richTextStatic col (pure t)
              txt yellow desc
              txt grey (" :: ")
              let (doneArgs, curArg:unsatArgs) = splitAt done args
              forM_ doneArgs $
                (>> txt grey " -> ") . txt blue . showSomeType False
              txt white (curArg & showSomeType False)
              txt grey " -> "
              forM_ unsatArgs $
                (>> txt grey " -> ") . txt red . showSomeType False
              txt green (out & showSomeType False)
    where
      pres :: V.Attr -> Text -> VtyWidget t m a -> VtyWidget t m a
      pres col pref x = row $ do
        width <- displayWidth
        let len = T.length pref
        fixed (pure len) $
          richTextStatic col (pure pref)
        fixed (width <&> (\x->x-len)) x

   feedbackWidget ::
        Dynamic t [MixedPipe]
     -> Dynamic t (SomePipeSpace MixedPipeGuts, Maybe SomeTypeRep)
     -> Dynamic t (PFallible (PreRunnable MixedPipeGuts))
     -> VtyWidget t m ()
   feedbackWidget pipesFromD (fmap snd -> constraintD) preRunD = do
     -- visD   <- holdDyn "" $ either (showError . unEPipe) (pack . show . snd) <$> astExpE
     -- redD   <- hold ""    $ either (showError . unEPipe) (pack . show . fst) <$> astExpE
     blueD  <- pure . current $ zipDynWith showCstrEnv constraintD pipesFromD
     redD   <- hold "" $ either (showError . unEPipe) (const "") <$> errOkE
     greenD <- hold "" $ either (const "")      (showT . prExpr) <$> errOkE

     void $ splitV (pure $ const 1) (pure $ join (,) True)
      (richTextStatic blue  blueD)
      (richTextStatic   red redD >>
       richTextStatic green greenD >> pure ())
    where
      errOkE = updated preRunD
      showCstrEnv cstr pipes =
        mconcat [ "Pipes producing ",
                  fromMaybe "Nothing" $ showSomeTypeRepNoKind <$> cstr
                , ": ", pack $ show (length pipes)
                ]

   mainSceneWidget ::
        VtyWidget t m (Dynamic t a)
     -> VtyWidget t m ()
     -> VtyWidget t m ()
     -> VtyWidget t m (Dynamic t a)
   mainSceneWidget editor executionResults feedback = do
     tabNav <- tabNavigation
     let tabHalves :: Int -> (Bool, Bool) -> (Bool, Bool)
         tabHalves = const swap
     halves <- foldDyn tabHalves (True, False) tabNav
     (((runnable, _present),
       _blank),
       _feedb) <-
      splitV (pure $ \x->x-8) (pure (True, False))
       (splitV (pure \x->x-1) (pure (True, False))
         (splitH (pure $ flip div 2) halves--(pure $ join (,) True)
            editor
            executionResults)
         blank)
       feedback
     pure runnable

   -- | Given a char to the left, the trigger char and current completible,
   --   decide whether to complete, and what to.
   completion :: Maybe Char -> Char -> Acceptable -> Maybe Text
   completion leftC newC acc =
           (\x ->
              trace
              (mconcat
               [ "completion: leftC=", catMaybes [leftC], ", "
               , "newC=", [newC], ", "
               , "acc=", show acc, ", "
               , "res=", show x
               ])
              x
           ) $
     let constituentLeftChar orMaybe =
           leftC <&>
           \x->
             Dom.Name.nameConstituent x && not (isDigit x) || orMaybe x
         completable =
           case newC of
           '.' -> constituentLeftChar (== '.')      == Just True
           ' ' -> constituentLeftChar (const False) /= Just False
           _ -> False
     in if not completable
        then Nothing
        else Just $
             case acc of -- yes, completion is context-dependent, huh!
               AScope _ -> (<>           ".") $ acceptablePresent acc
               APipe  _ -> (<> T.pack [newC]) $ acceptablePresent acc

inputCompletionsForExprAndColumn ::
     PipeSpace MixedPipe
  -> Column
  -> Expr (Located (QName Pipe))
  -> (Maybe SomeTypeRep, Expr (Located MixedPartPipe))
  -> [Acceptable]
inputCompletionsForExprAndColumn spc (Column coln) ast (constr, _partialPipe) =
  -- XXX: so we replicate the same pipe.  UGH!
  (APipe <$> scPipes)
  -- So, here we're ignoring the _selected_ pipe,
  -- only collecting the _accepted_ AST.
  --
  -- Important distinction.
  <> (AScope <$> subScNames)
 where
   -- 0. map char position to scope/pipe name
   astIndex = indexLocated ast
   -- determine the completable
   inputName@(QName iqn) = fromMaybe mempty $ lookupLocated coln astIndex
   -- componentise into scope name and tail
   (scopeName, Name rawName) = unsnocQName inputName &
                               fromMaybe (mempty, Name "")
   -- 1. find scope
   -- determine immediate children of named scope, matching the stem restriction
   -- mScope :: Maybe (PointScope MixedPipe)
   -- mScope = lookupSpaceScope (coerceQName scopeName) (psSpace spc)

   -- 2. find scope's children
   subScNames = childPipeScopeQNamesAt (coerceQName scopeName) spc
     & Prelude.filter (T.isInfixOf rawName . showName . lastQName)

   -- 3. map char position to partial pipe in supplied expr
   -- indexPartPipe = indexLocated partialPipe
   -- inputPartPipe = lookupLocated coln indexPartPipe

   -- 4. select scope's pipes that match the provided partial pipe
   scPipes =
     pipesToCstr spc
     (-- trace
      --  (mconcat
      --   [ "COMPLETION: "
      --   , "constr=", show constr, ", "
      --   , "input: '", show inputName, "'"
      --   ])
      constr)
     & case constr of
         Just{} ->
           filter (spQName >>>
                    \(QName (_ :|> x)) ->
                      (rawName `T.isInfixOf`) $ showName x)
         Nothing ->
           filter (spQName >>>
                    \(QName spqn) -> getAll $
                      bifoldSeq (\(Name x) (Name y)-> All $ x `T.isInfixOf` y)
                        (All True) (All $ Seq.length spqn == 1 && Seq.length iqn < 2)
                        iqn spqn)

   -- scPipes = selectFromScope
   --   (\k _ -> rawName `T.isInfixOf` showName k)
   --   <$> mScope
   --   & fromMaybe mempty
   --   & restrictByPartPipe inputPartPipe
bifoldSeq :: Monoid m => (a -> b -> m) -> m -> m -> Seq a -> Seq b -> m
bifoldSeq f z m xs' ys' = go xs' ys' z
  where
    go Seq.Empty  Seq.Empty  acc = acc
    go Seq.Empty  _          _   = m
    go _          Seq.Empty  _   = m
    go (x :<| xs) (y :<| ys) acc = go xs ys (acc <> f x y)

presentAcceptable
  :: (MonadFix m, MonadHold t m, PostBuild t m, MonadNodeId m, Reflex t)
  => Dynamic t PipePresentCtx
  -> Behavior t Bool
  -> Acceptable
  -> VtyWidget t m Acceptable
presentAcceptable ppcD focusB x = row (present x >> pure x)
 where
   present x = case x of
     APipe sp -> do
       let justNameLSigR = -- XXX: clearly subopt to do this here
             ppcB <&> \PipePresentCtx{..} ->
               withSomePipe sp
                 \(Pipe pd _) ->
                   (,)
                   (T.justifyRight (unWidth ppcName) ' ' . showName $ pdName pd)
                   (T.justifyLeft  (unWidth ppcSig)  ' ' . showSig  $ pdSig  pd)
       fixed (T.length . leftPad <$> ppcD) $
         richText (richTextFocusConfigDef focusB)
           (ppcB <&> leftPad)
       fixed (unWidth . ppcName <$> ppcD) $
         richText (richTextFocusConfig (foregro V.green) focusB) $
           fst <$> justNameLSigR
       fixed (T.length . ppcSep <$> ppcD) $
         richText (richTextFocusConfigDef focusB)
           (ppcB <&> ppcSep)
       fixed (unWidth . ppcSig <$> ppcD) $
         richText (richTextFocusConfig (foregro V.blue) focusB) $
           snd <$> justNameLSigR
     AScope scope -> do
       fixed (T.length . leftPad <$> ppcD) $
         richText (richTextFocusConfigDef focusB)
           (ppcB <&> leftPad)
       fixed (unWidth . ppcName <$> ppcD) $
         richText (richTextFocusConfig (foregro V.yellow) focusB)
           (ppcB <&> \PipePresentCtx{..} ->
             T.justifyRight (unWidth ppcName) ' ' (showQName scope))
       fixed (T.length . ppcSep <$> ppcD) $
         richText (richTextFocusConfigDef focusB)
           (ppcB <&> ppcSep)
       -- fixed (unWidth . ppcSig <$> ppcD) $
       --   richText (richTextFocusConfig (foregro V.blue) focusB)
       --     (pure . pack . show $ scopeSize scope)
   ppcB = current ppcD
   leftPad PipePresentCtx{..} =
     T.replicate (unWidth ppcReserved `div` 2) " "

data PipePresentCtx =
  PipePresentCtx
  { ppcFull     :: !Width
  , ppcSep      :: !Text
  , ppcReserved :: !Width
  , ppcName     :: !Width
  , ppcSig      :: !Width
  }

mkPipePresentCtx :: Text -> Width -> [Acceptable] -> PipePresentCtx
mkPipePresentCtx sep selrWidth xs =
  PipePresentCtx { ppcSep = sep, ..}
 where
   ppcReserved = Width $ T.length sep + 2
   ppcName     = Width $ Prelude.maximum . (T.length . acceptablePresent <$>) $ xs
   ppcSig      = ppcFull - ppcReserved - ppcName
   ppcFull     = selrWidth
