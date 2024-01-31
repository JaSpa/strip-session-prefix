{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuantifiedConstraints #-}

module BSession.Syntax
  ( -- * Session Types
    LSession,
    CSession,
    Session (..),
    Dir (..),
    Ty (..),

    -- ** Variables
    Var (..),
    VarLabel (..),

    -- ** Branching
    LBranch (..),
    CBranch,
    branchWidth',
    packBranches,
    unpackBranches,
    padLBranches,

    -- * Renaming
    Ren,
    ren,
    varSuc,
    extRen,

    -- * Substitution
    Sub,
    sub,
    sub0,
    extSub,

    -- * Handling recursive sessions
    contractive,
    unroll,
  )
where

import BSession.Nat
import Data.Hashable
import Data.Kind
import Data.List (genericLength, genericReplicate)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.String (IsString)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prettyprinter

-- |  A `VarLabel` is the user facing name of a variable.
newtype VarLabel = VarLabel T.Text
  deriving newtype (IsString, Pretty)

-- | Because `VarLabel`s are purely visual they have no effect on equality. All
-- `VarLabel`s compare equal!
instance Eq VarLabel where
  _ == _ = True

instance Hashable VarLabel where
  hashWithSalt s _ = s

data Var n = Var !VarLabel !(Fin n)
  deriving stock (Eq, Generic)

instance Hashable (Var n)

instance Pretty (Var n) where
  pretty (Var lbl n) = pretty lbl <> "@" <> pretty n

data Dir = In | Out
  deriving stock (Eq, Generic)

instance Hashable Dir

newtype Ty = Ty T.Text
  deriving newtype (Eq, IsString, Pretty, Hashable)

data LBranch a = LBranch
  { branchIndex :: !Natural,
    branchWidth :: !Natural,
    branchTarget :: a
  }
  deriving stock (Eq, Functor, Foldable, Traversable, Generic)

instance (Hashable a) => Hashable (LBranch a)

newtype CBranch a = CBranch (NE.NonEmpty a)
  deriving newtype (Eq, Functor, Foldable, Hashable)

branchWidth' :: CBranch a -> Natural
branchWidth' (CBranch as) = genericLength $ NE.toList as

packBranches :: NE.NonEmpty a -> CBranch a
packBranches = CBranch

unpackBranches :: CBranch a -> NE.NonEmpty (LBranch a)
unpackBranches b@(CBranch as) =
  let !w = branchWidth' b
   in NE.zipWith (\i a -> LBranch i w a) (NE.fromList [0 ..]) as

padLBranches :: forall a. a -> NE.NonEmpty (LBranch a) -> CBranch a
padLBranches pa = CBranch . go Nothing . NE.sortWith branchIndex
  where
    go :: Maybe Natural -> NonEmpty (LBranch a) -> NonEmpty a
    go m (LBranch i w a :| as) =
      let as' = case nonEmpty as of
            Nothing -> padding (Just i) (w + 1)
            Just as1 -> NE.toList $ go (Just i) as1
       in padding m i `NE.prependList` (a :| as')

    padding :: Maybe Natural -> Natural -> [a]
    padding Nothing i = genericReplicate (toInteger i) pa
    padding (Just i) i' = genericReplicate (toInteger i' - toInteger i - 1) pa

type LSession = Session LBranch

type CSession = Session CBranch

type Session :: (Type -> Type) -> Nat -> Type
data Session f n where
  SEnd :: Session f n
  SRet :: Session f n
  SVar :: !(Var n) -> Session f n
  SCom :: !Dir -> !Ty -> Session f n -> Session f n
  SAlt :: !Dir -> f (Session f n) -> Session f n
  SMu :: !VarLabel -> Session f (S n) -> Session f n

deriving stock instance (forall a. (Eq a) => Eq (f a)) => Eq (Session f n)

instance (forall a. (Eq a) => Eq (f a), forall a. (Hashable a) => Hashable (f a)) => Hashable (Session f n) where
  hashWithSalt salt = \case
    SEnd -> salt `hashWithSalt` (0 :: Int)
    SRet -> salt `hashWithSalt` (1 :: Int)
    SVar v -> salt `hashWithSalt` (2 :: Int) `hashWithSalt` v
    SCom x t s -> salt `hashWithSalt` (3 :: Int) `hashWithSalt` x `hashWithSalt` t `hashWithSalt` s
    SAlt x b -> salt `hashWithSalt` (4 :: Int) `hashWithSalt` x `hashWithSalt` b
    SMu v s -> salt `hashWithSalt` (5 :: Int) `hashWithSalt` v `hashWithSalt` s

instance (forall a. (Pretty a) => Pretty (f a)) => Pretty (Session f n) where
  pretty = \case
    SEnd -> "end"
    SRet -> "ret"
    SVar v -> pretty v
    SCom x t s -> (case x of In -> "?"; Out -> "!") <> pretty t <+> dot <+> pretty s
    SAlt x b -> (case x of In -> "&"; Out -> "+") <> pretty b -- encloseSep "{ " " }" " ; " (pretty <$> NE.toList ss)
    SMu v s -> "rec " <> pretty v <> dot <+> pretty s

instance (forall a. (Pretty a) => Pretty (f a)) => Show (Session f n) where
  show = show . pretty

instance (Pretty a) => Pretty (LBranch a) where
  pretty (LBranch n w a) = pretty n <> slash <> pretty w <> dot <+> pretty a

instance (Pretty a) => Pretty (CBranch a) where
  pretty (CBranch as) = encloseSep "{ " " }" " ; " (pretty <$> NE.toList as)

contractive :: (Foldable f) => Session f n -> Bool
contractive = go 0
  where
    go :: (Foldable f) => Int -> Session f n -> Bool
    go !preceedingBinders = \case
      SEnd -> True
      SRet -> True
      SVar (Var _ n) -> toNum n >= preceedingBinders
      SCom _ _ s -> contractive s
      SAlt _ ss -> all contractive ss
      SMu _ s -> go (preceedingBinders + 1) s

type Ren m n = Var m -> Var n

extRen :: Ren m n -> Ren (S m) (S n)
extRen _ (Var v FZ) = Var v FZ
extRen r (Var v (FS m)) = varSuc (r (Var v m))

varSuc :: Ren n (S n)
varSuc (Var v n) = Var v (FS n)

ren :: (Functor f) => Ren m n -> Session f m -> Session f n
ren r = sub (SVar . r)

type Sub f m n = Var m -> Session f n

extSub :: (Functor f) => Sub f m n -> Sub f (S m) (S n)
extSub _ (Var v FZ) = SVar (Var v FZ)
extSub s (Var v (FS m)) = ren varSuc $ s $ Var v m

sub0 :: Session f n -> Sub f (S n) n
sub0 s (Var _ FZ) = s
sub0 _ (Var v (FS n)) = SVar $ Var v n

sub :: (Functor f) => Sub f m n -> Session f m -> Session f n
sub sb = \case
  SEnd -> SEnd
  SRet -> SRet
  SVar v -> sb v
  SCom x t s -> SCom x t (sub sb s)
  SAlt x ss -> SAlt x (sub sb <$> ss)
  SMu v s -> SMu v (sub (extSub sb) s)

unroll :: (Functor f) => VarLabel -> Session f (S n) -> Session f n
unroll lbl s = sub (sub0 (SMu lbl s)) s