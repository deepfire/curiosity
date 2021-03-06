module Debug.TraceErr
  ( traceHandle
  , traceHandleM
  , traceErr
  , traceIOErr
  )
where

import Data.List (partition)

import Control.Monad (unless)
import Foreign.C.String as Foreign
import System.IO.Unsafe as Unsafe
import System.IO as IO


traceHandle :: Handle -> String -> a -> a
traceHandle h string expr = Unsafe.unsafePerformIO $ do
    hPutStrLn h string
    return expr

traceHandleM :: Applicative f => Handle -> String -> f ()
traceHandleM h string = traceHandle h string $ pure ()

traceErr :: String -> a -> a
traceErr string expr = Unsafe.unsafePerformIO $ do
    traceIOErr string
    return expr

foreign import ccall unsafe "HsBase.h debugBelch2"
   debugBelch :: Foreign.CString -> Foreign.CString -> IO ()

traceIOErr :: String -> IO ()
traceIOErr msg =
    Foreign.withCString "%s\n" $ \cfmt -> do
     -- NB: debugBelch can't deal with null bytes, so filter them
     -- out so we don't accidentally truncate the message.  See Trac #9395
     let (nulls, msg') = partition (=='\0') msg
     Foreign.withCString msg' $ \cmsg ->
      debugBelch cfmt cmsg
     unless (null nulls) $
       Foreign.withCString "WARNING: previous trace message had null bytes" $ \cmsg ->
         debugBelch cfmt cmsg
