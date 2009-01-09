{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_HADDOCK hide #-}
-----------------------------------------------------------------------------
-- |
-- Module     : Test.Matrix.Tri.Banded
-- Copyright  : Copyright (c) 2008, Patrick Perry <patperry@stanford.edu>
-- License    : BSD3
-- Maintainer : Patrick Perry <patperry@stanford.edu>
-- Stability  : experimental
--

module Test.Matrix.Tri.Banded (
    TriBanded(..),
    TriBandedMV(..),
    TriBandedMM(..),
    TriBandedSV(..),
    TriBandedSM(..),
    ) where

import Control.Monad ( replicateM )

import Test.QuickCheck hiding ( Test.vector )
import Test.QuickCheck.BLAS ( TestElem )
import qualified Test.QuickCheck as QC
import qualified Test.QuickCheck.BLAS as Test

import Data.Vector.Dense ( Vector )
import Data.Matrix.Dense ( Matrix )
import Data.Matrix.Banded
import Data.Matrix.Banded.Base( listsFromBanded )
import Data.Elem.BLAS ( BLAS3 )

import Data.Matrix.Tri ( Tri, triFromBase )
import Data.Matrix.Class( UpLoEnum(..), DiagEnum(..) )

import Unsafe.Coerce

triBanded :: (TestElem e) => UpLoEnum -> DiagEnum -> Int -> Int -> Gen (Banded (n,n) e)
triBanded Upper NonUnit n k = do
    a <- triBanded Upper Unit n k
    d <- Test.elements n
    let (_,_,(_:ds)) = listsFromBanded a
    return $ listsBanded (n,n) (0,k) (d:ds)

triBanded Lower NonUnit n k = do
    a <- triBanded Lower Unit n k
    d <- Test.elements n
    let (_,_,ds) = listsFromBanded a
        ds' = (init ds) ++ [d]
    return $ listsBanded (n,n) (k,0) ds'
    
triBanded _ Unit n 0 = do
    return $ listsBanded (n,n) (0,0) [replicate n 1]
    
triBanded Upper Unit n k = do
    a <- triBanded Upper Unit n (k-1)
    let (_,_,ds) = listsFromBanded a
    
    d <- Test.elements (n-k) >>= \xs -> return $ xs ++ replicate k 0
    
    return $ listsBanded (n,n) (0,k) $ ds ++ [d]
    
triBanded Lower Unit n k = do
    a <- triBanded Lower Unit n (k-1)
    let (_,_,ds) = listsFromBanded a

    d <- Test.elements (n-k) >>= \xs -> return $ replicate k 0 ++ xs
    
    return $ listsBanded (n,n) (k,0) $ [d] ++ ds
    
    
data TriBanded n e = 
    TriBanded (Tri Banded (n,n) e) (Banded (n,n) e) deriving Show

instance (TestElem e) => Arbitrary (TriBanded n e) where
    arbitrary = do
        u <- elements [ Upper, Lower  ]
        d <- elements [ Unit, NonUnit ]
        (m,n) <- Test.shape
        (_,k) <- Test.bandwidths (m,n)
        a <- triBanded u d n k

        l    <- if n == 0 then return 0 else choose (0,n-1)
        junk <- replicateM l $ Test.elements n
        diagJunk <- Test.elements n
        let (_,_,ds) = listsFromBanded a
            t = triFromBase u d $ case (u,d) of 
                    (Upper,NonUnit) -> 
                        listsBanded (n,n) (l,k) $ junk ++ ds
                    (Upper,Unit) ->
                        listsBanded (n,n) (l,k) $ junk ++ [diagJunk] ++ tail ds
                    (Lower,NonUnit) -> 
                        listsBanded (n,n) (k,l) $ ds ++ junk
                    (Lower,Unit) -> 
                        listsBanded (n,n) (k,l) $ init ds ++ [diagJunk] ++ junk

        (t',a') <- elements [ (t,a), unsafeCoerce (herm t, herm a)]
        return $ TriBanded t' a'
            
    coarbitrary = undefined

data TriBandedMV n e = 
    TriBandedMV (Tri Banded (n,n) e) (Banded (n,n) e) (Vector n e) deriving Show

instance (TestElem e) => Arbitrary (TriBandedMV n e) where
    arbitrary = do
        (TriBanded t a) <- arbitrary
        x <- Test.vector (numCols t)
        return $ TriBandedMV t a x
        
    coarbitrary = undefined
        
data TriBandedMM m n e = 
    TriBandedMM (Tri Banded (m,m) e) (Banded (m,m) e) (Matrix (m,n) e) deriving Show

instance (TestElem e) => Arbitrary (TriBandedMM m n e) where
    arbitrary = do
        (TriBanded t a) <- arbitrary
        (_,n) <- Test.shape
        b <- Test.matrix (numCols t, n)
        return $ TriBandedMM t a b
            
    coarbitrary = undefined
        
data TriBandedSV n e = 
    TriBandedSV (Tri Banded (n,n) e) (Vector n e) deriving (Show)
    
instance (TestElem e) => Arbitrary (TriBandedSV n e) where
    arbitrary = do
        (TriBanded t a) <- arbitrary
        if any (== 0) (elems $ diagBanded a 0)
            then arbitrary
            else do
                x <- Test.vector (numCols t)
                let y = t <*> x
                return (TriBandedSV t y)
        
    coarbitrary = undefined


data TriBandedSM m n e = 
    TriBandedSM (Tri Banded (m,m) e) (Matrix (m,n) e) 
    deriving (Show)
    
instance (TestElem e) => Arbitrary (TriBandedSM m n e) where
    arbitrary = do
        (TriBandedSV t _) <- arbitrary
        (_,n) <- Test.shape
        a <- Test.matrix (numCols t, n)
        
        let b = t <**> a
        return (TriBandedSM t b)
        
    coarbitrary = undefined
    