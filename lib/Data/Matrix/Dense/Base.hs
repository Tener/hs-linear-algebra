{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts, FlexibleInstances,
        TypeFamilies, Rank2Types, ScopedTypeVariables #-}
{-# OPTIONS_HADDOCK hide #-}
-----------------------------------------------------------------------------
-- |
-- Module     : Data.Matrix.Dense.Base
-- Copyright  : Copyright (c) , Patrick Perry <patperry@stanford.edu>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@stanford.edu>
-- Stability  : experimental
--

module Data.Matrix.Dense.Base
    where

import Control.Monad
import Control.Monad.ST
import Data.AEq
import Foreign
import System.IO.Unsafe
import Unsafe.Coerce

import BLAS.Internal( checkBinaryOp, checkedSubmatrix, checkedDiag,
    checkedRow, checkedCol, inlinePerformIO )

import Data.Elem.BLAS( Elem, BLAS1, BLAS3, conjugate )
import qualified Data.Elem.BLAS.Level1 as BLAS
import qualified Data.Elem.BLAS.Level2 as BLAS
import qualified Data.Elem.BLAS.Level3 as BLAS

import Data.Tensor.Class
import Data.Tensor.Class.ITensor
import Data.Tensor.Class.MTensor

import Data.Matrix.Class
import Data.Matrix.Herm
import Data.Matrix.TriBase

import Data.Vector.Dense.IOBase
import Data.Vector.Dense.Base

import Data.Matrix.Dense.IOBase

-- | Immutable dense matrices.  The type arguments are as follows:
--
--     * @np@: a phantom type for the shape of the matrix.  Most functions
--       will demand that this be specified as a pair.  When writing a function
--       signature, you should always prefer @Matrix (n,p) e@ to
--       @Matrix np e@.
--
--     * @e@: the element type of the matrix.  Only certain element types
--       are supported.
--
newtype Matrix np e = Matrix (IOMatrix np e)

freezeIOMatrix :: (BLAS1 e) => IOMatrix np e -> IO (Matrix np e)
freezeIOMatrix x = do
    y <- newCopyIOMatrix x
    return (Matrix y)

thawIOMatrix :: (BLAS1 e) => Matrix np e -> IO (IOMatrix np e)
thawIOMatrix (Matrix x) =
    newCopyIOMatrix x

unsafeFreezeIOMatrix :: IOMatrix np e -> IO (Matrix np e)
unsafeFreezeIOMatrix = return . Matrix

unsafeThawIOMatrix :: Matrix np e -> IO (IOMatrix np e)
unsafeThawIOMatrix (Matrix x) = return x

-- | Common functionality for all dense matrix types.
class (HasVectorView a, Elem e, MatrixShaped a
      , BaseVector (VectorView a) e) => BaseMatrix a e where
          
    ldaMatrix :: a (n,p) e -> Int
    isHermMatrix :: a (n,p) e -> Bool

    -- | Cast the shape type of the matrix.
    coerceMatrix :: a np e -> a np' e
    coerceMatrix = unsafeCoerce
    {-# INLINE coerceMatrix #-}

    unsafeSubmatrixView :: a (n,p) e -> (Int,Int) -> (Int,Int) -> a (n',p') e
    unsafeDiagView :: a (n,p) e -> Int -> VectorView a k e
    unsafeRowView :: a (n,p) e -> Int -> VectorView a p e
    unsafeColView :: a (n,p) e -> Int -> VectorView a n e

    -- | Possibly create a vector view of a matrix.  This will fail if the
    -- matrix is hermed or if the lda of the matrix is not equal to the
    -- number of rows in the matrix.
    maybeViewMatrixAsVector :: a (n,p) e -> Maybe (VectorView a np e)
    
    -- | Possibly create a matrix view of a row vector.  This will fail if
    -- the stride of the vector is not @1@ or the vector is conjugated.
    maybeViewVectorAsRow  :: VectorView a p e -> Maybe (a (one,p) e)
    
    -- | Possibly create a matrix view of a column vector.  This will fail
    -- if the stride of the vector is not @1@ or the vector is not conjugated.
    maybeViewVectorAsCol  :: VectorView a n e -> Maybe (a (n,one) e)
    
    -- | Possible create a matrix view of the vector.  This will fail if
    -- the stride of the vector is not @1@ or the vector is conjugated.
    -- An error will be called if the vector does not have the same number
    -- of elements as the desired matrix.
    maybeViewVectorAsMatrix :: (Int,Int) 
                            -> VectorView a np e 
                            -> Maybe (a (n,p) e)
    
    -- | Unsafe cast from a matrix to an 'IOMatrix'.
    unsafeMatrixToIOMatrix :: a (n,p) e -> IOMatrix (n,p) e
    unsafeIOMatrixToMatrix :: IOMatrix (n,p) e -> a (n,p) e


-- | Dense matrices that can be read in a monad.
class (BaseMatrix a e, BLAS3 e, ReadTensor a (Int,Int) e m
      , MMatrix a e m, MMatrix (Herm a) e m, MMatrix (Tri a) e m
      , MSolve (Tri a) e m
      , ReadVector (VectorView a) e m) => ReadMatrix a e m where

    -- | Cast the matrix to an 'IOMatrix', perform an @IO@ action, and
    -- convert the @IO@ action to an action in the monad @m@.  This
    -- operation is /very/ unsafe.
    unsafePerformIOWithMatrix :: a (n,p) e -> (IOMatrix (n,p) e -> IO r) -> m r

    -- | Convert a mutable matrix to an immutable one by taking a complete
    -- copy of it.
    freezeMatrix :: a (n,p) e -> m (Matrix (n,p) e)
    unsafeFreezeMatrix :: a (n,p) e -> m (Matrix (n,p) e)

-- | Dense matrices that can be created or modified in a monad.
class (ReadMatrix a e m, WriteTensor a (Int,Int) e m
      , WriteVector (VectorView a) e m) =>
    WriteMatrix a e m where

    -- | Creates a new matrix of the given shape.  The elements will be 
    -- uninitialized.
    newMatrix_ :: (Int,Int) -> m (a (n,p) e)

    -- | Unsafely convert an 'IO' action that creates an 'IOMatrix' into
    -- an action in @m@ that creates a matrix.
    unsafeConvertIOMatrix :: IO (IOMatrix (n,p) e) -> m (a (n,p) e)

    -- | Convert an immutable matrix to a mutable one by taking a complete
    -- copy of it.
    thawMatrix :: Matrix (n,p) e -> m (a (n,p) e)
    unsafeThawMatrix :: Matrix (n,p) e -> m (a (n,p) e)

-- | Creates a new matrix with the given association list.  Unspecified
-- indices will get initialized to zero.
newMatrix :: (WriteMatrix a e m) =>
    (Int,Int) -> [((Int,Int), e)] -> m (a (n,p) e)
newMatrix (m,n) ies = unsafeConvertIOMatrix $ do
    a <- newZeroMatrix (m,n)
    withIOMatrix a $ \p ->
        forM_ ies $ \((i,j),e) -> do
            when (i < 0 || i >= m || j < 0 || j >= n) $ fail $
                "Index `" ++ show (i,j) ++ 
                    "' is invalid for a matrix with shape `" ++ show (m,n) ++
                    "'"
            pokeElemOff p (i+j*m) e
    return a
{-# INLINE newMatrix #-}
    
unsafeNewMatrix :: (WriteMatrix a e m) =>
    (Int,Int) -> [((Int,Int), e)] -> m (a (n,p) e)
unsafeNewMatrix (m,n) ies = unsafeConvertIOMatrix $ do
    a <- newZeroMatrix (m,n)
    withIOMatrix a $ \p ->
        forM_ ies $ \((i,j),e) -> do
            pokeElemOff p (i+j*m) e
    return a
{-# INLINE unsafeNewMatrix #-}

-- | Create a new matrix with the given elements in column-major order.
newListMatrix :: (WriteMatrix a e m) => (Int,Int) -> [e] -> m (a (n,p) e)
newListMatrix (m,n) es = do
    a <- newZeroMatrix (m,n)
    unsafePerformIOWithMatrix a $ \a' -> do
        withIOMatrix a' $ flip pokeArray (take (m*n) es)
        return a
{-# INLINE newListMatrix #-}

-- | Form a matrix from a list of column vectors.
newColsMatrix :: (ReadVector x e m, WriteMatrix a e m) =>
    (Int,Int) -> [x n e] -> m (a (n,p) e)
newColsMatrix (m,n) cs = do
    a <- newZeroMatrix (m,n)
    forM_ (zip [0..(n-1)] cs) $ \(j,c) ->
        unsafeCopyVector (unsafeColView a j) c
    return a
{-# INLINE newColsMatrix #-}

-- | Form a matrix from a list of row vectors.
newRowsMatrix :: (ReadVector x e m, WriteMatrix a e m) =>
    (Int,Int) -> [x p e] -> m (a (n,p) e)
newRowsMatrix (m,n) rs = do
    a <- newZeroMatrix (m,n)
    forM_ (zip [0..(m-1)] rs) $ \(i,r) ->
        unsafeCopyVector (unsafeRowView a i) r
    return a
{-# INLINE newRowsMatrix #-}

-- | Create a new matrix from a column vector.
newColMatrix :: (ReadVector x e m, WriteMatrix a e m) =>
    x n e -> m (a (n,one) e)
newColMatrix x = newColsMatrix (dim x,1) [x]
{-# INLINE newColMatrix #-}

-- | Create a new matrix from a row vector.
newRowMatrix :: (ReadVector x e m, WriteMatrix a e m) =>
    x p e -> m (a (one,p) e)
newRowMatrix x = newRowsMatrix (1,dim x) [x]
{-# INLINE newRowMatrix #-}

-- | Create a zero matrix of the specified shape.
newZeroMatrix :: (WriteMatrix a e m) => (Int,Int) -> m (a (n,p) e)
newZeroMatrix mn = do
    a <- newMatrix_ mn
    setZeroMatrix a
    return a
{-# INLINE newZeroMatrix #-}

-- | Set every element in the matrix to zero.
setZeroMatrix :: (WriteMatrix a e m) => a (n,p) e -> m ()
setZeroMatrix a =
    unsafePerformIOWithMatrix a $ setZeroIOMatrix
{-# INLINE setZeroMatrix #-}

-- | Create a constant matrix of the specified shape.
newConstantMatrix :: (WriteMatrix a e m) => (Int,Int) -> e -> m (a (n,p) e)
newConstantMatrix mn e = do
    a <- newMatrix_ mn
    setConstantMatrix e a
    return a
{-# INLINE newConstantMatrix #-}

-- | Set every element in the matrix to the given constant.
setConstantMatrix :: (WriteMatrix a e m) => e -> a (n,p) e -> m ()
setConstantMatrix e a =
    unsafePerformIOWithMatrix a $ setConstantIOMatrix e
{-# INLINE setConstantMatrix #-}

-- | Create a new matrix of the given shape with ones along the diagonal, 
-- and zeros everywhere else.
newIdentityMatrix :: (WriteMatrix a e m) => (Int,Int) -> m (a (n,p) e)
newIdentityMatrix mn = do
    a <- newMatrix_ mn
    setIdentityMatrix a
    return a
{-# INLINE newIdentityMatrix #-}

-- | Set diagonal elements to one and all other elements to zero.
setIdentityMatrix :: (WriteMatrix a e m) => a (n,p) e -> m ()
setIdentityMatrix a = do
    setZeroMatrix a
    setConstantVector 1 (unsafeDiagView a 0)
{-# INLINE setIdentityMatrix #-}

-- | Get a copy of a matrix.
newCopyMatrix :: (ReadMatrix a e m, WriteMatrix b e m) =>
    a (n,p) e -> m (b (n,p) e)
newCopyMatrix a | isHermMatrix a = liftM herm $ newCopyMatrix (herm a)
                | otherwise      = do
    b <- newMatrix_ (shape a)
    unsafeCopyMatrix b a
    return b
{-# INLINE newCopyMatrix #-}

-- | Get a copy of a matrix and make sure the returned matrix is not
-- a view.  Specififially, the returned matrix will have @isHermMatrix@
-- equal to @False@.
newCopyMatrix' :: (ReadMatrix a e m, WriteMatrix b e m) =>
    a (n,p) e -> m (b (n,p) e)
newCopyMatrix' a = do
    b <- newMatrix_ (shape a)
    unsafeCopyMatrix b a
    return b
{-# INLINE newCopyMatrix' #-}

-- | @copyMatrix dst src@ replaces the values in @dst@ with those in
-- source.  The operands must be the same shape.
copyMatrix :: (WriteMatrix b e m, ReadMatrix a e m) => 
    b (n,p) e -> a (n,p) e -> m ()
copyMatrix b a = checkBinaryOp (shape b) (shape a) $ unsafeCopyMatrix b a
{-# INLINE copyMatrix #-}

unsafeCopyMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()
unsafeCopyMatrix = liftMatrix2 unsafeCopyVector
{-# INLINE unsafeCopyMatrix #-}

-- | @swapMatrix x y@ swaps the values stored in two matrices.
swapMatrix :: (WriteMatrix a e m, WriteMatrix b e m) =>
    a (n,p) e -> b (n,p) e -> m ()
swapMatrix a b = checkBinaryOp (shape b) (shape a) $ unsafeSwapMatrix a b
{-# INLINE swapMatrix #-}

unsafeSwapMatrix :: (WriteMatrix a e m, WriteMatrix b e m) =>
    a (n,p) e -> b (n,p) e -> m ()
unsafeSwapMatrix = liftMatrix2 unsafeSwapVector
{-# INLINE unsafeSwapMatrix #-}

-- | Swap the elements in two rows of a matrix.
swapRows :: (WriteMatrix a e m) => a (n,p) e -> Int -> Int -> m ()
swapRows a i j = 
    when (i /= j) $ unsafeSwapVector (rowView a i) (rowView a j)
{-# INLINE swapRows #-}

-- | Swap the elements in two columns of a matrix.
swapCols :: (WriteMatrix a e m) => a (n,p) e -> Int -> Int -> m ()
swapCols a i j = 
    when (i /= j) $ unsafeSwapVector (colView a i) (colView a j)
{-# INLINE swapCols #-}

unsafeSwapRows :: (WriteMatrix a e m) => a (n,p) e -> Int -> Int -> m ()
unsafeSwapRows a i j = 
    when (i /= j) $ unsafeSwapVector (unsafeRowView a i) (unsafeRowView a j)
{-# INLINE unsafeSwapRows #-}

unsafeSwapCols :: (WriteMatrix a e m) => a (n,p) e -> Int -> Int -> m ()
unsafeSwapCols a i j = 
    when (i /= j) $ unsafeSwapVector (unsafeColView a i) (unsafeColView a j)
{-# INLINE unsafeSwapCols #-}

-- | @submatrixView a ij mn@ returns a view of the submatrix of @a@ with element @(0,0)@
-- being element @ij@ in @a@, and having shape @mn@.
submatrixView :: (BaseMatrix a e) => a (n,p) e -> (Int,Int) -> (Int,Int) -> a (n',p') e
submatrixView a = checkedSubmatrix (shape a) (unsafeSubmatrixView a)
{-# INLINE submatrixView #-}

-- | Divide the rows of a matrix into two blocks and return views into the
-- blocks.  The integer argument indicates how many rows should be in the
-- first block.
splitRowsAt :: (BaseMatrix a e) =>
    Int -> a (n,p) e -> (a (n1,p) e, a (n2,p) e)
splitRowsAt m1 a = ( submatrixView a (0,0)  (m1,n)
                   , submatrixView a (m1,0) (m2,n)
                   )
  where 
    (m,n) = shape a
    m2    = m - m1
{-# INLINE splitRowsAt #-}

unsafeSplitRowsAt :: (BaseMatrix a e) =>
    Int -> a (n,p) e -> (a (n1,p) e, a (n2,p) e)
unsafeSplitRowsAt m1 a = ( unsafeSubmatrixView a (0,0)  (m1,n)
                         , unsafeSubmatrixView a (m1,0) (m2,n)
                         )
  where 
    (m,n) = shape a
    m2    = m - m1
{-# INLINE unsafeSplitRowsAt #-}

-- | Divide the columns of a matrix into two blocks and return views into the
-- blocks.  The integer argument indicates how many columns should be in the
-- first block.
splitColsAt :: (BaseMatrix a e) =>
    Int -> a (n,p) e -> (a (n,p1) e, a (n,p2) e)
splitColsAt n1 a = ( submatrixView a (0,0)  (m,n1)
                   , submatrixView a (0,n1) (m,n2)
                   )
  where
    (m,n) = shape a
    n2    = n - n1
{-# INLINE splitColsAt #-}

unsafeSplitColsAt :: (BaseMatrix a e) =>
    Int -> a (n,p) e -> (a (n,p1) e, a (n,p2) e)
unsafeSplitColsAt n1 a = ( unsafeSubmatrixView a (0,0)  (m,n1)
                         , unsafeSubmatrixView a (0,n1) (m,n2)
                         )
  where
    (m,n) = shape a
    n2    = n - n1
{-# INLINE unsafeSplitColsAt #-}

-- | Get a list of vector views of the rows of the matrix.
rowViews :: (BaseMatrix a e) => a (n,p) e -> [VectorView a p e]
rowViews a = [ unsafeRowView a i | i <- [0..numRows a - 1] ]
{-# INLINE rowViews #-}

-- | Get a list of vector views of the columns of the matrix.
colViews :: (BaseMatrix a e) => a (n,p) e -> [VectorView a n e]
colViews a = [ unsafeColView a j | j <- [0..numCols a - 1] ]
{-# INLINE colViews #-}

-- | Get a vector view of the given row in a matrix.
rowView :: (BaseMatrix a e) => a (n,p) e -> Int -> VectorView a p e
rowView a = checkedRow (shape a) (unsafeRowView a)
{-# INLINE rowView #-}

unsafeGetRowMatrix :: (ReadMatrix a e m, WriteVector y e m) =>
    a (n,p) e -> Int -> m (y p e)
unsafeGetRowMatrix a i = newCopyVector (unsafeRowView a i)
{-# INLINE unsafeGetRowMatrix #-}

-- | Get a vector view of the given column in a matrix.
colView :: (BaseMatrix a e) => a (n,p) e -> Int -> VectorView a n e
colView a = checkedCol (shape a) (unsafeColView a)
{-# INLINE colView #-}

unsafeGetColMatrix :: (ReadMatrix a e m, WriteVector y e m) =>
    a (n,p) e -> Int -> m (y n e)
unsafeGetColMatrix a j = newCopyVector (unsafeColView a j)
{-# INLINE unsafeGetColMatrix #-}

-- | Get a vector view of the given diagonal in a matrix.
diagView :: (BaseMatrix a e) => a (n,p) e -> Int -> VectorView a k e
diagView a = checkedDiag (shape a) (unsafeDiagView a)
{-# INLINE diagView #-}

-- | Get the given diagonal in a matrix.  Negative indices correspond
-- to sub-diagonals.
getDiag :: (ReadMatrix a e m, WriteVector y e m) => 
    a (n,p) e -> Int -> m (y k e)
getDiag a = checkedDiag (shape a) (unsafeGetDiag a)
{-# INLINE getDiag #-}

-- | Same as 'getDiag' but not range-checked.
unsafeGetDiag :: (ReadMatrix a e m, WriteVector y e m) => 
    a (n,p) e -> Int -> m (y k e)
unsafeGetDiag a i = newCopyVector (unsafeDiagView a i)
{-# INLINE unsafeGetDiag #-}

-- | Conjugate every element of a matrix.
doConjMatrix :: (WriteMatrix a e m) => a (n,p) e -> m ()
doConjMatrix = liftMatrix doConjVector
{-# INLINE doConjMatrix #-}

-- | Get a new matrix with elements with the conjugates of the elements
-- of the given matrix.
getConjMatrix :: (ReadMatrix a e m, WriteMatrix b e m) =>
    a (n,p) e -> m (b (n,p) e)
getConjMatrix = getUnaryMatrixOp doConjMatrix
{-# INLINE getConjMatrix #-}

-- | Scale every element of a matrix by the given value.
scaleByMatrix :: (WriteMatrix a e m) => e -> a (n,p) e -> m ()
scaleByMatrix k = liftMatrix (scaleByVector k)
{-# INLINE scaleByMatrix #-}

-- | Get a new matrix by scaling the elements of another matrix
-- by a given value.
getScaledMatrix :: (ReadMatrix a e m, WriteMatrix b e m) =>
    e -> a (n,p) e -> m (b (n,p) e)
getScaledMatrix e = getUnaryMatrixOp (scaleByMatrix e)
{-# INLINE getScaledMatrix #-}

-- | Add a constant to every element in a matrix.
shiftByMatrix :: (WriteMatrix a e m) => e -> a (n,p) e -> m ()
shiftByMatrix k = liftMatrix (shiftByVector k)
{-# INLINE shiftByMatrix #-}

-- | Get a new matrix by shifting the elements of another matrix
-- by a given value.
getShiftedMatrix :: (ReadMatrix a e m, WriteMatrix b e m) =>
    e -> a (n,p) e -> m (b (n,p) e)
getShiftedMatrix e = getUnaryMatrixOp (shiftByMatrix e)
{-# INLINE getShiftedMatrix #-}

-- | Replace the first argument with the elementwise sum.
addMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()
addMatrix b a = 
    checkBinaryOp (shape b) (shape a) $ unsafeAddMatrix b a
{-# INLINE addMatrix #-}

unsafeAddMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()
unsafeAddMatrix b a = unsafeAxpyMatrix 1 a b
{-# INLINE unsafeAddMatrix #-}

-- | @getAddMatrix a b@ creates a new matrix equal to the sum @a+b@.  The 
-- operands must have the same shape.
getAddMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
getAddMatrix = checkMatrixOp2 unsafeGetAddMatrix
{-# INLINE getAddMatrix #-}

unsafeGetAddMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
unsafeGetAddMatrix = unsafeGetBinaryMatrixOp unsafeAddMatrix
{-# INLINE unsafeGetAddMatrix #-}

-- | Replace the first argument with the elementwise sum.
subMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()    
subMatrix b a = 
    checkBinaryOp (shape b) (shape a) $ unsafeSubMatrix b a
{-# INLINE subMatrix #-}

unsafeSubMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()
unsafeSubMatrix b a = unsafeAxpyMatrix (-1) a b
{-# INLINE unsafeSubMatrix #-}

-- | @getSubMatrix a b@ creates a new matrix equal to the difference @a-b@.  The 
-- operands must have the same shape.
getSubMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
getSubMatrix = checkMatrixOp2 unsafeGetSubMatrix
{-# INLINE getSubMatrix #-}

unsafeGetSubMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
unsafeGetSubMatrix = unsafeGetBinaryMatrixOp unsafeSubMatrix
{-# INLINE unsafeGetSubMatrix #-}

-- | @axpyMatrix a x y@ replaces @y := a x + y@.
axpyMatrix :: (ReadMatrix a e m, WriteMatrix b e m) =>
    e -> a (n,p) e -> b (n,p) e -> m ()
axpyMatrix alpha x y = 
    checkBinaryOp (shape x) (shape y) $ unsafeAxpyMatrix alpha x y
{-# INLINE axpyMatrix #-}

unsafeAxpyMatrix :: (ReadMatrix a e m, WriteMatrix b e m) =>
    e -> a (n,p) e -> b (n,p) e -> m ()
unsafeAxpyMatrix alpha = liftMatrix2 (unsafeAxpyVector alpha)
{-# INLINE unsafeAxpyMatrix #-}

-- | Replace the first argument with the elementwise product.
mulMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()    
mulMatrix b a = 
    checkBinaryOp (shape b) (shape a) $ unsafeMulMatrix b a
{-# INLINE mulMatrix #-}

unsafeMulMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()
unsafeMulMatrix = liftMatrix2 unsafeMulVector
{-# INLINE unsafeMulMatrix #-}

-- | @getMulMatrix a b@ creates a new matrix equal to the elementwise product 
-- @a*b@.  The operands must have the same shape.
getMulMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
getMulMatrix = checkMatrixOp2 unsafeGetMulMatrix
{-# INLINE getMulMatrix #-}

unsafeGetMulMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
unsafeGetMulMatrix = unsafeGetBinaryMatrixOp unsafeMulMatrix
{-# INLINE unsafeGetMulMatrix #-}

-- | Replace the first argument with the elementwise quotient.
divMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()    
divMatrix b a = 
    checkBinaryOp (shape b) (shape a) $ unsafeDivMatrix b a
{-# INLINE divMatrix #-}

unsafeDivMatrix :: (WriteMatrix b e m, ReadMatrix a e m) =>
    b (n,p) e -> a (n,p) e -> m ()
unsafeDivMatrix = liftMatrix2 unsafeDivVector
{-# INLINE unsafeDivMatrix #-}

-- | @getDivMatrix a b@ creates a new matrix equal to the elementwise ratio
-- @a/b@.  The operands must have the same shape.
getDivMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
getDivMatrix = checkMatrixOp2 unsafeGetDivMatrix
{-# INLINE getDivMatrix #-}

unsafeGetDivMatrix :: 
    (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    a (n,p) e -> b (n,p) e -> m (c (n,p) e)
unsafeGetDivMatrix = unsafeGetBinaryMatrixOp unsafeDivMatrix
{-# INLINE unsafeGetDivMatrix #-}

-------------------------------- MMatrix ----------------------------------

-- | A type class for mutable matrices associated with a monad.  The member
-- functions of the type class do not perform any checks on the validity of
-- shapes or indices, so in general their safe counterparts should be
-- preferred.
class (MatrixShaped a, BLAS3 e, Monad m) => MMatrix a e m where
    unsafeGetSApply :: (ReadVector x e m, WriteVector y e m) =>
        e -> a (k,l) e -> x l e -> m (y k e)
    unsafeGetSApply alpha a x = do
        y <- newVector_ (numRows a)
        unsafeDoSApplyAdd alpha a x 0 y
        return y
    {-# INLINE unsafeGetSApply #-}

    unsafeGetSApplyMat :: (ReadMatrix b e m, WriteMatrix c e m) =>
        e -> a (r,s) e -> b (s,t) e -> m (c (r,t) e)
    unsafeGetSApplyMat alpha a b = do
        c <- newMatrix_ (numRows a, numCols b)
        unsafeDoSApplyAddMat alpha a b 0 c
        return c
    {-# INLINE unsafeGetSApplyMat #-}

    unsafeDoSApplyAdd :: (ReadVector x e m, WriteVector y e m) =>
        e -> a (k,l) e -> x l e -> e -> y k e -> m ()
    unsafeDoSApplyAdd alpha a x beta (y :: y k e) = do
        (y' :: y k e) <- unsafeGetSApply alpha a x
        scaleByVector beta y
        unsafeAxpyVector 1 y' y
    {-# INLINE unsafeDoSApplyAdd #-}

    unsafeDoSApplyAddMat :: (ReadMatrix b e m, WriteMatrix c e m) =>
        e -> a (r,s) e -> b (s,t) e -> e -> c (r,t) e -> m ()
    unsafeDoSApplyAddMat alpha a b beta (c :: c (r,t) e) = do
        (c' :: c (r,t) e) <- unsafeGetSApplyMat alpha a b
        scaleByMatrix beta c
        unsafeAxpyMatrix 1 c' c
    {-# INLINE unsafeDoSApplyAddMat #-}

    unsafeDoSApply_ :: (WriteVector y e m) =>
        e -> a (n,n) e -> y n e -> m ()
    unsafeDoSApply_ alpha a (x :: y n e) = do
        (y :: y n e) <- newVector_ (dim x)
        unsafeDoSApplyAdd alpha a x 0 y
        unsafeCopyVector x y
    {-# INLINE unsafeDoSApply_ #-}

    unsafeDoSApplyMat_ :: (WriteMatrix b e m) =>
        e -> a (k,k) e -> b (k,l) e -> m ()
    unsafeDoSApplyMat_ alpha a (b :: b (k,l) e) = do
        (c :: b (k,l) e) <- newMatrix_ (shape b)
        unsafeDoSApplyAddMat alpha a b 0 c
        unsafeCopyMatrix b c
    {-# INLINE unsafeDoSApplyMat_ #-}

    unsafeGetRow :: (WriteVector x e m) => a (k,l) e -> Int -> m (x l e)
    unsafeGetRow (a :: a (k,l) e) i =
        let unsafeGetRowHelp :: (WriteVector x e m) => x l e -> m (x l e)
            unsafeGetRowHelp (_ :: x l e) = do
                (e :: x k e) <- newBasisVector (numRows a) i
                liftM conj $ unsafeGetSApply 1 (herm a) e
        in unsafeGetRowHelp undefined
    {-# INLINE unsafeGetRow #-}        
        
    unsafeGetCol :: (WriteVector x e m) => a (k,l) e -> Int -> m (x k e)
    unsafeGetCol (a :: a (k,l) e) j =
        let unsafeGetColHelp :: (WriteVector x e m) => x k e -> m (x k e)
            unsafeGetColHelp (_ :: x k e) = do
                (e :: x l e) <- newBasisVector (numCols a) j
                unsafeGetSApply 1 a e
        in unsafeGetColHelp undefined
    {-# INLINE unsafeGetCol #-}

    -- | Get a lazy list the row vectors in the matrix.
    getRows :: (WriteVector x e m) => 
        a (k,l) e -> m [x l e]
    {-# INLINE getRows #-}

    -- | Get a lazy list of the column vectors in the matrix.
    getCols :: (WriteVector x e m) => 
        a (k,l) e -> m [x k e]

getColsM :: (MMatrix a e m, WriteVector x e m)
          => (forall b. m b -> m b)
          -> a (k,l) e -> m [x k e]
getColsM unsafeInterleaveM a =
    let n    = numCols a
        go j | j == n    = return []
             | otherwise = unsafeInterleaveM $ do
                               c  <- unsafeGetCol a j
                               cs <- go (j+1)
                               return (c:cs)
    in go 0
{-# INLINE getColsM #-}

getColsIO :: (MMatrix a e IO, WriteVector x e IO)
          => a (k,l) e -> IO [x k e]
getColsIO = getColsM unsafeInterleaveIO

getColsST :: (MMatrix a e (ST s), WriteVector x e (ST s))
          => a (k,l) e -> ST s [x k e]
getColsST = getColsM unsafeInterleaveST

getRowsM :: (MMatrix a e m, WriteVector x e m)
         => (forall b. m b -> m b)
         -> a (k,l) e -> m [x l e]
getRowsM unsafeInterleaveM a =
    let m    = numRows a
        go i | i == m    = return []
             | otherwise = unsafeInterleaveM $ do
                                r  <- unsafeGetRow a i
                                rs <- go (i+1)
                                return (r:rs)
    in go 0
{-# INLINE getRowsM #-}

getRowsIO :: (MMatrix a e IO, WriteVector x e IO)
          => a (k,l) e -> IO [x l e]
getRowsIO = getRowsM unsafeInterleaveIO

getRowsST :: (MMatrix a e (ST s), WriteVector x e (ST s))
          => a (k,l) e -> ST s [x l e]
getRowsST = getRowsM unsafeInterleaveST


-- | @gemv alpha a x beta y@ replaces @y := alpha a * x + beta y@.
gemv :: (ReadMatrix a e m, ReadVector x e m, WriteVector y e m) =>
    e -> a (k,l) e -> x l e -> e -> y k e -> m ()
gemv alpha a x beta y
    | numRows a == 0 || numCols a == 0 =
        scaleByVector beta y
        
    | isConj y && (isConj x || stride x == 1) =
        let transA = if isConj x then NoTrans else ConjTrans
            transB = transMatrix (herm a)
            m      = 1
            n      = dim y
            k      = dim x
            ldA    = stride x
            ldB    = ldaMatrix a
            ldC    = stride y
            alpha' = conjugate alpha
            beta'  = conjugate beta
            x'     = unsafeVectorToIOVector x
            y'     = unsafeVectorToIOVector y
        in 
            withMatrixPtr a $ \pB ->
            withIOVector x' $ \pA ->
            withIOVector y' $ \pC ->
                BLAS.gemm transA transB m n k alpha' pA ldA pB ldB beta' pC ldC
    
    | (isConj y && otherwise) || isConj x = do
        doConjVector y
        gemv alpha a x beta (conj y)
        doConjVector y
        
    | otherwise =
        let transA = transMatrix a
            (m,n)  = case (isHermMatrix a) of
                         False -> shape a
                         True  -> (flipShape . shape) a
            ldA    = ldaMatrix a
            incX   = stride x
            incY   = stride y
            x'     = unsafeVectorToIOVector x
            y'     = unsafeVectorToIOVector y
        in 
            withMatrixPtr a   $ \pA ->
            withIOVector x' $ \pX ->
            withIOVector y' $ \pY -> do
                BLAS.gemv transA m n alpha pA ldA pX incX beta pY incY
  where 
    withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f


-- | @gemm alpha a b beta c@ replaces @c := alpha a * b + beta c@.
gemm :: (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    e -> a (r,s) e -> b (s,t) e -> e -> c (r,t) e -> m ()
gemm alpha a b beta c
    | numRows a == 0 || numCols a == 0 || numCols b == 0 = 
        scaleByMatrix beta c
    | isHermMatrix c = gemm (conjugate alpha) (herm b) (herm a) (conjugate beta) (herm c)
    | otherwise =
        let transA = transMatrix a
            transB = transMatrix b
            (m,n)  = shape c
            k      = numCols a
            ldA    = ldaMatrix a
            ldB    = ldaMatrix b
            ldC    = ldaMatrix c
        in 
            withMatrixPtr   a $ \pA ->
            withIOMatrix (unsafeMatrixToIOMatrix b) $ \pB ->
            withIOMatrix (unsafeMatrixToIOMatrix c) $ \pC ->
                BLAS.gemm transA transB m n k alpha pA ldA pB ldB beta pC ldC
  where 
    withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f


hemv :: (ReadMatrix a e m, ReadVector x e m, WriteVector y e m) =>
    e -> Herm a (k,k) e -> x k e -> e -> y k e -> m ()
hemv alpha h (x :: x k e) beta (y :: y k e)
    | numRows h == 0 =
        return ()
    | isConj y = do
        doConjVector y
        hemv alpha h x beta (conj y)
        doConjVector y
    | isConj x = do
        (x' :: y k e) <- newCopyVector' x
        hemv alpha h x' beta y
    | otherwise =
        let (u,a) = hermToBase h
            n     = numCols a
            u'    = case isHermMatrix a of
                        True  -> flipUpLo u
                        False -> u
            uploA = u'
            ldA   = ldaMatrix a
            incX  = stride x
            incY  = stride y
            x'    = unsafeVectorToIOVector x
            y'    = unsafeVectorToIOVector y
        in 
            withMatrixPtr a   $ \pA ->
            withIOVector x' $ \pX ->
            withIOVector y' $ \pY ->
                BLAS.hemv uploA n alpha pA ldA pX incX beta pY incY
  where 
    withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f

hemm :: (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    e -> Herm a (k,k) e -> b (k,l) e -> e -> c (k,l) e -> m ()
hemm alpha h b beta c
    | numRows b == 0 || numCols b == 0 || numCols c == 0 = return ()
    | (isHermMatrix a) /= (isHermMatrix c) || (isHermMatrix a) /= (isHermMatrix b) =
        zipWithM_ (\x y -> hemv alpha h x beta y) (colViews b) (colViews c)
    | otherwise =
        let (m,n)   = shape c
            (side,u',m',n')
                    = if isHermMatrix a
                          then (RightSide, flipUpLo u, n, m)
                          else (LeftSide,  u,          m, n)
            uploA   = u'
            ldA     = ldaMatrix a
            ldB     = ldaMatrix b
            ldC     = ldaMatrix c
        in 
            withMatrixPtr   a $ \pA ->
            withIOMatrix (unsafeMatrixToIOMatrix b) $ \pB ->
            withIOMatrix (unsafeMatrixToIOMatrix c) $ \pC ->
                BLAS.hemm side uploA m' n' alpha pA ldA pB ldB beta pC ldC
    where
      withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f
      (u,a) = hermToBase h

hemv' :: (ReadMatrix a e m, ReadVector x e m, WriteVector y e m) =>
    e -> Herm a (r,s) e -> x s e -> e -> y r e -> m ()
hemv' alpha a x beta y = 
    hemv alpha (coerceHerm a) x beta (coerceVector y)

hemm' :: (ReadMatrix a e m, ReadMatrix b e m, WriteMatrix c e m) =>
    e -> Herm a (r,s) e -> b (s,t) e -> e -> c (r,t) e -> m ()
hemm' alpha a b beta c = 
    hemm alpha (coerceHerm a) b beta (coerceMatrix c)

unsafeDoSApplyAddTriMatrix :: (ReadMatrix a e m, MMatrix a e m, 
    ReadVector x e m, WriteVector y e m) =>
        e -> Tri a (k,l) e -> x l e -> e -> y k e -> m ()
unsafeDoSApplyAddTriMatrix alpha t x beta (y :: y k e) =
    if beta == 0
        then unsafeDoSApplyTriMatrix alpha t x y
        else do
            (y' :: y k e) <- newCopyVector y
            unsafeDoSApplyTriMatrix alpha t x y'
            scaleByVector beta y
            unsafeAxpyVector 1 y' y

unsafeDoSApplyAddMatTriMatrix :: (ReadMatrix a e m,
    ReadMatrix b e m, WriteMatrix c e m) =>
        e -> Tri a (r,s) e -> b (s,t) e -> e -> c (r,t) e -> m ()
unsafeDoSApplyAddMatTriMatrix alpha t b beta (c :: c (r,t) e) =
    if beta == 0
        then unsafeDoSApplyMatTriMatrix alpha t b c
        else do
            (c' :: c (r,t) e) <- newCopyMatrix c
            unsafeDoSApplyMatTriMatrix alpha t b c'
            scaleByMatrix beta c
            unsafeAxpyMatrix 1 c' c

unsafeDoSApplyTriMatrix :: (ReadMatrix a e m, MMatrix a e m, 
    ReadVector x e m, WriteVector y e m) =>
        e -> Tri a (k,l) e -> x l e -> y k e -> m ()
unsafeDoSApplyTriMatrix alpha t x y =
    case (u, toLower d a, toUpper d a) of
        (Lower,Left t',_) -> do
            unsafeCopyVector y (coerceVector x)
            trmv alpha t' y
            
        (Lower,Right (t',r),_) -> do
            let y1 = unsafeSubvectorView y 0            (numRows t')
                y2 = unsafeSubvectorView y (numRows t') (numRows r)
            unsafeCopyVector y1 x
            trmv alpha t' y1
            unsafeDoSApplyAdd alpha r x 0 y2
            
        (Upper,_,Left t') -> do
            unsafeCopyVector (coerceVector y) x
            trmv alpha t' (coerceVector y)

        (Upper,_,Right (t',r)) ->
            let x1 = unsafeSubvectorView x 0            (numCols t')
                x2 = unsafeSubvectorView x (numCols t') (numCols r)
            in do
                unsafeCopyVector y x1
                trmv alpha t' y
                unsafeDoSApplyAdd alpha r x2 1 y
  where
    (u,d,a) = triToBase t

unsafeDoSApplyMatTriMatrix :: (ReadMatrix a e m,
    ReadMatrix b e m, WriteMatrix c e m) =>
        e -> Tri a (r,s) e -> b (s,t) e -> c (r,t) e -> m ()
unsafeDoSApplyMatTriMatrix alpha t b c =
    case (u, toLower d a, toUpper d a) of
        (Lower,Left t',_) -> do
            unsafeCopyMatrix c (coerceMatrix b)
            trmm alpha t' c
            
        (Lower,Right (t',r),_) -> do
            let c1 = unsafeSubmatrixView c (0,0)          (numRows t',numCols c)
                c2 = unsafeSubmatrixView c (numRows t',0) (numRows r ,numCols c)
            unsafeCopyMatrix c1 b
            trmm alpha t' c1
            unsafeDoSApplyAddMat alpha r b 0 c2
            
        (Upper,_,Left t') -> do
            unsafeCopyMatrix (coerceMatrix c) b
            trmm alpha t' (coerceMatrix c)

        (Upper,_,Right (t',r)) ->
            let b1 = unsafeSubmatrixView b (0,0)          (numCols t',numCols b)
                b2 = unsafeSubmatrixView b (numCols t',0) (numCols r ,numCols b)
            in do
                unsafeCopyMatrix c b1
                trmm alpha t' c
                unsafeDoSApplyAddMat alpha r b2 1 c
  where
    (u,d,a) = triToBase t


toLower :: (BaseMatrix a e) => DiagEnum -> a (m,n) e 
        -> Either (Tri a (m,m) e) 
                  (Tri a (n,n) e, a (k,n) e)
toLower d a =
    if m <= n
        then Left $  triFromBase Lower d (unsafeSubmatrixView a (0,0) (m,m))
        else let t = triFromBase Lower d (unsafeSubmatrixView a (0,0) (n,n))
                 r = unsafeSubmatrixView a (n,0) (k,n)
             in Right (t,r)
  where
    (m,n) = shape a
    k     = m - n
    
toUpper :: (BaseMatrix a e) => DiagEnum -> a (m,n) e
        -> Either (Tri a (n,n) e)
                  (Tri a (m,m) e, a (m,k) e)
toUpper d a =
    if n <= m
        then Left $  triFromBase Upper d (unsafeSubmatrixView a (0,0) (n,n))
        else let t = triFromBase Upper d (unsafeSubmatrixView a (0,0) (m,m))
                 r = unsafeSubmatrixView a (0,m) (m,k)
             in Right (t,r)
  where
    (m,n) = shape a
    k     = n - m

trmv :: (ReadMatrix a e m, WriteVector y e m) =>
    e -> Tri a (k,k) e -> y n e -> m ()
trmv alpha t x 
    | dim x == 0 = 
        return ()
        
    | isConj x =
        let (u,d,a) = triToBase t
            side    = RightSide
            (h,u')  = if isHermMatrix a then (NoTrans  , flipUpLo u) 
                                        else (ConjTrans, u)
            uploA   = u'
            transA  = h
            diagA   = d
            m       = 1
            n       = dim x
            alpha'  = conjugate alpha
            ldA     = ldaMatrix a
            ldB     = stride x
        in 
            withMatrixPtr   a $ \pA ->
            withVectorPtrIO x $ \pB ->
                BLAS.trmm side uploA transA diagA m n alpha' pA ldA pB ldB

    | otherwise =
        let (u,d,a)   = triToBase t
            (transA,u') = if isHermMatrix a then (ConjTrans, flipUpLo u) 
                                            else (NoTrans  , u)
            uploA     = u'
            diagA     = d
            n         = dim x
            ldA       = ldaMatrix a
            incX      = stride x
        in do
            when (alpha /= 1) $ scaleByVector alpha x
            withMatrixPtr a   $ \pA ->
                withVectorPtrIO x $ \pX -> do
                   BLAS.trmv uploA transA diagA n pA ldA pX incX
  where 
    withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f
    withVectorPtrIO = withIOVector . unsafeVectorToIOVector


trmm :: (ReadMatrix a e m, WriteMatrix b e m) =>
    e -> Tri a (k,k) e -> b (k,l) e -> m ()
trmm _ _ b
    | numRows b == 0 || numCols b == 0 = return ()
trmm alpha t b =
    let (u,d,a)   = triToBase t
        (h,u')    = if isHermMatrix a then (ConjTrans, flipUpLo u) else (NoTrans, u)
        (m,n)     = shape b
        (side,h',m',n',alpha')
                  = if isHermMatrix b
                        then (RightSide, flipTrans h, n, m, conjugate alpha)
                        else (LeftSide , h          , m, n, alpha       )
        uploA     = u'
        transA    = h'
        diagA     = d
        ldA       = ldaMatrix a
        ldB       = ldaMatrix b
    in  
        withMatrixPtr   a $ \pA ->
        withIOMatrix (unsafeMatrixToIOMatrix b) $ \pB ->
            BLAS.trmm side uploA transA diagA m' n' alpha' pA ldA pB ldB
  where 
    withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f
  
unsafeDoSSolveTriMatrix :: (ReadMatrix a e m,
    ReadVector y e m, WriteVector x e m) =>
        e -> Tri a (k,l) e -> y k e -> x l e -> m ()
unsafeDoSSolveTriMatrix alpha t y x =
    case (u, toLower d a, toUpper d a) of
        (Lower,Left t',_) -> do
            unsafeCopyVector x (coerceVector y)
            trsv alpha t' (coerceVector x)
            
        (Lower,Right (t',_),_) -> do
            let y1 = unsafeSubvectorView y 0            (numRows t')
            unsafeCopyVector x y1
            trsv alpha t' x
            
        (Upper,_,Left t') -> do
            unsafeCopyVector x (coerceVector y)
            trsv alpha t' x

        (Upper,_,Right (t',r)) ->
            let x1 = unsafeSubvectorView x 0            (numCols t')
                x2 = unsafeSubvectorView x (numCols t') (numCols r)
            in do
                unsafeCopyVector x1 y
                trsv alpha t' x1
                setZeroVector x2
  where
    (u,d,a) = triToBase t


unsafeDoSSolveMatTriMatrix :: (ReadMatrix a e m,
    ReadMatrix c e m, WriteMatrix b e m) =>
        e -> Tri a (r,s) e -> c (r,t) e -> b (s,t) e -> m ()
unsafeDoSSolveMatTriMatrix alpha t c b =
    case (u, toLower d a, toUpper d a) of
        (Lower,Left t',_) -> do
            unsafeCopyMatrix b (coerceMatrix c)
            trsm alpha t' (coerceMatrix b)
            
        (Lower,Right (t',_),_) -> do
            let c1 = unsafeSubmatrixView c (0,0)          (numRows t',numCols c)
            unsafeCopyMatrix b c1
            trsm alpha t' b
            
        (Upper,_,Left t') -> do
            unsafeCopyMatrix (coerceMatrix b) c
            trsm alpha t' (coerceMatrix b)

        (Upper,_,Right (t',r)) ->
            let b1 = unsafeSubmatrixView b (0,0)          (numCols t',numCols b)
                b2 = unsafeSubmatrixView b (numCols t',0) (numCols r ,numCols b)
            in do
                unsafeCopyMatrix b1 c
                trsm alpha t' b1
                setZeroMatrix b2
  where
    (u,d,a) = triToBase t


trsv :: (ReadMatrix a e m, WriteVector y e m) =>
    e -> Tri a (k,k) e -> y n e -> m ()
trsv alpha t x
    | dim x == 0 = return ()

    | isConj x =
        let (u,d,a) = triToBase t
            side    = RightSide
            (h,u')  = if isHermMatrix a then (NoTrans, flipUpLo u) else (ConjTrans, u)
            uploA   = u'
            transA  = h
            diagA   = d
            m       = 1
            n       = dim x
            alpha'  = conjugate alpha
            ldA     = ldaMatrix a
            ldB     = stride x
        in 
            withMatrixPtr   a $ \pA ->
            withVectorPtrIO x $ \pB ->
                BLAS.trsm side uploA transA diagA m n alpha' pA ldA pB ldB

    | otherwise =
        let (u,d,a) = triToBase t
            (transA,u') = if isHermMatrix a then (ConjTrans, flipUpLo u) 
                                            else (NoTrans  , u)
            uploA     = u'
            diagA     = d
            n         = dim x
            ldA       = ldaMatrix a
            incX      = stride x
        in do
            when (alpha /= 1) $ scaleByVector alpha x
            withMatrixPtr   a $ \pA ->
                withVectorPtrIO x $ \pX ->
                    BLAS.trsv uploA transA diagA n pA ldA pX incX
  where 
    withVectorPtrIO = withIOVector . unsafeVectorToIOVector
    withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f

trsm :: (ReadMatrix a e m, WriteMatrix b e m) =>
    e -> Tri a (k,k) e -> b (k,l) e -> m ()
trsm _ _ b
    | numRows b == 0 || numCols b == 0 = return ()
trsm alpha t b =
    let (u,d,a)   = triToBase t
        (h,u')    = if isHermMatrix a then (ConjTrans, flipUpLo u) else (NoTrans, u)
        (m,n)     = shape b
        (side,h',m',n',alpha')
                  = if isHermMatrix b
                        then (RightSide, flipTrans h, n, m, conjugate alpha)
                        else (LeftSide , h          , m, n, alpha     )
        uploA     = u'
        transA    = h'
        diagA     = d
        ldA       = ldaMatrix a
        ldB       = ldaMatrix b
    in 
        withMatrixPtr   a $ \pA ->
        withIOMatrix (unsafeMatrixToIOMatrix b) $ \pB -> do
            BLAS.trsm side uploA transA diagA m' n' alpha' pA ldA pB ldB
  where 
    withMatrixPtr d f = unsafePerformIOWithMatrix d $ flip withIOMatrix f

------------------------------------ MSolve ------------------------------

-- | A type class for mutable matrices with inverses.  The member
-- functions of the type class do not perform any checks on the validity
-- of shapes or indices, so in general their safe counterparts should be
-- preferred.
class (MatrixShaped a, BLAS3 e, Monad m) => MSolve a e m where
    unsafeDoSolve :: (ReadVector y e m, WriteVector x e m) =>
        a (k,l) e -> y k e -> x l e -> m ()
    unsafeDoSolve = unsafeDoSSolve 1
    {-# INLINE unsafeDoSolve #-}
    
    unsafeDoSolveMat :: (ReadMatrix c e m, WriteMatrix b e m) =>
        a (r,s) e -> c (r,t) e -> b (s,t) e -> m ()
    unsafeDoSolveMat = unsafeDoSSolveMat 1
    {-# INLINE unsafeDoSolveMat #-}    
    
    unsafeDoSSolve :: (ReadVector y e m, WriteVector x e m) =>
        e -> a (k,l) e -> y k e -> x l e -> m ()
    unsafeDoSSolve alpha a y x = do
        unsafeDoSolve a y x
        scaleByVector alpha x
    {-# INLINE unsafeDoSSolve #-}        
    
    unsafeDoSSolveMat :: (ReadMatrix c e m, WriteMatrix b e m) =>
        e -> a (r,s) e -> c (r,t) e -> b (s,t) e -> m ()
    unsafeDoSSolveMat alpha a c b = do
        unsafeDoSolveMat a c b
        scaleByMatrix alpha b
    {-# INLINE unsafeDoSSolveMat #-}

    unsafeDoSolve_ :: (WriteVector x e m) => a (k,k) e -> x k e -> m ()
    unsafeDoSolve_ = unsafeDoSSolve_ 1
    {-# INLINE unsafeDoSolve_ #-}

    unsafeDoSSolve_ :: (WriteVector x e m) => e -> a (k,k) e -> x k e -> m ()
    unsafeDoSSolve_ alpha a x = do
        scaleByVector alpha x
        unsafeDoSolve_ a x
    {-# INLINE unsafeDoSSolve_ #-}        
        
    unsafeDoSolveMat_ :: (WriteMatrix b e m) => a (k,k) e -> b (k,l) e -> m ()
    unsafeDoSolveMat_ = unsafeDoSSolveMat_ 1
    {-# INLINE unsafeDoSolveMat_ #-}
        
    unsafeDoSSolveMat_ :: (WriteMatrix b e m) => e -> a (k,k) e -> b (k,l) e -> m ()
    unsafeDoSSolveMat_ alpha a b = do
        scaleByMatrix alpha b
        unsafeDoSolveMat_ a b
    {-# INLINE unsafeDoSSolveMat_ #-}

------------------------------------ Instances ------------------------------


instance (Elem e) => BaseMatrix IOMatrix e where
    ldaMatrix = ldaMatrixIOMatrix
    {-# INLINE ldaMatrix #-}
    isHermMatrix = isHermIOMatrix
    {-# INLINE isHermMatrix #-}
    unsafeSubmatrixView = unsafeSubmatrixViewIOMatrix
    {-# INLINE unsafeSubmatrixView #-}
    unsafeDiagView = unsafeDiagViewIOMatrix
    {-# INLINE unsafeDiagView #-}
    unsafeRowView = unsafeRowViewIOMatrix
    {-# INLINE unsafeRowView #-}
    unsafeColView = unsafeColViewIOMatrix
    {-# INLINE unsafeColView #-}
    maybeViewMatrixAsVector = maybeViewIOMatrixAsVector
    {-# INLINE maybeViewMatrixAsVector #-}
    maybeViewVectorAsMatrix = maybeViewVectorAsIOMatrix
    {-# INLINE maybeViewVectorAsMatrix #-}
    maybeViewVectorAsRow = maybeViewVectorAsRowIOMatrix
    {-# INLINE maybeViewVectorAsRow #-}    
    maybeViewVectorAsCol = maybeViewVectorAsColIOMatrix
    {-# INLINE maybeViewVectorAsCol #-}
    unsafeIOMatrixToMatrix = id
    {-# INLINE unsafeIOMatrixToMatrix #-}
    unsafeMatrixToIOMatrix = id
    {-# INLINE unsafeMatrixToIOMatrix #-}

instance (BLAS3 e) => MMatrix IOMatrix e IO where
    unsafeDoSApplyAdd = gemv
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = gemm
    {-# INLINE unsafeDoSApplyAddMat #-}
    unsafeGetRow = unsafeGetRowMatrix
    {-# INLINE unsafeGetRow #-}
    unsafeGetCol = unsafeGetColMatrix
    {-# INLINE unsafeGetCol #-}
    getRows = getRowsIO
    {-# INLINE getRows #-}
    getCols = getColsIO
    {-# INLINE getCols #-}

instance (BLAS3 e) => MMatrix (Herm IOMatrix) e IO where
    unsafeDoSApplyAdd = hemv'
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = hemm'
    {-# INLINE unsafeDoSApplyAddMat #-}    
    getRows = getRowsIO
    {-# INLINE getRows #-}
    getCols = getColsIO
    {-# INLINE getCols #-}

instance (BLAS3 e) => MMatrix (Tri IOMatrix) e IO where
    unsafeDoSApplyAdd = unsafeDoSApplyAddTriMatrix
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = unsafeDoSApplyAddMatTriMatrix
    {-# INLINE unsafeDoSApplyAddMat #-}
    unsafeDoSApply_ = trmv
    {-# INLINE unsafeDoSApply_ #-}
    unsafeDoSApplyMat_ = trmm
    {-# INLINE unsafeDoSApplyMat_ #-}
    getRows = getRowsIO
    {-# INLINE getRows #-}
    getCols = getColsIO
    {-# INLINE getCols #-}

instance (BLAS3 e) => MSolve  (Tri IOMatrix) e IO where
    unsafeDoSSolve = unsafeDoSSolveTriMatrix
    {-# INLINE unsafeDoSSolve #-}
    unsafeDoSSolveMat = unsafeDoSSolveMatTriMatrix
    {-# INLINE unsafeDoSSolveMat #-}    
    unsafeDoSSolve_ = trsv
    {-# INLINE unsafeDoSSolve_ #-}
    unsafeDoSSolveMat_ = trsm
    {-# INLINE unsafeDoSSolveMat_ #-}

instance (BLAS3 e) => ReadMatrix IOMatrix e IO where
    unsafePerformIOWithMatrix a f = f a
    {-# INLINE unsafePerformIOWithMatrix #-}
    freezeMatrix = freezeIOMatrix
    {-# INLINE freezeMatrix #-}
    unsafeFreezeMatrix = unsafeFreezeIOMatrix
    {-# INLINE unsafeFreezeMatrix #-}

instance (BLAS3 e) => WriteMatrix IOMatrix e IO where
    newMatrix_ = newIOMatrix_
    {-# INLINE newMatrix_ #-}
    unsafeConvertIOMatrix = id
    {-# INLINE unsafeConvertIOMatrix #-}
    thawMatrix = thawIOMatrix
    {-# INLINE thawMatrix #-}
    unsafeThawMatrix = unsafeThawIOMatrix
    {-# INLINE unsafeThawMatrix #-}

-- | Create a new matrix of the given size and initialize the given elements to
-- the given values.  All other elements get set to zero.
matrix :: (BLAS3 e) => (Int,Int) -> [((Int,Int), e)] -> Matrix (n,p) e
matrix mn ies = unsafePerformIO $
    unsafeFreezeIOMatrix =<< newMatrix mn ies
{-# NOINLINE matrix #-}

-- | Same as 'matrix' but does not do any bounds checking.
unsafeMatrix :: (BLAS3 e) => (Int,Int) -> [((Int,Int), e)] -> Matrix (n,p) e
unsafeMatrix mn ies =  unsafePerformIO $ 
    unsafeFreezeIOMatrix =<< unsafeNewMatrix mn ies
{-# NOINLINE unsafeMatrix #-}

-- | Create a new matrix with the given elements in row-major order.
listMatrix :: (BLAS3 e) => (Int,Int) -> [e] -> Matrix (n,p) e
listMatrix mn es = unsafePerformIO $ 
    unsafeFreezeIOMatrix =<< newListMatrix mn es
{-# NOINLINE listMatrix #-}

replaceMatrix :: (BLAS1 e) => Matrix np e -> [((Int,Int),e)] -> Matrix np e
replaceMatrix (Matrix a) ies =
    unsafePerformIO $ do
        b <- newCopyIOMatrix a
        mapM_ (uncurry $ writeElem b) ies
        return (Matrix b)
{-# NOINLINE replaceMatrix #-}

unsafeReplaceMatrix :: (BLAS1 e) => Matrix np e -> [((Int,Int),e)] -> Matrix np e
unsafeReplaceMatrix (Matrix a) ies =
    unsafePerformIO $ do
        b <- newCopyIOMatrix a
        mapM_ (uncurry $ unsafeWriteElem b) ies
        return (Matrix b)
{-# NOINLINE unsafeReplaceMatrix #-}

-- | Create a matrix of the given shape from a list of rows
rowsMatrix :: (BLAS3 e) => (Int,Int) -> [Vector p e] -> Matrix (n,p) e
rowsMatrix mn rs = unsafePerformIO $ 
    unsafeFreezeIOMatrix =<< newRowsMatrix mn rs
{-# NOINLINE rowsMatrix #-}

-- | Create a matrix of the given shape from a list of columns
colsMatrix :: (BLAS3 e) => (Int,Int) -> [Vector n e] -> Matrix (n,p) e
colsMatrix mn cs = unsafePerformIO $ 
    unsafeFreezeIOMatrix =<< newColsMatrix mn cs
{-# NOINLINE colsMatrix #-}

-- | Get a matrix from a row vector.
matrixFromRow :: (BLAS3 e) => Vector p e -> Matrix (one,p) e
matrixFromRow (Vector x) = 
    case maybeViewVectorAsRow x of
        Just x' -> Matrix x'
        Nothing -> unsafePerformIO $ unsafeFreezeIOMatrix =<< newRowMatrix x
{-# NOINLINE matrixFromRow #-}

-- | Get a matrix from a column vector.
matrixFromCol :: (BLAS3 e) => Vector n e -> Matrix (n,one) e
matrixFromCol (Vector x) = 
    case maybeViewVectorAsCol x of
        Just x' -> Matrix x'
        Nothing -> unsafePerformIO $ unsafeFreezeIOMatrix =<< newColMatrix x
{-# NOINLINE matrixFromCol #-}

-- | Get a matrix from the elements stored in columnwise order in the vector.
matrixFromVector :: (BLAS3 e) => (Int,Int) -> Vector np e -> Matrix (n,p) e
matrixFromVector (m,n) x
    | dim x /= m*n =
        error $ "matrixFromVector " ++ show (m,n) ++ "<vector of dim "
              ++ show (dim x) ++ ">: vector dimension must be equal to "
              ++ "the number of elements in the desired matrix"
    | otherwise =
        case maybeViewVectorAsMatrix (m,n) x of
            Just a  -> a
            Nothing -> listMatrix (m,n) (elems x)

-- | Get a vector by concatenating the columns of the matrix.
vectorFromMatrix :: (BLAS3 e) => Matrix (n,p) e -> Vector np e
vectorFromMatrix a =
    case maybeViewMatrixAsVector a of
        Just x  -> x
        Nothing -> listVector (size a) (concatMap elems (colViews a))

-- | Get a new zero of the given shape.
zeroMatrix :: (BLAS3 e) => (Int,Int) -> Matrix (n,p) e
zeroMatrix mn = unsafePerformIO $
    unsafeFreezeIOMatrix =<< newZeroMatrix mn
{-# NOINLINE zeroMatrix #-}

-- | Get a new constant of the given shape.
constantMatrix :: (BLAS3 e) => (Int,Int) -> e -> Matrix (n,p) e
constantMatrix mn e = unsafePerformIO $
    unsafeFreezeIOMatrix =<< newConstantMatrix mn e
{-# NOINLINE constantMatrix #-}

-- | Get a new matrix of the given shape with ones along the diagonal and
-- zeroes everywhere else.
identityMatrix :: (BLAS3 e) => (Int,Int) -> Matrix (n,p) e
identityMatrix mn = unsafePerformIO $
    unsafeFreezeIOMatrix =<< newIdentityMatrix mn
{-# NOINLINE identityMatrix #-}

-- | @submatrix a ij mn@ returns the submatrix of @a@ with element @(0,0)@
-- being element @ij@ in @a@, and having shape @mn@.
submatrix :: (Elem e) => Matrix (n,p) e -> (Int,Int) -> (Int,Int) -> Matrix (n',p') e
submatrix (Matrix a) ij mn = 
    Matrix $ submatrixView a ij mn
{-# INLINE submatrix #-}

unsafeSubmatrix :: (Elem e) => Matrix (n,p) e -> (Int,Int) -> (Int,Int) -> Matrix (n',p') e
unsafeSubmatrix (Matrix a) ij mn = 
    Matrix $ unsafeSubmatrixView a ij mn
{-# INLINE unsafeSubmatrix #-}

-- | Get a the given diagonal in a matrix.  Negative indices correspond to
-- sub-diagonals.
diag :: (Elem e) => Matrix (n,p) e -> Int -> Vector k e
diag (Matrix a) i = Vector (diagView a i)
{-# INLINE diag #-}

-- | Same as 'diag' but index is not range-checked.
unsafeDiag :: (Elem e) => Matrix (n,p) e -> Int -> Vector k e
unsafeDiag (Matrix a) i = Vector (diagView a i)
{-# INLINE unsafeDiag #-}

unsafeAtMatrix :: (Elem e) => Matrix np e -> (Int,Int) -> e
unsafeAtMatrix (Matrix (IOMatrix f p _ _ l h)) (i,j)
    | h = inlinePerformIO $ do
        e  <- liftM conjugate $ peekElemOff p (i*l+j)
        io <- touchForeignPtr f
        e `seq` io `seq` return e
    | otherwise = inlinePerformIO $ do
        e  <- peekElemOff p (i+j*l)
        io <- touchForeignPtr f
        e `seq` io `seq` return e
{-# INLINE unsafeAtMatrix #-}

indicesMatrix :: Matrix np e -> [(Int,Int)]
indicesMatrix (Matrix a) = indicesIOMatrix a
{-# INLINE indicesMatrix #-}

elemsMatrix :: (Elem e) => Matrix np e -> [e]
elemsMatrix (Matrix a) = 
    case maybeViewIOMatrixAsVector a of
        (Just x) -> elemsVector (Vector x)
        Nothing  -> concatMap (elemsVector . Vector) (vecViews a)
  where
    vecViews = if isHermIOMatrix a
                   then rowViews . coerceMatrix
                   else colViews . coerceMatrix
{-# INLINE elemsMatrix #-}

assocsMatrix :: (Elem e) => Matrix np e -> [((Int,Int),e)]
assocsMatrix a = zip (indicesMatrix a) (elemsMatrix a)
{-# INLINE assocsMatrix #-}

tmapMatrix :: (BLAS3 e) => (e -> e) -> Matrix np e -> Matrix np e
tmapMatrix f a@(Matrix ma)
    | isHermIOMatrix ma = coerceMatrix $ herm $ 
                              listMatrix (n,m) $ map (conjugate . f) (elems a)
    | otherwise         = coerceMatrix $
                              listMatrix (m,n) $ map f (elems a)
  where
    (m,n) = shape a

tzipWithMatrix :: (BLAS3 e) =>
    (e -> e -> e) -> Matrix np e -> Matrix np e -> Matrix np e
tzipWithMatrix f a b
    | shape b /= mn =
        error ("tzipWith: matrix shapes differ; first has shape `" ++
                show mn ++ "' and second has shape `" ++
                show (shape b) ++ "'")
    | otherwise =
        coerceMatrix $
            listMatrix mn $ zipWith f (colElems a) (colElems b)
  where
    mn = shape a
    colElems = (concatMap elems) . colViews . coerceMatrix

instance Shaped Matrix (Int,Int) where
    shape (Matrix a) = shapeIOMatrix a
    {-# INLINE shape #-}
    bounds (Matrix a) = boundsIOMatrix a
    {-# INLINE bounds #-}

instance MatrixShaped Matrix where
    herm (Matrix a) = Matrix (herm a)
    {-# INLINE herm #-}
    
instance HasVectorView Matrix where
    type VectorView Matrix = Vector
    
instance (Elem e) => BaseMatrix Matrix e where
    ldaMatrix (Matrix a) = ldaMatrixIOMatrix a
    {-# INLINE ldaMatrix #-}
    isHermMatrix (Matrix a) = isHermMatrix a
    {-# INLINE isHermMatrix #-}
    unsafeSubmatrixView (Matrix a) ij mn =
        Matrix (unsafeSubmatrixViewIOMatrix a ij mn)
    {-# INLINE unsafeSubmatrixView #-}
    unsafeDiagView (Matrix a) i = Vector (unsafeDiagViewIOMatrix a i)
    {-# INLINE unsafeDiagView #-}
    unsafeRowView (Matrix a) i = Vector (unsafeRowViewIOMatrix a i)
    {-# INLINE unsafeRowView #-}
    unsafeColView (Matrix a) i = Vector (unsafeColViewIOMatrix a i)
    {-# INLINE unsafeColView #-}
    maybeViewMatrixAsVector (Matrix a) = liftM Vector (maybeViewMatrixAsVector a)
    {-# INLINE maybeViewMatrixAsVector #-}
    maybeViewVectorAsMatrix mn (Vector x) = 
        liftM Matrix $ maybeViewVectorAsIOMatrix mn x
    {-# INLINE maybeViewVectorAsMatrix #-}
    maybeViewVectorAsRow (Vector x) = liftM Matrix (maybeViewVectorAsRow x)
    {-# INLINE maybeViewVectorAsRow #-}
    maybeViewVectorAsCol (Vector x) = liftM Matrix (maybeViewVectorAsCol x)
    {-# INLINE maybeViewVectorAsCol #-}
    unsafeIOMatrixToMatrix = Matrix
    {-# INLINE unsafeIOMatrixToMatrix #-}
    unsafeMatrixToIOMatrix (Matrix a) = a
    {-# INLINE unsafeMatrixToIOMatrix #-}

instance (BLAS3 e) => ITensor Matrix (Int,Int) e where
    size (Matrix a) = sizeIOMatrix a
    {-# INLINE size #-}
    (//)          = replaceMatrix
    unsafeReplace = unsafeReplaceMatrix
    unsafeAt      = unsafeAtMatrix
    {-# INLINE unsafeAt #-}
    indices       = indicesMatrix
    {-# INLINE indices #-}
    elems         = elemsMatrix
    {-# INLINE elems #-}
    assocs        = assocsMatrix
    {-# INLINE assocs #-}
    tmap          = tmapMatrix
    {-# INLINE tmap #-}
    (*>) k (Matrix a) = unsafePerformIO $ liftM coerceMatrix $
        unsafeFreezeIOMatrix =<< getScaledMatrix k (coerceMatrix a)
    {-# NOINLINE (*>) #-}
    shift k (Matrix a) = unsafePerformIO $ liftM coerceMatrix $
        unsafeFreezeIOMatrix =<< getShiftedMatrix k (coerceMatrix a)
    {-# NOINLINE shift #-}

instance (BLAS3 e, Monad m) => ReadTensor Matrix (Int,Int) e m where
    getSize = return . size
    {-# INLINE getSize #-}
    getAssocs = return . assocs
    {-# INLINE getAssocs #-}
    getIndices = return . indices
    {-# INLINE getIndices #-}
    getElems = return . elems
    {-# INLINE getElems #-}
    getAssocs' = return . assocs
    {-# INLINE getAssocs' #-}
    getIndices' = return . indices
    {-# INLINE getIndices' #-}
    getElems' = return . elems
    {-# INLINE getElems' #-}
    unsafeReadElem x i = return $ unsafeAt x i
    {-# INLINE unsafeReadElem #-}

instance (BLAS3 e) => MMatrix Matrix e IO where
    unsafeDoSApplyAdd = gemv
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = gemm
    {-# INLINE unsafeDoSApplyAddMat #-}
    unsafeGetRow = unsafeGetRowMatrix
    {-# INLINE unsafeGetRow #-}
    unsafeGetCol = unsafeGetColMatrix
    {-# INLINE unsafeGetCol #-}
    getRows = getRowsIO
    {-# INLINE getRows #-}
    getCols = getColsIO
    {-# INLINE getCols #-}

instance (BLAS3 e) => MMatrix (Herm Matrix) e IO where
    unsafeDoSApplyAdd = hemv'
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = hemm'
    {-# INLINE unsafeDoSApplyAddMat #-}    
    getRows = getRowsIO
    {-# INLINE getRows #-}
    getCols = getColsIO
    {-# INLINE getCols #-}

instance (BLAS3 e) => MMatrix (Tri Matrix) e IO where
    unsafeDoSApplyAdd = unsafeDoSApplyAddTriMatrix
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = unsafeDoSApplyAddMatTriMatrix
    {-# INLINE unsafeDoSApplyAddMat #-}
    unsafeDoSApply_ = trmv
    {-# INLINE unsafeDoSApply_ #-}
    unsafeDoSApplyMat_ = trmm
    {-# INLINE unsafeDoSApplyMat_ #-}
    getRows = getRowsIO
    {-# INLINE getRows #-}
    getCols = getColsIO
    {-# INLINE getCols #-}

instance (BLAS3 e) => MSolve  (Tri Matrix) e IO where
    unsafeDoSSolve = unsafeDoSSolveTriMatrix
    {-# INLINE unsafeDoSSolve #-}
    unsafeDoSSolveMat = unsafeDoSSolveMatTriMatrix
    {-# INLINE unsafeDoSSolveMat #-}    
    unsafeDoSSolve_ = trsv
    {-# INLINE unsafeDoSSolve_ #-}
    unsafeDoSSolveMat_ = trsm
    {-# INLINE unsafeDoSSolveMat_ #-}

instance (BLAS3 e) => ReadMatrix Matrix e IO where
    unsafePerformIOWithMatrix (Matrix a) f = f a
    {-# INLINE unsafePerformIOWithMatrix #-}
    freezeMatrix (Matrix a) = freezeIOMatrix a
    {-# INLINE freezeMatrix #-}
    unsafeFreezeMatrix (Matrix a) = unsafeFreezeIOMatrix a
    {-# INLINE unsafeFreezeMatrix #-}

instance (BLAS3 e) => MMatrix Matrix e (ST s) where
    unsafeDoSApplyAdd = gemv
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = gemm
    {-# INLINE unsafeDoSApplyAddMat #-}
    unsafeGetRow = unsafeGetRowMatrix
    {-# INLINE unsafeGetRow #-}
    unsafeGetCol = unsafeGetColMatrix
    {-# INLINE unsafeGetCol #-}
    getRows = getRowsST
    {-# INLINE getRows #-}
    getCols = getColsST
    {-# INLINE getCols #-}

instance (BLAS3 e) => MMatrix (Herm Matrix) e (ST s) where
    unsafeDoSApplyAdd = hemv'
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = hemm'
    {-# INLINE unsafeDoSApplyAddMat #-}    
    getRows = getRowsST
    {-# INLINE getRows #-}
    getCols = getColsST
    {-# INLINE getCols #-}

instance (BLAS3 e) => MMatrix (Tri Matrix) e (ST s) where
    unsafeDoSApplyAdd = unsafeDoSApplyAddTriMatrix
    {-# INLINE unsafeDoSApplyAdd #-}
    unsafeDoSApplyAddMat = unsafeDoSApplyAddMatTriMatrix
    {-# INLINE unsafeDoSApplyAddMat #-}
    unsafeDoSApply_ = trmv
    {-# INLINE unsafeDoSApply_ #-}
    unsafeDoSApplyMat_ = trmm
    {-# INLINE unsafeDoSApplyMat_ #-}
    getRows = getRowsST
    {-# INLINE getRows #-}
    getCols = getColsST
    {-# INLINE getCols #-}

instance (BLAS3 e) => MSolve  (Tri Matrix) e (ST s) where
    unsafeDoSSolve = unsafeDoSSolveTriMatrix
    {-# INLINE unsafeDoSSolve #-}
    unsafeDoSSolveMat = unsafeDoSSolveMatTriMatrix
    {-# INLINE unsafeDoSSolveMat #-}    
    unsafeDoSSolve_ = trsv
    {-# INLINE unsafeDoSSolve_ #-}
    unsafeDoSSolveMat_ = trsm
    {-# INLINE unsafeDoSSolveMat_ #-}

instance (BLAS3 e) => ReadMatrix Matrix e (ST s) where
    unsafePerformIOWithMatrix (Matrix a) f = unsafeIOToST $ f a
    {-# INLINE unsafePerformIOWithMatrix #-}
    freezeMatrix (Matrix a) = unsafeIOToST $ freezeIOMatrix a
    {-# INLINE freezeMatrix #-}
    unsafeFreezeMatrix (Matrix a) = unsafeIOToST $ unsafeFreezeIOMatrix a
    {-# INLINE unsafeFreezeMatrix #-}

compareMatrixWith :: (BLAS3 e) => 
    (e -> e -> Bool) -> Matrix (n,p) e -> Matrix (n,p) e -> Bool
compareMatrixWith cmp a b
    | shape a /= shape b =
        False
    | isHermMatrix a == isHermMatrix b =
        let elems' = if isHermMatrix a then elems . herm
                                       else elems
        in
            and $ zipWith cmp (elems' a) (elems' b)
    | otherwise =
        and $ zipWith cmp (colElems a) (colElems b)
  where
    colElems c = concatMap elems (colViews $ coerceMatrix c)

instance (BLAS3 e, Eq e) => Eq (Matrix (n,p) e) where
    (==) = compareMatrixWith (==)

instance (BLAS3 e, AEq e) => AEq (Matrix (n,p) e) where
    (===) = compareMatrixWith (===)
    (~==) = compareMatrixWith (~==)

instance (BLAS3 e, Show e) => Show (Matrix (n,p) e) where
    show a | isHermMatrix a = 
                "herm (" ++ show (herm a) ++ ")"
           | otherwise =
                "listMatrix " ++ show (shape a) ++ " " ++ show (elems a)
        
instance (BLAS3 e) => Num (Matrix (n,p) e) where
    (+) x y     = unsafePerformIO $ unsafeFreezeIOMatrix =<< getAddMatrix x y
    {-# NOINLINE (+) #-}
    (-) x y     = unsafePerformIO $ unsafeFreezeIOMatrix =<< getSubMatrix x y
    {-# NOINLINE (-) #-}
    (*) x y     = unsafePerformIO $ unsafeFreezeIOMatrix =<< getMulMatrix x y
    {-# NOINLINE (*) #-}
    negate      = ((-1) *>)
    abs         = tmap abs
    signum      = tmap signum
    fromInteger = coerceMatrix . (constantMatrix (1,1)) . fromInteger
    
instance (BLAS3 e) => Fractional (Matrix (n,p) e) where
    (/) x y      = unsafePerformIO $ unsafeFreezeIOMatrix =<< getDivMatrix x y
    {-# NOINLINE (/) #-}
    recip        = tmap recip
    fromRational = coerceMatrix . (constantMatrix (1,1)) . fromRational 

instance (BLAS3 e, Floating e) => Floating (Matrix (m,n) e) where
    pi    = constantMatrix (1,1) pi
    exp   = tmap exp
    sqrt  = tmap sqrt
    log   = tmap log
    (**)  = tzipWithMatrix (**)
    sin   = tmap sin
    cos   = tmap cos
    tan   = tmap tan
    asin  = tmap asin
    acos  = tmap acos
    atan  = tmap atan
    sinh  = tmap sinh
    cosh  = tmap cosh
    tanh  = tmap tanh
    asinh = tmap asinh
    acosh = tmap acosh
    atanh = tmap atanh

-- | Take a unary elementwise vector operation and apply it to the elements
-- of a matrix.
liftMatrix :: (ReadMatrix a e m) =>
    (forall k. VectorView a k e -> m ()) -> a (n,p) e -> m ()
liftMatrix f a =
    case maybeViewMatrixAsVector a of
        Just x -> f x
        _ ->
            let xs = case isHermMatrix a of
                          True ->  rowViews (coerceMatrix a)
                          False -> colViews (coerceMatrix a)
            in mapM_ f xs
{-# INLINE liftMatrix #-}

-- | Take a binary elementwise vector operation and apply it to the elements
-- of a pair of matrices.
liftMatrix2 :: (ReadMatrix a e m, ReadMatrix b f m) =>
    (forall k. VectorView a k e -> VectorView b k f -> m ()) ->
        a (n,p) e -> b (n,p) f -> m ()
liftMatrix2 f a b =
    if isHermMatrix a == isHermMatrix b
        then case (maybeViewMatrixAsVector a, maybeViewMatrixAsVector b) of
                 ((Just x), (Just y)) -> f x y
                 _                    -> elementwise
        else elementwise
  where
    elementwise =
        let vecsA = if isHermMatrix a then rowViews . coerceMatrix
                                      else colViews . coerceMatrix
            vecsB = if isHermMatrix a then rowViews . coerceMatrix
                                      else colViews . coerceMatrix
            xs = vecsA a
            ys = vecsB b
        in zipWithM_ f xs ys
{-# INLINE liftMatrix2 #-}

checkMatrixOp2 :: (BaseMatrix x e, BaseMatrix y f) => 
    (x n e -> y n f -> a) ->
        x n e -> y n f -> a
checkMatrixOp2 f x y = 
    checkBinaryOp (shape x) (shape y) $ f x y
{-# INLINE checkMatrixOp2 #-}

getUnaryMatrixOp :: (ReadMatrix a e m, WriteMatrix b e m) =>
    (b (n,p) e -> m ()) -> a (n,p) e -> m (b (n,p) e)
getUnaryMatrixOp f a = do
    b <- newCopyMatrix a
    f b
    return b
{-# INLINE getUnaryMatrixOp #-}

unsafeGetBinaryMatrixOp :: 
    (WriteMatrix c e m, ReadMatrix a e m, ReadMatrix b f m) =>
    (c (n,p) e -> b (n,p) f -> m ()) ->
        a (n,p) e -> b (n,p) f -> m (c (n,p) e)
unsafeGetBinaryMatrixOp f a b = do
    c <- newCopyMatrix a
    f c b
    return c

transMatrix :: (BaseMatrix a e) => a (n,p) e -> TransEnum
transMatrix a = 
    case (isHermMatrix a) of
          False -> NoTrans
          True  -> ConjTrans
{-# INLINE transMatrix #-}

indexOfMatrix :: (BaseMatrix a e) => a (n,p) e -> (Int,Int) -> Int
indexOfMatrix a (i,j) = 
    let (i',j') = case isHermMatrix a of
                        True  -> (j,i)
                        False -> (i,j)
        l = ldaMatrix a
    in i' + j'*l
{-# INLINE indexOfMatrix #-}