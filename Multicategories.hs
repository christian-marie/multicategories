{-# LANGUAGE DataKinds, RankNTypes, TypeOperators, KindSignatures, GADTs, ScopedTypeVariables, PolyKinds, TypeFamilies, FlexibleInstances, MultiParamTypeClasses #-}
module Multicategories where

import Control.Applicative
import Control.Category
import Control.Comonad
import Control.Monad (ap)
import Control.Monad.ST
import Data.Constraint
import Data.Foldable
import Data.Functor.Identity
import Data.Functor.Rep
import Data.Proxy
import Data.Semigroupoid
import Data.Semigroupoid.Ob
import Data.Traversable
import Data.Vector as Vector
import Data.Vector.Mutable as Mutable
import GHC.TypeLits
import Unsafe.Coerce
import Prelude hiding ((++), id, (.))

--------------------------------------------------------------------------------
-- * (Erasable) Type-Level Lists
--------------------------------------------------------------------------------

type family (++) (a :: [k]) (b :: [k]) :: [k]
type instance '[] ++ bs = bs
type instance (a ': as) ++ bs = a ': (as ++ bs)

-- | Proof provided by every single class on theorem proving in the last 20 years.
appendNilAxiom :: forall as. Dict (as ~ (as ++ '[]))
appendNilAxiom = unsafeCoerce (Dict :: Dict (as ~ as))

-- | Proof provided by every single class on theorem proving in the last 20 years.
appendAssocAxiom :: forall p q r as bs cs. p as -> q bs -> r cs -> Dict ((as ++ (bs ++ cs)) ~ ((as ++ bs) ++ cs))
appendAssocAxiom _ _ _ = unsafeCoerce (Dict :: Dict (as ~ as))

--------------------------------------------------------------------------------
-- * Records
--------------------------------------------------------------------------------

-- | Note: @Rec Proxy is@ is a natural number we can do induction on.
data Rec :: (k -> *) -> [k] -> * where
  RNil :: Rec f '[]
  (:&) :: !(f a) -> !(Rec f as) -> Rec f (a ': as)

-- | Append two records
rappend :: Rec f as -> Rec f bs -> Rec f (as ++ bs)
rappend RNil bs      = bs
rappend (a :& as) bs = a :& rappend as bs

-- | Map over a record
rmap :: (forall a. f a -> g a) -> Rec f as -> Rec g as
rmap _ RNil = RNil
rmap f (a :& as) = f a :& rmap f as

-- | Split a record
splitRec :: Rec f is -> Rec g (is ++ js) -> (Rec g is, Rec g js)
splitRec RNil    as        = (RNil, as)
splitRec (_ :& is) (a :& as) = case splitRec is as of
  (l,r) -> (a :& l, r)

foldrRec :: (forall i is. f i -> r is -> r (i ': is)) -> r '[] -> Rec f is -> r is
foldrRec _ z RNil = z
foldrRec f z (a :& as) = f a (foldrRec f z as)

traverseRec :: Applicative m => (forall i. f i -> m (g i)) -> Rec f is -> m (Rec g is)
traverseRec f (a :& as) = (:&) <$> f a <*> traverseRec f as
traverseRec f RNil = pure RNil

--------------------------------------------------------------------------------
-- * Graded structures
--------------------------------------------------------------------------------

class Graded (f :: [k] -> k -> *) where
  grade :: f is o -> Rec Proxy is

class KnownGrade is where
  gradeVal :: Rec Proxy is

instance KnownGrade '[] where
  gradeVal = RNil

instance KnownGrade is => KnownGrade (i ': is) where
  gradeVal = Proxy :& gradeVal

--------------------------------------------------------------------------------
-- * Arguments for a multicategory form a polycategory
--------------------------------------------------------------------------------

-- | Each 'Multicategory' is a contravariant functor in @'Forest' f@ in its first argument.
data Forest :: ([k] -> k -> *) -> [k] -> [k] -> * where
  Nil  :: Forest f '[] '[]
  (:-) :: f is o -> Forest f js os -> Forest f (is ++ js) (o ': os)

infixr 5 :-, :&

foldrForest :: (forall i o is. f i o -> r is -> r (i ++ is)) -> r '[] -> Forest f m n -> r m
foldrForest _ z Nil = z
foldrForest f z (a :- as) = f a (foldrForest f z as)


gradeForest :: Graded f => Forest f is os -> Rec Proxy is
gradeForest = foldrForest (\a r -> grade a `rappend` r) RNil

splitForest :: forall f g ds is js os r. Rec f is -> Forest g js os -> Forest g ds (is ++ js) -> (forall bs cs. (ds ~ (bs ++ cs)) => Forest g bs is -> Forest g cs js -> r) -> r
splitForest RNil bs as k = k Nil as
splitForest (i :& is) bs ((j :: g as o) :- js) k = splitForest is bs js $ \ (l :: Forest g bs as1) (r :: Forest g cs js) ->
  case appendAssocAxiom (Proxy :: Proxy as) (Proxy :: Proxy bs) (Proxy :: Proxy cs) of
    Dict -> k (j :- l) r

--------------------------------------------------------------------------------
-- * Multicategories
--------------------------------------------------------------------------------

-- | multicategory / planar colored operad
class Graded f => Multicategory f where
  ident   :: f '[a] a
  compose :: f bs c -> Forest f as bs -> f as c

instance Multicategory f => Semigroupoid (Forest f) where
  o Nil Nil = Nil
  o (b :- bs) as = splitForest (grade b) bs as $ \es fs -> compose b es :- o bs fs

instance (Multicategory f, KnownGrade is) => Ob (Forest f) is where
  semiid = idents gradeVal

idents :: Multicategory f => Rec Proxy is -> Forest f is is
idents (a :& as) = ident :- idents as
idents RNil      = Nil

--------------------------------------------------------------------------------
-- * Symmetric Multicategories
--------------------------------------------------------------------------------

-- | generators for the symmetric groupoid Sigma_k
data Swap :: [a] -> [a] -> * where
  Swap :: Swap (a ': b ': bs) (b ': a ': bs)
  Skip :: Swap as bs -> Swap (a ': as) (a ': bs)

swapRec :: Swap as bs -> Rec f as -> Rec f bs
swapRec (Skip s) (i :& is)      = i :& swapRec s is
swapRec Swap     (i :& j :& is) = j :& i :& is

unswapRec :: Swap bs as -> Rec f as -> Rec f bs
unswapRec (Skip s) (i :& is)      = i :& unswapRec s is
unswapRec Swap     (i :& j :& is) = j :& i :& is

class Multicategory f => Symmetric f where
  swap :: Swap as bs -> f as o -> f bs o

-- TODO: Cartesian Multicategories

--------------------------------------------------------------------------------
-- * Endo
--------------------------------------------------------------------------------

-- | The endomorphism multicategory over a Hask; the multicategory represented by Hask.
data Endo is o where
  Endo :: !(Rec Proxy is) -> (Rec Identity is -> o) -> Endo is o

instance Graded Endo where
  grade (Endo g _) = g

instance Multicategory Endo where
  ident = Endo gradeVal $ \(Identity a :& RNil) -> a
  compose (Endo _ f) as = Endo (gradeForest as) $ \v -> f $ go as v where
    go :: Forest Endo is os -> Rec Identity is -> Rec Identity os
    go (Endo gg g :- gs) v = case splitRec gg v of
      (l,r) -> Identity (g l) :& go gs r
    go Nil RNil = RNil

instance Symmetric Endo where -- TODO
  swap s (Endo g f) = Endo (swapRec s g) (f . unswapRec s)

--------------------------------------------------------------------------------
-- * Free multicategory
--------------------------------------------------------------------------------

-- | free multicategory given graded atoms
data Free :: ([k] -> k -> *) -> [k] -> k -> * where
  Ident :: Free f '[a] a
  Apply :: f bs c -> Forest (Free f) as bs -> Free f as c

instance Graded f => Graded (Free f) where
  grade Ident = Proxy :& RNil
  grade (Apply _ as) = gradeForest as

instance Graded f => Multicategory (Free f) where
  ident = Ident
  compose Ident ((a :: Free f bs c) :- Nil) = case appendNilAxiom :: Dict (bs ~ (bs ++ '[])) of Dict -> a
  compose (Apply f as) bs = Apply f (o as bs)

instance Symmetric f => Symmetric (Free f) where
  -- swap s (Apply f as) = Apply (swap s f) (swapForest s as)

--------------------------------------------------------------------------------
-- * Kleisli arrows of outrageous fortune
--------------------------------------------------------------------------------

data Atkey a i j where
  Atkey :: a -> Atkey a i i

amap :: (a -> b) -> Atkey a i j -> Atkey b i j
amap f (Atkey a) = Atkey (f a)

--------------------------------------------------------------------------------
-- * The monad attached to a planar operad
--------------------------------------------------------------------------------

-- The monad attached to an operad. This generalizes the notion of the writer monad to an arbitrary operad
data M (f :: [()] -> () -> *) (a :: *) where
  M :: f is '() -> Rec (Atkey a '()) is -> M f a

instance Functor (M f) where
  fmap f (M s d) = M s (rmap (\(Atkey a) -> Atkey (f a)) d)

instance Multicategory f => Applicative (M f) where
  pure = return
  (<*>) = ap

instance Multicategory f => Monad (M f) where
  return a = M ident (Atkey a :& RNil)
  M s0 d0 >>= (f :: a -> M f b) = go d0 $ \ as ds -> M (compose s0 as) ds where
    go :: Rec (Atkey a '()) is -> (forall os. Forest f os is -> Rec (Atkey b '()) os -> r) -> r
    go RNil k = k Nil RNil
    go (Atkey a :& is) k = go is $ \fs as -> case f a of
      M s bs -> k (s :- fs) (rappend bs as)

data K a b = K a

instance Foldable (M f) where
  foldr f z (M _ d) = case foldrRec (\(Atkey a) (K b) -> K (f a b)) (K z) d of
    K r -> r

instance Traversable (M f) where
  traverse f (M s d) = M s <$> traverseRec (\(Atkey a) -> Atkey <$> f a) d

--------------------------------------------------------------------------------
-- * The monad transformer attached to a planar operad
--------------------------------------------------------------------------------

data T f g o where
  T :: f is o -> g is -> T f g o

-- This does not form a valid monad unless the monad @m@ is commutative. (Just like @ListT@)
newtype MT (f :: [()] -> () -> *) (m :: * -> *) (a :: *) = MT { runMT :: m (T f (Rec (Atkey a '())) '()) }

instance Functor m => Functor (MT f m) where
  fmap f (MT m) = MT $ fmap (\(T s d) -> T s (rmap (\(Atkey a) -> Atkey (f a)) d)) m

instance (Multicategory f, Functor m, Monad m) => Applicative (MT f m) where
  pure = return
  (<*>) = ap

instance (Multicategory f, Monad m) => Monad (MT f m) where
  return a = MT (return (T ident (Atkey a :& RNil)))
  MT m >>= (f :: a -> MT f m b) = MT $ do
      T s0 d0 <- m
      go d0 $ \ as ds -> return $ T (compose s0 as) ds
    where
      go :: Rec (Atkey a '()) is -> (forall os. Forest f os is -> Rec (Atkey b '()) os -> m r) -> m r
      go RNil k = k Nil RNil
      go (Atkey a :& is) k = go is $ \fs as -> do
        T s bs <- runMT (f a)
        k (s :- fs) (rappend bs as)
  fail s = MT $ fail s

instance Foldable m => Foldable (MT f m) where
  foldr f z (MT m) = Data.Foldable.foldr (\(T _ d) z' -> case foldrRec (\(Atkey a) (K r) -> K (f a r)) (K z') d of K o -> o) z m

instance Traversable m => Traversable (MT f m) where
  traverse f (MT m) = MT <$> traverse (\(T s d) -> T s <$> traverseRec (\(Atkey a) -> Atkey <$> f a) d) m

-- TODO: Build a monad transformer associated with an operad based on ListT-done-right?

--------------------------------------------------------------------------------
-- * Algebras over a Operad
--------------------------------------------------------------------------------

type OperadAlgebra f a = M f a -> a
type OperadCoalgebra f a = a -> M f a

--------------------------------------------------------------------------------
-- * Indexed Monads from a Multicategory
--------------------------------------------------------------------------------

type (f :: k -> *) ~> (g :: k -> *) = forall (a :: k). f a -> g a
infixr 0 ~>

class IFunctor m where
  imap :: (a ~> b) -> m a ~> m b

class IFunctor m => IMonad m where
  ireturn :: a ~> m a
  ibind :: (a ~> m b) -> (m a ~> m b)

-- | A McBride-style indexed monad associated with a multicategory
data IM (f :: [k] -> k -> *) (a :: k -> *) (o :: k) where
  IM :: f is o -> Rec a is -> IM f a o

instance IFunctor (IM f) where
  imap f (IM s d) = IM s (rmap f d)

instance Multicategory f => IMonad (IM f) where
  ireturn a = IM ident (a :& RNil)
  ibind (f :: a ~> IM f b) (IM s0 d0) = go d0 $ \ as ds -> IM (compose s0 as) ds where
    go :: Rec a is -> (forall os. Forest f os is -> Rec b os -> r) -> r
    go RNil k = k Nil RNil
    go (a :& is) k = go is $ \fs as -> case f a of
      IM s bs -> k (s :- fs) (rappend bs as)

--------------------------------------------------------------------------------
-- * A category obtained by keeping only 1-argument multimorphisms
--------------------------------------------------------------------------------

-- | One category you get when given an operad. This is a forgetful functor that forgets all but the unary arrows.
newtype Oper f a b = Oper { runOper :: f '[a] b }

opermap :: (forall as b. f as b -> g as b) -> Oper f a b -> Oper g a b
opermap f (Oper a) = Oper (f a)

instance Multicategory f => Category (Oper f) where
  id = Oper ident
  Oper f . Oper g = Oper $ compose f (g :- Nil)

--------------------------------------------------------------------------------
-- * Free multicategory from a category
--------------------------------------------------------------------------------

-- | Build a free multicategory from a category, left adjoint to Oper
data C :: (i -> i -> *) -> [i] -> i -> * where
  C :: p a b -> C p '[a] b

instance Graded (C p) where
  grade C{} = gradeVal

instance Category p => Multicategory (C p) where
  ident = C id
  compose (C f) (C g :- Nil) = C (f . g)

instance Category p => Symmetric (C p) where
  swap = error "The permutations of 1 element are trivial. How did you get here?"

--------------------------------------------------------------------------------
-- * Variants
--------------------------------------------------------------------------------

data Variant :: (k -> *) -> [k] -> * where
  Variant :: Selector f as a -> Variant f as

data Selector :: (k -> *) -> [k] -> k -> * where
  Head :: f a -> Selector f (a ': as) a
  Tail :: Selector f as b -> Selector f (a ': as) b

selectors :: Rec f as -> Rec (Selector f as) as
selectors RNil      = RNil
selectors (a :& as) = Head a :& rmap Tail (selectors as)

--------------------------------------------------------------------------------
-- * The comonad associated with an operad.
--------------------------------------------------------------------------------

-- The comonad associated with an operad
newtype W (f :: [()] -> () -> *) (a :: *) = W { runW :: forall is. f is '() -> Rec (Atkey a '()) is } -- Coatkey?

instance Functor (W f) where
  fmap f (W g) = W (rmap (\(Atkey a) -> Atkey (f a)) . g)

instance Multicategory f => Comonad (W f) where
  extract (W f) = case f ident of
    Atkey a :& RNil -> a

--------------------------------------------------------------------------------
-- * Indexed Monads from a Multicategory
--------------------------------------------------------------------------------

-- instance Multicategory f => IMonad (IM f)

class IFunctor w => IComonad w where
  iextract :: w a ~> a
  iextend  :: (w a ~> b) -> (w a ~> w b)

-- an indexed comonad associated with a multicategory
newtype IW (f :: [k] -> k -> *) (a :: k -> *) (o :: k) = IW { runIW :: forall is. f is o -> Rec a is }

-- instance Multicategory f => IComonad (IW f)

instance IFunctor (IW f) where
  imap f (IW g) = IW $ \s -> rmap f (g s)

instance Multicategory f => IComonad (IW f) where
  iextract (IW f) = case f ident of
    a :& RNil -> a
  iextend (f :: IW f a ~> b) (IW w) = IW $ \s -> go (grade s) s where
    go :: Rec Proxy is -> f is a1 -> Rec b is
    go gs s = undefined
  -- duplicate (W f) = W (\s d -> rmap (\(Atkey a) -> W $ \s' d' -> graft d' in for the corresponding arg of s, then prune the result to that interval) d)


--------------------------------------------------------------------------------
-- * A category over an operad
--------------------------------------------------------------------------------
-- http://ncatlab.org/nlab/show/category+over+an+operad

-- we could model a category with object constraints with something simple like:

-- class (Semigroupoid q, Semigroupoid r) => Profunctor p q r | p -> q r where
--   dimap :: q a b -> r c d -> p b c -> p a d

-- class (Profunctor p (Forest p) (Oper p), Graded p) => Multicategory p where ident :: p '[a] a ...
--
-- now 'compose' is an lmap.
