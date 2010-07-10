{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, Rank2Types,
        TypeFamilies #-}
{-# OPTIONS_HADDOCK hide #-}
-----------------------------------------------------------------------------
-- |
-- Module     : BLAS.Matrix.Base
-- Copyright  : Copyright (c) , Patrick Perry <patperry@gmail.com>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@gmail.com>
-- Stability  : experimental
--

module BLAS.Matrix.Base
    where

import Control.Monad( forM_ )
import Control.Monad.ST
import Data.AEq( AEq(..) )
import Data.Typeable( Typeable )
import Foreign( peekElemOff )
import Text.Printf( printf )
import Unsafe.Coerce( unsafeCoerce )

import BLAS.Elem
import BLAS.Internal( inlinePerformIO )

import BLAS.Types
import BLAS.Vector
import BLAS.Vector.STBase

import BLAS.Matrix.STBase


-- | Immutable dense matrices. The type arguments are as follows:
--
--     * @e@: the element type of the matrix.
--
newtype Matrix e = Matrix { unMatrix :: STMatrix RealWorld e }
    deriving (RMatrix, Typeable)

instance HasVectorView Matrix where
    type VectorView Matrix = Vector

-- | A safe way to create and work with a mutable matrix before returning 
-- an immutable matrix for later perusal. This function avoids copying
-- the matrix before returning it - it uses 'unsafeFreezeMatrix' internally,
-- but this wrapper is a safe interface to that function. 
runMatrix :: (forall s . ST s (STMatrix s e)) -> Matrix e
runMatrix mx = runST $ mx >>= unsafeFreezeMatrix
{-# INLINE runMatrix #-}

-- | Converts a mutable matrix to an immutable one by taking a complete
-- copy of it.
freezeMatrix :: (Storable e) => STMatrix s e -> ST s (Matrix e)
freezeMatrix = fmap Matrix . unsafeCoerce . newCopyMatrix
{-# INLINE freezeMatrix #-}

-- | Converts a mutable matrix into an immutable matrix. This simply casts
-- the matrix from one type to the other without copying the matrix.
--
-- Note that because the matrix is possibly not copied, any subsequent
-- modifications made to the mutable version of the matrix may be shared with
-- the immutable version. It is safe to use, therefore, if the mutable
-- version is never modified after the freeze operation.
unsafeFreezeMatrix :: STMatrix s e -> ST s (Matrix e)
unsafeFreezeMatrix = return . Matrix . unsafeCoerce
{-# INLINE unsafeFreezeMatrix #-}

-- | Converts an immutable matrix to a mutable one by taking a complete
-- copy of it.
thawMatrix :: (Storable e) => Matrix e -> ST s (STMatrix s e)
thawMatrix = newCopyMatrix
{-# INLINE thawMatrix #-}

-- | Converts an immutable matrix into a mutable matrix. This simply casts
-- the matrix from one type to the other without copying the matrix.
--
-- Note that because the matrix is possibly not copied, any subsequent
-- modifications made to the mutable version of the matrix may be shared with
-- the immutable version. It is only safe to use, therefore, if the immutable
-- matrix is never referenced again in this thread, and there is no
-- possibility that it can be also referenced in another thread.
unsafeThawMatrix :: Matrix e -> ST s (STMatrix s e)
unsafeThawMatrix = return . unsafeCoerce . unMatrix
{-# INLINE unsafeThawMatrix #-}

-- | Create a matrix with the given dimension and elements.  The elements
-- given in the association list must all have unique indices, otherwise
-- the result is undefined.
--
-- Not every index within the bounds of the matrix need appear in the
-- association list, but the values associated with indices that do not
-- appear will be undefined.
matrix :: (Storable e) => (Int,Int) -> [((Int,Int), e)] -> Matrix e
matrix mn ies = runMatrix $ do
    a <- newMatrix_ mn
    setAssocsMatrix a ies
    return a
{-# INLINE matrix #-}

-- | Same as 'matrix', but does not range-check the indices.
unsafeMatrix :: (Storable e) => (Int,Int) -> [((Int,Int), e)] -> Matrix e
unsafeMatrix mn ies = runMatrix $ do
    a <- newMatrix_ mn
    unsafeSetAssocsMatrix a ies
    return a
{-# INLINE unsafeMatrix #-}

-- | Create a matrix of the given dimension with elements initialized
-- to the values from the list, in column major order.
listMatrix :: (Storable e) => (Int,Int) -> [e] -> Matrix e
listMatrix mn es = runMatrix $ do
    a <- newMatrix_ mn
    setElemsMatrix a es
    return a
{-# INLINE listMatrix #-}

-- | Create a matrix of the given dimension with all elements initialized
-- to the given value
constantMatrix :: (Storable e) => (Int,Int) -> e -> Matrix e
constantMatrix mn e = runMatrix $ newMatrix mn e
{-# INLINE constantMatrix #-}

-- | Returns the element of a matrix at the specified index.
atMatrix :: (Storable e) => Matrix e -> (Int,Int) -> e
atMatrix a ij@(i,j)
    | i < 0 || i >= m || j < 0 || j >= n = error $
        printf ("atMatrix <matrix with dim (%d,%d)> (%d,%d):"
                ++ " invalid index") m n i j
    | otherwise =
        unsafeAtMatrix a ij
  where
      (m,n) = dimMatrix a
{-# INLINE atMatrix #-}

unsafeAtMatrix :: (Storable e) => Matrix e -> (Int,Int) -> e
unsafeAtMatrix (Matrix (STMatrix a _ _ lda)) (i,j) = inlinePerformIO $ 
    unsafeWithVector a $ \p ->
        peekElemOff p (i + j * lda)
{-# INLINE unsafeAtMatrix #-}

-- | Returns a list of the elements of a matrix, in the same order as their
-- indices.
elemsMatrix :: (Storable e) => Matrix e -> [e]
elemsMatrix a = concatMap elemsVector (colsMatrix a)
{-# INLINE elemsMatrix #-}

-- | Returns the contents of a matrix as a list of associations.
assocsMatrix :: (Storable e) => Matrix e -> [((Int,Int),e)]
assocsMatrix x = zip (indicesMatrix x) (elemsMatrix x)
{-# INLINE assocsMatrix #-}

unsafeReplaceMatrix :: (Storable e) => Matrix e -> [((Int,Int),e)] -> Matrix e
unsafeReplaceMatrix a ies = runMatrix $ do
    a' <- newCopyMatrix a
    unsafeSetAssocsMatrix a' ies
    return a'

-- | Create a new matrix by replacing the values at the specified indices.
replaceMatrix :: (Storable e) => Matrix e -> [((Int,Int),e)] -> Matrix e
replaceMatrix a ies = runMatrix $ do
    a' <- newCopyMatrix a
    setAssocsMatrix a' ies
    return a'

-- | @accumMatrix f@ takes a matrix and an association list and accumulates
-- pairs from the list into the matrix with the accumulating function @f@.
accumMatrix :: (Storable e)
            => (e -> e' -> e) 
            -> Matrix e
            -> [((Int,Int), e')]
            -> Matrix e
accumMatrix f a ies = runMatrix $ do
    a' <- newCopyMatrix a
    forM_ ies $ \(i,new) -> do
        old <- readMatrix a' i
        unsafeWriteMatrix a' i (f old new) -- index checked on prev. line
    return a'

-- | Same as 'accumMatrix' but does not range-check indices.
unsafeAccumMatrix :: (Storable e)
                  => (e -> e' -> e)
                  -> Matrix e
                  -> [((Int,Int), e')]
                  -> Matrix e
unsafeAccumMatrix f a ies = runMatrix $ do
    a' <- newCopyMatrix a
    forM_ ies $ \(i,new) -> do
        old <- unsafeReadMatrix a' i
        unsafeWriteMatrix a' i (f old new)
    return a'

instance (Storable e, Show e) => Show (Matrix e) where
    show x = "listMatrix " ++ show (dimMatrix x) ++ " " ++ show (elemsMatrix x)
    {-# INLINE show #-}

instance (Storable e, Eq e) => Eq (Matrix e) where
    (==) = compareMatrixWith (==)
    {-# INLINE (==) #-}

instance (Storable e, AEq e) => AEq (Matrix e) where
    (===) = compareMatrixWith (===)
    {-# INLINE (===) #-}
    (~==) = compareMatrixWith (~==)
    {-# INLINE (~==) #-}

-- | @shiftMatrix k a@ returns @k + a@.
shiftMatrix :: (VNum e) => e -> Matrix e -> Matrix e
shiftMatrix k = resultMatrix $ shiftToMatrix k

-- | @shiftDiagMatrix d a@ returns @diag(d) + a@.
shiftDiagMatrix :: (BLAS1 e) => Vector e -> Matrix e -> Matrix e
shiftDiagMatrix s = resultMatrix $ shiftDiagToMatrix s

-- | @shiftDiagMatrixWithScale alpha d a@ returns @alpha * diag(d) + a@.
shiftDiagMatrixWithScale :: (BLAS1 e) => e -> Vector e -> Matrix e -> Matrix e
shiftDiagMatrixWithScale e s = resultMatrix $ shiftDiagToMatrixWithScale e s

-- | @addMatrix a b@ returns @a + b@.
addMatrix :: (VNum e) => Matrix e -> Matrix e -> Matrix e
addMatrix = resultMatrix2 addToMatrix

-- | @addMatrixWithScale alpha a beta b@ returns @alpha*a + beta*b@.
addMatrixWithScale :: (VNum e) => e -> Matrix e -> e -> Matrix e -> Matrix e
addMatrixWithScale alpha a beta b =
    (resultMatrix2 $ \a' b' -> addToMatrixWithScale alpha a' beta b') a b

-- | @subMatrix a b@ returns @a - b@.
subMatrix :: (VNum e) => Matrix e -> Matrix e -> Matrix e
subMatrix = resultMatrix2 subToMatrix

-- | @scaleMatrix k a@ returns @k * a@.
scaleMatrix :: (VNum e) => e -> Matrix e -> Matrix e
scaleMatrix k = resultMatrix $ scaleToMatrix k

-- | @scaleRowsMatrix s a@ returns @diag(s) * a@.
scaleRowsMatrix :: (VNum e) => Vector e -> Matrix e -> Matrix e
scaleRowsMatrix s = resultMatrix $ scaleRowsToMatrix s

-- | @scaleColsMatrix s a@ returns @a * diag(s)@.
scaleColsMatrix :: (VNum e) => Vector e -> Matrix e -> Matrix e
scaleColsMatrix s = resultMatrix $ scaleColsToMatrix s

-- | @negateMatrix a@ returns @-a@.
negateMatrix :: (VNum e) => Matrix e -> Matrix e
negateMatrix = resultMatrix negateToMatrix


compareMatrixWith :: (Storable e, Storable e')
                  => (e -> e' -> Bool)
                  -> Matrix e
                  -> Matrix e'
                  -> Bool
compareMatrixWith cmp a a' =
    dimMatrix a == dimMatrix a'
    && and (zipWith cmp (elemsMatrix a) (elemsMatrix a'))
{-# INLINE compareMatrixWith #-}

resultMatrix :: (Storable f)
             => (forall s . Matrix e -> STMatrix s f -> ST s a)
             -> Matrix e
             -> Matrix f
resultMatrix f a = runMatrix $ newResultMatrix f a
{-# INLINE resultMatrix #-}

resultMatrix2 :: (Storable g)
              => (forall s . Matrix e -> Matrix f -> STMatrix s g -> ST s a)
              -> Matrix e
              -> Matrix f
              -> Matrix g
resultMatrix2 f a1 a2 = runMatrix $ newResultMatrix2 f a1 a2
{-# INLINE resultMatrix2 #-}