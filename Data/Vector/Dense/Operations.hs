{-# OPTIONS_GHC -fglasgow-exts #-}
-----------------------------------------------------------------------------
-- |
-- Module     : Data.Vector.Dense.Operations
-- Copyright  : Copyright (c) 2008, Patrick Perry <patperry@stanford.edu>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@stanford.edu>
-- Stability  : experimental
--

module Data.Vector.Dense.Operations (
    -- * Vector norms and inner products
    -- ** Pure
    sumAbs,
    norm2,
    whichMaxAbs,
    (<.>),
    
    -- * Vector arithmetic
    -- ** Pure
    shift,
    scale,
    sum,
    
    -- ** Impure
    getSum,
    
    ) where
  
import Control.Monad ( forM_ )
import Data.Vector.Dense.Internal
import BLAS.Tensor
import BLAS.Elem.Base ( Elem )
import qualified BLAS.Elem.Base as E

import Foreign ( Ptr )
import System.IO.Unsafe
import Unsafe.Coerce

import BLAS.Internal  ( inlinePerformIO, checkVecVecOp )
import BLAS.C hiding ( copy, swap, iamax, conj, axpy, acxpy )
import qualified BLAS.C as BLAS
import qualified BLAS.C.Types as T

infixl 7 <.>




-- | Computes the sum of two vectors.
getSum :: (BLAS1 e) => e -> DVector s n e -> e -> DVector t n e -> IO (DVector r n e)
getSum alpha x beta y = checkVecVecOp "getSum" (dim x) (dim y) $ unsafeGetSum alpha x beta y

unsafeGetSum :: (BLAS1 e) => e -> DVector s n e -> e -> DVector t n e -> IO (DVector r n e)
unsafeGetSum 1 x beta y
    | beta /= 1 = unsafeGetSum beta y 1 x
unsafeGetSum alpha x beta y
    | isConj x = do
        s <- unsafeGetSum (E.conj alpha) (conj x) (E.conj beta) (conj y)
        return (conj s)
    | otherwise = do
        s <- newCopy y
        scaleBy beta (unsafeThaw s)
        axpy alpha x (unsafeThaw s)
        return (unsafeCoerce s)
            



sum :: (BLAS1 e) => e -> Vector n e -> e -> Vector n e -> Vector n e
sum alpha x beta y = unsafePerformIO $ getSum alpha x beta y
{-# NOINLINE sum #-}


{-# RULES
"scale/plus"   forall k l x y. plus (scale k x) (scale l y) = add k x l y
"scale1/plus"  forall k x y.   plus (scale k x) y = add k x 1 y
"scale2/plus"  forall k x y.   plus x (scale k y) = add 1 x k y

"scale/minus"  forall k l x y. minus (scale k x) (scale l y) = add k x (-l) y
"scale1/minus" forall k x y.   minus (scale k x) y = add k x (-1) y
"scale2/minus" forall k x y.   minus x (scale k y) = add 1 x (-k) y
  #-}
  