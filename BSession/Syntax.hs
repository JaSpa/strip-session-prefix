{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module BSession.Syntax where

import BSession.Nat
import Data.Hashable
import Data.Kind
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import GHC.Generics (Generic)
import Prettyprinter

-- |  A `VarLabel` is the user facing name of a variable.
newtype VarLabel = VarLabel T.Text
  deriving newtype (Pretty)

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
  deriving newtype (Eq, Pretty, Hashable)

type Session0 = Session Z

type Session :: Nat -> Type
data Session n where
  SEnd :: Session n
  SRet :: Session n
  SVar :: !(Var n) -> Session n
  SCom :: !Dir -> !Ty -> Session n -> Session n
  SAlt :: !Dir -> NE.NonEmpty (Session n) -> Session n
  SMu :: !VarLabel -> Session (S n) -> Session n

deriving stock instance Eq (Session n)

deriving stock instance Generic (Session n)

instance Hashable (Session n)

instance Pretty (Session n) where
  pretty = \case
    SEnd -> "end"
    SRet -> "ret"
    SVar v -> pretty v
    SCom x t s -> (case x of In -> "?"; Out -> "!") <> pretty t <+> dot <+> pretty s
    SAlt x ss -> (case x of In -> "&"; Out -> "+") <> encloseSep "{ " " }" " ; " (pretty <$> NE.toList ss)
    SMu v s -> "rec " <> pretty v <> dot <+> pretty s

contractive :: Session n -> Bool
contractive = go 0
  where
    go :: Int -> Session n -> Bool
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

ren :: forall m n. Ren m n -> Session m -> Session n
ren r = sub (SVar . r)

type Sub m n = Var m -> Session n

extSub :: Sub m n -> Sub (S m) (S n)
extSub _ (Var v FZ) = SVar (Var v FZ)
extSub s (Var v (FS m)) = ren varSuc $ s $ Var v m

sub0 :: Session n -> Sub (S n) n
sub0 s (Var _ FZ) = s
sub0 _ (Var v (FS n)) = SVar $ Var v n

sub :: Sub m n -> Session m -> Session n
sub sb = \case
  SEnd -> SEnd
  SRet -> SRet
  SVar v -> sb v
  SCom x t s -> SCom x t (sub sb s)
  SAlt x ss -> SAlt x (sub sb <$> ss)
  SMu v s -> SMu v (sub (extSub sb) s)

unroll :: VarLabel -> Session (S n) -> Session n
unroll lbl s = sub (sub0 (SMu lbl s)) s
