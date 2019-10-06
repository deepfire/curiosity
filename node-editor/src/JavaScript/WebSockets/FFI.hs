{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE JavaScriptFFI #-}
{-# OPTIONS_HADDOCK hide #-}

module JavaScript.WebSockets.FFI (
  -- * Types
    Socket
  , Waiter
  , ConnectionQueue
  , ConnectionWaiters
  , WaiterKilled
    -- * FFI
  , ws_newSocket
  , ws_closeSocket
  , ws_socketSend
  , ws_awaitConn
  , ws_clearWaiters
  , ws_clearQueue
  , ws_handleOpen
  , ws_handleClose
  , ws_readyState
  ) where

import Prelude
import Data.Text   (Text)

#ifdef ghcjs_HOST_OS
import JavaScript.Array (MutableJSArray)
import GHCJS.Buffer (Buffer)
import GHCJS.DOM.Types (ArrayBuffer, JSString, JSVal)
import GHCJS.Types (JSString, JSVal)
type JSObject = JSVal
type JSBool = JSVal
#else
import JavaScript.NoGHCJS
#endif

data Socket_
type Socket = JSVal

data Waiter_
type Waiter = JSVal

type WaiterKilled = JSVal

type ConnectionQueue = MutableJSArray
type ConnectionWaiters = MutableJSArray

type WSCloseEvent = JSVal

#ifdef ghcjs_HOST_OS
foreign import javascript unsafe "$1.close();"
  ws_closeSocket :: Socket -> IO ()

foreign import javascript unsafe "$1.send($2);"
  ws_socketSend :: Socket -> ArrayBuffer -> IO ()

foreign import javascript interruptible "$1.onopen = function() { $c($1); };"
  ws_handleOpen :: Socket -> IO Socket

foreign import javascript unsafe  "var ws = new WebSocket($1);\
                                   ws.binaryType = 'arraybuffer';\
                                   ws.onmessage = function(e) {\
                                     if (!(typeof e === 'undefined')) {\
                                       if (window.ws_debug) {\
                                         console.log(e);\
                                       };\
                                       $2.push(e.data);\
                                       if ($3.length > 0) {\
                                         var e0 = $2.shift();\
                                         var found = false;\
                                         while ($3.length > 0 && !found) {\
                                           var w0 = $3.shift();\
                                           found = w0(e0);\
                                         };\
                                         if (!found) {\
                                           $2.unshift(e0);\
                                         };\
                                       };\
                                     }\
                                   };\
                                   $r = ws;"
  ws_newSocket :: JSString -> ConnectionQueue -> ConnectionWaiters -> IO Socket

foreign import javascript interruptible  "if ($1.length > 0) {\
                                            var d = $1.shift();\
                                            $c(d);\
                                          } else {\
                                            $2.push(function(d) {\
                                              if ($3.k) {\
                                                return false;\
                                              } else {\
                                                $c(d);\
                                                return true;\
                                              };\
                                            });\
                                          }"
  ws_awaitConn :: ConnectionQueue -> ConnectionWaiters -> WaiterKilled -> IO ArrayBuffer

foreign import javascript unsafe "while ($1.length > 0) {\
                                    var w0 = $1.shift();\
                                    w0(null);\
                                  };"
  ws_clearWaiters :: ConnectionWaiters -> IO ()

foreign import javascript unsafe "while ($1.length > 0) { $1.shift(); };"
  ws_clearQueue :: ConnectionQueue -> IO ()

foreign import javascript interruptible  "$1.onclose = function (e) { $c(e); };"
  ws_handleClose :: Socket -> IO WSCloseEvent

foreign import javascript unsafe "$1.readyState"
  ws_readyState :: Socket -> IO Int
#else

ws_closeSocket :: Socket -> IO ()
ws_socketSend :: Socket -> JSString -> IO ()
ws_handleOpen :: Socket -> IO Socket
ws_newSocket :: JSString -> ConnectionQueue -> ConnectionWaiters -> IO Socket
ws_awaitConn :: ConnectionQueue -> ConnectionWaiters -> WaiterKilled -> IO JSVal
ws_clearWaiters :: ConnectionWaiters -> IO ()
ws_clearQueue :: ConnectionQueue -> IO ()
ws_handleClose :: Socket -> IO WSCloseEvent
ws_readyState :: Socket -> IO Int

ws_closeSocket = error "ws_closeSocket: only available in JavaScript"
ws_socketSend = error "ws_socketSend: only available in JavaScript"
ws_handleOpen = error "ws_handleOpen: only available in JavaScript"
ws_newSocket = error "ws_newSocket: only available in JavaScript"
ws_awaitConn = error "ws_awaitConn: only available in JavaScript"
ws_clearWaiters = error "ws_clearWaiters: only available in JavaScript"
ws_clearQueue = error "ws_clearQueue: only available in JavaScript"
ws_handleClose = error "ws_handleClose: only available in JavaScript"
ws_readyState = error "ws_readyState: only available in JavaScript"

#endif
