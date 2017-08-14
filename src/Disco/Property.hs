{-# LANGUAGE GADTs #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Disco.Property
-- Copyright   :  (c) 2016-2017 disco team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@gmail.com
--
-- Properties of disco functions.
--
-----------------------------------------------------------------------------

module Disco.Property
       where

import           Unbound.Generics.LocallyNameless (Name, lunbind)

import qualified Test.QuickCheck                  as QC

import           Control.Monad.Except
import           Data.Coerce
import           Data.List                        (transpose)
import qualified Data.Map                         as M
import           Data.Ratio
import           Data.Traversable                 (for)

import           Disco.AST.Core
import           Disco.AST.Typed
import           Disco.Context
import           Disco.Desugar
import           Disco.Eval
import           Disco.Interpret.Core
import           Disco.Syntax.Operators           (BOp (..))
import           Disco.Types
-- XXX make TestResult more informative:
--   - if it succeeded, was it tested exhaustively, or randomly?
--   - if the latter, how many examples were used?
--   - If a random test failed, what were the inputs that produced
--     the counterexample?

data TestResult
  = TestOK
  | TestFalse
  | TestRuntimeFailure InterpError
  | TestEqualityFailure Value Type Value Type

instance Monoid TestResult where
  mempty = TestOK
  TestOK `mappend` r = r
  r `mappend` _      = r

testIsOK :: TestResult -> Bool
testIsOK TestOK = True
testIsOK _ = False

-- XXX comment me

-- XXX if there is a quantifier, present it as a counterexample rather
-- than just an equality test failure

-- XXX do shrinking for randomly generated test cases

-- XXX don't reload defs every time?
runTest :: Int -> Ctx Core Core -> AProperty -> Disco TestResult
runTest n defs aprop
  = flip catchError (return . TestRuntimeFailure) . fmap mconcat
    . withDefs defs $ do
  lunbind aprop $ \(binds, at) -> do
    envs <- testCases n binds
    for envs $ \env -> extendsEnv env $ do
      case getEquatands at of
        Nothing        -> do
          v <- evalTerm at
          case v of
            VCons 1 [] -> return TestOK
            _          -> return TestFalse
        Just (at1,at2) -> do
          v1 <- evalTerm at1
          v2 <- evalTerm at2
          v <- decideEqFor (getType at1) v1 v2
          case v of
            True  -> return TestOK
            False -> return $ TestEqualityFailure v1 (getType at1) v2 (getType at2)
  where
    evalTerm = rnf . runDSM . desugarTerm

-- | Check whether a term looks like a top-level equality test.
getEquatands :: ATerm -> Maybe (ATerm, ATerm)
getEquatands (ATBin _ Eq at1 at2) = Just (at1, at2)
getEquatands _                    = Nothing

-- | @testCases n bindings@ generates environments in which to conduct
--   tests.  If @bindings@ is empty, only one test is necessary, and
--   @testCases@ returns a singleton list with the empty environment.
--   Otherwise, @testCases@ generates @n@ environments; in each
--   environment the given names are bound to values of the
--   appropriate types.  The values in the first environment are
--   simplest; they become increasingly complex as the environments
--   progress.
testCases :: Int -> [(Name ATerm, Type)] -> Disco [Env]
testCases _ []    = return [M.empty]
testCases n binds = do
  valLists <- mapM (genValues n) tys
  return $ map (M.fromList . zip ys) $ transpose valLists
  where
    (xs, tys) = unzip binds
    ys :: [Name Core]
    ys = map coerce xs

------------------------------------------------------------
-- Random test case generation
------------------------------------------------------------

-- | A generator of disco values.
data DiscoGen where

  -- | A @DiscoGen@ contains a QuickCheck generator of an
  --   existentially quantified type, and a way to turn that type into a
  --   disco 'Value'.
  DiscoGen :: QC.Gen a -> (a -> Value) -> DiscoGen

  -- | Alternatively, a @Universe@ has a list of all values of the
  --   given type, along with a cached size.  Invariant: the Integer
  --   is equal to the length of the list.
  Universe :: Integer -> [Value] -> DiscoGen

emptyUniverse :: DiscoGen
emptyUniverse = Universe 0 []

-- | Convert a 'Universe'-style 'DiscoGen' into a generator-style one,
--   unless it is empty.
fromUniverse :: DiscoGen -> DiscoGen
fromUniverse g@(DiscoGen _ _) = g
fromUniverse (Universe 0 [])  = emptyUniverse
fromUniverse (Universe _ vs)  = DiscoGen (QC.elements vs) id

-- | Create the 'DiscoGen' for a given type.
discoGenerator :: Type -> DiscoGen
discoGenerator TyN = DiscoGen
  (QC.arbitrary :: QC.Gen (QC.NonNegative Integer))
  (vnum . (%1) . QC.getNonNegative)
discoGenerator TyZ = DiscoGen
  (QC.arbitrary :: QC.Gen Integer)
  (vnum . (%1))
discoGenerator TyQP = DiscoGen
  (QC.arbitrary :: QC.Gen (QC.NonNegative Integer, QC.Positive Integer))
  (\(QC.NonNegative m, QC.Positive n) -> vnum (m % (n+1)))
discoGenerator TyQ  = DiscoGen
  (QC.arbitrary :: QC.Gen (Integer, QC.Positive Integer))
  (\(m, QC.Positive n) -> vnum (m % (n+1)))

discoGenerator (TyFin n)
  | n <= 32   = Universe n (map (vnum . (%1)) [0 .. n-1])
  | otherwise = DiscoGen
      (QC.choose (0,n-1) :: QC.Gen Integer)
      (\n -> vnum (n%1))

discoGenerator (TyList ty)  = case fromUniverse $ discoGenerator ty of
  Universe _ _ {- empty -} -> emptyUniverse
  DiscoGen tyGen tyToValue -> DiscoGen (QC.listOf tyGen) (toDiscoList . map tyToValue)

discoGenerator ty@(TyVar _) = error $ "discoGenerator " ++ show ty
discoGenerator TyVoid       = emptyUniverse
discoGenerator TyUnit       = Universe 1 [VCons 0 []]
discoGenerator TyBool       = Universe 2 [VCons 0 [], VCons 1 []]
discoGenerator (TyPair ty1 ty2) =
  case (discoGenerator ty1, discoGenerator ty2) of
    (Universe 0 _, _) -> emptyUniverse
    (_, Universe 0 _) -> emptyUniverse
    (Universe n1 vs1, Universe n2 vs2)
      | n1 * n2 <= 32 {- XXX configurable? -} ->
        Universe (n1*n2) [vPair v1 v2 | v1 <- vs1, v2 <- vs2]
    (g1, g2) ->
      case (fromUniverse g1, fromUniverse g2) of
        (DiscoGen gen1 toValue1, DiscoGen gen2 toValue2) ->
          DiscoGen
            ((,) <$> gen1 <*> gen2)
            (\(a,b) -> vPair (toValue1 a) (toValue2 b))
  where
    vPair v1 v2 = VCons 0 [v1, v2]
discoGenerator (TySum ty1 ty2) =
  case (discoGenerator ty1, discoGenerator ty2) of
    (Universe n1 vs1, Universe n2 vs2)
      | n1 + n2 <= 32 ->
        Universe (n1 + n2)
          (map vLeft vs1 ++ map vRight vs2)
    (g1, g2) ->
      case (fromUniverse g1, fromUniverse g2) of
        (DiscoGen gen1 toValue1, DiscoGen gen2 toValue2) ->
          DiscoGen
            (QC.choose (0 :: Double, 1) >>= \r ->
               if r < 0.5 then Left <$> gen1 else Right <$> gen2)
            (either (vLeft . toValue1) (vRight . toValue2))
  where
    vLeft  v = VCons 0 [v]
    vRight v = VCons 1 [v]

-- | @genValues n ty@ generates a sequence of @n@ increasingly complex
--   values of type @ty@, using the 'DiscoGen' for @ty@.
genValues :: Int -> Type -> Disco [Value]
genValues n ty = case discoGenerator ty of
  DiscoGen gen toValue -> do
    as <- generate n gen
    return $ map toValue as
  Universe _ vs -> return vs

-- | Use a QuickCheck generator to generate a given number of
--   increasingly complex values of a given type.  Like the @sample'@
--   function from QuickCheck, but the number of values is
--   configurable, and it lives in the @Disco@ monad.
generate :: Int -> QC.Gen a -> Disco [a]
generate n gen = io . QC.generate $ sequence [QC.resize m gen | m <- [0 .. n]]
