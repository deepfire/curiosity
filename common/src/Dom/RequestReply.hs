module Dom.RequestReply (module Dom.RequestReply) where

import qualified Data.Text                        as Text
import           GHC.Generics                       (Generic)
import qualified Options.Applicative              as Opt
import           Options.Applicative         hiding (Parser)

import Basis
import Data.Parsing
import Data.IntUnique

import Dom.Expr
import Dom.Error
import Dom.Located
import Dom.Name
import Dom.Pipe
import Dom.Pipe.EPipe
import Dom.SomeValue

import Ground.Expr
import Ground.Table


--------------------------------------------------------------------------------
-- | Request/Reply:  asks with expectance of certain type of reply.
--
data Request n
  = Run
    { reqExpr :: Expr n }
  | Let
    { reqName :: QName Pipe
    , reqExpr :: Expr n
    }
  deriving (Generic)
  deriving (Show) via (Quiet (Request n))

type StandardRequest = (Unique, Request (Located (QName Pipe)))
type StandardReply   = (Unique, Either EPipe SomeValue)

--------------------------------------------------------------------------------
-- * Parsing
--
parseGroundRequest :: Maybe Int -> Text -> PFallible StandardRequest
parseGroundRequest mTokenPos s =
  EParse +++ (unsafeCoerceUnique 0,) $
  parseExprWithToken parseQName'
    (parseRequest parseSomeValueLiteral)
    (mTokenPos <|> Just (Text.length s - 1)) s

parseRequest ::
     Parser SomeValue
  -> Parser n
  -> Parser (Either Text (Request n))
parseRequest lit name =
  try (parseLet lit name <* eof)
  <|>  parseRun lit name

parseRun ::
     Parser SomeValue
  -> Parser n
  -> Parser (Either Text (Request n))
parseRun litP nameP =
  fmap Run <$> parseExpr litP nameP

parseLet ::
     Parser SomeValue
  -> Parser n
  -> Parser (Either Text (Request n))
parseLet litP nameP = do
  name <- parseQName
  _    <- token (string "=")
  expr <- parseExpr litP nameP
  pure $ Let name <$> expr

cliRequest :: Opt.Parser (Request (Located (QName Pipe)))
cliRequest = subparser $ mconcat
  [ cmd "run" $
    Run
      <$> pipedesc
  , cmd "let" $
    Let
      <$> (QName <$> argument auto (metavar "NAME"))
      <*> pipedesc
  ]
  where
    cmd name p = command name $ info (p <**> helper) mempty
    pipedesc = argument (eitherReader
                          (bimap (Text.unpack . showError . unEPipe) id
                           . parseGroundExpr Nothing . pack))
               (metavar "PIPEDESC")

--------------------------------------------------------------------------------
-- | Serialise instances
--
tagRequest, tagReply :: Word
tagRequest   = 31--415926535
tagReply     = 27--182818284

instance (Serialise n, Typeable n) => Serialise (Request n) where
  encode x = case x of
    Run e -> encodeListLen 2 <> encodeWord (tagRequest + 0) <> encode e
    Let n e -> encodeListLen 3 <> encodeWord (tagRequest + 1) <> encode n <> encode e
  decode = do
    len <- decodeListLen
    tag <- decodeWord
    case (len, tag) of
      (2, 31) -> Run <$> decode
      (3, 32) -> Let <$> decode <*> decode
      _ -> failLenTag len tag

failLenTag :: forall s a. Typeable a => Int -> Word -> Decoder s a
failLenTag len tag = fail $ "invalid "<>show (typeRep @a)<>" encoding: len="<>show len<>" tag="<>show tag
