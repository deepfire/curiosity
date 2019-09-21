{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeInType                 #-}
module Data.Dict
  ( Dict(..)
  , Dicts(..)
  , Data.Dict.lookup
  , link
  )
where

import           Codec.Serialise
import           Data.Kind                          (Constraint, Type)
import qualified Data.Map                         as Map
import           Data.Proxy                         (Proxy(..))
import           Data.Typeable                      (Typeable)
import           Type.Reflection                    (SomeTypeRep, someTypeRep)
import qualified Type.Reflection.Unsafe           as Unsafe


data Dict  (c :: Type -> Constraint) =
  forall a. (c a, Typeable a) =>
  Dict (Proxy a)

data Dicts (c :: Type -> Constraint) =
  Dicts (Map.Map SomeTypeRep (Dict c))

lookup :: forall (c :: Type -> Constraint). Dicts c -> SomeTypeRep -> Maybe (Dict c)
lookup (Dicts ds) = flip Map.lookup ds

link :: forall c a. (c a, Typeable a) => Proxy a -> (SomeTypeRep, Dict c)
link p = (someTypeRep p, Dict p)
