{-# LANGUAGE GADTSyntax #-}

module Solve
  ( solveConstraints, SolveError(..) )
  where

import           Data.Coerce

import           Control.Arrow ((***), (&&&), first, second)
import           Data.Map (Map, (!))
import qualified Data.Map    as M
import           Data.Set (Set)
import qualified Data.Set    as S

import           Control.Lens (toListOf, each, (^..), both)

import           Control.Monad.Except
import           Control.Monad.State

import           Unbound.Generics.LocallyNameless

import qualified Graph as G
import           Graph (Graph)
import           Subst
import           Types
import           Constraints
import           Unify

------------------------------------------------------------
-- Errors
------------------------------------------------------------

-- | Type of errors which can be generated by the constraint solving
--   process.
data SolveError where
  NoWeakUnifier :: SolveError
  NoUnify :: SolveError
  deriving Show

-- | Convert 'Nothing' into the given error.
maybeError :: e -> Maybe a -> Except e a
maybeError e Nothing  = throwError e
maybeError _ (Just a) = return a

------------------------------------------------------------
-- Top-level solving algorithm
------------------------------------------------------------

-- | Given an arbitrary list of equality and subtyping constraints on
--   types with type variables, either solve them, resulting in a
--   substitution for the type variables, or throw an error if the
--   constraints are unsolvable.  Based on the algorithm given in
--   Dmitriy Traytel, Stefan Berghofer, and Tobias Nipkow, "Extending
--   Hindley-Milner Type Inference with Coercive
--   Subtyping". Programming Languages and Systems (2011): 89-104.
solveConstraints :: [Constraint Type] -> Except SolveError S
solveConstraints cs = do

  -- Step 1: check whether the constraints have a weak unifier.  If
  -- not, we know they cannot be solved; if so, we know the
  -- simplification algorithm will terminate.
  maybeError NoWeakUnifier $ weakUnify (map (either id toEqn) cs)

  -- Step 2: simplify the given constraints, resulting in a set of
  -- atomic subtyping constraints along with a substitution.
  (atomicConstraints, θ_simp) <- simplify cs

  -- Step 3: turn the remaining atomic subtyping constraints into a
  -- directed constraint graph.
  let g = mkConstraintGraph atomicConstraints

  -- Step 4: eliminate cycles from the graph, turning each strongly
  -- connected component into a single node, unifying all the atoms in
  -- each component.
  (g', θ_cyc) <- elimCycles g

  -- Steps 5 and 6: solve the graph, iteratively finding satisfying
  -- assignments for each type variable based on its successor and
  -- predecessor base types in the graph; then unify all the type
  -- variables in any remaining weakly connected components.
  θ_sol       <- solveGraph g'

  return (θ_sol @@ θ_cyc @@ θ_simp)

------------------------------------------------------------
-- Step 2: constraint simplification
------------------------------------------------------------

type SimplifyM a = StateT ([Constraint Type], S) (LFreshMT (Except SolveError)) a

-- | This step does unification of equality constraints, as well as
--   structural decomposition of subtyping constraints.  For example,
--   if we have a constraint (x -> y) <: (z -> Int), then we can
--   decompose it into two constraints, (z <: x) and (y <: Int); if we
--   have a constraint v <: (a,b), then we substitute v ↦ (x,y) (where
--   x and y are fresh type variables) and continue; and so on.
--
--   After this step, the remaining constraints will all be atomic
--   constraints, that is, only of the form (v1 <: v2), (v <: b), or
--   (b <: v), where v is a type variable and b is a base type.

simplify :: [Constraint Type] -> Except SolveError ([(Atom, Atom)], S)
simplify cs
  = (fmap . first . map) extractAtoms
  $ runLFreshMT (execStateT simplify' (cs, idS))
  where

    -- Extract the type atoms from an atomic constraint.
    extractAtoms (Right (TyAtom a1 :<: TyAtom a2)) = (a1, a2)
    extractAtoms c = error $ "simplify left non-atomic or non-subtype constraint " ++ show c

    -- Iterate picking one simplifiable constraint and simplifying it
    -- until none are left.
    simplify' :: SimplifyM ()
    simplify' = avoid (toListOf fvAny cs) $ do
      mc <- pickSimplifiable
      case mc of
        Nothing -> return ()
        Just s  -> simplifyOne s >> simplify'

    -- Pick out one simplifiable constraint, removing it from the list
    -- of constraints in the state.  Return Nothing if no more
    -- constraints can be simplified.
    pickSimplifiable :: SimplifyM (Maybe (Constraint Type))
    pickSimplifiable = do
      cs <- fst <$> get
      case pick simplifiable cs of
        Nothing     -> return Nothing
        Just (a,as) -> modify (first (const as)) >> return (Just a)

    -- Pick the first element from a list satisfying the given
    -- predicate, returning the element and the list with the element
    -- removed.
    pick :: (a -> Bool) -> [a] -> Maybe (a,[a])
    pick _ [] = Nothing
    pick p (a:as)
      | p a       = Just (a,as)
      | otherwise = second (a:) <$> pick p as

    -- Check if a constraint can be simplified.  An equality
    -- constraint can always be "simplified" via unification.  A
    -- subtyping constraint can be simplified if either it involves a
    -- type constructor (in which case we can decompose it), or if it
    -- involves two base types (in which case it can be removed if the
    -- relationship holds).
    simplifiable :: Constraint Type -> Bool
    simplifiable (Left _) = True
    simplifiable (Right (TyCons {} :<: TyCons {})) = True
    simplifiable (Right (TyVar  {} :<: TyCons {})) = True
    simplifiable (Right (TyCons {} :<: TyVar  {})) = True
    simplifiable (Right (TyAtom a1 :<: TyAtom a2)) = isBase a1 && isBase a2

    -- Simplify the given simplifiable constraint.
    simplifyOne :: Constraint Type -> SimplifyM ()

    -- If we have an equality constraint, run unification on it.  The
    -- resulting substitution is applied to the remaining constraints
    -- as well as prepended to the current substitution.
    simplifyOne (Left eqn) =
      case unify [eqn] of
        Nothing -> throwError NoUnify
        Just s' -> modify (substs s' *** (s' @@))

    -- Given a subtyping constraint between two type constructors,
    -- decompose it if the constructors are the same (or fail if they
    -- aren't), taking into account the variance of each argument to
    -- the constructor.
    simplifyOne (Right (TyCons c1 tys1 :<: TyCons c2 tys2))
      | c1 /= c2  = throwError NoUnify
      | otherwise = modify (first (zipWith3 variance (arity c1) tys1 tys2 ++))

    -- Given a subtyping constraint between a variable and a type
    -- constructor, expand the variable into the same constructor
    -- applied to fresh type variables.
    simplifyOne con@(Right (TyVar a :<: TyCons c tys)) = do
      as <- mapM (const (TyVar <$> lfresh (string2Name "a"))) (arity c)
      let s' = a |-> TyCons c as
      modify ((substs s' . (con:)) *** (s'@@))
    simplifyOne (Right (c@(TyCons {}) :<: v@(TyVar {})))
      = simplifyOne (Right (v :<: c))

    -- Given a subtyping constraint between two base types, just check
    -- whether the first is indeed a subtype of the second.  (Note
    -- that we only pattern match here on type atoms, which could
    -- include variables, but this will only ever get called if
    -- 'simplifiable' was true, which checks that both are base
    -- types.)
    simplifyOne (Right (TyAtom a1 :<: TyAtom a2)) = do
      case isSub a1 a2 of
        True  -> return ()
        False -> throwError NoUnify

    -- Create a subtyping constraint based on the variance of a type
    -- constructor argument position: in the usual order for
    -- covariant, and reversed for contravariant.
    variance Co     ty1 ty2 = ty1 =<= ty2
    variance Contra ty1 ty2 = ty2 =<= ty1

------------------------------------------------------------
-- Step 3: Build constraint graph
------------------------------------------------------------

-- | Given a list of atomic subtype constraints (each pair @(a1,a2)@
--   corresponds to the constraint @a1 <: a2@) build the corresponding
--   constraint graph.
mkConstraintGraph :: [(Atom, Atom)] -> Graph Atom
mkConstraintGraph cs = G.mkGraph nodes (S.fromList cs)
  where
    nodes = S.fromList $ cs ^.. traverse . each

------------------------------------------------------------
-- Step 4: Eliminate cycles
------------------------------------------------------------

-- | Eliminate cycles in the constraint set by collapsing each
--   strongly connected component to a single node, (unifying all the
--   types in the SCC). A strongly connected component is a maximal
--   set of nodes where every node is reachable from every other by a
--   directed path; since we are using directed edges to indicate a
--   subtyping constraint, this means every node must be a subtype of
--   every other, and the only way this can happen is if all are in
--   fact equal.
--
--   Of course, this step can fail if the types in a SCC are not
--   unifiable.  If it succeeds, it returns the collapsed graph (which
--   is now guaranteed to be acyclic, i.e. a DAG) and a substitution.
elimCycles :: Graph Atom -> Except SolveError (Graph Atom, S)
elimCycles g
  = maybeError NoUnify
  $ (G.map fst &&& (compose . S.map snd . G.nodes)) <$> g'
  where

    g' :: Maybe (Graph (Atom, S))
    g' = G.sequenceGraph $ G.map unifySCC (G.condensation g)

    unifySCC :: Set Atom -> Maybe (Atom, S)
    unifySCC atoms
      | S.null atoms = error "Impossible! unifySCC on the empty set"
      | otherwise    = (flip substs a &&& id) <$> equate tys
      where
        as@(a:_) = S.toList atoms
        tys      = map TyAtom as

------------------------------------------------------------
-- Steps 5 and 6: Constraint resolution
------------------------------------------------------------

-- | Build the set of successor and predecessor base types of each
--   type variable in the constraint graph.  For each type variable,
--   make sure the sup of its predecessors is <: the inf of its
--   successors, and assign it one of the two: if it has only
--   successors, assign it their inf; otherwise, assign it the sup of
--   its predecessors.  If it has both predecessors and successors, we
--   have a choice of whether to assign it the sup of predecessors or
--   inf of successors; both lead to a sound & complete algorithm.  We
--   choose to assign it the sup of its predecessors in this case,
--   since it seems nice to default to "simpler" types lower down in
--   the subtyping chain.
--
--   After picking concrete base types for all the type variables we
--   can, the only thing possibly remaining in the graph are
--   components containing only type variables and no base types.  It
--   is sound, and simplifies the generated types considerably, to
--   simply unify any type variables which are related by subtyping
--   constraints.  That is, we collect all the type variables in each
--   weakly connected component and unify them.
--
--   As an example where this final step makes a difference, consider
--   a term like @\x. (\y.y) x@.  A fresh type variable is generated
--   for the type of @x@, and another for the type of @y@; the
--   application of @(\y.y)@ to @x@ induces a subtyping constraint
--   between the two type variables.  The most general type would be
--   something like @forall a b. (a <: b) => a -> b@, but we want to
--   avoid generating unnecessary subtyping constraints (the type
--   system might not even support subtyping qualifiers like this).
--   Instead, we unify the two type variables and the resulting type
--   is @forall a. a -> a@.
solveGraph :: Graph Atom -> Except SolveError S
solveGraph g = (convertSubst . unifyWCC) <$> go ss ps
  where
    convertSubst :: S' Atom -> S
    convertSubst = map (coerce *** TyAtom)

    unifyWCC :: S' Atom -> S' Atom
    unifyWCC s = concatMap mkEquateSubst wccVarGroups @@ s
      where
        wccVarGroups  = filter (all isVar) . substs s $ G.wcc g
        mkEquateSubst = (\(a:as) -> map (\(AVar v) -> (coerce v, a)) as) . S.toList

    -- Get the successor and predecessor sets for all the type variables.
    (ss, ps) = (onlyVars *** onlyVars) $ G.cessors g
    onlyVars = M.filterWithKey (\a _ -> isVar a)

    go :: Map Atom (Set Atom) -> Map Atom (Set Atom) -> Except SolveError (S' Atom)
    go succs preds = case as of

      -- No variables left that have base type constraints.
      []    -> return idS

      -- Solve one variable at a time.  See below.
      (a:_) ->

        case solveVar a of
          Nothing       -> throwError NoUnify

          -- If we solved for a, delete it from the maps, apply the
          -- resulting substitution to the remainder, and recurse.
          -- The substitution we want will be the composition of the
          -- substitution for a with the substitution generated by the
          -- recursive call.
          Just s ->
            (@@ s) <$> go (substs s (M.delete a succs)) (substs s (M.delete a preds))

      where
        -- NOTE we can't solve a bunch in parallel!  Might end up
        -- assigning them conflicting solutions if some depend on
        -- others.  For example, consider the situation
        --
        --            Z
        --            |
        --            a3
        --           /  \
        --          a1   N
        --
        -- If we try to solve in parallel we will end up assigning a1
        -- -> Z (since it only has base types as an upper bound) and
        -- a3 -> N (since it has both upper and lower bounds, and by
        -- default we pick the lower bound), but this is wrong since
        -- we should have a1 < a3.
        --
        -- If instead we solve them one at a time, we could e.g. first
        -- solve a1 -> Z, and then we would find a3 -> Z as well.
        -- Alternately, if we first solve a3 -> N then we will have a1
        -- -> N as well.  Both are acceptable.
        --
        -- In fact, this exact graph comes from (^x.x+1) which was
        -- erroneously being inferred to have type Z -> N when I first
        -- wrote the code.

        -- Get only the variables we can solve on this pass, which
        -- have base types in their predecessor or successor set.
        as = filter (\a -> any isBase (succs ! a) || any isBase (preds ! a)) (M.keys succs)

        -- Solve for a variable, failing if it has no solution, otherwise returning
        -- a substitution for it.
        solveVar :: Atom -> Maybe (S' Atom)
        solveVar a@(AVar v) =
          case (filter isBase (S.toList $ succs ! a), filter isBase (S.toList $ preds ! a)) of
            ([], []) ->
              error $ "Impossible! solveGraph.solveVar called on variable "
                      ++ show a ++ " with no base type successors or predecessors"

            -- Only successors.  Just assign a to their inf, if one exists.
            (bsuccs, []) -> (coerce v |->) <$> ainf bsuccs

            -- Only predecessors.  Just assign a to their sup.
            ([], bpreds) -> (coerce v |->) <$> asup bpreds

            -- Both successors and predecessors.  Both must have a
            -- valid bound, and the bounds must not overlap.  Assign a
            -- to the sup of its predecessors.
            (bsuccs, bpreds) -> do
              ub <- ainf bsuccs
              lb <- asup bpreds
              case isSub lb ub of
                True  -> Just (coerce v |-> lb)
                False -> Nothing

        solveVar a = error $ "Impossible! solveGraph.solveVar called on non-variable " ++ show a

