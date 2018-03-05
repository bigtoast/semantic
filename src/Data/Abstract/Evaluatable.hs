{-# LANGUAGE DefaultSignatures, FunctionalDependencies, UndecidableInstances #-}
module Data.Abstract.Evaluatable
( Evaluatable(..)
, AbstractValue(..)
, module Addressable
, module Analysis
, module FreeVariables
, module Function
, MonadEvaluator(..)
, require
, load
) where

import Control.Abstract.Addressable as Addressable
import Control.Abstract.Analysis as Analysis
import Control.Abstract.Evaluator
import Control.Abstract.Function as Function
import Control.Monad.Effect.Fail
import Data.Abstract.Address
import Data.Abstract.Environment
import Data.Abstract.FreeVariables as FreeVariables
import Data.Abstract.Linker
import Data.Abstract.Value
import Data.Algebra
import qualified Data.ByteString.Char8 as BC
import Data.Functor.Classes
import Data.Proxy
import Data.Semigroup
import Data.Term
import Prelude hiding (fail)
import Prologue


-- | The 'Evaluatable' class defines the necessary interface for a term to be evaluated. While a default definition of 'eval' is given, instances with computational content must implement 'eval' to perform their small-step operational semantics.
class Evaluatable constr where
  eval :: ( AbstractValue value
          , FreeVariables term
          , MonadAddressable (LocationFor value) value m
          , MonadAnalysis term value m
          , MonadEvaluator term value m
          , MonadFunction term value m
          , Ord (LocationFor value)
          , Semigroup (Cell (LocationFor value) value)
          )
       => SubtermAlgebra constr term (m value)
  default eval :: (MonadFail m, Show1 constr) => SubtermAlgebra constr term (m value)
  eval expr = fail $ "Eval unspecialized for " ++ liftShowsPrec (const (const id)) (const id) 0 expr ""

-- | If we can evaluate any syntax which can occur in a 'Union', we can evaluate the 'Union'.
instance Apply Evaluatable fs => Evaluatable (Union fs) where
  eval = Prologue.apply (Proxy :: Proxy Evaluatable) eval

-- | Evaluating a 'TermF' ignores its annotation, evaluating the underlying syntax.
instance Evaluatable s => Evaluatable (TermF s a) where
  eval In{..} = eval termFOut


-- Instances

-- | '[]' is treated as an imperative sequence of statements/declarations s.t.:
--
--   1. Each statement’s effects on the store are accumulated;
--   2. Each statement can affect the environment of later statements (e.g. by 'modify'-ing the environment); and
--   3. Only the last statement’s return value is returned.
instance Evaluatable [] where
  eval []     = pure unit      -- Return unit value if this is an empty list of terms
  eval [x]    = subtermValue x -- Return the value for the last term
  eval (x:xs) = do
    _ <- subtermValue x        -- Evaluate the head term
    env <- getGlobalEnv        -- Get the global environment after evaluation
                               -- since it might have been modified by the
                               -- evaluation above ^.

    -- Finally, evaluate the rest of the terms, but do so by calculating a new
    -- environment each time where the free variables in those terms are bound
    -- to the global environment.
    localEnv (const (bindEnv (liftFreeVariables (freeVariables . subterm) xs) env)) (eval xs)


-- | Require/import another term/file and return an Effect.
--
-- Looks up the term's name in the cache of evaluated modules first, returns a value if found, otherwise loads/evaluates the module.
require :: ( FreeVariables term
           , MonadAnalysis term v m
           , MonadEvaluator term v m
           )
        => term
        -> m v
require term = getModuleTable >>= maybe (load term) pure . linkerLookup name
  where name = moduleName term

-- | Load another term/file and return an Effect.
--
-- Always loads/evaluates.
load :: ( FreeVariables term
        , MonadAnalysis term v m
        , MonadEvaluator term v m
        )
     => term
     -> m v
load term = askModuleTable >>= maybe notFound evalAndCache . linkerLookup name
  where name = moduleName term
        notFound = fail ("cannot find " <> show name)
        evalAndCache e = do
          v <- evaluateTerm e
          modifyModuleTable (linkerInsert name v)
          pure v

-- | Get a module name from a term (expects single free variables).
moduleName :: FreeVariables term => term -> Prelude.String
moduleName term = let [n] = toList (freeVariables term) in BC.unpack n