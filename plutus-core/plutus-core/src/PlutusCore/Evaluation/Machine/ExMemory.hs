-- editorconfig-checker-disable-file
{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MagicHash             #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module PlutusCore.Evaluation.Machine.ExMemory
    ( CostingInteger
    , ExMemory(..)
    , CostRose(..)
    , ExCPU(..)
    , ExMemoryUsage(..)
    , CostStream(..)
    , unconsCost
    , reconsCost
    , sumCostStream
    , mapCostStream
    , addCostStream
    , minCostStream
    , toCostRose
    , flattenCostRose
    ) where

import PlutusCore.Data
import PlutusCore.Pretty
import PlutusPrelude

import Codec.Serialise (Serialise)
import Data.Aeson
import Data.ByteString qualified as BS
import Data.Proxy
import Data.SatInt
import Data.Text qualified as T
import GHC.Exts (Int (I#))
import GHC.Integer
import GHC.Integer.Logarithms
import GHC.Prim
import Language.Haskell.TH.Syntax (Lift)
import NoThunks.Class
import Universe

{-
 ************************************************************************************
 *  WARNING: exercise caution when altering the ExMemoryUsage instances here.       *
 *                                                                                  *
 *  The instances defined in this file will be used to calculate script validation  *
 *  costs, and if an instance is changed then any scripts which were deployed when  *
 *  a previous instance was in effect MUST STILL VALIDATE using the new instance.   *
 *  It is unsafe to increase the memory usage of a type because that may increase   *
 *  the resource usage of existing scripts beyond the limits set (and paid for)     *
 *  when they were uploaded to the chain, but because our costing functions are all *
 *  monotone) it is safe to decrease memory usage, as long it decreases for *all*   *
 *  possible values of the type.                                                    *
 ************************************************************************************
-}


{- Note [Memory Usage for Plutus]

The base unit is 'ExMemory', which corresponds to machine words. For primitives,
we use static values for the size, see the corresponding instances. For
composite data types, the Generic instance is used, + 1 for the constructor tag.
For ADTs, the currently selected branch is counted, not the maximum value.
Memory usage of the annotation is not counted, because this should be
abstractly specifiable. It's an implementation detail.

-}

{- Note [Integer types for costing]
We care about the speed of our integer operations for costing, this has a significant effect on speed.
But we also need to care about overflow: the cost counters overflowing is a potential attack!

We have a few choices here for what to do with an overflow:
- Don't (this is what 'Integer' does, it's unbounded)
- Wrap (this is what 'Int'/'Int64' and friends do)
- Throw an overflow error (this is what 'Data.SafeInt' does)
- Saturate (i.e. return max/min bound, this is what 'Data.SatInt does)

In our case
- Not overflowing would be nice, but 'Integer' is significantly slower than the other types.
- Wrapping is quite dangerous, as it could lead to us getting attacked by someone wrapping
their cost around to something that looks below the budget.
- Throwing would be okay, but we'd have to worry about exception catching.
- Saturating is actually quite nice: we care about whether `a op b < budget`. So long as `budget < maxBound`,
  then `a op b < budget` will have the same truth value *regardless* of whether the operation overflows and saturates,
  since saturating implies `a op b >= maxBound > budget`. Plus, it means we don't need to deal with
  exceptions.

So we use 'Data.SatInt', a variant of 'Data.SafeInt' that does saturating arithmetic.

'SatInt' is quite fast, but not quite as fast as using 'Int64' directly (I don't know
why that would be, apart from maybe just the overflow checks), but the wrapping behaviour
of 'Int64' is unacceptable.

One other wrinkle is that 'SatInt' is backed by an 'Int' (i.e. a machine integer
with platform-dependent size), rather than an 'Int64' since the primops that we
need are only available for 'Int' until GHC 9.2 or so. So on 32bit platforms, we
would have much less headroom.

However, we don't build on 32bit platforms anyway, so we can ignore that.
-}

-- See Note [Integer types for costing]
-- See also Note [Budgeting units] in ExBudget.hs
type CostingInteger = SatInt

-- | Counts size in machine words.
newtype ExMemory = ExMemory CostingInteger
  deriving stock (Eq, Ord, Show, Generic, Lift)
  deriving newtype (Num, NFData, Read, Bounded)
  deriving (FromJSON, ToJSON) via CostingInteger
  deriving Serialise via CostingInteger
  deriving anyclass NoThunks
instance Pretty ExMemory where
    pretty (ExMemory i) = pretty (toInteger i)
instance PrettyBy config ExMemory where
    prettyBy _ m = pretty m

instance Semigroup ExMemory where
    (<>) = coerce $ (+) @CostingInteger
    {-# INLINE (<>) #-}

instance Monoid ExMemory where
    mempty = coerce (0 :: CostingInteger)
    {-# INLINE mempty #-}

-- | Counts CPU units in picoseconds: maximum value for SatInt is 2^63 ps, or
-- appproximately 106 days.
newtype ExCPU = ExCPU CostingInteger
  deriving stock (Eq, Ord, Show, Generic, Lift)
  deriving newtype (Num, NFData, Read, Bounded)
  deriving (FromJSON, ToJSON) via CostingInteger
  deriving Serialise via CostingInteger
  deriving anyclass NoThunks
instance Pretty ExCPU where
    pretty (ExCPU i) = pretty (toInteger i)
instance PrettyBy config ExCPU where
    prettyBy _ m = pretty m

instance Semigroup ExCPU where
    (<>) = coerce $ (+) @CostingInteger
    {-# INLINE (<>) #-}

instance Monoid ExCPU where
    mempty = coerce (0 :: CostingInteger)
    {-# INLINE mempty #-}

{- Note [ExMemoryUsage instances for non-constants]
In order to calculate the cost of a built-in function we need to feed the 'ExMemory' of each
argument to the costing function associated with the builtin. For a polymorphic builtin this means
that we need to be able to compute the 'ExMemory' of the AST provided as an argument to the builtin.
How do we do that? Our strategy is:

1. if the AST is a wrapped constant, then calculate the 'ExMemory' of the constant
2. if the AST is something else, return 1

This is pretty reasonable: a polymorphic builtin *is* allowed to check if the AST that it got as an
argument is a constant or not, and if it happens to be a constant, the builtin *is* allowed to use
it whatever way it wishes (see Note [Builtins and Plutus type checking] for details). Hence a
builtin may in fact do something ad hoc for constants and we need to account for this possibility in
the costing machinery.

But if the given AST is not a constant, the builtin can't do anything else with it, hence we simply
return 1, meaning "the costing function can't use this 'ExMemory' in any non-vacuous way".

See 'HasMeaningIn' for a full list of constraints determining what a builtin can do with values.

However for all types of values, except the one used by the production evaluator, we implement
'ExMemoryUsage' as a call to 'error'. Not because other evaluators don't compute costs during
evaluation -- the CK machine for example does in fact compute them (because we share the same
builtins machinery between all the evaluators and we want it to be efficient on the production path,
hence it's easier to optimize it for all evaluators than just for the single production evaluator).
And not because the resulting 'ExBudget' is not forced by an evaluator that doesn't care about
costing -- it still gets forced (for the same reason).

The actual reason why we call 'error' is because at the moment no builtin is supposed to have a
costing function that actually computes the 'ExMemory' of the given AST. Currently, if the builtin
takes an 'Opaque', it's not supposed to actually look inside of it (unlike with 'SomeConstant') and
hence the costing function is supposed to ignore that argument. It is possible that we'll eventually
decide to add such a builtin, so the current approach of throwing an 'error' is a precaution
ensuring that we won't add any weirdness by accident.

We don't call 'error' on the production path, because we don't want this risk in there. A failing
test is fine, a failing reasonable transaction is not and we don't want to risk it, even if it seems
very unlikely that such a failure could slip in.

The way we ignore arguments in costing functions is by computing the 'ExMemory' of each of those
arguments lazily. I.e. a call to 'memoryUsage' can only be forced within a costing function and
never outside of one. We have to do this regardless of all the reasoning above: if we compute
the 'ExMemory' of, say, a list strictly, then a builtin prepending an element to a list will
have the complexity of O(length_of_the_list) (because computing the 'ExMemory' of a list requires
traversing the list), while we of course want it to be O(1).
-}

-- | A lazy tree of costs. Convenient for calculating the costs of values of built-in types, because
-- they may have arbitrary branching (in particular a 'Data' object can contain a list of 'Data'
-- objects inside of it).
--
-- 'CostRose' gets collapsed to a lazy linear structure down the pipeline, so that we can
-- stream the costs to the outside where, say, the CEK machine picks them up one by one and handles
-- somehow (in particular, subtracts from the remaining budget).
data CostRose
    = CostLeaf {-# UNPACK #-} !CostingInteger
    | CostFork {-# UNPACK #-} !CostingInteger CostForest
    deriving stock (Show)

data CostForest
    = CostForestLast !CostRose
    | CostForestCons !CostRose CostForest
    deriving stock (Show)

toCostRose :: CostingInteger -> [CostRose] -> CostRose
toCostRose i []             = CostLeaf i
-- TODO: try filtering out zeros somehow?
toCostRose i (rose : roses) = CostFork i $ foldr step CostForestLast roses rose where
    step :: CostRose -> (CostRose -> CostForest) -> CostRose -> CostForest
    step new k old = CostForestCons old $ k new
    {-# INLINE step #-}
{-# INLINE toCostRose #-}

class ExMemoryUsage a where
    -- Inlining the implementations of this method gave us a 1-2% speedup.
    memoryUsage :: a -> CostRose -- ^ How much memory does 'a' use?

instance (ExMemoryUsage a, ExMemoryUsage b) => ExMemoryUsage (a, b) where
    memoryUsage (a, b) = toCostRose 1 [memoryUsage a, memoryUsage b]
    {-# INLINE memoryUsage #-}

-- See https://github.com/input-output-hk/plutus/issues/1861
instance ExMemoryUsage (SomeTypeIn uni) where
  memoryUsage _ = toCostRose 1 [] -- TODO things like @list (list (list integer))@ take up a non-constant amount of space.
  {-# INLINE memoryUsage #-}

-- See https://github.com/input-output-hk/plutus/issues/1861
instance (Closed uni, uni `Everywhere` ExMemoryUsage) => ExMemoryUsage (Some (ValueOf uni)) where
  -- TODO this is just to match up with existing golden tests. We probably need to account for @uni@ as well.
  memoryUsage (Some (ValueOf uni x)) = bring (Proxy @ExMemoryUsage) uni (memoryUsage x)
  {-# INLINE memoryUsage #-}

instance ExMemoryUsage () where
  memoryUsage () = toCostRose 1 []
  {-# INLINE memoryUsage #-}

memoryUsageInteger :: Integer -> CostingInteger
-- integerLog2# is unspecified for 0 (but in practice returns -1)
memoryUsageInteger 0 = 1
-- Assume 64 Int
memoryUsageInteger i = fromIntegral $ I# (integerLog2# (abs i) `quotInt#` integerToInt 64) + 1
-- So that the produced GHC Core doesn't explode in size, we don't win anything by inlining this
-- function anyway.
{-# NOINLINE memoryUsageInteger #-}

instance ExMemoryUsage Integer where
  memoryUsage i = toCostRose (memoryUsageInteger i) [] where
  {-# INLINE memoryUsage #-}

instance ExMemoryUsage Word8 where
  memoryUsage _ = toCostRose 1 []
  {-# INLINE memoryUsage #-}

{- Bytestrings: we want things of length 0 to have size 0, 1-8 to have size 1,
   9-16 to have size 2, etc.  Note that (-1) div 8 == -1, so the code below
   gives the correct answer for the empty bytestring.  Maybe we should just use
   1 + (toInteger $ BS.length bs) `div` 8, which would count one extra for
   things whose sizes are multiples of 8. -}
instance ExMemoryUsage BS.ByteString where
  memoryUsage bs = toCostRose (((n-1) `quot` 8) + 1) []  -- Don't use `div` here!  That gives 1 instead of 0 for n=0.
      where n = fromIntegral $ BS.length bs :: SatInt
  {-# INLINE memoryUsage #-}

instance ExMemoryUsage T.Text where
  -- This is slow and inaccurate, but matches the version that was originally deployed.
  -- We may try and improve this in future so long as the new version matches this exactly.
  memoryUsage text = memoryUsage $ T.unpack text
  {-# INLINE memoryUsage #-}

instance ExMemoryUsage Int where
  memoryUsage _ = toCostRose 1 []
  {-# INLINE memoryUsage #-}

instance ExMemoryUsage Char where
  memoryUsage _ = toCostRose 1 []
  {-# INLINE memoryUsage #-}

instance ExMemoryUsage Bool where
  memoryUsage _ = toCostRose 1 []
  {-# INLINE memoryUsage #-}

instance ExMemoryUsage a => ExMemoryUsage [a] where
    memoryUsage = toCostRose 0 . map memoryUsage
    {-# INLINE memoryUsage #-}

{- Another naive traversal for size.  This accounts for the number of nodes in
   a Data object, and also the sizes of the contents of the nodes.  This is not
   ideal, but it seems to be the best we can do.  At present this only comes
   into play for 'equalsData', which is implemented using the derived
   implementation of '==' (fortunately the costing functions are lazy, so this
   won't be called for things like 'unBData' which have constant costing
   functions because they only have to look at the top node).  The problem is
   that when we call 'equalsData' the comparison will take place entirely in
   Haskell, so the costing functions for the contents of 'I' and 'B' nodes
   won't be called.  Thus if we just counted the number of nodes the sizes of
   'I 2' and 'B <huge bytestring>' would be the same but they'd take different
   amounts of time to compare.  It's not clear how to trade off the costs of
   processing a node and processing the contents of nodes: the implementation
   below compromises by charging four units per node, but we may wish to revise
   this after experimentation.
-}
{- This code runs on the chain and hence should be as efficient as possible. To
   that end it's tempting to make these functions strict and tail recursive (and
   similarly in the instance for lists above), but experiments showed that that
   didn't improve matters and in fact some versions led to a slight slowdown.
-}
instance ExMemoryUsage Data where
    memoryUsage = sizeData where
        addNodeMem = toCostRose 4 . pure
        {-# INLINE addNodeMem #-}

        sizeData d = addNodeMem $ case d of
            -- TODO: include the size of the tag, but not just yet.  See SCP-3677.
            Constr _ l -> toCostRose 0 $ l <&> sizeData
            Map l      -> toCostRose 0 $ l <&> \(d1, d2) -> toCostRose 0 $ [d1, d2] <&> sizeData
            List l     -> toCostRose 0 $ l <&> sizeData
            I n        -> memoryUsage n
            B b        -> memoryUsage b

-- | A lazy stream of 'CostingInteger's. Basically @NonEmpty CostingInteger@, except the elements
-- are stored strictly.
--
-- The semantics of a stream are those of the sum of its elements. I.e. a stream that is a reordered
-- version of another stream is considered equal to that stream (not by the derived 'Eq' instance,
-- though).
data CostStream
    = CostLast {-# UNPACK #-} !CostingInteger
    | CostCons {-# UNPACK #-} !CostingInteger CostStream
    deriving stock (Show)

-- TODO: (# CostingInteger, (# (# #) | CostStream #) #)?
-- | Uncons an element from a 'CostStream' and return the rest of the stream, if not empty.
unconsCost :: CostStream -> (CostingInteger, Maybe CostStream)
unconsCost (CostLast cost)       = (cost, Nothing)
unconsCost (CostCons cost costs) = (cost, Just costs)
{-# INLINE unconsCost #-}

-- | Cons an element to a 'CostStream', if given any. Otherwise create a new 'CostStream' using
-- 'CostLast'.
reconsCost :: CostingInteger -> Maybe CostStream -> CostStream
reconsCost cost = maybe (CostLast cost) (CostCons cost)
{-# INLINE reconsCost #-}

{- Note [Global local functions]
Normally when defining a helper function one would put it into a @where@ or a @let@ block.
However if the enclosing function gets inlined, then the definition of the helper one gets inlined
too, which when happens in multiple places can create serious GHC Core bloat, making it really hard
to analyze the generated code. Hence in some cases we optimize for lower amounts of produced GHC
Core by turning some helper functions into global ones.

This doesn't work as well when the helper function captures a variables bound by the enclosing one,
so we leave such helper functions local. We could probably create a global helper and a local
function within it instead, but so far it doesn't appear as those capturing helpers actually get
duplicated in the generated Core.
-}

-- See Note [Global local functions].
sumCostStreamGo :: CostingInteger -> CostStream -> CostingInteger
sumCostStreamGo !acc (CostLast cost)       = acc + cost
sumCostStreamGo !acc (CostCons cost costs) = sumCostStreamGo (acc + cost) costs

-- | Add up all the costs in a 'CostStream'.
sumCostStream :: CostStream -> CostingInteger
sumCostStream (CostLast cost0)        = cost0
sumCostStream (CostCons cost0 costs0) = sumCostStreamGo cost0 costs0
{-# INLINE sumCostStream #-}

-- See Note [Global local functions].
-- | Map a function over a 'CostStream'.
mapCostStream :: (CostingInteger -> CostingInteger) -> CostStream -> CostStream
mapCostStream f (CostLast cost0)        = CostLast (f cost0)
mapCostStream f (CostCons cost0 costs0) = CostCons (f cost0) $ go costs0 where
    go :: CostStream -> CostStream
    go (CostLast cost)       = CostLast (f cost)
    go (CostCons cost costs) = CostCons (f cost) $ go costs
{-# INLINE mapCostStream #-}

-- See Note [Global local functions].
addCostStreamGo :: CostStream -> CostStream -> CostStream
addCostStreamGo (CostLast costL)        costsR = CostCons costL costsR
addCostStreamGo (CostCons costL costsL) costsR = CostCons costL $ addCostStreamGo costsR costsL

-- | Add two streams by interleaving their elements (as opposed to draining out one of the streams
-- before starting to take elements from the other one). No particular reason to prefer
-- interleaving over draining out one of the streams first.
addCostStream :: CostStream -> CostStream -> CostStream
addCostStream costsL0 costsR0 = case (costsL0, costsR0) of
    (CostLast costL, CostLast costR) -> CostLast $ costL + costR
    _                                -> addCostStreamGo costsL0 costsR0
{-# INLINE addCostStream #-}

-- See Note [Global local functions].
-- Didn't attempt to optimize it.
minCostStreamGo :: CostStream -> CostStream -> CostStream
minCostStreamGo costsL costsR =
    -- Peel off a cost from each of the streams, if there's any, compare the two costs, emit
    -- the minimum cost to the outside and recurse. If the two elements aren't equal, then we put
    -- the difference between them back to the stream that had the greatest cost (thus subtracting
    -- the minimum cost from the stream -- since we just accounted for it by lazily emitting it to
    -- the outside). Proceed until one of the streams is drained out.
    let (!costL, !mayCostsL') = unconsCost costsL
        (!costR, !mayCostsR') = unconsCost costsR
        (!costMin, !mayCostsL'', !mayCostsR'') = case costL `compare` costR of
            LT -> (costL, mayCostsL', pure $ reconsCost (costR - costL) mayCostsR')
            EQ -> (costL, mayCostsL', mayCostsR')
            GT -> (costR, pure $ reconsCost (costL - costR) mayCostsL', mayCostsR')
    in reconsCost costMin $ minCostStreamGo <$> mayCostsL'' <*> mayCostsR''

-- | Calculate the minimum of two 'CostStream's. May return a stream that is longer than either of
-- the two (but not more than twice).
minCostStream :: CostStream -> CostStream -> CostStream
minCostStream costsL0 costsR0 = case (costsL0, costsR0) of
    (CostLast costL, CostLast costR) -> CostLast $ min costL costR
    _                                -> minCostStreamGo costsL0 costsR0
{-# INLINE minCostStream #-}

appendCostForest :: CostForest -> CostForest -> CostForest
appendCostForest (CostForestLast rose1)         forest2 = CostForestCons rose1 forest2
appendCostForest (CostForestCons rose1 forest1) forest2 =
    CostForestCons rose1 $ appendCostForest forest1 forest2

-- See Note [Global local functions].
flattenCostRoseForestGo :: CostRose -> CostForest -> CostStream
flattenCostRoseForestGo (CostLeaf cost1) forest2 =
    CostCons cost1 $ flattenCostForestGo forest2
flattenCostRoseForestGo (CostFork cost1 forest1) forest2 =
    CostCons cost1 $ case forest1 of
        CostForestLast rose1'          -> flattenCostRoseForestGo rose1' forest2
        CostForestCons rose1' forest1' ->
            flattenCostRoseForestGo rose1' $ appendCostForest forest1' forest2

-- See Note [Global local functions].
-- Exact copy of 'flattenCostRose'.
flattenCostRoseGo :: CostRose -> CostStream
flattenCostRoseGo (CostLeaf cost)        = CostLast cost
flattenCostRoseGo (CostFork cost forest) = CostCons cost $ flattenCostForestGo forest

-- See Note [Global local functions].
flattenCostForestGo :: CostForest -> CostStream
flattenCostForestGo (CostForestLast rose)        = flattenCostRoseGo rose
flattenCostForestGo (CostForestCons rose forest) = flattenCostRoseForestGo rose forest

flattenCostRose :: CostRose -> CostStream
flattenCostRose (CostLeaf cost)        = CostLast cost
flattenCostRose (CostFork cost forest) = CostCons cost $ flattenCostForestGo forest
{-# INLINE flattenCostRose #-}
