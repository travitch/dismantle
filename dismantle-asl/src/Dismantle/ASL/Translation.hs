{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}

module Dismantle.ASL.Translation (
    TranslationState(..)
  , translateExpr
  , translateStatement
  , addExtendedTypeData
  , unliftGenerator
  , InnerGenerator
  , throwTrace
  , Overrides(..)
  , overrides
  , UserType(..)
  , Definitions(..)
  , userTypeRepr
  , ToBaseType
  , ToBaseTypes
  ) where

import           Control.Lens ( (&), (.~) )
import           Control.Applicative ( (<|>) )
import qualified Control.Exception as X
import           Control.Monad ( when, void, foldM, foldM_, (<=<) )
import qualified Control.Monad.Fail as F
import qualified Control.Monad.State.Class as MS
import           Control.Monad.Trans ( lift )
import qualified Control.Monad.Trans as MT
import qualified Control.Monad.State as MSS
import           Control.Monad.Trans.Maybe as MaybeT
import           Data.Typeable
import qualified Data.BitVector.Sized as BVS
import           Data.Maybe ( fromMaybe )
import           Data.Void ( Void )
import qualified Data.Void as Void
import           Data.Parameterized.Classes
import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.NatRepr as NR
import           Data.Parameterized.Some ( Some(..) )
import qualified Data.Parameterized.TraversableFC as FC
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Lang.Crucible.CFG.Expr as CCE
import qualified Lang.Crucible.CFG.Generator as CCG
import qualified Lang.Crucible.Types as CT
import qualified What4.BaseTypes as WT
import qualified What4.ProgramLoc as WP
import qualified What4.Utils.StringLiteral as WT

import qualified Language.ASL.Syntax as AS

import           Dismantle.ASL.Extension ( ASLExt, ASLApp(..), ASLStmt(..) )
import           Dismantle.ASL.Exceptions ( TranslationException(..), LoggedTranslationException(..) )
import           Dismantle.ASL.Signature
import           Dismantle.ASL.Types
import           Dismantle.ASL.StaticExpr as SE
import           Dismantle.ASL.Translation.Preprocess
import           Dismantle.ASL.SyntaxTraverse ( logMsg, indentLog, unindentLog )
import qualified Dismantle.ASL.SyntaxTraverse as TR
import qualified Dismantle.ASL.SyntaxTraverse as AS ( pattern VarName )

import qualified Lang.Crucible.CFG.Reg as CCR
import qualified What4.Utils.MonadST as MST
import qualified Data.STRef as STRef

-- | This wrapper is used as a uniform return type in 'lookupVarRef', as each of
-- the lookup types (arguments, locals, or globals) technically return different
-- values, but they are values that are pretty easy to handle uniformly.
--
-- We could probably get rid of this wrapper if we made a function like
-- @withVarValue@ that took a continuation instead.
data ExprConstructor arch regs h s ret where
  ExprConstructor :: a tp
                  -> (a tp -> Generator h s arch ret (CCG.Expr (ASLExt arch) s tp))
                  -> ExprConstructor (ASLExt arch) regs h s ret

-- | Inside of the translator, look up the current definition of a name
--
-- We currently assume that arguments are never assigned to (i.e., there is no
-- name shadowing).
lookupVarRef' :: forall arch h s ret
              . T.Text
             -> Generator h s arch ret (Maybe (Some (CCG.Expr (ASLExt arch) s)))
lookupVarRef' name = do
  ts <- MS.get
  env <- getStaticEnv
  case (lookupLocalConst env <|>
        lookupArg ts <|>
        lookupRef ts <|>
        lookupGlobalStruct ts <|>
        lookupGlobal ts <|>
        lookupEnum ts <|>
        lookupConst ts) of
    Just (ExprConstructor e con) -> Just <$> Some <$> con e
    Nothing -> return Nothing
  where
    lookupLocalConst env = do
      sv <- staticEnvValue env name
      case sv of
        StaticInt i -> return (ExprConstructor (CCG.App (CCE.IntLit i)) return)
        StaticBool b -> return (ExprConstructor (CCG.App (CCE.BoolLit b)) return)
        StaticBV bv -> case bitsToBVExpr bv of
          Some bve -> return (ExprConstructor bve return)

    lookupArg ts = do
      Some e <- Map.lookup name (tsArgAtoms ts)
      return (ExprConstructor (CCG.AtomExpr e) return)
    lookupRef ts = do
      Some r <- Map.lookup name (tsVarRefs ts)
      return (ExprConstructor r $ (liftGenerator . CCG.readReg))
    lookupGlobalStruct _ = do
      if name `elem` globalStructNames
        then return (ExprConstructor (CCG.App CCE.EmptyApp) $ return)
        else fail ""
    lookupGlobal ts = do
      Some g <- Map.lookup name (tsGlobals ts)
      return (ExprConstructor g $ (liftGenerator . CCG.readGlobal))
    lookupEnum ts = do
      e <- Map.lookup name (tsEnums ts)
      return (ExprConstructor (CCG.App (CCE.IntLit e)) return)
    lookupConst ts = do
      Some (ConstVal repr e) <- Map.lookup name (tsConsts ts)
      case repr of
        WT.BaseBoolRepr -> return (ExprConstructor (CCG.App (CCE.BoolLit e)) return)
        WT.BaseIntegerRepr -> return (ExprConstructor (CCG.App (CCE.IntLit e)) return)
        WT.BaseBVRepr wRepr ->
          return (ExprConstructor (CCG.App (CCE.BVLit wRepr (BVS.bvIntegerU e))) return)
        _ -> error "bad const type"

lookupVarRef :: forall arch h s ret
             . T.Text
            -> Generator h s arch ret (Some (CCG.Expr (ASLExt arch) s))
lookupVarRef name = do
  mref <- lookupVarRef' name
  case mref of
    Just ref -> return ref
    Nothing -> throwTrace $ UnboundName name

-- | Inside of the translator, look up the current definition of a name
--
-- We currently assume that arguments are never assigned to (i.e., there is no
-- name shadowing).
lookupVarType :: forall arch h s ret
              . T.Text
             -> Generator h s arch ret (Maybe (Some (CT.TypeRepr)))
lookupVarType name = do
  f <- lookupVarType'
  return $ f name

lookupVarType' :: Generator h s arch ret (T.Text -> Maybe (Some (CT.TypeRepr)))
lookupVarType' = do
  ts <- MS.get
  svals <- MS.gets tsStaticValues
  return $ \name ->
    let
      lookupLocalConst = do
        sv <- Map.lookup name svals
        case typeOfStatic sv of
          StaticIntType -> return $ Some CT.IntegerRepr
          StaticBoolType -> return $ Some CT.BoolRepr
          StaticBVType sz -> case intToBVRepr sz of
            Some (BVRepr nr) -> return $ Some $ CT.BVRepr nr
      lookupArg = do
        Some e <- Map.lookup name (tsArgAtoms ts)
        return $ Some $ CCG.typeOfAtom e
      lookupRef = do
        Some r <- Map.lookup name (tsVarRefs ts)
        return $ Some $ CCG.typeOfReg r
      lookupGlobal = do
        Some g <- Map.lookup name (tsGlobals ts)
        return $ Some $ CCG.globalType g
      lookupEnum = do
        _ <- Map.lookup name (tsEnums ts)
        return $ Some $ CT.IntegerRepr
      lookupConst = do
        Some (ConstVal repr _) <- Map.lookup name (tsConsts ts)
        return $ Some $ CT.baseToType repr
    in
      lookupLocalConst <|>
      lookupArg <|>
      lookupRef <|>
      lookupGlobal <|>
      lookupEnum <|>
      lookupConst


-- | Overrides for syntactic forms
--
-- Each of the frontends can match on different bits of syntax and handle their
-- translation specially.  This should be useful for replacing some trivial
-- accessors with simpler forms in Crucible.
data Overrides arch =
  Overrides { overrideStmt :: forall h s ret . AS.Stmt -> Maybe (Generator h s arch ret ())
            , overrideExpr :: forall h s ret . AS.Expr -> TypeConstraint -> StaticEnvMap -> Maybe (Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData))
            }

type InnerGenerator h s arch ret a = CCG.Generator (ASLExt arch) s (TranslationState h ret) ret (MST.ST h) a

newtype Generator h s arch ret a = Generator
  { _unGenerator :: InnerGenerator h s arch ret a}
  deriving
    ( Functor
    , Applicative
    , Monad
    , MSS.MonadState (TranslationState h ret s)
    )

instance MST.MonadST h (Generator h s arch ret) where
  liftST m = Generator $ MT.lift $ MST.liftST m

instance TR.MonadLog (Generator h s arch ret) where
  logMsg logLvl msg' = do
    (logHandle, curLvl, indent) <- MSS.gets tsLogHandle
    let msg = T.replicate (fromIntegral indent) " " <> msg'
    let mkmsg ex = msg : ex
    when (curLvl >= logLvl) $
      MST.liftST (STRef.modifySTRef logHandle mkmsg)

  logIndent f = do
    (logHandle, curLvl, indent) <- MSS.gets tsLogHandle
    MSS.modify' $ \s -> s { tsLogHandle = (logHandle, curLvl, f indent) }
    return indent

instance F.MonadFail (Generator h s arch ret) where
  fail s = throwTrace $ BindingFailure s

throwTrace :: TranslationException -> Generator h s arch ret a
throwTrace e = do
  env <- MSS.gets tsStaticValues
  unindentLog $ logMsg 2 $ "Static Environment: " <> (T.pack (show env))
  (logHandle, _, _) <- MSS.gets tsLogHandle
  tracedLog <- MST.liftST (STRef.readSTRef logHandle)
  X.throw $ LoggedTranslationException tracedLog e

liftGenerator :: InnerGenerator h s arch ret a
              -> Generator h s arch ret a
liftGenerator m = Generator $ m

unliftGenerator :: Generator h s arch ret a
                -> InnerGenerator h s arch ret a
unliftGenerator (Generator m) = m


liftGenerator2 :: Generator h s arch ret a
               -> Generator h s arch ret b
               -> (InnerGenerator h s arch ret a
                  -> InnerGenerator h s arch ret b
                  -> InnerGenerator h s arch ret c)
               -> Generator h s arch ret c
liftGenerator2 (Generator f) (Generator g) m = Generator $ m f g

mkAtom :: CCG.Expr (ASLExt arch) s tp -> Generator h s arch ret (CCG.Atom s tp)
mkAtom e = liftGenerator $ CCG.mkAtom e

-- This is primarily storing variable bindings and the set of signatures
-- available for other callees.
data TranslationState h ret s =
  TranslationState { tsArgAtoms :: Map.Map T.Text (Some (CCG.Atom s))
                   -- ^ Atoms corresponding to function/procedure inputs.  We assume that these are
                   -- immutable and allocated before we start executing.
                   , tsVarRefs :: Map.Map T.Text (Some (CCG.Reg s))
                   -- ^ Local registers containing values; these are created on first use
                   , tsExtendedTypes :: Map.Map T.Text ExtendedTypeData
                   -- ^ Additional type information for local variables
                   , tsGlobals :: Map.Map T.Text (Some CCG.GlobalVar)
                   -- ^ Global variables corresponding to machine state (e.g., machine registers).
                   -- These are allocated before we start executing based on the list of
                   -- transitively-referenced globals in the signature.
                   , tsEnums :: Map.Map T.Text Integer
                   -- ^ Map from enumeration constant names to their integer values.
                   , tsConsts :: Map.Map T.Text (Some ConstVal)
                   -- ^ Map from constants to their types and values.
                   , tsUserTypes :: Map.Map T.Text (Some UserType)
                   -- ^ The base types assigned to user-defined types (defined in the ASL script)
                   -- , tsEnumBounds :: Map.Map T.Text Natural
                   -- ^ The number of constructors in an enumerated type.  These
                   -- bounds are used in assertions checking the completeness of
                   -- case statements.
                   -- ,
                   , tsFunctionSigs :: Map.Map T.Text SomeSimpleFunctionSignature
                   -- ^ A collection of all of the signatures of defined functions (both functions
                   -- and procedures)
                   , tsHandle :: STRef.STRef h (Set.Set (T.Text,StaticValues))
                   -- ^ Used to name functions encountered during translation
                   , tsStaticValues :: StaticValues
                   -- ^ Environment to give concrete instantiations to polymorphic variables
                   , tsSig :: SomeFunctionSignature ret
                   -- ^ Signature of the function/procedure we are translating
                   , tsLogHandle :: (STRef.STRef h [T.Text], Integer, Integer)
                   -- ^ Handle for logging output
                   }



-- | The distinguished name of the global variable that represents the bit of
-- information indicating that the processor is in the UNPREDICTABLE state
--
-- We simulate the UNPREDICATABLE and UNDEFINED ASL statements with virtual
-- processor state.
unpredictableVarName :: T.Text
unpredictableVarName = T.pack "__UnpredictableBehavior"

-- | The distinguished name of the global variable that represents the bit of
-- state indicating that the processor is in the UNDEFINED state.
undefinedVarName :: T.Text
undefinedVarName = T.pack "__UndefinedBehavior"

-- | The distinguished name of the global variable that represents the bit of
-- state indicating that an assertion has been tripped.
assertionfailureVarName :: T.Text
assertionfailureVarName = T.pack "__AssertionFailure"

-- | The distinguished name of the global variable that represents the bit of
-- state indicating that instruction processing is finished
-- FIXME: Currently unused.

-- endofinstructionVarName :: T.Text
-- endofinstructionVarName = T.pack "__EndOfInstruction"

-- | Obtain the current value of all the give globals
-- This is a subset of all of the global state (and a subset of the current
-- global state).
withGlobals :: forall m h s arch ret globals r
             . (m ~ Generator h s arch ret)
            => Ctx.Assignment (LabeledValue T.Text WT.BaseTypeRepr) globals
            -> (Ctx.Assignment WT.BaseTypeRepr globals -> Ctx.Assignment BaseGlobalVar globals -> m r)
            -> m r
withGlobals reprs k = do
  globMap <- MS.gets tsGlobals
  let globReprs = FC.fmapFC projectValue reprs
  globals <- FC.traverseFC (fetchGlobal globMap) reprs
  k globReprs globals
  where
    fetchGlobal :: forall tp . Map.Map T.Text (Some CCG.GlobalVar)
                -> LabeledValue T.Text WT.BaseTypeRepr tp
                -> m (BaseGlobalVar tp)
    fetchGlobal globMap (LabeledValue globName rep)
      | Just (Some gv) <- Map.lookup globName globMap
      , Just Refl <- testEquality (CT.baseToType rep) (CCG.globalType gv) =
          return $ BaseGlobalVar gv
      | otherwise = throwTrace $ TranslationError $ "Missing global (or wrong type): " ++ show globName

translateStatement :: forall arch ret h s
                    . Overrides arch
                   -> AS.Stmt
                   -> Generator h s arch ret ()
translateStatement ov stmt = do
  logMsg 2 (TR.prettyShallowStmt stmt)
  translateStatement' ov stmt

assertExpr :: Overrides arch
           -> AS.Expr
           -> T.Text
           -> Generator h s arch ret ()
assertExpr ov e msg = do
  (Some res) <- translateExpr overrides e
  Refl <- assertAtomType e CT.BoolRepr res
  assertAtom ov res (Just e) msg

assertAtom :: Overrides arch
           -> CCG.Atom s CT.BoolType
           -> Maybe AS.Expr
           -> T.Text
           -> Generator h s arch ret ()
assertAtom ov test mexpr msg = do
  case mexpr of
    Just (AS.ExprVarRef (AS.QualifiedIdentifier _ "FALSE")) -> return ()
    Just expr ->
      liftGenerator $ CCG.assertExpr (CCG.AtomExpr test) (CCG.App (CCE.StringLit $ WT.UnicodeLiteral $ msg <> (T.pack $ "Expression: " <> show expr)))
    _ -> liftGenerator $ CCG.assertExpr (CCG.AtomExpr test) (CCG.App (CCE.StringLit $ WT.UnicodeLiteral msg))
  Some assertTrippedE <- lookupVarRef assertionfailureVarName
  assertTripped <- mkAtom assertTrippedE
  Refl <- assertAtomType' CT.BoolRepr assertTripped
  result <- mkAtom $ CCG.App (CCE.Or (CCG.AtomExpr assertTripped) (CCG.AtomExpr test))
  translateAssignment' ov (AS.LValVarRef (AS.QualifiedIdentifier AS.ArchQualAny assertionfailureVarName)) result TypeBasic Nothing

crucibleToStaticType :: Some CT.TypeRepr -> Maybe StaticType
crucibleToStaticType (Some ct) = case ct of
  CT.IntegerRepr -> Just $ StaticIntType
  CT.BoolRepr -> Just $ StaticBoolType
  CT.BVRepr nr -> Just $ StaticBVType (WT.intValue nr)
  _ -> Nothing

getStaticEnv :: Generator h s arch ret StaticEnvMap
getStaticEnv = do
  svals <- MS.gets tsStaticValues
  tlookup <- lookupVarType'
  return $ StaticEnvMap svals (staticTypeMap tlookup)
  where
    staticTypeMap f nm =
      fromMaybe Nothing $ crucibleToStaticType <$> (f nm)

abnormalExit :: Overrides arch -> Generator h s arch ret ()
abnormalExit _ = do
  SomeFunctionSignature sig <- MS.gets tsSig
  let retT = CT.SymbolicStructRepr (funcRetRepr sig)
  defaultv <- getDefaultValue retT
  returnWithGlobals defaultv

returnWithGlobals :: ret ~ FuncReturn globalWrites tps
                  => CCG.Atom s (CT.SymbolicStructType tps)
                  -> Generator h s arch ret ()
returnWithGlobals retVal = do
  let retT = CCG.typeOfAtom retVal
  SomeFunctionSignature sig <- MS.gets tsSig
  withGlobals (funcGlobalWriteReprs sig) $ \globalBaseTypes globals -> liftGenerator $ do
    globalsSnapshot <- CCG.extensionStmt (GetRegState globalBaseTypes globals)
    let result = MkBaseStruct
          (Ctx.empty Ctx.:> CT.SymbolicStructRepr globalBaseTypes Ctx.:> retT)
          (Ctx.empty Ctx.:> globalsSnapshot Ctx.:> CCG.AtomExpr retVal)
    CCG.returnFromFunction (CCG.App $ CCE.ExtensionApp result)

-- | Translate a single ASL statement into Crucible
translateStatement' :: forall arch ret h s
                    . Overrides arch
                   -> AS.Stmt
                   -- ^ Statement we are translating
                   -> Generator h s arch ret ()
translateStatement' ov stmt
  | Just so <- overrideStmt ov stmt = so
  | otherwise = case stmt of
      AS.StmtReturn mexpr -> do
        SomeFunctionSignature sig <- MS.gets tsSig
        -- Natural return type
        let retT = CT.SymbolicStructRepr (funcRetRepr sig)
        let expr = case mexpr of
              Nothing -> AS.ExprTuple []
              Just (AS.ExprTuple es) -> AS.ExprTuple es
              Just e | Ctx.sizeInt (Ctx.size (funcRetRepr sig)) == 1 ->
                AS.ExprTuple [e]
              Just e -> e
        (Some a, _) <- translateExpr' ov expr (ConstraintSingle retT)
        Refl <- assertAtomType expr retT a
        returnWithGlobals a
      AS.StmtIf clauses melse -> translateIf ov clauses melse
      AS.StmtCase e alts -> translateCase ov e alts
      AS.StmtAssert e -> assertExpr ov e "ASL Assertion"
      AS.StmtVarsDecl ty idents -> mapM_ (declareUndefinedVar ty) idents
      AS.StmtVarDeclInit (ident, ty) expr -> translateDefinedVar ov ty ident expr
      AS.StmtConstDecl (ident, ty) expr -> do
        -- NOTE: We use the same translation for constants.  We don't do any verification that the
        -- ASL doesn't attempt to modify a constant.
        env <- getStaticEnv
        case SE.exprToStatic env expr of
          Just sv -> mapStaticVals (Map.insert ident sv)
          _ -> return ()
        translateDefinedVar ov ty ident expr

      AS.StmtAssign lval expr -> translateAssignment ov lval expr
      AS.StmtWhile test body -> do
        let testG = do
              Some testA <- translateExpr ov test
              Refl <- assertAtomType test CT.BoolRepr testA
              return (CCG.AtomExpr testA)
        let bodyG = indentLog $ mapM_ (translateStatement ov) body
        liftGenerator2 testG bodyG $ \testG' bodyG' ->
          CCG.while (WP.InternalPos, testG') (WP.InternalPos, bodyG')
      AS.StmtRepeat body test -> translateRepeat ov body test
      AS.StmtFor var (lo, hi) body -> translateFor ov var lo hi body
      AS.StmtCall qIdent args -> do
        translateFunctionCall ov qIdent args ConstraintNone >>= \case
          Nothing -> return ()
          _ -> throwTrace $ UnexpectedReturnInStmtCall

      _ -> throwTrace $ UnsupportedStmt stmt


translateFunctionCall :: forall e arch h s ret
                       . InputArgument s e
                      => Overrides arch
                      -> AS.QualifiedIdentifier
                      -> [e]
                      -> TypeConstraint
                      -> Generator h s arch ret (Maybe (Some (CCG.Atom s), ExtendedTypeData))
translateFunctionCall ov qIdent args ty = do
  logMsg 2 $ "CALL: " <> (T.pack (show qIdent))
  sigMap <- MS.gets tsFunctionSigs
  let ident = mkFunctionName qIdent (length args)
  case Map.lookup ident sigMap of
    Nothing -> throwTrace $ MissingFunctionDefinition ident
    Just (SomeSimpleFunctionSignature sig) -> do
      (finalIdent, argAtoms, Some retT) <- unifyArgs ov ident (zip (sfuncArgs sig) args) (sfuncRet sig) ty
      case Ctx.fromList argAtoms of
        Some argAssign -> do
          let atomTypes = FC.fmapFC CCG.typeOfAtom argAssign

          withGlobals (sfuncGlobalReadReprs sig) $ \globalReprs globals -> do
            let globalsType = CT.baseToType (WT.BaseStructRepr globalReprs)
            globalsSnapshot <- liftGenerator $ CCG.extensionStmt (GetRegState globalReprs globals)
            let vals = FC.fmapFC CCG.AtomExpr argAssign
            let ufGlobalRep = WT.BaseStructRepr (FC.fmapFC projectValue (sfuncGlobalWriteReprs sig))
            let ufCtx = (Ctx.empty Ctx.:> ufGlobalRep Ctx.:> retT)
            let uf = UF finalIdent (WT.BaseStructRepr ufCtx) (atomTypes Ctx.:> globalsType) (vals Ctx.:> globalsSnapshot)
            atom <- mkAtom (CCG.App (CCE.ExtensionApp uf))
            let globalResult = GetBaseStruct (CT.SymbolicStructRepr ufCtx) Ctx.i1of2 (CCG.AtomExpr atom)
            withGlobals (sfuncGlobalWriteReprs sig) $ \_ thisGlobals -> liftGenerator $ do
              _ <- CCG.extensionStmt (SetRegState thisGlobals (CCG.App $ CCE.ExtensionApp globalResult))
              return ()
            let returnResult = GetBaseStruct (CT.SymbolicStructRepr ufCtx) Ctx.i2of2 (CCG.AtomExpr atom)
            result <- mkAtom (CCG.App $ CCE.ExtensionApp returnResult)
            case retT of
              WT.BaseStructRepr ctx@(Ctx.Empty Ctx.:> _) -> do
                let [ret] = sfuncRet sig
                ext <- mkExtendedTypeData ret
                let retTC = CT.SymbolicStructRepr ctx
                let returnResult' = GetBaseStruct retTC (Ctx.baseIndex) (CCG.AtomExpr result)
                unboxedResult <- mkAtom (CCG.App $ CCE.ExtensionApp returnResult')
                return $ Just $ (Some unboxedResult, ext)
              WT.BaseStructRepr _ -> do
                exts <- mapM mkExtendedTypeData (sfuncRet sig)
                return $ Just $ (Some result, TypeTuple exts)
              -- FIXME: all true return values are wrapped in a tuple. A non-tuple result
              -- indicates no return value. This is a workaround for empty tuples not being
              -- completely supported by crucible/what4
              _ -> return Nothing
  where
    -- At the cost of adding significant complexity to the CFG, we *could* attempt to terminate early
    -- whenever undefined or unpredictable behavior is encountered from a called function.
    -- This seems excessive, since we can always check these flags at the toplevel.

    -- EndOfInstruction, however, should retain the processor state while avoiding any
    -- additional instruction processing.

    -- We only need to perform this check if the global writes set of a called function could
    -- possibly have updated the end of instruction flag.

    -- FIXME: We are not checking early exit currently as it turned out to be too expensive.
    -- We are better off doing an intelligent analysis of when it is feasible for an instruction
    -- to have finished processing.

    -- checkEarlyExit :: forall tp ctx
    --                 . CCG.Atom s (CT.SymbolicStructType ctx)
    --                -> Ctx.Index ctx tp
    --                -> LabeledValue T.Text WT.BaseTypeRepr tp
    --                -> Generator h s arch ret ()
    -- checkEarlyExit struct idx (LabeledValue globName rep) = do
    --   if globName `elem` [endofinstructionVarName]
    --   then do
    --     let testE = GetBaseStruct (CCG.typeOfAtom struct) idx (CCG.AtomExpr struct)
    --     test <- mkAtom $ CCG.App $ CCE.ExtensionApp $ testE
    --     Refl <- assertAtomType' CT.BoolRepr test
    --     liftGenerator2 (abnormalExit ov) (return ()) $ \exit ret ->
    --       CCG.ifte_ (CCG.AtomExpr test) exit ret
    --   else return ()



-- | Translate a for statement into Crucible
--
-- The translation is from
--
-- > for i = X to Y
-- >    body
--
-- to
--
-- > i = X
-- > while(i <= Y)
-- >   body
-- >   i = i + 1
--
-- NOTE: The translation is inclusive of the upper bound - is that right?
--
-- NOTE: We are assuming that the variable assignment is actually a declaration of integer type
translateFor :: Overrides arch
             -> AS.Identifier
             -> AS.Expr
             -> AS.Expr
             -> [AS.Stmt]
             -> Generator h s arch ret ()
translateFor ov var lo hi body = do
  env <- getStaticEnv
  case (SE.exprToStatic env lo, SE.exprToStatic env hi) of
    (Just (StaticInt loInt), Just (StaticInt hiInt)) ->
      unrollFor ov var loInt hiInt body
    _ -> do
      vars <- MS.gets tsVarRefs
      case Map.lookup var vars of
        Just (Some lreg) -> do
          Some atom <- translateExpr ov lo
          Refl <- assertAtomType' (CCG.typeOfReg lreg) atom
          liftGenerator $ CCG.assignReg lreg (CCG.AtomExpr atom)
        _ -> do
          let ty = AS.TypeRef (AS.QualifiedIdentifier AS.ArchQualAny (T.pack "integer"))
          translateDefinedVar ov ty var lo
      let ident = AS.QualifiedIdentifier AS.ArchQualAny var
      let testG = do
            let testE = AS.ExprBinOp AS.BinOpLTEQ (AS.ExprVarRef ident) hi
            Some testA <- translateExpr ov testE
            Refl <- assertAtomType testE CT.BoolRepr testA
            return (CCG.AtomExpr testA)
      let increment = do
            AS.StmtAssign (AS.LValVarRef ident)
              (AS.ExprBinOp AS.BinOpAdd (AS.ExprVarRef ident) (AS.ExprLitInt 1))

      let bodyG = mapM_ (translateStatement ov) (body ++ [increment])
      liftGenerator2 testG bodyG $ \testG' bodyG' ->
        CCG.while (WP.InternalPos, testG') (WP.InternalPos, bodyG')


unrollFor :: Overrides arch
          -> AS.Identifier
          -> Integer
          -> Integer
          -> [AS.Stmt]
          -> Generator h s arch ret ()
unrollFor ov var lo hi body = do
  mapM_ translateForUnrolled [lo .. hi]
  where
    translateForUnrolled i = forgetNewStatics $ do
      mapStaticVals (Map.insert var (StaticInt i))
      translateStatement ov (letInStmt [] body)

translateRepeat :: Overrides arch
                -> [AS.Stmt]
                -> AS.Expr
                -> Generator h s arch ret ()
translateRepeat ov body test = liftGenerator $ do
  cond_lbl <- CCG.newLabel
  loop_lbl <- CCG.newLabel
  exit_lbl <- CCG.newLabel

  CCG.defineBlock loop_lbl $ do
    unliftGenerator $ mapM_ (translateStatement ov) body
    CCG.jump cond_lbl

  CCG.defineBlock cond_lbl $ do
    Some testA <- unliftGenerator $ translateExpr ov test
    Refl <- unliftGenerator $ assertAtomType test CT.BoolRepr testA
    CCG.branch (CCG.AtomExpr testA) loop_lbl exit_lbl

  CCG.continue exit_lbl (CCG.jump loop_lbl)

translateDefinedVar :: Overrides arch
                    -> AS.Type
                    -> AS.Identifier
                    -> AS.Expr
                    -> Generator h s arch ret ()
translateDefinedVar ov ty ident expr = do
  Some expected <- translateType ty
  (Some atom, ext) <- translateExpr' ov expr (ConstraintSingle expected)
  Refl <- assertAtomType expr expected atom
  locals <- MS.gets tsVarRefs
  when (Map.member ident locals) $ do
    X.throw (LocalAlreadyDefined ident)
  putExtendedTypeData ident ext
  reg <- Generator $ CCG.newReg (CCG.AtomExpr atom)
  MS.modify' $ \s -> s { tsVarRefs = Map.insert ident (Some reg) locals }


-- | Convert an lVal to its equivalent expression.
lValToExpr :: AS.LValExpr -> Maybe AS.Expr
lValToExpr lval = case lval of
  AS.LValVarRef qName -> return $ AS.ExprVarRef qName
  AS.LValMember lv memberName -> do
    lve <- lValToExpr lv
    return $ AS.ExprMember lve memberName
  AS.LValArrayIndex lv slices -> do
    lve <- lValToExpr lv
    return $ AS.ExprIndex lve slices
  AS.LValSliceOf lv slices -> do
    lve <- lValToExpr lv
    return $ AS.ExprSlice lve slices
  _ -> Nothing


constraintOfLVal :: Overrides arch
           -> AS.LValExpr
           -> Generator h s arch ret TypeConstraint
constraintOfLVal ov lval = case lval of
  AS.LValIgnore -> return $ ConstraintNone
  AS.LValVarRef (AS.QualifiedIdentifier _ ident) -> do
    mTy <- lookupVarType ident
    case mTy of
      Just (Some ty) -> return $ ConstraintSingle ty
      Nothing -> do
        sig <- MS.gets tsSig
        case Map.lookup (someSigName sig, ident) localTypeHints of
          Just tc -> return $ tc
          _ -> return $ ConstraintNone
  AS.LValTuple lvs -> do
    lvTs <- mapM (constraintOfLVal ov) lvs
    return $ ConstraintTuple lvTs
  AS.LValMemberBits _ bits
    | Just (Some nr) <- WT.someNat (length bits)
    , Just WT.LeqProof <- (WT.knownNat @1) `WT.testLeq` nr ->
      return $ ConstraintSingle $ CT.BVRepr nr
  AS.LValSlice lvs -> do
    mTy <- runMaybeT $ do
      lengths <- mapM (bvLengthM <=< lift . constraintOfLVal ov) lvs
      case WT.someNat (sum lengths) of
        Just (Some repr)
          | Just WT.LeqProof <- (WT.knownNat @1) `WT.testLeq` repr ->
            return $ Some $ CT.BVRepr repr
        _ -> fail ""
    return $ mConstraint mTy
  AS.LValSliceOf e [slice] -> do
    mLen <- getStaticSliceLength slice
    case mLen of
      Just (Some (BVRepr len)) ->
        return $ ConstraintSingle $ CT.BVRepr len
      Nothing -> do
        innerConstraint <- constraintOfLVal ov e
        return $ relaxConstraint innerConstraint

  _ -> case lValToExpr lval of
         Just lve -> do
           Some lveAtom <- translateExpr ov lve
           return $ ConstraintSingle $ (CCG.typeOfAtom lveAtom)
         Nothing -> return ConstraintNone
  where
    bvLengthM t = MaybeT (return (bvLength t))

    bvLength :: TypeConstraint -> Maybe Integer
    bvLength tp = case tp of
      ConstraintSingle (CT.BVRepr nr) -> Just (WT.intValue nr)
      _ -> Nothing

    mConstraint :: Maybe (Some (CT.TypeRepr)) -> TypeConstraint
    mConstraint mTy = case mTy of
      Just (Some ty) -> ConstraintSingle ty
      Nothing -> ConstraintNone



-- | Translate general assignment statements into Crucible
--
-- This case is interesting, as assignments can be to locals or globals.
--
-- NOTE: We are assuming that there cannot be assignments to arguments.
translateAssignment :: Overrides arch
                    -> AS.LValExpr
                    -> AS.Expr
                    -> Generator h s arch ret ()
translateAssignment ov lval e = do
  -- If possible, determine the type of the left hand side first in order
  -- to inform the translation of the given expression
  constraint <- constraintOfLVal ov lval
  (Some atom, ext) <- translateExpr' ov e constraint
  translateAssignment'' ov lval atom constraint ext (Just e)

translateAssignment' :: forall arch s tp h ret . Overrides arch
                     -> AS.LValExpr
                     -> CCG.Atom s tp
                     -> ExtendedTypeData
                     -> Maybe AS.Expr
                     -> Generator h s arch ret ()
translateAssignment' ov lval atom atomext mE =
  translateAssignment'' ov lval atom (ConstraintSingle (CCG.typeOfAtom atom)) atomext mE

mkSliceRange :: (Integer, Integer) -> AS.Slice
mkSliceRange (lo, hi) = AS.SliceRange (AS.ExprLitInt hi) (AS.ExprLitInt lo)

translateAssignment'' :: forall arch s tp h ret . Overrides arch
                     -> AS.LValExpr
                     -> CCG.Atom s tp
                     -> TypeConstraint
                     -> ExtendedTypeData
                     -> Maybe AS.Expr
                     -> Generator h s arch ret ()
translateAssignment'' ov lval atom constraint atomext mE = do
  case lval of
    AS.LValIgnore -> return () -- Totally ignore - this probably shouldn't happen (except inside of a tuple)
    AS.LValVarRef (AS.QualifiedIdentifier _ ident) -> do
      locals <- MS.gets tsVarRefs
      putExtendedTypeData ident atomext

      case Map.lookup ident locals of
        Just (Some lreg) -> do
          Refl <- assertAtomType' (CCG.typeOfReg lreg) atom
          Generator $ CCG.assignReg lreg (CCG.AtomExpr atom)
        Nothing -> do
          globals <- MS.gets tsGlobals
          case Map.lookup ident globals of
            Just (Some gv) -> do
              Refl <- assertAtomType' (CCG.globalType gv) atom
              Generator $ CCG.writeGlobal gv (CCG.AtomExpr atom)
            Nothing -> do
              reg <- Generator $ CCG.newReg (CCG.AtomExpr atom)
              MS.modify' $ \s -> s { tsVarRefs = Map.insert ident (Some reg) locals }
    AS.LValMember struct memberName -> do
      Just lve <- return $ lValToExpr struct
      (Some structAtom, ext) <- translateExpr' ov lve ConstraintNone
      case ext of
        TypeRegister sig ->
          case Map.lookup memberName sig of
            Just slice -> do
              translatelValSlice ov struct (mkSliceRange slice) atom constraint
            _ -> X.throw $ MissingRegisterField lve memberName
        TypeStruct acc ->
          case (CCG.typeOfAtom structAtom, Map.lookup memberName acc) of
            (CT.SymbolicStructRepr tps, Just (StructAccessor repr idx _))
              | Just Refl <- testEquality tps repr
              , CT.AsBaseType asnBt <- CT.asBaseType $ CCG.typeOfAtom atom
              , Just Refl <- testEquality asnBt (tps Ctx.! idx) -> do
                let ctps = toCrucTypes tps
                let fields = Ctx.generate (Ctx.size ctps) (getStructField tps ctps structAtom)
                let idx' = fromBaseIndex tps ctps idx
                let newStructAsn = fields & (ixF idx') .~ (CCG.AtomExpr atom)
                newStruct <- mkAtom $ CCG.App $ CCE.ExtensionApp $ MkBaseStruct ctps newStructAsn
                translateAssignment' ov struct newStruct ext Nothing
            _ -> throwTrace $ InvalidStructUpdate lval (CCG.typeOfAtom atom)
        TypeGlobalStruct acc ->
          case Map.lookup memberName acc of
            Just globalName ->
              translateAssignment'' ov (AS.LValVarRef (AS.QualifiedIdentifier AS.ArchQualAny globalName)) atom constraint atomext mE
            _ -> throwTrace $ MissingGlobalStructField struct memberName

        _ -> throwTrace $ UnexpectedExtendedType lve ext

    AS.LValTuple lvals ->
      case atomext of
        TypeTuple exts | length exts == length lvals ->
          case CCG.typeOfAtom atom of
            CT.SymbolicStructRepr tps -> void $ Ctx.traverseAndCollect (assignTupleElt lvals exts tps atom) tps
            tp -> X.throw $ ExpectedStructType mE tp
        _ -> error $ "Unexpected extended type information:" <> show lvals <> " " <> show atomext

    AS.LValSliceOf lv [slice] -> translatelValSlice ov lv slice atom constraint

    AS.LValSliceOf lv [fstSlice@(AS.SliceSingle _), slice] -> do
      case CCG.typeOfAtom atom of
        CT.BVRepr wRepr -> do
          let topIndex = WT.intValue wRepr - 1
          Some topBit <- translateSlice' ov atom (AS.SliceSingle (AS.ExprLitInt topIndex)) ConstraintNone
          translatelValSlice ov lv fstSlice topBit ConstraintNone
          Some rest <- translateSlice' ov atom (AS.SliceRange (AS.ExprLitInt (topIndex - 1))
                                                (AS.ExprLitInt 0)) ConstraintNone
          translatelValSlice ov lv slice rest ConstraintNone
        tp -> throwTrace $ ExpectedBVType' mE tp

    AS.LValArrayIndex ref@(AS.LValVarRef (AS.QualifiedIdentifier _ arrName)) [AS.SliceSingle slice] -> do
        Some e <- lookupVarRef arrName
        arrAtom <- mkAtom e
        Some idxAtom <- translateExpr ov slice
        if | CT.AsBaseType bt <- CT.asBaseType (CCG.typeOfAtom idxAtom)
           , CT.SymbolicArrayRepr (Ctx.Empty Ctx.:> bt') retTy <- CCG.typeOfAtom arrAtom
           , Just Refl <- testEquality bt bt' -- index types match
           , CT.AsBaseType btAsn <- CT.asBaseType (CCG.typeOfAtom atom)
           , Just Refl <- testEquality btAsn retTy -- array element types match
           -> do
               let asn = Ctx.singleton (CCE.BaseTerm bt (CCG.AtomExpr idxAtom))
               let arr = CCG.App $ CCE.SymArrayUpdate retTy (CCG.AtomExpr arrAtom) asn (CCG.AtomExpr atom)
               newArr <- mkAtom arr
               translateAssignment' ov ref newArr TypeBasic Nothing
           | otherwise -> error $ "Invalid array assignment: " ++ show lval

    AS.LValArrayIndex _ (_ : _ : _) -> do
      error $
        "Unexpected multi-argument array assignment. Is this actually a setter?" ++ show lval

    AS.LValMemberBits struct bits -> do
      Just lve <- return $ lValToExpr struct
      (Some _, ext) <- translateExpr' ov lve ConstraintNone
      getRange <- return $ \memberName -> case ext of
        TypeRegister sig ->
          case Map.lookup memberName sig of
            Just (lo, hi) -> return $ (hi - lo) + 1
            _ -> throwTrace $ MissingRegisterField lve memberName
        TypeStruct acc ->
          case Map.lookup memberName acc of
            Just (StructAccessor repr idx _) ->
              case repr Ctx.! idx of
                CT.BaseBVRepr nr -> return $ WT.intValue nr
                x -> throwTrace $ InvalidStructUpdate struct (CT.baseToType x)
            _ -> throwTrace $ MissingStructField lve memberName
        TypeGlobalStruct acc ->
          case Map.lookup memberName acc of
            Just globalname -> do
              lookupVarType globalname >>= \case
                Nothing -> throwTrace $ MissingGlobal globalname
                Just (Some tp) ->
                  case tp of
                    CT.BVRepr nr -> return $ WT.intValue nr
                    x -> throwTrace $ InvalidStructUpdate struct x
            _ -> throwTrace $ MissingGlobalStructField acc memberName
        _ -> throwTrace $ UnexpectedExtendedType lve ext
      total <- foldM (\acc -> \mem -> do
        range <- getRange mem
        Some aslice <- translateSlice' ov atom (mkSliceRange (acc, (acc + range) - 1)) ConstraintNone
        let lv' = AS.LValMember struct mem
        translateAssignment' ov lv' aslice TypeBasic Nothing
        return $ acc + range)
        -- FIXME: It's unclear which direction the fields should be read
        0 (List.reverse bits)
      Some (BVRepr trepr) <- return $ intToBVRepr total
      _ <- assertAtomType' (CT.BVRepr trepr) atom
      return ()

    AS.LValSlice lvs ->
      case CCG.typeOfAtom atom of
        CT.BVRepr repr -> foldM_ (translateImplicitSlice ov repr atom) 0 lvs
        tp -> throwTrace $ ExpectedBVType' mE tp

    _ -> X.throw $ UnsupportedLVal lval
    where assignTupleElt :: [AS.LValExpr]
                         -> [ExtendedTypeData]
                         -> Ctx.Assignment WT.BaseTypeRepr ctx
                         -> CCG.Atom s (CT.SymbolicStructType ctx)
                         -> Ctx.Index ctx tp'
                         -> WT.BaseTypeRepr tp'
                         -> Generator h s arch ret ()
          assignTupleElt lvals exts tps struct ix _ = do
            let getStruct = GetBaseStruct (CT.SymbolicStructRepr tps) ix (CCG.AtomExpr struct)
            getAtom <- mkAtom (CCG.App (CCE.ExtensionApp getStruct))
            let ixv = Ctx.indexVal ix
            translateAssignment' ov (lvals !! ixv) getAtom (exts !! ixv) Nothing

          getStructField :: forall bctx ctx ftp
                          . ctx ~ ToCrucTypes bctx
                         => Ctx.Assignment CT.BaseTypeRepr bctx
                         -> Ctx.Assignment CT.TypeRepr ctx
                         -> CCG.Atom s (CT.SymbolicStructType bctx)
                         -> Ctx.Index ctx ftp
                         -> CCG.Expr (ASLExt arch) s ftp
          getStructField btps ctps struct ix = case toFromBaseProof (ctps Ctx.! ix) of
            Just Refl ->
              let
                  ix' = toBaseIndex btps ctps ix
                  getStruct =
                    (GetBaseStruct (CT.SymbolicStructRepr btps) ix' (CCG.AtomExpr struct)) ::
                      ASLApp (CCG.Expr (ASLExt arch) s) ftp
              in
                CCG.App $ CCE.ExtensionApp getStruct
            _ -> error "unreachable"

translateImplicitSlice :: Overrides arch
                       -> WT.NatRepr w
                       -> CCG.Atom s (CT.BVType w)
                       -> Integer
                       -> AS.LValExpr
                       -> Generator h s arch ret (Integer)
translateImplicitSlice ov rhsRepr rhs offset lv  = do
  lvT <- constraintOfLVal ov lv
  case lvT of
    ConstraintSingle (CT.BVRepr lvRepr) -> do
      let lvLength = WT.intValue lvRepr
      let rhsLength = WT.intValue rhsRepr
      let hi = rhsLength - offset - 1
      let lo = rhsLength - offset - lvLength
      let slice = AS.SliceRange (AS.ExprLitInt hi) (AS.ExprLitInt lo)
      Some slicedRhs <- translateSlice' ov rhs slice ConstraintNone
      translateAssignment' ov lv slicedRhs TypeBasic Nothing
      return (offset + lvLength)
    _ -> X.throw $ UnsupportedLVal lv

translatelValSlice :: Overrides arch
               -> AS.LValExpr
               -> AS.Slice
               -> CCG.Atom s tp
               -> TypeConstraint
               -> Generator h s arch ret ()
translatelValSlice ov lv slice asnAtom' constraint = do
  let Just lve = lValToExpr lv
  Some atom' <- translateExpr ov lve
  SliceRange signed lenRepr _ loAtom hiAtom atom <- getSliceRange ov slice atom' constraint
  asnAtom <- extBVAtom signed lenRepr asnAtom'
  Just (Some result, _) <- translateFunctionCall overrides (AS.VarName "setSlice") [Some atom, Some loAtom, Some hiAtom, Some asnAtom] ConstraintNone
  translateAssignment' ov lv result TypeBasic Nothing


-- | Get the "default" value for a given crucible type. We can't use unassigned
-- registers, as ASL functions occasionally return values uninitialized.
getDefaultValue :: forall h s arch ret tp
                 . CT.TypeRepr tp
                -> Generator h s arch ret (CCG.Atom s tp)
getDefaultValue repr = case repr of
  CT.BVRepr _ -> mkUF' "UNDEFINED_bitvector"
  CT.SymbolicStructRepr tps -> do
    let crucAsn = toCrucTypes tps
    if | Refl <- baseCrucProof tps -> do
         fields <- FC.traverseFC getDefaultValue crucAsn
         mkAtom $ CCG.App $ CCE.ExtensionApp $
           MkBaseStruct crucAsn (FC.fmapFC CCG.AtomExpr fields)
  CT.IntegerRepr -> mkUF' "UNDEFINED_integer"
  CT.BoolRepr -> mkUF' "UNDEFINED_boolean"
  -- CT.SymbolicArrayRepr idx xs -> mkUF "UNDEFINED_Array" repr
  _ -> error $ "Invalid undefined value: " <> show repr
  where
    mkUF' :: T.Text ->  Generator h s arch ret (CCG.Atom s tp)
    mkUF' nm = do
      Just (Some atom, _) <- translateFunctionCall @Void overrides (AS.VarName nm) [] (ConstraintSingle repr)
      Refl <- assertAtomType' repr atom
      return $ atom


-- | Put a new local in scope and initialize it to an undefined value
declareUndefinedVar :: AS.Type
                    -> AS.Identifier
                    -> Generator h s arch ret ()
declareUndefinedVar ty ident = do
  locals <- MS.gets tsVarRefs
  when (Map.member ident locals) $ do
    X.throw (LocalAlreadyDefined ident)
  addExtendedTypeData ident ty
  tty <- translateType ty
  case tty of
    Some rep -> do
      defaultv <- getDefaultValue rep
      reg <- Generator $ CCG.newReg (CCG.AtomExpr defaultv)
      MS.modify' $ \s -> s { tsVarRefs = Map.insert ident (Some reg) locals }



mkExtendedTypeData :: AS.Type
                   -> Generator h s arch ret (ExtendedTypeData)
mkExtendedTypeData = mkExtendedTypeData' getUT getExtendedTypeData
  where
    getUT :: T.Text -> Generator h s arch ret (Maybe (Some UserType))
    getUT tpName = Map.lookup tpName <$> MS.gets tsUserTypes

addExtendedTypeData :: AS.Identifier
                    -> AS.Type                    
                    -> Generator h s arch ret ()
addExtendedTypeData ident ty = do
  ext <- mkExtendedTypeData ty
  putExtendedTypeData ident ext

putExtendedTypeData :: AS.Identifier
                    -> ExtendedTypeData
                    -> Generator h s arch ret ()
putExtendedTypeData ident ext' = do
  ext'' <- getExtendedTypeData ident
  ext <- mergeExtensions ext' ext''
  MS.modify' $ \s -> s { tsExtendedTypes = Map.insert ident ext (tsExtendedTypes s) }

getExtendedTypeData :: AS.Identifier
                    -> Generator h s arch ret (ExtendedTypeData)
getExtendedTypeData ident = do
  exts <- MS.gets tsExtendedTypes
  return $ fromMaybe TypeBasic (Map.lookup ident exts)

mergeExtensions :: ExtendedTypeData
                -> ExtendedTypeData
                -> Generator h s arch ret (ExtendedTypeData)
mergeExtensions ext1 ext2 =
  case (ext1, ext2) of
  (_, TypeBasic) -> return ext1
  (TypeBasic, _) -> return ext2
  _ -> if ext1 == ext2 then return ext1
    else return TypeBasic


-- | Translate types (including user-defined types) into Crucible type reprs
--
-- Translations of user-defined types (i.e., types defined in an ASL program)
-- are stored in the 'TranslationState' and are looked up when needed.
--
translateType :: AS.Type -> Generator h s arch ret (Some CT.TypeRepr)
translateType t = do
  env <- getStaticEnv
  t' <- case applyStaticEnv env t of
    Just t' -> return $ t'
    Nothing -> throwTrace $ CannotStaticallyEvaluateType t (staticEnvMapVals env)
  case t' of
    AS.TypeRef (AS.QualifiedIdentifier _ "integer") -> return (Some CT.IntegerRepr)
    AS.TypeRef (AS.QualifiedIdentifier _ "boolean") -> return (Some CT.BoolRepr)
    AS.TypeRef (AS.QualifiedIdentifier _ "bit") -> return (Some (CT.BVRepr (NR.knownNat @1)))
    AS.TypeRef qi@(AS.QualifiedIdentifier _ ident) -> do
      uts <- MS.gets tsUserTypes
      case Map.lookup ident uts of
        Nothing -> X.throw (UnexpectedType qi)
        Just (Some ut) -> return (Some (CT.baseToType (userTypeRepr ut)))
    AS.TypeFun "bits" e ->
      case e of
        AS.ExprLitInt nBits
          | Just (Some nr) <- NR.someNat nBits
          , Just NR.LeqProof <- NR.isPosNat nr -> return (Some (CT.BVRepr nr))
        _ -> throwTrace $ UnsupportedType t'
    AS.TypeFun "__RAM" (AS.ExprLitInt n)
       | Just (Some nRepr) <- NR.someNat n
       , Just NR.LeqProof <- NR.isPosNat nRepr ->
         return $ Some $ CT.baseToType $
           WT.BaseArrayRepr (Ctx.empty Ctx.:> WT.BaseBVRepr (WT.knownNat @52)) (WT.BaseBVRepr nRepr)
    AS.TypeFun _ _ -> throwTrace $ UnsupportedType t'
    AS.TypeArray _ty _idxTy -> throwTrace $ UnsupportedType t'
    AS.TypeReg _i _flds -> throwTrace $ UnsupportedType t'
    _ -> throwTrace $ UnsupportedType t'

withState :: TranslationState h ret s
          -> Generator h s arch ret a
          -> Generator h s arch ret a
withState s f = do
  s' <- MS.get
  MS.put s
  r <- f
  MS.put s'
  return r

forgetNewStatics :: Generator h s arch ret a
                 -> Generator h s arch ret a
forgetNewStatics f = do
  svals <- MS.gets tsStaticValues
  r <- f
  MS.modify' $ \s -> s { tsStaticValues = svals }
  return r

-- Return a translation state that doesn't contain any local variables from
-- the current translation context
freshLocalsState :: Generator h s arch ret (TranslationState h ret s)
freshLocalsState = do
  s <- MS.get
  return $ s { tsArgAtoms = Map.empty
             , tsVarRefs = Map.empty
             , tsExtendedTypes = Map.empty
             , tsStaticValues = Map.empty
             }

mapStaticVals :: (Map.Map T.Text StaticValue -> Map.Map T.Text StaticValue)
             -> Generator h s arch ret ()
mapStaticVals f = do
  env <- MS.gets tsStaticValues
  MS.modify' $ \s -> s { tsStaticValues = f env }


-- Unify a syntactic ASL type against a crucible type, and update
-- the current static variable evironment with any discovered instantiations
unifyType :: AS.Type
          -> TypeConstraint
          -> Generator h s arch ret ()
unifyType aslT constraint = do
  env <- getStaticEnv
  case (aslT, constraint) of
    (AS.TypeFun "bits" expr, ConstraintSingle (CT.BVRepr repr)) ->
      case expr of
        AS.ExprLitInt i | Just (Some nr) <- NR.someNat i, Just Refl <- testEquality repr nr -> return ()
        AS.ExprVarRef (AS.QualifiedIdentifier _ ident) ->
          case staticEnvValue env ident of
            Just (StaticInt i) | Just (Some nr) <- NR.someNat i, Just Refl <- testEquality repr nr -> return ()
            Nothing -> mapStaticVals (Map.insert ident (StaticInt $ toInteger (NR.natValue repr)))
            _ -> throwTrace $ TypeUnificationFailure aslT constraint (staticEnvMapVals env)
        AS.ExprBinOp AS.BinOpMul e e' ->
          case (mInt env e, mInt env e') of
            (Left i, Left i') | Just (Some nr) <- NR.someNat (i * i'), Just Refl <- testEquality repr nr -> return ()
            (Right (AS.ExprVarRef (AS.QualifiedIdentifier _ ident)), Left i')
              | reprVal <- toInteger $ WT.natValue repr
              , (innerVal, 0) <- reprVal `divMod` i' ->
                mapStaticVals $ Map.insert ident (StaticInt innerVal)
            (Left i, Right (AS.ExprVarRef (AS.QualifiedIdentifier _ ident)))
              | reprVal <- toInteger $ WT.natValue repr
              , (innerVal, 0) <- reprVal `divMod` i ->
               mapStaticVals $ Map.insert ident (StaticInt innerVal)
            _ -> throwTrace $ TypeUnificationFailure aslT constraint (staticEnvMapVals env)
        _ -> throwTrace $ TypeUnificationFailure aslT constraint (staticEnvMapVals env)
    -- it's not clear if this is always safe

    -- (AS.TypeFun "bits" _ , ConstraintHint (HintMaxBVSize nr)) -> do
    --   case applyStaticEnv' env aslT of
    --     Just _ -> return ()
    --     _ -> unifyType aslT (ConstraintSingle (CT.BVRepr nr))
    (_, ConstraintHint _) -> return ()
    (_, ConstraintNone) -> return ()
    (_, ConstraintTuple _) -> throwTrace $ TypeUnificationFailure aslT constraint (staticEnvMapVals env)
    (_, ConstraintSingle cTy) -> do
      Some atomT' <- translateType aslT
      case testEquality cTy atomT' of
        Just Refl -> return ()
        _ -> throwTrace $ TypeUnificationFailure aslT constraint (staticEnvMapVals env)
  where
    mInt env e = case SE.exprToStatic env e of
      Just (StaticInt i) -> Left i
      _ -> Right e



dependentVarsOfType :: AS.Type -> [T.Text]
dependentVarsOfType t = case t of
  AS.TypeFun "bits" e -> TR.varsOfExpr e
  _ -> []


unifyTypes :: [AS.Type]
           -> TypeConstraint
           -> Generator h s arch ret ()
unifyTypes tps constraint = do
  case constraint of
    ConstraintSingle (CT.SymbolicStructRepr stps) |
        insts <- zip tps (FC.toListFC (ConstraintSingle . CT.baseToType) stps)
      , length insts == length tps ->
          mapM_ (\(tp, stp) -> unifyType tp stp) insts
    ConstraintTuple cts
      | length tps == length cts ->
        mapM_ (\(tp, ct) -> unifyType tp ct) (zip tps cts)
    ConstraintNone -> return ()
    _ -> X.throw $ TypesUnificationFailure tps constraint

getConcreteTypeConstraint :: AS.Type -> Generator h s arch ret TypeConstraint
getConcreteTypeConstraint t = do
  env <- getStaticEnv
  case applyStaticEnv env t of
    Just t' -> do
      Some ty <- translateType t'
      return $ ConstraintSingle ty
    _ -> return $ ConstraintNone

someTypeOfAtom :: CCG.Atom s tp
               -> TypeConstraint
someTypeOfAtom atom = ConstraintSingle (CCG.typeOfAtom atom)


class InputArgument s t where
  unifyArg :: Overrides arch
           -> TranslationState h ret s
           -> AS.SymbolDecl
           -> t
           -> Generator h s arch ret (Some (CCG.Atom s))
  collectStaticValues :: TranslationState h ret s
                      -> AS.SymbolDecl
                      -> t
                      -> Generator h s arch ret ()

instance InputArgument s AS.Expr where
  unifyArg ov outerState (_, t) e = do
    cty <- getConcreteTypeConstraint t
    (Some atom, _) <- withState outerState $ translateExpr' ov e cty
    unifyType t (ConstraintSingle (CCG.typeOfAtom atom))
    return $ Some atom

  collectStaticValues outerState (nm, _) e = do
    sv <- withState outerState $ do
      env <- getStaticEnv
      return $ SE.exprToStatic env e
    case sv of
      Just i -> mapStaticVals (Map.insert nm i)
      _ -> return ()

instance InputArgument s (Some (CCG.Atom s)) where
  unifyArg _ _ (_, t) (Some atom) = do
    unifyType t (ConstraintSingle (CCG.typeOfAtom atom))
    return (Some atom)
  collectStaticValues _ _ _ = return ()

-- | For functions without arguments
instance InputArgument s Void where
  unifyArg _ _ _ v = Void.absurd v
  collectStaticValues _ _ v = Void.absurd v

asBaseType :: Some CT.TypeRepr -> Some WT.BaseTypeRepr
asBaseType (Some t) = case CT.asBaseType t of
  CT.AsBaseType bt -> Some bt
  CT.NotBaseType -> error $ "Expected base type: " <> show t



unifyArgs :: InputArgument s e
          => Overrides arch
          -> T.Text
          -> [(FunctionArg, e)]
          -> [AS.Type]
          -> TypeConstraint
          -> Generator h s arch ret
               (T.Text, [Some (CCG.Atom s)], Some WT.BaseTypeRepr)
unifyArgs ov fnname fargs rets constraint = do
  let args = map (\((FunctionArg nm t _), e)  -> ((nm, t), e)) fargs
  outerState <- MS.get
  freshState <- freshLocalsState
  (atoms, retT, tenv) <- withState freshState $ do
      mapM_ (\(decl, e) -> collectStaticValues outerState decl e) args
      atoms <- mapM (\(decl, e) -> unifyArg ov outerState decl e) args
      unifyRet rets constraint
      retsT <- mapM translateType rets
      let retT = mkBaseStructRepr (map asBaseType retsT)
      tenv <- getStaticEnv
      return (atoms, retT, tenv)
  let dvars = concat $ map dependentVarsOfType rets ++ map (\((_,t), _) -> dependentVarsOfType t) args
  listenv <- mapM (getConcreteValue tenv) dvars
  let env = Map.fromList listenv
  hdl <- MS.gets tsHandle
  MST.liftST (STRef.modifySTRef hdl (Set.insert (fnname,env)))
  return (mkFinalFunctionName env fnname, atoms, retT)
  where
    unifyRet :: [AS.Type] -- return type of function
             -> TypeConstraint -- potential concrete target type
             -> Generator h s arch ret ()
    unifyRet [t] constraint' = unifyType t constraint'
    unifyRet ts constraints' = unifyTypes ts constraints'

    getConcreteValue env nm = case staticEnvValue env nm of
      Just i -> return (nm, i)
      _ -> throwTrace $ CannotMonomorphizeFunctionCall fnname (staticEnvMapVals env)


-- | Collect any new variables declared
getNewVars :: Generator h s arch ret a
           -> Generator h s arch ret ([Some (CCG.Reg s)], a)
getNewVars f = do
  vars <- MS.gets tsVarRefs
  r <- f
  vars' <- MS.gets tsVarRefs
  let diff = Map.difference vars' vars
  return (Map.elems diff, r)

-- | Initialize registers to their default values
initVars :: [Some (CCG.Reg s)]
         -> Generator h s arch ret ()
initVars regs = do
    mapM_ initVar regs
  where
    initVar (Some reg) = do
      defaultVal <- getDefaultValue (CCG.typeOfReg reg)
      Generator $ CCG.assignReg reg (CCG.AtomExpr defaultVal)

-- | Statement-level if-then-else. Newly assigned variables from
-- either branch are implicitly assigned to default
-- values before branching avoid dangling registers.
ifte_ :: CCG.Expr (ASLExt arch) s CT.BoolType
      -> Generator h s arch ret () -- ^ true branch
      -> Generator h s arch ret () -- ^ false branch
      -> Generator h s arch ret ()
ifte_ e (Generator x) (Generator y) = do
  c_id <- liftGenerator $ CCG.newLabel
  (newvarsThen, x_id) <- getNewVars (liftGenerator $ (CCG.defineBlockLabel $ x >> CCG.jump c_id))
  (newvarsElse, y_id) <- getNewVars (liftGenerator $ (CCG.defineBlockLabel $ y >> CCG.jump c_id))
  initVars $ newvarsThen ++ newvarsElse
  liftGenerator $ CCG.continue c_id (CCG.branch e x_id y_id)

translateIf :: Overrides arch
            -> [(AS.Expr, [AS.Stmt])]
            -> Maybe [AS.Stmt]
            -> Generator h s arch ret ()
translateIf ov clauses melse =
  case clauses of
    [] -> indentLog $ mapM_ (translateStatement ov) (fromMaybe [] melse)
    (cond, body) : rest ->
      withStaticTest cond
        (mapM_ (translateStatement ov) body)
        (translateIf ov rest melse) $ do
      Some condAtom <- translateExpr ov cond
      Refl <- assertAtomType cond CT.BoolRepr condAtom
      let genThen = indentLog $ mapM_ (translateStatement ov) body
      let genElse = translateIf ov rest melse
      ifte_ (CCG.AtomExpr condAtom) genThen genElse

translateCase :: Overrides arch
              -> AS.Expr
              -> [AS.CaseAlternative]
              -> Generator h s arch ret ()
translateCase ov expr alts = case alts of
  [AS.CaseOtherwise els] -> mapM_ (translateStatement ov) els
  -- FIXME: We assume that the case below is equivalent to "otherwise"
  [AS.CaseWhen _ Nothing body] -> mapM_ (translateStatement ov) body
  -- FIXME: If we detect an "unreachable", translate it as if the preceding "when"
  -- were "otherwise"
  [AS.CaseWhen _ Nothing body, AS.CaseOtherwise [AS.StmtCall (AS.QualifiedIdentifier _ "Unreachable") []]] ->
    mapM_ (translateStatement ov) body
  (AS.CaseWhen pats Nothing body : rst) -> do
    let matchExpr = caseWhenExpr expr pats
    Some matchAtom <- translateExpr ov matchExpr
    Refl <- assertAtomType matchExpr CT.BoolRepr matchAtom
    let genThen = indentLog $ mapM_ (translateStatement ov) body
    let genRest = translateCase ov expr rst
    ifte_ (CCG.AtomExpr matchAtom) genThen genRest
  _ -> error (show alts)
  where
    caseWhenExpr :: AS.Expr -> [AS.CasePattern] -> AS.Expr
    caseWhenExpr _ [] = error "caseWhenExpr"
    caseWhenExpr expr' [pat] = matchPat expr' pat
    caseWhenExpr expr' (pat:pats) = AS.ExprBinOp AS.BinOpLogicalOr (matchPat expr' pat) (caseWhenExpr expr' pats)

matchPat :: AS.Expr -> AS.CasePattern -> AS.Expr
matchPat expr (AS.CasePatternInt i) = AS.ExprBinOp AS.BinOpEQ expr (AS.ExprLitInt i)
matchPat expr (AS.CasePatternBin bv) = AS.ExprBinOp AS.BinOpEQ expr (AS.ExprLitBin bv)
matchPat expr (AS.CasePatternIdentifier ident) = AS.ExprBinOp AS.BinOpEQ expr (AS.ExprVarRef (AS.QualifiedIdentifier AS.ArchQualAny ident))
matchPat expr (AS.CasePatternMask mask) = AS.ExprBinOp AS.BinOpEQ expr (AS.ExprLitMask mask)
matchPat _ AS.CasePatternIgnore = X.throw $ UNIMPLEMENTED "ignore pattern unimplemented"
matchPat _ (AS.CasePatternTuple _) = X.throw $ UNIMPLEMENTED "tuple pattern unimplemented"

assertAtomType :: AS.Expr
               -- ^ Expression that was translated
               -> CT.TypeRepr tp1
               -- ^ Expected type
               -> CCG.Atom s tp2
               -- ^ Translation (which contains the actual type)
               -> Generator h s arch ret (tp1 :~: tp2)
assertAtomType expr expectedRepr atom =
  case testEquality expectedRepr (CCG.typeOfAtom atom) of
    Nothing -> throwTrace (UnexpectedExprType (Just expr) (CCG.typeOfAtom atom) expectedRepr)
    Just Refl -> return Refl

assertAtomType' :: CT.TypeRepr tp1
                -- ^ Expected type
                -> CCG.Atom s tp2
                -- ^ Translation (which contains the actual type)
                -> Generator h s arch ret (tp1 :~: tp2)
assertAtomType' expectedRepr atom =
  case testEquality expectedRepr (CCG.typeOfAtom atom) of
    Nothing -> throwTrace (UnexpectedExprType Nothing (CCG.typeOfAtom atom) expectedRepr)
    Just Refl -> return Refl

data BVRepr tp where
  BVRepr :: (tp ~ CT.BVType w, 1 WT.<= w) => WT.NatRepr w -> BVRepr tp

getAtomBVRepr :: CCG.Atom s tp
              -> Generator h s arch ret (BVRepr tp)
getAtomBVRepr atom =
  case CCG.typeOfAtom atom of
    CT.BVRepr wRepr -> return $ BVRepr wRepr
    tp -> throwTrace $ ExpectedBVType' Nothing tp

translateExpr' :: Overrides arch
              -> AS.Expr
              -> TypeConstraint
              -> Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData)
translateExpr' ov expr constraint = do
  logMsg 2 $ T.pack (show expr) <> " :: " <> T.pack (show constraint)
  translateExpr'' ov expr constraint

getStaticValue :: AS.Expr
               -> Generator h s arch ret (Maybe (StaticValue))
getStaticValue expr = do
  env <- getStaticEnv
  return $ SE.exprToStatic env expr


-- This is not necessarily complete
constraintsOfArgs :: AS.BinOp -> TypeConstraint -> (TypeConstraint, TypeConstraint)
constraintsOfArgs bop tc = case bop of
  AS.BinOpAdd -> (tc, tc)
  AS.BinOpSub -> (tc, tc)
  _ -> (ConstraintNone, ConstraintNone)

intToBVRepr :: Integer -> Some (BVRepr)
intToBVRepr nBits = do
  case NR.mkNatRepr (fromIntegral nBits) of
   Some nr
     | Just NR.LeqProof <- NR.testLeq (NR.knownNat @1) nr ->
       Some $ BVRepr nr
     | otherwise -> X.throw InvalidZeroLengthBitvector

bitsToBVExpr :: [Bool] -> Some (CCG.Expr (ASLExt arch) s)
bitsToBVExpr bits = do
  case intToBVRepr (fromIntegral $ length bits) of
   Some (BVRepr nr) -> Some $ CCG.App $ CCE.BVLit nr (bitsToInteger bits)

-- | Translate an ASL expression into an Atom (which is a reference to an immutable value)
--
-- Atoms may be written to registers, which are mutable locals
translateExpr'' :: Overrides arch
              -> AS.Expr
              -> TypeConstraint
              -> Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData)
translateExpr'' ov expr ty = do
  env <- getStaticEnv
  let eo = overrideExpr ov expr ty env
  case eo of
    Just f -> f
    _ -> do
      mStatic <- getStaticValue expr
      case mStatic of
        Just (StaticInt i) -> mkAtom' (CCG.App (CCE.IntLit i))
        Just (StaticBool b) -> mkAtom' (CCG.App (CCE.BoolLit b))
        _ -> case expr of
          AS.ExprLitInt i -> mkAtom' (CCG.App (CCE.IntLit i))
          AS.ExprLitBin bits
            | Some bvexpr <- bitsToBVExpr bits ->
              mkAtom' bvexpr

          AS.ExprVarRef (AS.QualifiedIdentifier _ ident) -> do
            Some e <- lookupVarRef ident
            atom <- mkAtom e
            ext <- getExtendedTypeData ident
            return (Some atom, ext)

          AS.ExprLitReal {} -> throwTrace $ UnsupportedExpr expr
          AS.ExprLitString {} -> throwTrace $ UnsupportedExpr expr
          AS.ExprUnOp op expr' -> basicExpr $ translateUnaryOp ov op expr'
          AS.ExprBinOp op e1 e2 -> basicExpr $ translateBinaryOp ov op e1 e2 ty
          AS.ExprTuple exprs -> do
            atomExts <- case ty of
              ConstraintSingle (CT.SymbolicStructRepr tps) -> do
                let exprTs = zip (FC.toListFC Some tps) exprs
                mapM (\(Some ty', e) -> translateExpr' ov e (ConstraintSingle (CT.baseToType ty'))) exprTs
              ConstraintTuple cts -> do
                mapM (\(ct, e) -> translateExpr' ov e ct) (zip cts exprs)
              _ -> do
               mapM (\e -> translateExpr' ov e ConstraintNone) exprs
            let (atoms, exts) = unzip atomExts
            case Ctx.fromList atoms of
              Some asgn -> do
                let reprs = FC.fmapFC CCG.typeOfAtom asgn
                let atomExprs = FC.fmapFC CCG.AtomExpr asgn
                let struct = MkBaseStruct reprs atomExprs
                atom <- mkAtom (CCG.App (CCE.ExtensionApp struct))
                return (Some atom, TypeTuple exts)

          AS.ExprInSet e elts -> do
            Some atom <- translateExpr ov e
            when (null elts) $ X.throw (EmptySetElementList expr)
            preds <- mapM (translateSetElementTest ov expr atom) elts
            mkAtom' (foldr disjoin (CCG.App (CCE.BoolLit False)) preds)
          AS.ExprIf clauses elseExpr -> translateIfExpr ov expr clauses elseExpr ty

          AS.ExprCall qIdent args -> do
            ret <- translateFunctionCall ov qIdent args ty
            case ret of
              Just x -> return x
              Nothing -> throwTrace $ UnexpectedReturnInExprCall
          -- FIXME: Should this trip a global flag?
          AS.ExprImpDef _ t -> do
            Some ty' <- translateType t
            defaultv <- getDefaultValue ty'
            return (Some defaultv, TypeBasic)

          AS.ExprMember struct memberName -> do
            (Some structAtom, ext) <- translateExpr' ov struct ConstraintNone
            case ext of
              TypeRegister sig -> do
                case Map.lookup memberName sig of
                  Just slice -> do
                    satom <- translateSlice ov struct (mkSliceRange slice) ConstraintNone
                    return (satom, TypeBasic)
                  _ -> X.throw $ MissingRegisterField struct memberName
              TypeStruct acc -> do
                case (CCG.typeOfAtom structAtom, Map.lookup memberName acc) of
                  (CT.SymbolicStructRepr tps, Just (StructAccessor repr idx fieldExt)) |
                    Just Refl <- testEquality tps repr -> do
                      let getStruct = GetBaseStruct (CT.SymbolicStructRepr tps) idx (CCG.AtomExpr structAtom)
                      atom <- mkAtom (CCG.App (CCE.ExtensionApp getStruct))
                      return (Some atom, fieldExt)
                  _ -> throwTrace $ MissingStructField struct memberName
              TypeGlobalStruct acc ->
                case Map.lookup memberName acc of
                  Just globalName -> do
                    translateExpr' ov (AS.ExprVarRef (AS.QualifiedIdentifier AS.ArchQualAny globalName)) ty
                  _ -> throwTrace $ MissingGlobalStructField struct memberName
              _ -> X.throw $ UnexpectedExtendedType struct ext

          AS.ExprMemberBits var bits -> do
            let (hdvar : tlvars) = map (\member -> AS.ExprMember var member) bits
            let expr' = foldl (\var' -> \e -> AS.ExprBinOp AS.BinOpConcat var' e) hdvar tlvars
            translateExpr' ov expr' ty

          AS.ExprSlice e [slice] -> do
            satom <- translateSlice ov e slice ty
            return (satom, TypeBasic)

          AS.ExprSlice e (slice : slices) -> do
            let expr' = AS.ExprBinOp AS.BinOpConcat (AS.ExprSlice e [slice]) (AS.ExprSlice e slices)
            translateExpr' ov expr' ty

          AS.ExprIndex array [AS.SliceSingle slice]  -> do
            (Some atom, ext) <- translateExpr' ov array ConstraintNone
            Some idxAtom <- translateExpr ov slice
            if | CT.AsBaseType bt <- CT.asBaseType (CCG.typeOfAtom idxAtom)
               , CT.SymbolicArrayRepr (Ctx.Empty Ctx.:> bt') retTy <- CCG.typeOfAtom atom
               , Just Refl <- testEquality bt bt' -> do
                   let asn = Ctx.singleton (CCE.BaseTerm bt (CCG.AtomExpr idxAtom))
                   let arr = CCE.SymArrayLookup retTy (CCG.AtomExpr atom) asn
                   ext' <- case ext of
                     TypeArray ext' -> return ext'
                     _ -> return TypeBasic
                   atom' <- mkAtom (CCG.App arr)
                   return (Some atom', ext')
               | otherwise -> throwTrace $ UnsupportedExpr expr
          AS.ExprUnknown t -> do
            Some ty' <- translateType t
            defaultv <- getDefaultValue ty'
            return (Some defaultv, TypeBasic)

          _ -> throwTrace $ UnsupportedExpr expr
  where
    basicExpr f = do
      satom <- f
      return (satom, TypeBasic)

translateExpr :: Overrides arch
              -> AS.Expr
              -> Generator h s arch ret (Some (CCG.Atom s))
translateExpr ov expr = do
  (atom, _) <- translateExpr' ov expr ConstraintNone
  return atom

normalizeSlice :: AS.Slice -> (AS.Expr, AS.Expr)
normalizeSlice slice = case slice of
  AS.SliceRange e e' -> (e', e)
  AS.SliceSingle e -> (e, e)
  AS.SliceOffset e e' ->
    let hi = AS.ExprBinOp AS.BinOpAdd e (AS.ExprBinOp AS.BinOpSub e' (AS.ExprLitInt 1))
        in (e, hi)

data SliceRange s where
  SliceRange :: (1 WT.<= atomLength, 1 WT.<= sliceLength, sliceLength WT.<= atomLength)
                => Bool -- requires signed extension
                -> WT.NatRepr sliceLength
                -> WT.NatRepr atomLength
                -> CCG.Atom s CT.IntegerType
                -> CCG.Atom s CT.IntegerType
                -> CCG.Atom s (CT.BVType atomLength)
                -> SliceRange s

exprRangeToLength :: StaticEnvMap -> AS.Expr -> AS.Expr -> Maybe Integer
exprRangeToLength env lo hi = case (lo, hi) of
  (AS.ExprVarRef loVar, AS.ExprBinOp AS.BinOpAdd e (AS.ExprVarRef hiVar)) -> getStaticLength loVar hiVar e
  (AS.ExprVarRef loVar, AS.ExprBinOp AS.BinOpAdd (AS.ExprVarRef hiVar) e) -> getStaticLength loVar hiVar e
  (AS.ExprBinOp AS.BinOpSub (AS.ExprVarRef loVar) e, AS.ExprVarRef hiVar) -> getStaticLength loVar hiVar e
  (e, e') | e == e' -> Just 1
  _ | Just (StaticInt loInt) <- SE.exprToStatic env lo
    , Just (StaticInt hiInt) <- SE.exprToStatic env hi ->
      Just $ (hiInt - loInt) + 1
  _ -> Nothing

  where getStaticLength loVar hiVar e =
          if | loVar == hiVar
             , Just (StaticInt i) <- SE.exprToStatic env e
             , i > 0 ->
               Just $ i + 1
             | otherwise -> Nothing

getStaticSliceLength :: AS.Slice
                     -> Generator h s arch ret (Maybe (Some BVRepr))
getStaticSliceLength slice = do
  let (e', e) = normalizeSlice slice
  env <- getStaticEnv
  if | Just len <- exprRangeToLength env e' e
     , Just (Some lenRepr) <- WT.someNat len
     , Just WT.LeqProof <- (WT.knownNat @1) `WT.testLeq` lenRepr ->
        return $ Just $ Some $ BVRepr lenRepr
     | otherwise -> return Nothing

getSymbolicSliceRange :: Overrides arch
                      -> AS.Slice
                      -> Generator h s arch ret (CCG.Atom s CT.IntegerType, CCG.Atom s CT.IntegerType)
getSymbolicSliceRange ov slice = do
  let (e', e) = normalizeSlice slice
  Some loAtom <- translateExpr ov e'
  Some hiAtom <- translateExpr ov e
  Refl <- assertAtomType e' CT.IntegerRepr loAtom
  Refl <- assertAtomType e CT.IntegerRepr hiAtom
  return (loAtom, hiAtom)

getSliceRange :: Overrides arch
              -> AS.Slice
              -> CCG.Atom s tp
              -> TypeConstraint
              -> Generator h s arch ret (SliceRange s)
getSliceRange ov slice slicedAtom constraint = do
  (loAtom, hiAtom) <- getSymbolicSliceRange ov slice
  mLength <- getStaticSliceLength slice
  (Some lenRepr :: Some WT.NatRepr, signed :: Bool) <- case mLength of
    Just (Some (BVRepr len)) -> return $ (Some len, False)
    _ -> case constraint of
      ConstraintSingle (CT.BVRepr len) -> return $ (Some len, False)
      ConstraintHint (HintMaxBVSize maxlength) ->
        case CCG.typeOfAtom slicedAtom of
          CT.BVRepr wRepr -> case wRepr `WT.testNatCases` maxlength of
            WT.NatCaseEQ -> return $ (Some wRepr, False)
            WT.NatCaseLT _ -> return $ (Some wRepr, False)
            WT.NatCaseGT WT.LeqProof -> return $ (Some maxlength, False)
          CT.IntegerRepr -> return $ (Some maxlength, False)
          _ -> throwTrace $ UnsupportedSlice slice constraint
      ConstraintHint (HintMaxSignedBVSize maxlength) ->
        case CCG.typeOfAtom slicedAtom of
          CT.BVRepr wRepr -> case wRepr `WT.testNatCases` maxlength of
            WT.NatCaseEQ -> return $ (Some wRepr, False)
            WT.NatCaseLT _ -> return $ (Some wRepr, False)
            WT.NatCaseGT WT.LeqProof -> return $ (Some maxlength, True)
          CT.IntegerRepr -> return $ (Some maxlength, True)
          _ -> throwTrace $ UnsupportedSlice slice constraint
      ConstraintHint HintAnyBVSize ->
        case CCG.typeOfAtom slicedAtom of
          CT.BVRepr wRepr -> return $ (Some wRepr, False)
          _ -> throwTrace $ UnsupportedSlice slice constraint
      _ -> throwTrace $ UnsupportedSlice slice constraint
  WT.LeqProof <- case (WT.knownNat @1) `WT.testLeq` lenRepr of
    Just x -> return x
    _ -> throwTrace $ UnsupportedSlice slice constraint
  case CCG.typeOfAtom slicedAtom of
    CT.BVRepr wRepr
      | Just WT.LeqProof <- lenRepr `WT.testLeq` wRepr ->
        return $ SliceRange signed lenRepr wRepr loAtom hiAtom slicedAtom
    CT.IntegerRepr -> do
      env <- getStaticEnv
      let (_, hi) = normalizeSlice slice
      case SE.exprToStatic env hi of
        Just (StaticInt hi') | Some (BVRepr hiRepr) <- intToBVRepr (hi'+1) ->
            if | Just WT.LeqProof <- lenRepr `WT.testLeq` hiRepr -> do
                 intAtom <- mkAtom $ CCG.App (CCE.IntegerToBV hiRepr (CCG.AtomExpr slicedAtom))
                 return $ SliceRange signed lenRepr hiRepr loAtom hiAtom intAtom
               | otherwise -> throwTrace $ InvalidSymbolicSlice lenRepr hiRepr
        _ -> throwTrace $ RequiredConcreteValue hi (staticEnvMapVals env)
    _ -> throwTrace $ UnsupportedSlice slice constraint

translateSlice :: Overrides arch
               -> AS.Expr
               -> AS.Slice
               -> TypeConstraint
               -> Generator h s arch ret (Some (CCG.Atom s))
translateSlice ov e slice constraint = do
   Some atom <- translateExpr ov e
   translateSlice' ov atom slice constraint


translateSlice' :: Overrides arch
                -> CCG.Atom s tp
                -> AS.Slice
                -> TypeConstraint
                -> Generator h s arch ret (Some (CCG.Atom s))
translateSlice' ov atom' slice constraint = do
  SliceRange signed lenRepr wRepr loAtom hiAtom atom <- getSliceRange ov slice atom' constraint
  case lenRepr `WT.testNatCases` wRepr of
    WT.NatCaseEQ ->
      -- when the slice covers the whole range we just return the whole atom
      return $ Some $ atom
    WT.NatCaseLT WT.LeqProof -> do
      signedAtom <- mkAtom $ CCG.App $ CCE.BoolLit signed
      Just (sresult, _) <- translateFunctionCall overrides (AS.VarName "getSlice")
        [Some atom, Some signedAtom, Some loAtom, Some hiAtom] (ConstraintSingle (CT.BVRepr lenRepr))
      return sresult
    _ -> throwTrace $ UnsupportedSlice slice constraint

withStaticTest :: AS.Expr
               -> Generator h s arch ret a
               -> Generator h s arch ret a
               -> Generator h s arch ret a
               -> Generator h s arch ret a
withStaticTest test ifTrue ifFalse ifUnknown = do
  env <- getStaticEnv
  case SE.exprToStatic env test of
    Just (StaticBool True) -> ifTrue
    Just (StaticBool False) -> ifFalse
    _ -> ifUnknown

-- FIXME: This implies some kind of ordering on constraints
mergeConstraints :: TypeConstraint -> TypeConstraint -> TypeConstraint
mergeConstraints ty1 ty2 = case (ty1, ty2) of
  (ConstraintNone, _) -> ty2
  (_, ConstraintNone) -> ty1
  (ConstraintSingle _, _) -> ty1
  (_, ConstraintSingle _) -> ty2
  (ConstraintHint HintAnyBVSize, ConstraintHint (HintMaxBVSize _)) -> ty2
  (ConstraintHint (HintMaxBVSize _), ConstraintHint HintAnyBVSize) -> ty1
  (ConstraintHint HintAnyBVSize, ConstraintHint (HintMaxSignedBVSize _)) -> ty2
  (ConstraintHint (HintMaxSignedBVSize _), ConstraintHint HintAnyBVSize) -> ty1
  _ -> error $ "Incompatible type constraints: " ++ show ty1 ++ " " ++ show ty2

-- | Translate the expression form of a conditional into a Crucible atom
translateIfExpr :: Overrides arch
                -> AS.Expr
                -> [(AS.Expr, AS.Expr)]
                -> AS.Expr
                -> TypeConstraint
                -> Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData)
translateIfExpr ov orig clauses elseExpr ty =
  case clauses of
    [] -> X.throw (MalformedConditionalExpression orig)
    [(test, res)] ->
      withStaticTest test
        (translateExpr' ov res ty)
        (translateExpr' ov elseExpr ty) $ do
      Some testA <- translateExpr ov test
      (Some resA, extRes) <- translateExpr' ov res ty
      (Some elseA, extElse) <- translateExpr' ov elseExpr (mergeConstraints ty (someTypeOfAtom resA))
      ext <- mergeExtensions extRes extElse
      Refl <- assertAtomType test CT.BoolRepr testA
      Refl <- assertAtomType res (CCG.typeOfAtom elseA) resA
      case CT.asBaseType (CCG.typeOfAtom elseA) of
        CT.NotBaseType -> X.throw (ExpectedBaseType orig (CCG.typeOfAtom elseA))
        CT.AsBaseType btr -> do
          atom <- mkAtom (CCG.App (CCE.BaseIte btr (CCG.AtomExpr testA) (CCG.AtomExpr resA) (CCG.AtomExpr elseA)))
          return (Some atom, ext)
    (test, res) : rest ->
      withStaticTest test
        (translateExpr' ov res ty)
        (translateIfExpr ov orig rest elseExpr ty) $ do
      (Some trA, extRest) <- translateIfExpr ov orig rest elseExpr ty
      Some testA <- translateExpr ov test
      (Some resA, extRes) <- translateExpr' ov res (mergeConstraints ty (someTypeOfAtom trA))
      ext <- mergeExtensions extRes extRest
      Refl <- assertAtomType test CT.BoolRepr testA
      Refl <- assertAtomType res (CCG.typeOfAtom trA) resA
      case CT.asBaseType (CCG.typeOfAtom trA) of
        CT.NotBaseType -> X.throw (ExpectedBaseType orig (CCG.typeOfAtom trA))
        CT.AsBaseType btr -> do
          atom <- mkAtom (CCG.App (CCE.BaseIte btr (CCG.AtomExpr testA) (CCG.AtomExpr resA) (CCG.AtomExpr trA)))
          return (Some atom, ext)

maskToBV :: AS.Mask -> AS.BitVector
maskToBV mask = map maskBitToBit mask
  where
    maskBitToBit mb = case mb of
      AS.MaskBitSet -> True
      AS.MaskBitUnset -> False
      AS.MaskBitEither -> False

-- | Translate set element tests
--
-- Single element tests are translated into a simple equality test
--
-- Ranges are translated as a conjunction of inclusive tests. x IN [5..10] => 5 <= x && x <= 10
translateSetElementTest :: Overrides arch
                        -> AS.Expr
                        -> CCG.Atom s tp
                        -> AS.SetElement
                        -> Generator h s arch ret (CCG.Expr (ASLExt arch) s CT.BoolType)
translateSetElementTest ov e0 a0 elt =
  case elt of
    AS.SetEltSingle expr@(AS.ExprLitMask mask) -> do
      let maskExpr = AS.ExprLitBin (maskToBV mask)
      Some maskAtom <- translateExpr ov maskExpr
      Refl <- assertAtomType expr (CCG.typeOfAtom a0) maskAtom
      Some maskedBV <- bvBinOp CCE.BVOr (e0, a0) (maskExpr, maskAtom)
      Some testAtom <- applyBinOp eqOp (e0, a0) (AS.ExprBinOp AS.BinOpBitwiseOr e0 expr, maskedBV)
      Refl <- assertAtomType expr CT.BoolRepr testAtom
      return (CCG.AtomExpr testAtom)

    AS.SetEltSingle expr -> do
      Some atom1 <- translateExpr ov expr
      Refl <- assertAtomType expr (CCG.typeOfAtom a0) atom1
      Some atom2 <- applyBinOp eqOp (e0, a0) (expr, atom1)
      Refl <- assertAtomType expr CT.BoolRepr atom2
      return (CCG.AtomExpr atom2)
    AS.SetEltRange lo hi -> do
      Some loA <- translateExpr ov lo
      Some hiA <- translateExpr ov hi
      Refl <- assertAtomType lo (CCG.typeOfAtom a0) loA
      Refl <- assertAtomType hi (CCG.typeOfAtom a0) hiA
      Some loTest <- applyBinOp leOp (lo, loA) (e0, a0)
      Some hiTest <- applyBinOp leOp (e0, a0) (hi, hiA)
      Refl <- assertAtomType lo CT.BoolRepr loTest
      Refl <- assertAtomType hi CT.BoolRepr hiTest
      return (CCG.App (CCE.And (CCG.AtomExpr loTest) (CCG.AtomExpr hiTest)))



disjoin :: (CCE.IsSyntaxExtension ext)
        => CCG.Expr ext s CT.BoolType
        -> CCG.Expr ext s CT.BoolType
        -> CCG.Expr ext s CT.BoolType
disjoin p1 p2 = CCG.App (CCE.Or p1 p2)

translateBinaryOp :: forall h s ret arch
                   . Overrides arch
                  -> AS.BinOp
                  -> AS.Expr
                  -> AS.Expr
                  -> TypeConstraint
                  -> Generator h s arch ret (Some (CCG.Atom s))
translateBinaryOp ov op e1 e2 tc = do
  let (tc1, tc2) = constraintsOfArgs op tc
  (Some a1, _) <- translateExpr' ov e1 tc1
  (Some a2, _) <- translateExpr' ov e2 tc2
  let p1 = (e1, a1)
  let p2 = (e2, a2)
  env <- getStaticEnv
  case op of
    AS.BinOpPlusPlus -> X.throw (UnsupportedBinaryOperator op)
    AS.BinOpLogicalAnd -> logicalBinOp CCE.And p1 p2
    AS.BinOpLogicalOr -> logicalBinOp CCE.Or p1 p2
    AS.BinOpBitwiseOr -> bvBinOp CCE.BVOr p1 p2
    AS.BinOpBitwiseAnd -> bvBinOp CCE.BVAnd p1 p2
    AS.BinOpBitwiseXor -> bvBinOp CCE.BVXor p1 p2
    AS.BinOpEQ -> applyBinOp eqOp p1 p2
    AS.BinOpNEQ -> do
      Some atom <- applyBinOp eqOp p1 p2
      Refl <- assertAtomType (AS.ExprBinOp op e1 e2) CT.BoolRepr atom
      Some <$> mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
    AS.BinOpGT -> do
      -- NOTE: We always use unsigned comparison for bitvectors - is that correct?
      Some atom <- applyBinOp leOp p1 p2
      Refl <- assertAtomType (AS.ExprBinOp op e1 e2) CT.BoolRepr atom
      Some <$> mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
    AS.BinOpLTEQ -> applyBinOp leOp p1 p2
    AS.BinOpLT -> applyBinOp ltOp p1 p2
    AS.BinOpGTEQ -> do
      Some atom <- applyBinOp ltOp p1 p2
      Refl <- assertAtomType (AS.ExprBinOp op e1 e2) CT.BoolRepr atom
      Some <$> mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
    AS.BinOpAdd -> applyBinOp addOp p1 p2
    AS.BinOpSub -> applyBinOp subOp p1 p2
    AS.BinOpMul -> applyBinOp mulOp p1 p2
    AS.BinOpMod -> applyBinOp modOp p1 p2
    --FIXME: REM is only used once in mapvpmw, is it just mod there?
    AS.BinOpRem -> applyBinOp modOp p1 p2
    AS.BinOpDiv -> applyBinOp divOp p1 p2
    AS.BinOpShiftLeft -> bvBinOp CCE.BVShl p1 p2
    AS.BinOpShiftRight -> bvBinOp CCE.BVLshr p1 p2
    -- FIXME: What is the difference between BinOpDiv and BinOpDivide?
    AS.BinOpConcat -> do
      BVRepr n1 <- getAtomBVRepr a1
      BVRepr n2 <- getAtomBVRepr a2
      Just n1PosProof <- return $ WT.isPosNat n1
      WT.LeqProof <- return $ WT.leqAdd n1PosProof n2
      Some <$> mkAtom (CCG.App (CCE.BVConcat n1 n2 (CCG.AtomExpr a1) (CCG.AtomExpr a2)))
    AS.BinOpPow
      | Just (StaticInt 2) <- SE.exprToStatic env e1 -> do
        Refl <- assertAtomType e2 CT.IntegerRepr a2
        let nr = WT.knownNat @128
        let shift = CCG.App $ CCE.IntegerToBV nr (CCG.AtomExpr a2)
        let base = CCG.App $ CCE.BVLit nr 1
        let shifted = CCG.App $ (CCE.BVShl nr base shift)
        Some <$> mkAtom (CCG.App (CCE.BvToInteger nr shifted))

    _ -> X.throw (UnsupportedBinaryOperator op)

-- Linear Arithmetic operators

addOp :: BinaryOperatorBundle h s arch ret 'SameK
addOp = BinaryOperatorBundle (mkBVBinOP CCE.BVAdd) (mkBinOP CCE.NatAdd) (mkBinOP CCE.IntAdd)

subOp :: BinaryOperatorBundle h s arch ret 'SameK
subOp = BinaryOperatorBundle (mkBVBinOP CCE.BVSub) (mkBinOP CCE.NatSub) (mkBinOP CCE.IntSub)

-- Nonlinear Arithmetic operators

-- For now we hide these behind uninterpreted functions until we have a better story
-- for when we actually need their theories

-- mulOp :: BinaryOperatorBundle ext s 'SameK
-- mulOp = BinaryOperatorBundle CCE.BVMul CCE.NatMul CCE.IntMul

-- modOp :: BinaryOperatorBundle ext s 'SameK
-- modOp = BinaryOperatorBundle (error "BV mod not supported") CCE.NatMod CCE.IntMod

-- divOp :: BinaryOperatorBundle ext s 'SameK
-- divOp = BinaryOperatorBundle (error "BV div not supported") CCE.NatDiv CCE.IntDiv

mkUF :: T.Text
     -> CCG.Expr (ASLExt arch) s tp
     -> CCG.Expr (ASLExt arch) s tp
     -> Generator h s arch ret (CCG.Atom s tp)
mkUF nm arg1E arg2E = do
  arg1 <- mkAtom arg1E
  arg2 <- mkAtom arg2E
  Just (Some atom, _) <- translateFunctionCall overrides (AS.VarName nm) [Some arg1, Some arg2] ConstraintNone
  Refl <- assertAtomType' (CCG.typeOfAtom arg1) atom
  return atom

mulOp :: BinaryOperatorBundle h s arch ret 'SameK
mulOp = BinaryOperatorBundle (\_ -> mkUF "BVMul") (mkUF "NatMul") (mkUF "IntMul")

modOp :: BinaryOperatorBundle h s arch ret 'SameK
modOp = BinaryOperatorBundle (error "BV mod not supported") (mkUF "NatMod") (mkUF "IntMod")

divOp :: BinaryOperatorBundle h s arch ret 'SameK
divOp = BinaryOperatorBundle (error "BV div not supported") (mkUF "NatDiv") (mkUF "IntDiv")


realmulOp :: BinaryOperatorBundle h s arch ret 'SameK
realmulOp = BinaryOperatorBundle (mkBVBinOP CCE.BVMul) (mkBinOP CCE.NatMul) (mkBinOP CCE.IntMul)

realmodOp :: BinaryOperatorBundle h s arch ret 'SameK
realmodOp = BinaryOperatorBundle (error "BV mod not supported") (mkBinOP CCE.NatMod) (mkBinOP CCE.IntMod)

realdivOp :: BinaryOperatorBundle h s arch ret 'SameK
realdivOp = BinaryOperatorBundle (error "BV div not supported") (mkBinOP CCE.NatDiv) (mkBinOP CCE.IntDiv)

-- Comparison operators

eqOp :: BinaryOperatorBundle h s arch ret 'BoolK
eqOp = BinaryOperatorBundle (mkBVBinOP CCE.BVEq) (mkBinOP CCE.NatEq) (mkBinOP CCE.IntEq)

leOp :: BinaryOperatorBundle h s arch ret 'BoolK
leOp = BinaryOperatorBundle (mkBVBinOP CCE.BVUle) (mkBinOP CCE.NatLe) (mkBinOP CCE.IntLe)

ltOp :: BinaryOperatorBundle h s arch ret 'BoolK
ltOp = BinaryOperatorBundle (mkBVBinOP CCE.BVUlt) (mkBinOP CCE.NatLt) (mkBinOP CCE.IntLt)


mkBVBinOP :: (a -> b -> c -> CCE.App (ASLExt arch) (CCR.Expr (ASLExt arch) s) tp) -> (a -> b -> c -> Generator h s arch ret (CCG.Atom s tp))
mkBVBinOP f a b c = do
  mkAtom (CCG.App (f a b c))

mkBinOP :: (a -> b -> CCE.App (ASLExt arch) (CCR.Expr (ASLExt arch) s) tp) -> (a -> b -> Generator h s arch ret (CCG.Atom s tp))
mkBinOP f a b = do
  mkAtom (CCG.App (f a b))

data ReturnK = BoolK
             -- ^ Tag used for comparison operations, which always return BoolType
             | SameK
             -- ^ Tag used for other operations, which preserve the type

type family BinaryOperatorReturn (r :: ReturnK) (tp :: CT.CrucibleType) where
  BinaryOperatorReturn 'BoolK tp = CT.BoolType
  BinaryOperatorReturn 'SameK tp = tp

data BinaryOperatorBundle h s arch ret (rtp :: ReturnK) =
  BinaryOperatorBundle { obBV :: forall n . (1 WT.<= n) => WT.NatRepr n -> CCG.Expr (ASLExt arch) s (CT.BVType n) -> CCG.Expr (ASLExt arch) s (CT.BVType n) -> Generator h s arch ret (CCG.Atom s (BinaryOperatorReturn rtp (CT.BVType n)))
                       , obNat :: CCG.Expr (ASLExt arch) s CT.NatType -> CCG.Expr (ASLExt arch) s CT.NatType -> Generator h s arch ret (CCG.Atom s (BinaryOperatorReturn rtp CT.NatType))
                       , obInt :: CCG.Expr (ASLExt arch) s CT.IntegerType -> CCG.Expr (ASLExt arch) s CT.IntegerType -> Generator h s arch ret (CCG.Atom s (BinaryOperatorReturn rtp CT.IntegerType))
                       }



-- | Apply a binary operator to two operands, performing the necessary type checks
applyBinOp :: BinaryOperatorBundle h s arch ret rtp
           -> (AS.Expr, CCG.Atom s tp1)
           -> (AS.Expr, CCG.Atom s tp2)
           -> Generator h s arch ret (Some (CCG.Atom s))
applyBinOp bundle (e1, a1) (e2, a2) =
  case CCG.typeOfAtom a1 of
    CT.BVRepr nr -> do
      case CCG.typeOfAtom a2 of
        CT.IntegerRepr -> do
            let a2' = CCG.App (CCE.IntegerToBV nr (CCG.AtomExpr a2))
            Some <$> obBV bundle nr (CCG.AtomExpr a1) a2'
        _ -> do
          Refl <- assertAtomType e2 (CT.BVRepr nr) a2
          Some <$> obBV bundle nr (CCG.AtomExpr a1) (CCG.AtomExpr a2)
    CT.NatRepr -> do
      Refl <- assertAtomType e2 CT.NatRepr a2
      Some <$> obNat bundle (CCG.AtomExpr a1) (CCG.AtomExpr a2)
    CT.IntegerRepr -> do
      case CCG.typeOfAtom a2 of
        CT.BVRepr nr -> do
          let a1' = CCG.App (CCE.IntegerToBV nr (CCG.AtomExpr a1))
          Some <$> obBV bundle nr a1' (CCG.AtomExpr a2)
        _ -> do
          Refl <- assertAtomType e2 CT.IntegerRepr a2
          Some <$> obInt bundle (CCG.AtomExpr a1) (CCG.AtomExpr a2)
    CT.BoolRepr -> do
      case CCG.typeOfAtom a2 of
        CT.BoolRepr -> do
          let nr = WT.knownNat @1
          let a1' = CCG.App $ CCE.BoolToBV nr (CCG.AtomExpr a1)
          let a2' = CCG.App $ CCE.BoolToBV nr (CCG.AtomExpr a2)
          Some <$> obBV bundle nr a1' a2'
        _ -> X.throw (UnsupportedComparisonType e1 (CCG.typeOfAtom a1))

    _ -> X.throw (UnsupportedComparisonType e1 (CCG.typeOfAtom a1))

bvBinOp :: (ext ~ ASLExt arch)
        => (forall n . (1 WT.<= n) => WT.NatRepr n -> CCG.Expr ext s (CT.BVType n) -> CCG.Expr ext s (CT.BVType n) -> CCE.App ext (CCG.Expr ext s) (CT.BVType n))
        -> (AS.Expr, CCG.Atom s tp1)
        -> (AS.Expr, CCG.Atom s tp2)
        -> Generator h s arch ret (Some (CCG.Atom s))
bvBinOp con (e1, a1) (e2, a2) =
  case CCG.typeOfAtom a1 of
    CT.BVRepr nr -> do
      case CCG.typeOfAtom a2 of
        CT.IntegerRepr -> do
          let a2' = CCG.App (CCE.IntegerToBV nr (CCG.AtomExpr a2))
          Some <$> mkAtom (CCG.App (con nr (CCG.AtomExpr a1) a2'))
        _ -> do
          Refl <- assertAtomType e2 (CT.BVRepr nr) a2
          Some <$> mkAtom (CCG.App (con nr (CCG.AtomExpr a1) (CCG.AtomExpr a2)))
    CT.IntegerRepr -> do
      case CCG.typeOfAtom a2 of
        CT.BVRepr nr -> do
          let a1' = CCG.App (CCE.IntegerToBV nr (CCG.AtomExpr a1))
          Some <$> mkAtom (CCG.App (con nr a1' (CCG.AtomExpr a2)))
        CT.IntegerRepr -> do
          let bvrepr = WT.knownNat @64
          let a1' = CCG.App $ CCE.IntegerToBV bvrepr (CCG.AtomExpr a1)
          let a2' = CCG.App $ CCE.IntegerToBV bvrepr (CCG.AtomExpr a2)
          Some <$> mkAtom (CCG.App (CCE.BvToInteger bvrepr (CCG.App (con bvrepr a1' a2'))))
        _ -> throwTrace (ExpectedBVType e1 (CCG.typeOfAtom a2))
    _ -> throwTrace $ (ExpectedBVType e1 (CCG.typeOfAtom a1))

logicalBinOp :: (ext ~ ASLExt arch)
             => (CCG.Expr ext s CT.BoolType -> CCG.Expr ext s CT.BoolType -> CCE.App ext (CCG.Expr ext s) CT.BoolType)
             -> (AS.Expr, CCG.Atom s tp1)
             -> (AS.Expr, CCG.Atom s tp2)
             -> Generator h s arch ret (Some (CCG.Atom s))
logicalBinOp con (e1, a1) (e2, a2) = do
  Refl <- assertAtomType e1 CT.BoolRepr a1
  Refl <- assertAtomType e2 CT.BoolRepr a2
  Some <$> mkAtom (CCG.App (con (CCG.AtomExpr a1) (CCG.AtomExpr a2)))

translateUnaryOp :: Overrides arch
                 -> AS.UnOp
                 -> AS.Expr
                 -> Generator h s arch ret (Some (CCG.Atom s))
translateUnaryOp ov op expr = do
  Some atom <- translateExpr ov expr
  case op of
    AS.UnOpNot -> do
      case CCG.typeOfAtom atom of
        CT.BVRepr nr -> do
          Some <$> mkAtom (CCG.App (CCE.BVNot nr (CCG.AtomExpr atom)))
        CT.BoolRepr -> do
          Some <$> mkAtom (CCG.App (CCE.Not (CCG.AtomExpr atom)))
        _ -> throwTrace $ UnexpectedExprType (Just expr) (CCG.typeOfAtom atom) (CT.BoolRepr)
    AS.UnOpNeg ->
      case CCG.typeOfAtom atom of
        CT.IntegerRepr -> do
          Some <$> mkAtom (CCG.App (CCE.IntNeg (CCG.AtomExpr atom)))
        _ -> throwTrace $ UnexpectedExprType (Just expr) (CCG.typeOfAtom atom) (CT.BoolRepr)

data BVAtomPair s where
  BVAtomPair :: (tp ~ CT.BVType w, 1 WT.<= w)
             => WT.NatRepr w
             -> CCG.Atom s tp
             -> CCG.Atom s tp
             -> BVAtomPair s

-- zero-extend one bitvector to match the other's size
matchBVSizes :: CCG.Atom s tp
             -> CCG.Atom s tp'
             -> Generator h s arch ret (BVAtomPair s)
matchBVSizes atom1 atom2 = do
  BVRepr wRepr1 <- getAtomBVRepr atom1
  BVRepr wRepr2 <- getAtomBVRepr atom2
  case wRepr1 `WT.testNatCases` wRepr2 of
    WT.NatCaseEQ ->
      return $ BVAtomPair wRepr1 atom1 atom2
    WT.NatCaseLT WT.LeqProof -> do
      atom1' <- mkAtom (CCG.App (CCE.BVZext wRepr2 wRepr1 (CCG.AtomExpr atom1)))
      return $ BVAtomPair wRepr2 atom1' atom2
    WT.NatCaseGT WT.LeqProof -> do
      atom2' <- mkAtom (CCG.App (CCE.BVZext wRepr1 wRepr2 (CCG.AtomExpr atom2)))
      return $ BVAtomPair wRepr1 atom1 atom2'

extBVAtom :: 1 WT.<= w
           => Bool
           -> WT.NatRepr w
           -> CCG.Atom s tp
           -> Generator h s arch ret (CCG.Atom s (CT.BVType w))
extBVAtom signed repr atom = do
  BVRepr atomRepr <- getAtomBVRepr atom
  case atomRepr `WT.testNatCases` repr of
    WT.NatCaseEQ ->
      return atom
    WT.NatCaseLT WT.LeqProof -> do
      let bop = if signed then CCE.BVSext else CCE.BVZext
      atom' <- mkAtom (CCG.App (bop repr atomRepr (CCG.AtomExpr atom)))
      return atom'
    _ -> throwTrace $ UnexpectedBitvectorLength (CT.BVRepr atomRepr) (CT.BVRepr repr)

relaxConstraint :: TypeConstraint -> TypeConstraint
relaxConstraint constraint = case constraint of
  ConstraintSingle (CT.BVRepr nr) -> ConstraintHint (HintMaxBVSize nr)
  _ -> constraint

-- Overrides that dispatch to ambiguous function overloads based on the argument type
overloadedDispatchOverrides :: AS.Expr
                            -> TypeConstraint
                            -> Maybe (Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData))
overloadedDispatchOverrides e tc = case e of
  AS.ExprCall (AS.QualifiedIdentifier q "Align") args@[e1, _] -> Just $ do
    Some atom1 <- translateExpr overrides e1
    nm <- case CCG.typeOfAtom atom1 of
      CT.IntegerRepr ->
        return $ "Alignintegerinteger"
      CT.BVRepr _ ->
        return $ "AlignbitsNinteger"
      x -> error $ "Unexpected override type:" ++ show x
    translateExpr' overrides (AS.ExprCall (AS.QualifiedIdentifier q nm) args) ConstraintNone
  AS.ExprCall (AS.QualifiedIdentifier q fun) args@[e1, e2]
    | fun `elem` ["Min","Max"]
    -> Just $ do
    Some atom1 <- translateExpr overrides e1
    Some atom2 <- translateExpr overrides e2
    Refl <- assertAtomType e1 CT.IntegerRepr atom1
    Refl <- assertAtomType e2 CT.IntegerRepr atom2
    translateExpr' overrides (AS.ExprCall (AS.QualifiedIdentifier q (fun <> "integerinteger")) args) tc
  _ ->  mkFaultOv "IsExternalAbort" <|>
        mkFaultOv "IsAsyncAbort" <|>
        mkFaultOv "IsSErrorInterrupt" <|>
        mkFaultOv "IsExternalSyncAbort"
  where
    mkFaultOv nm =
      case e of
        AS.ExprCall (AS.QualifiedIdentifier q nm') [arg] | nm == nm' -> Just $ do
          (_, ext) <- translateExpr' overrides arg ConstraintNone
          ov <- case ext of
            TypeStruct _ -> return $ "FaultRecord"
            _ -> return $ "Fault"
          translateExpr' overrides (AS.ExprCall (AS.QualifiedIdentifier q (nm <> ov)) [arg]) tc
        _ -> Nothing

getBVLength :: Maybe AS.Expr
            -> TypeConstraint
            -> Generator h s arch ret (Some BVRepr)
getBVLength mexpr ty = do
  env <- getStaticEnv
  case () of
    _ | Just e <- mexpr
      , Just (StaticInt i) <- SE.exprToStatic env e
      , Just (Some repr) <- WT.someNat i
      , Just WT.LeqProof <- (WT.knownNat @1) `WT.testLeq` repr ->
        return $ Some $ BVRepr repr
    _ | ConstraintSingle (CT.BVRepr nr) <- ty ->
        return $ Some $ BVRepr $ nr
    _ | ConstraintHint (HintMaxBVSize nr) <- ty ->
        return $ Some $ BVRepr $ nr
    _ -> throwTrace $ CannotDetermineBVLength mexpr ty

-- This is a dead code path that no longer appears when all of the memory translation
-- functions are stubbed out.
  
-- getSymbolicBVLength :: AS.Expr
--                     -> Maybe (Generator h s arch ret (CCG.Atom s CT.IntegerType))
-- getSymbolicBVLength e = case e of
--     AS.ExprCall (AS.QualifiedIdentifier _ nm) [e]
--       | nm == "Zeros" || nm == "Ones" -> Just $ do
--         (Some argAtom) <- translateExpr overrides e
--         Refl <- assertAtomType e CT.IntegerRepr argAtom
--         mkAtom $ CCG.AtomExpr argAtom
--     AS.ExprLitBin bits -> Just $ do
--       mkAtom $ CCG.App $ CCE.IntLit $ fromIntegral $ length bits
--     AS.ExprSlice _ [slice] -> Just $ do
--       (loAtom, hiAtom) <- getSymbolicSliceRange overrides slice
--       mkAtom $ CCG.App $ CCE.IntSub (CCG.AtomExpr hiAtom) (CCG.AtomExpr loAtom)
--     AS.ExprVarRef (AS.QualifiedIdentifier _ ident) -> Just $ do
--       mTy <- lookupVarType ident
--       case mTy of
--         Just (Some (CT.BVRepr wRepr)) ->
--           mkAtom $ CCG.App $ CCE.IntLit $ WT.intValue wRepr
--         _ -> throwTrace $ UnboundName ident
--     AS.ExprBinOp AS.BinOpConcat e1 e2
--       | Just f1 <- getSymbolicBVLength e1
--       , Just f2 <- getSymbolicBVLength e2 -> Just $ f1 >>= \len1 -> f2 >>= \len2 ->
--         mkAtom $ CCG.App $ CCE.IntAdd (CCG.AtomExpr len1) (CCG.AtomExpr len2)
--     _ -> Nothing

list1ToMaybe :: [a] -> Maybe (Maybe a)
list1ToMaybe xs = case xs of
  [x] -> Just (Just x)
  [] -> Just Nothing
  _ -> Nothing

mkAtom' :: CCG.Expr (ASLExt arch) s tp
        -> Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData)
mkAtom' e = do
  atom <- mkAtom e
  return (Some atom, TypeBasic)

-- Overrides to handle cases where bitvector lengths cannot be
-- determined statically.
polymorphicBVOverrides :: forall h s arch ret
                        . AS.Expr
                       -> TypeConstraint
                       -> StaticEnvMap
                       -> Maybe (Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData))
polymorphicBVOverrides expr ty env = case expr of
  AS.ExprBinOp bop arg1@(AS.ExprSlice _ _) arg2
    | bop == AS.BinOpEQ || bop == AS.BinOpNEQ -> Just $ do
        (Some atom1', _) <- translateExpr' overrides arg1 (ConstraintHint HintAnyBVSize)
        BVRepr atom1sz <- getAtomBVRepr atom1'
        (Some atom2', _) <- translateExpr' overrides arg2 (ConstraintHint $ HintMaxBVSize atom1sz)
        BVAtomPair _ atom1 atom2 <- matchBVSizes atom1' atom2'
        (Some result') <- applyBinOp eqOp (arg1, atom1) (arg2, atom2)
        Refl <- assertAtomType' CT.BoolRepr result'
        result <- case bop of
          AS.BinOpEQ -> return result'
          AS.BinOpNEQ -> mkAtom (CCG.App (CCE.Not (CCG.AtomExpr result')))
          _ -> error $ "Unexpected binary operation: " ++ show bop
        return (Some result, TypeBasic)
  AS.ExprBinOp AS.BinOpConcat expr1 (AS.ExprCall (AS.VarName "Zeros") [expr2])
    | Just (StaticInt 0) <- SE.exprToStatic env expr2 ->
      Just $ translateExpr' overrides expr1 ty

  -- This is a dead code path that no longer appears when all of the memory translation
  -- functions are stubbed out.
  -- AS.ExprBinOp AS.BinOpConcat expr1 expr2
  --   | Just hint <- getConstraintHint ty
  --   , (mLen1 :: Maybe (Generator h s arch ret (CCG.Atom s CT.IntegerType))) <- getSymbolicBVLength expr1
  --   , (mLen2 :: Maybe (Generator h s arch ret (CCG.Atom s CT.IntegerType))) <- getSymbolicBVLength expr2
  --   , isJust mLen1 || isJust mLen2-> Just $ do
  --       (Some atom1', _) <- translateExpr' overrides expr1 (relaxConstraint ty)
  --       (Some atom2', _) <- translateExpr' overrides expr2 (relaxConstraint ty)
  --       BVAtomPair wRepr atom1 atom2 <- case hint of
  --         HintMaxSignedBVSize wRepr -> do
  --           atom1 <- extBVAtom False wRepr atom1' -- will inherit signed bits from atom2
  --           atom2 <- extBVAtom True wRepr atom2'
  --           return $ BVAtomPair wRepr atom1 atom2
  --         HintMaxBVSize wRepr -> do
  --           atom1 <- extBVAtom False wRepr atom1'
  --           atom2 <- extBVAtom False wRepr atom2'
  --           return $ BVAtomPair wRepr atom1 atom2
  --         HintAnyBVSize -> do
  --           matchBVSizes atom1' atom2'
  --       shift <- case (mLen1, mLen2) of
  --         (Just f1, _) -> f1 >>= \len1 ->
  --           return $ CCG.App $ CCE.IntegerToBV wRepr $ CCG.App $
  --             CCE.IntSub (CCG.App (CCE.IntLit $ WT.intValue wRepr)) (CCG.AtomExpr len1)
  --         (_, Just f2) -> f2 >>= \len2 ->
  --           return $ CCG.App $ CCE.IntegerToBV wRepr $ (CCG.AtomExpr len2)
  --       let atom1Shifted = CCG.App $ CCE.BVShl wRepr (CCG.AtomExpr atom1) shift

  --       result <- mkAtom $ CCG.App $ CCE.BVOr wRepr atom1Shifted (CCG.AtomExpr atom2)
  --       return (Some result, TypeBasic)

  AS.ExprCall (AS.QualifiedIdentifier _ "Int") [argExpr, isUnsigned] -> Just $ do
    Some unsigned <- translateExpr overrides isUnsigned
    Refl <- assertAtomType' CT.BoolRepr unsigned

    (Some ubvatom, _) <- translateExpr' overrides argExpr (ConstraintHint $ HintAnyBVSize)
    BVRepr unr <- getAtomBVRepr ubvatom
    uatom <- mkAtom $ CCG.App $ CCE.BvToInteger unr (CCG.AtomExpr ubvatom)

    (Some sbvatom, _) <- translateExpr' overrides argExpr ConstraintNone
    BVRepr snr <- getAtomBVRepr sbvatom
    satom <- mkAtom $ CCG.App $ CCE.SbvToInteger snr (CCG.AtomExpr sbvatom)
    Just Refl <- return $ testEquality unr snr

    mkAtom' $ CCG.App $ CCE.BaseIte CT.BaseIntegerRepr (CCG.AtomExpr unsigned) (CCG.AtomExpr uatom) (CCG.AtomExpr satom)
  AS.ExprCall (AS.QualifiedIdentifier _ "UInt") [argExpr] -> Just $ do
    (Some atom, _) <- translateExpr' overrides argExpr (ConstraintHint $ HintAnyBVSize)
    BVRepr nr <- getAtomBVRepr atom
    mkAtom' (CCG.App (CCE.BvToInteger nr (CCG.AtomExpr atom)))

  AS.ExprCall (AS.QualifiedIdentifier _ "SInt") [argExpr] -> Just $ do
    Some atom <- translateExpr overrides argExpr
    BVRepr nr <- getAtomBVRepr atom
    mkAtom' (CCG.App (CCE.SbvToInteger nr (CCG.AtomExpr atom)))
  AS.ExprCall (AS.QualifiedIdentifier _ "IsZero") [argExpr] -> Just $ do
    (Some atom, _) <- translateExpr' overrides argExpr (ConstraintHint $ HintAnyBVSize)
    BVRepr nr <- getAtomBVRepr atom
    mkAtom' (CCG.App (CCE.BVEq nr (CCG.AtomExpr atom) (CCG.App (CCE.BVLit nr 0))))
  AS.ExprCall (AS.QualifiedIdentifier _ "IsOnes") [argExpr] -> Just $ do
    argExpr' <- case argExpr of
      AS.ExprSlice e slices ->
        return $ AS.ExprSlice (AS.ExprUnOp AS.UnOpNot e) slices
      _ -> return $ AS.ExprUnOp AS.UnOpNot argExpr
    translateExpr' overrides
      (AS.ExprCall (AS.QualifiedIdentifier AS.ArchQualAny "IsZero") [argExpr'])
      ConstraintNone
  AS.ExprCall (AS.QualifiedIdentifier _ fun) (val : rest)
    | fun == "ZeroExtend" || fun == "SignExtend"
    , Just mexpr <- list1ToMaybe rest -> Just $ do
    Some (BVRepr targetWidth) <- getBVLength mexpr ty
    (Some valAtom, _) <- case fun of
      "ZeroExtend" -> translateExpr' overrides val (ConstraintHint (HintMaxBVSize targetWidth))
      "SignExtend" -> translateExpr' overrides val (ConstraintHint (HintMaxSignedBVSize targetWidth))
      _ -> error $ "Unexpected function name:" ++ show fun
    BVRepr valWidth <- getAtomBVRepr valAtom
    case valWidth `WT.testNatCases` targetWidth of
      WT.NatCaseEQ ->
        return $ (Some valAtom, TypeBasic)
      WT.NatCaseLT WT.LeqProof -> do
        atom <- case fun of
          "ZeroExtend" -> mkAtom (CCG.App (CCE.BVZext targetWidth valWidth (CCG.AtomExpr valAtom)))
          "SignExtend" -> mkAtom (CCG.App (CCE.BVSext targetWidth valWidth (CCG.AtomExpr valAtom)))
          _ -> error $ "Unexpected function name:" ++ show fun
        return $ (Some atom, TypeBasic)
      _ -> throwTrace $ ExpectedBVSizeLeq valWidth targetWidth
  AS.ExprCall (AS.QualifiedIdentifier _ fun) args
    | fun == "Zeros" || fun == "Ones"
    , Just mexpr <- list1ToMaybe args -> Just $ do
    Some (BVRepr targetWidth) <- getBVLength mexpr ty
    zeros <- mkAtom (CCG.App (CCE.BVLit targetWidth 0))
    case fun of
      "Zeros" -> return (Some zeros, TypeBasic)
      "Ones" -> mkAtom' (CCG.App $ CCE.BVNot targetWidth (CCG.AtomExpr zeros))
      _ -> error $ "Unexpected function name:" ++ show fun
  AS.ExprCall (AS.QualifiedIdentifier _ "Replicate") [AS.ExprLitBin [False], repe] -> Just $ do
    translateExpr' overrides
     (AS.ExprCall (AS.QualifiedIdentifier AS.ArchQualAny "Zeros") [repe])
     ty
  AS.ExprCall (AS.QualifiedIdentifier _ fun@"Replicate") args@[bve, repe] -> Just $ do
    Some bvatom <- translateExpr overrides bve
    case (SE.exprToStatic env repe, CCG.typeOfAtom bvatom) of
      (Just (StaticInt width), CT.BVRepr nr) |
          Just (Some rep) <- WT.someNat width
        , Just WT.LeqProof <- (WT.knownNat @1) `WT.testLeq` rep -> do
          mkAtom' $ replicateBV rep nr (CCG.AtomExpr bvatom)
      (Nothing, _) -> throwTrace $ RequiredConcreteValue repe (staticEnvMapVals env)
      _ -> throwTrace $ InvalidOverloadedFunctionCall fun args
  _ -> Nothing


replicateBV :: forall ext s rep w
             . 1 WT.<= w
            => 1 WT.<= rep
            => WT.NatRepr rep
            -> WT.NatRepr w
            -> CCG.Expr ext s (CT.BVType w)
            -> CCG.Expr ext s (CT.BVType (rep WT.* w))
replicateBV repRepr wRepr bv =
  if | predRepr <- WT.decNat repRepr -- rep - 1
     , mulRepr <- predRepr `WT.natMultiply` wRepr -- rep * w
     , Refl <- WT.minusPlusCancel repRepr (WT.knownNat @1) ->
       case WT.isZeroOrGT1 predRepr of
         Left Refl -> bv
         Right WT.LeqProof
           | WT.LeqProof <- WT.addPrefixIsLeq predRepr (WT.knownNat @1)
           , Refl <- WT.lemmaMul wRepr repRepr
           , Refl <- WT.plusMinusCancel predRepr (WT.knownNat @1)
           , WT.LeqProof <- WT.leqMulPos predRepr wRepr
           , WT.LeqProof <- WT.leqAdd (WT.leqProof (WT.knownNat @1) wRepr) mulRepr ->
             CCG.App $ CCE.BVConcat wRepr mulRepr bv (replicateBV predRepr wRepr bv)

-- Overrides for bitshifting functions
bitShiftOverrides :: forall h s arch ret
                        . AS.Expr
                       -> TypeConstraint
                       -> Maybe (Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData))
bitShiftOverrides e _ = case e of
  AS.ExprCall (AS.QualifiedIdentifier _ "primitive_ASR") [x, shift] -> Just $ do
    Some xAtom <- translateExpr overrides x
    Some shiftAtom <- translateExpr overrides shift
    Refl <- assertAtomType shift CT.IntegerRepr shiftAtom
    BVRepr nr <- getAtomBVRepr xAtom
    let bvShift = CCG.App $ CCE.IntegerToBV nr (CCG.AtomExpr shiftAtom)
    result <- mkAtom (CCG.App $ CCE.BVAshr nr (CCG.AtomExpr xAtom) bvShift)
    return $ (Some result, TypeBasic)
  _ -> Nothing


-- Overrides for arithmetic
arithmeticOverrides :: forall h s arch ret
                        . AS.Expr
                       -> TypeConstraint
                       -> Maybe (Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData))
arithmeticOverrides expr ty = case expr of
  AS.ExprCall (AS.VarName "primitive") [AS.ExprBinOp op e1 e2] -> Just $ do
    let (tc1, tc2) = constraintsOfArgs op ty
    (Some a1, _) <- translateExpr' overrides e1 tc1
    (Some a2, _) <- translateExpr' overrides e2 tc2
    let p1 = (e1, a1)
    let p2 = (e2, a2)
    satom <- case op of
      AS.BinOpMul -> applyBinOp realmulOp p1 p2
      AS.BinOpDiv -> applyBinOp realdivOp p1 p2
      AS.BinOpDivide -> applyBinOp realdivOp p1 p2
      AS.BinOpMod -> applyBinOp realmodOp p1 p2
      _ -> throwTrace $ UnsupportedExpr expr
    return (satom, TypeBasic)

  --FIXME: determine actual rounding here
  AS.ExprCall (AS.QualifiedIdentifier _ fun@"RoundTowardsZero") args@[e] -> Just $ do
    case e of
      (AS.ExprBinOp AS.BinOpDivide
        (AS.ExprCall (AS.QualifiedIdentifier _ "Real")
                       [e1])
        (AS.ExprCall (AS.QualifiedIdentifier _ "Real")
                       [e2]))
          -> translateExpr' overrides (AS.ExprBinOp AS.BinOpDiv e1 e2) ty
      _ -> X.throw $ InvalidOverloadedFunctionCall fun args
  --FIXME: determine actual rounding here
  AS.ExprCall (AS.QualifiedIdentifier _ fun@"RoundUp") args@[e] -> Just $ do
    case e of
      (AS.ExprBinOp AS.BinOpDivide
        (AS.ExprCall (AS.QualifiedIdentifier _ "Real")
                       [e1])
        (AS.ExprCall (AS.QualifiedIdentifier _ "Real")
                       [e2]))
          -> translateExpr' overrides (AS.ExprBinOp AS.BinOpDiv e1 e2) ty
      _ -> X.throw $ InvalidOverloadedFunctionCall fun args
  AS.ExprCall (AS.QualifiedIdentifier _ "NOT") [e] -> Just $ do
    translateExpr' overrides (AS.ExprUnOp AS.UnOpNot e) ty
  AS.ExprCall (AS.QualifiedIdentifier _ "Abs") [e] -> Just $ do
    Some atom <- translateExpr overrides e
    case CCG.typeOfAtom atom of
      CT.IntegerRepr -> do
        mkAtom' (CCG.App (CCE.IntAbs (CCG.AtomExpr atom)))
      tp -> X.throw $ ExpectedIntegerType e tp
  _ -> Nothing

overrides :: forall arch . Overrides arch
overrides = Overrides {..}
  where overrideStmt :: forall h s ret . AS.Stmt -> Maybe (Generator h s arch ret ())

        overrideStmt stmt = case stmt of
          _ | Just ([], stmts) <- unletInStmt stmt -> Just $ do
              vars <- MS.gets tsVarRefs
              forgetNewStatics $ mapM_ (translateStatement overrides) stmts
              MS.modify' $ \s -> s { tsVarRefs = vars }

          _ | Just (unvars, stmts) <- unletInStmt stmt -> Just $ do
              mapM_ (translateStatement overrides) stmts
              MS.modify' $ \s -> s { tsVarRefs = foldr Map.delete (tsVarRefs s) unvars
                                   , tsStaticValues = foldr Map.delete (tsStaticValues s) unvars}

          _ | Just f <- unstaticBinding stmt -> Just $ do
                env <- getStaticEnv
                let (nm, sv) = f env
                mapStaticVals (Map.insert nm sv)

          _ | Just stmts <- unblockStmt stmt -> Just $ do
                mapM_ (translateStatement overrides) stmts

          -- The Elem setter is inlined by the desugaring pass, so an explicit call should be a no-op
          AS.StmtCall (AS.VarName "SETTER_Elem") _ -> Just $ return ()

          -- Check for stubbed functions that should have been inlined elsewhere
          AS.StmtCall (AS.VarName "BadASLFunction") _ -> Just $ do
            throwTrace $ BadASLFunctionCall

          AS.StmtCall (AS.QualifiedIdentifier _ "ASLSetUndefined") [] -> Just $ do
            result <- mkAtom $ CCG.App $ CCE.BoolLit True
            translateAssignment' overrides (AS.LValVarRef (AS.QualifiedIdentifier AS.ArchQualAny undefinedVarName)) result TypeBasic Nothing
            abnormalExit overrides
          AS.StmtCall (AS.QualifiedIdentifier _ "ASLSetUnpredictable") [] -> Just $ do
            result <- mkAtom $ CCG.App $ CCE.BoolLit True
            translateAssignment' overrides (AS.LValVarRef (AS.QualifiedIdentifier AS.ArchQualAny unpredictableVarName)) result TypeBasic Nothing
            abnormalExit overrides
          AS.StmtCall (AS.QualifiedIdentifier _ "__abort") [] -> Just $ do
            translateStatement overrides $ AS.StmtCall (AS.QualifiedIdentifier AS.ArchQualAny "EndOfInstruction") []
          AS.StmtCall (AS.QualifiedIdentifier q nm@"TakeHypTrapException") [arg] -> Just $ do
            (_, ext) <- translateExpr' overrides arg ConstraintNone
            ov <- case ext of
              TypeStruct _ -> return $ "ExceptionRecord"
              _ -> return $ "integer"
            translateStatement overrides (AS.StmtCall (AS.QualifiedIdentifier q (nm <> ov)) [arg])
          AS.StmtCall (AS.QualifiedIdentifier _ nm) [_]
            | nm `elem` ["print", "putchar"] -> Just $ do
              return ()
          AS.StmtCall (AS.QualifiedIdentifier _ "Mem_Internal_Set") [addrExpr, szExpr, valueExpr] -> Just $ do
            Some addr <- translateExpr overrides addrExpr
            Refl <- assertAtomType addrExpr (CT.BVRepr (WT.knownNat @32)) addr
            globals <- MS.gets tsGlobals
            Just (Some mem) <- return $ Map.lookup "__Memory" globals
            memAtom <- (liftGenerator $ CCG.readGlobal mem) >>= mkAtom
            env <- getStaticEnv
            case SE.exprToStatic env szExpr of
              Just (SE.StaticInt sz)
                | Some (BVRepr szRepr) <- intToBVRepr sz
                , bvSize <- (WT.knownNat @8) `WT.natMultiply` szRepr
                , WT.LeqProof <- WT.leqMulPos (WT.knownNat @8) szRepr -> do
                  Some value <- translateExpr overrides valueExpr 
                  Refl <- assertAtomType valueExpr (CT.BVRepr bvSize) value
                  let ramRepr = CCG.typeOfAtom memAtom
                  case CT.asBaseType ramRepr of
                    CT.AsBaseType btramRepr -> do
                      let uf = UF ("write_mem_" <> (T.pack $ show sz)) btramRepr
                            (Ctx.empty
                             Ctx.:> ramRepr
                             Ctx.:> CT.BVRepr (WT.knownNat @32)
                             Ctx.:> CT.BVRepr bvSize)
                            (Ctx.empty
                             Ctx.:> (CCG.AtomExpr memAtom)
                             Ctx.:> (CCG.AtomExpr addr)
                             Ctx.:> (CCG.AtomExpr value))
                      liftGenerator $ CCG.writeGlobal mem (CCG.App (CCE.ExtensionApp uf))
                    _ -> throwTrace $ ExpectedBaseTypeRepr ramRepr
              _ -> throwTrace $ RequiredConcreteValue szExpr (staticEnvMapVals env)
          _ -> Nothing

        overrideExpr :: forall h s ret
                      . AS.Expr
                     -> TypeConstraint
                     -> StaticEnvMap
                     -> Maybe (Generator h s arch ret (Some (CCG.Atom s), ExtendedTypeData))
        overrideExpr expr ty env =
          case expr of
            AS.ExprBinOp AS.BinOpEQ e mask@(AS.ExprLitMask _) -> Just $ do
              translateExpr' overrides (AS.ExprInSet e [AS.SetEltSingle mask]) ty
            AS.ExprBinOp AS.BinOpNEQ e mask@(AS.ExprLitMask _) -> Just $ do
              translateExpr' overrides (AS.ExprUnOp AS.UnOpNot (AS.ExprInSet e [AS.SetEltSingle mask])) ty
            AS.ExprCall (AS.QualifiedIdentifier _ "sizeOf") [x] -> Just $ do
              Some xAtom <- translateExpr overrides x
              BVRepr nr <- getAtomBVRepr xAtom
              translateExpr' overrides (AS.ExprLitInt (WT.intValue nr)) ConstraintNone
            AS.ExprCall (AS.VarName "truncate") [bvE, lenE] -> Just $ do
              Some bv <- translateExpr overrides bvE
              BVRepr bvRepr <- getAtomBVRepr bv
              case SE.exprToStatic env lenE of
                Just (SE.StaticInt len)
                  | Some (BVRepr lenRepr) <- intToBVRepr len ->
                    case bvRepr `WT.testNatCases` lenRepr of
                      WT.NatCaseEQ -> return $ (Some bv, TypeBasic)
                      WT.NatCaseGT WT.LeqProof ->
                        mkAtom' $ CCG.App $ CCE.BVTrunc lenRepr bvRepr (CCG.AtomExpr bv)
                      WT.NatCaseLT _ ->
                        throwTrace $ UnexpectedBitvectorLength (CT.BVRepr lenRepr) (CT.BVRepr bvRepr)
                _ -> throwTrace $ RequiredConcreteValue lenE (staticEnvMapVals env)
            AS.ExprCall (AS.QualifiedIdentifier _ "Mem_Internal_Get") [addrExpr, szExpr] -> Just $ do
              Some addr <- translateExpr overrides addrExpr
              Refl <- assertAtomType addrExpr (CT.BVRepr (WT.knownNat @32)) addr
              globals <- MS.gets tsGlobals
              Just (Some mem) <- return $ Map.lookup "__Memory" globals
              memAtom <- (liftGenerator $ CCG.readGlobal mem) >>= mkAtom
              case SE.exprToStatic env szExpr of
                Just (SE.StaticInt sz)
                  | Some (BVRepr szRepr) <- intToBVRepr sz
                  , bvSize <- (WT.knownNat @8) `WT.natMultiply` szRepr
                  , WT.LeqProof <- WT.leqMulPos (WT.knownNat @8) szRepr -> do
                    let ramRepr = CCG.typeOfAtom memAtom
                    let uf = UF ("read_mem_" <> (T.pack $ show sz)) (WT.BaseBVRepr bvSize)
                          (Ctx.empty
                           Ctx.:> ramRepr
                           Ctx.:> (CT.BVRepr (WT.knownNat @32)))
                          (Ctx.empty
                           Ctx.:> (CCG.AtomExpr memAtom)
                           Ctx.:> (CCG.AtomExpr addr))
                    atom <- mkAtom (CCG.App (CCE.ExtensionApp uf))
                    return (Some atom, TypeBasic)
                _ -> throwTrace $ RequiredConcreteValue szExpr (staticEnvMapVals env)
            _ ->
              polymorphicBVOverrides expr ty env <|>
              arithmeticOverrides expr ty <|>
              overloadedDispatchOverrides expr ty <|>
              bitShiftOverrides expr ty
