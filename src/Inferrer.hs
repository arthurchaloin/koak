module Inferrer where

import           Control.Monad.State
import           Data.Word
import           Data.List
import           Data.Word
import           Data.Maybe
import qualified Data.ByteString.Char8           as C8
import qualified Data.ByteString.Short           as BS
import qualified Data.Map                        as Map

import           LLVM
import           LLVM.IRBuilder
import           LLVM.AST.Linkage
import           LLVM.AST.Global
import           LLVM.AST.ParameterAttribute
import           LLVM.AST.Type                   as Types
import qualified LLVM.AST                        as AST
import qualified LLVM.AST.Float                  as F
import qualified LLVM.AST.Constant               as C
import qualified LLVM.AST.FloatingPointPredicate as FP
import qualified LLVM.AST.IntegerPredicate       as IP
import qualified LLVM.AST.AddrSpace              as A
import           LLVM.IRBuilder.Internal.SnocList

import           Helpers
import qualified Syntax

as :: AST.Operand -> Type -> IRBuilderT ModuleBuilder AST.Operand
as o@(AST.ConstantOperand (C.Int 1 _)) (IntegerType 1) = pure o
as o@(AST.ConstantOperand (C.Int 1 _)) (IntegerType 32) = zext o int
as o@(AST.ConstantOperand (C.Int 32 _)) (IntegerType 1) = trunc o bool
as o@(AST.ConstantOperand (C.Int 32 _)) (IntegerType 32) = pure o
as o@(AST.ConstantOperand (C.Int 32 _)) (FloatingPointType DoubleFP) = sitofp o Types.double
as o@(AST.ConstantOperand (C.Float _)) (IntegerType 1) = fptosi o bool
as o@(AST.ConstantOperand (C.Float _)) (IntegerType 32) = fptosi o int
as o@(AST.ConstantOperand (C.Float _)) (FloatingPointType DoubleFP) = pure o
as o@(AST.LocalReference (IntegerType 1) _) (IntegerType 1) = pure o
as o@(AST.LocalReference (IntegerType 1) _) (IntegerType 32) = zext o int
as o@(AST.LocalReference (IntegerType 32) _) (IntegerType 1) = trunc o bool
as o@(AST.LocalReference (IntegerType 32) _) (IntegerType 32) = pure o
as o@(AST.LocalReference (IntegerType 32) _) (FloatingPointType DoubleFP) = sitofp o Types.double
as o@(AST.LocalReference (FloatingPointType DoubleFP) _) (IntegerType 1) = fptosi o bool
as o@(AST.LocalReference (FloatingPointType DoubleFP) _) (IntegerType 32) = fptosi o int
as o@(AST.LocalReference (FloatingPointType DoubleFP) _) (FloatingPointType DoubleFP) = pure o
as o@(AST.LocalReference (IntegerType 1) _) (FloatingPointType DoubleFP) = do
  tmp <- zext o int
  sitofp tmp Types.double
as o@(AST.ConstantOperand (C.Int 1 _)) (FloatingPointType DoubleFP) = do
  tmp <- zext o int
  sitofp tmp Types.double
as o@(AST.LocalReference t _) t'
  | t == t' = pure o
  | otherwise = error $ "cannot cast " ++ (show t) ++ " to " ++ (show t')
as o t = error $ "cannot cast " ++ (show o) ++ " to " ++ (show t)

getFuncDefByName :: ModuleBuilderState -> AST.Name -> Maybe AST.Definition
getFuncDefByName (ModuleBuilderState builderDefs _) name = find byName (getSnocList builderDefs)
  where
    byName (AST.GlobalDefinition (AST.Function _ _ _ _ _ _ typeName _ _ _ _ _ _ _ _ _ _)) = typeName == name
    byName _ = False

getFnRetType :: AST.Definition -> AST.Type
getFnRetType (AST.GlobalDefinition (AST.Function _ _ _ _ _ funcType _ _ _ _ _ _ _ _ _ _ _)) = funcType

getFnArgsType :: AST.Definition -> [AST.Type]
getFnArgsType (AST.GlobalDefinition (AST.Function _ _ _ _ _ _ _ params _ _ _ _ _ _ _ _ _)) = paramsType
  where paramsType = map (\(Parameter t _ _) -> t) $ fst params

getFuncType :: AST.Definition -> AST.Type
getFuncType (AST.GlobalDefinition (AST.Function _ _ _ _ _ funcType _ (params, isVaArgs) _ _ _ _ _ _ _ _ _)) = asPointer $ AST.FunctionType funcType paramsTypes isVaArgs
  where
    paramsTypes = map (\(AST.Parameter t _ _) -> t) params
    asPointer fn = PointerType (fn) (A.AddrSpace 0)

getVarTypeByName :: ModuleBuilderState -> AST.Name -> AST.Type
getVarTypeByName (ModuleBuilderState _ builderTypeDefs) name = case Map.lookup name builderTypeDefs of
  Just t  -> t
  Nothing -> error $ "could not find type of variable " ++ show name

getFnTypeByName :: ModuleBuilderState -> AST.Name -> AST.Type
getFnTypeByName mbs name = case getFuncDefByName mbs name of
  Just func -> getFuncType func
  Nothing   -> error $ "could not find type of function " ++ show name

getFnArgsTypeByName :: ModuleBuilderState -> AST.Name -> [AST.Type]
getFnArgsTypeByName mbs name = case getFuncDefByName mbs name of
  Just func -> getFnArgsType func
  Nothing   -> error $ "could not find args type of function " ++ show name

getFnRetTypeByName :: ModuleBuilderState -> AST.Name -> AST.Type
getFnRetTypeByName mbs name = case getFuncDefByName mbs name of
  Just func -> getFnRetType func
  Nothing   -> error $ "could not find return type of function " ++ show name

getVarTypeByName' :: [Syntax.Expr] -> AST.Name -> AST.Type
getVarTypeByName' ast name = case astFind' declByName ast of
  Just (Syntax.Decl t _ _) -> t
  Nothing -> error $ "could not find type of variable " ++ show name ++ " in the ast"
  where
    declByName d@(Syntax.Decl _ dname _ ) = (AST.Name dname) == name
    declByName _                          = False

getFnRetTypeByName' :: [Syntax.Expr] -> AST.Name -> AST.Type
getFnRetTypeByName' ast name = case astFind' funcByName ast of
  Just (Syntax.Function _ _ t _)  -> t
  Just (Syntax.Extern _ _ t _)    -> t
  Nothing -> error $ "could not find type of function " ++ show name ++ " in the ast"
  where
    funcByName d@(Syntax.Function fname _ _ _ ) = (AST.Name fname) == name
    funcByName d@(Syntax.Extern ename _ _ _ )   = (AST.Name ename) == name
    funcByName _                                = False

astFind' :: (Syntax.Expr -> Bool) -> [Syntax.Expr] -> Maybe Syntax.Expr
astFind' cond exprs = case catMaybes $ map (astFind cond) exprs of
  (x:_) -> Just x
  []    -> Nothing

astFind :: (Syntax.Expr -> Bool) -> Syntax.Expr -> Maybe Syntax.Expr
astFind cond b@(Syntax.Block exprs)             = astFind' cond exprs
astFind cond d@(Syntax.Decl _ _ expr)           = if cond d then Just d else Nothing
astFind cond f@(Syntax.Function _ exprs _ expr) = if cond f then Just f else astFind' cond (expr:exprs)
astFind cond e@(Syntax.Extern _ _ _ _)          = if cond e then Just e else Nothing
astFind cond i@(Syntax.If c thenb elseb)        = astFind' cond [c, thenb, elseb]
astFind cond w@(Syntax.While a b)               = astFind' cond [a, b]
astFind cond f@(Syntax.For a b c d)             = astFind' cond [a, b, c, d]
astFind cond _ = Nothing
-- astFind cond a@(Syntax.Assign _ expr)     = astFind cond expr
-- astFind cond v@(Syntax.Var _)             = if cond v then Just v else Nothing
-- astFind cond c@(Syntax.Call _ exprs)      = astFind' cond exprs
-- astFind cond b@(Syntax.BinOp _ lhs rhs)   = astFind' cond [lhs, rhs]

inferTypes :: String -> Type -> Type -> (Type, Type)
inferTypes name lhsType rhsType
  | lhsType == Types.double || rhsType == Types.double = (Types.double, inferRetType Types.double name)
  | lhsType == int || rhsType == int                   = (int, inferRetType int name)
  | lhsType == bool || rhsType == bool                 = (int, inferRetType int name)
  | otherwise = error $ name ++ " types mismatch " ++ (show lhsType) ++ " " ++ (show rhsType)
  where
    inferRetType _ "Eq"    = bool
    inferRetType _ "NotEq" = bool
    inferRetType _ "Lt"    = bool
    inferRetType _ "Gt"    = bool
    inferRetType _ "Lte"   = bool
    inferRetType _ "Gte"   = bool
    inferRetType d _       = d

getStrongType :: ModuleBuilderState -> Syntax.Expr -> Type
getStrongType s (Syntax.BinOp op lhs rhs) = snd $ inferTypes (show op) (getStrongType s lhs) (getStrongType s rhs)
getStrongType s e = inferType s e

inferType :: ModuleBuilderState -> Syntax.Expr -> Type
inferType _ (Syntax.Block [])               = int
inferType s (Syntax.Block b)                = last $ map (inferType s) b
inferType _ (Syntax.Data (Syntax.Double _)) = Types.double
inferType _ (Syntax.Data (Syntax.Int _))    = int
inferType _ (Syntax.Data (Syntax.Str _))    = charptr
inferType _ (Syntax.Decl t _ _)             = t
inferType s (Syntax.Assign _ expr)          = inferType s expr
inferType s (Syntax.Var name)               = getVarTypeByName s (AST.Name name)
inferType s (Syntax.If _ thenb elseb)       = fst $ inferTypes "if-else" (inferType s thenb) (inferType s elseb)
inferType s (Syntax.While _ b)              = inferType s b
inferType s (Syntax.For _ _ _ b)            = inferType s b
inferType s (Syntax.Call fname _)           = getFnRetTypeByName s (AST.Name fname)
inferType s (Syntax.BinOp op lhs rhs)       = fst $ inferTypes (show op) (inferType s lhs) (inferType s rhs)

inferTypeFromAst :: [Syntax.Expr] -> Syntax.Expr -> Type
inferTypeFromAst _   (Syntax.Block [])               = int
inferTypeFromAst ast (Syntax.Block b)                = last $ map (inferTypeFromAst ast) b
inferTypeFromAst _   (Syntax.Data (Syntax.Double _)) = Types.double
inferTypeFromAst _   (Syntax.Data (Syntax.Int _))    = int
inferTypeFromAst _   (Syntax.Data (Syntax.Str _))    = charptr
inferTypeFromAst _   (Syntax.Decl t _ _)             = t
inferTypeFromAst ast (Syntax.Assign _ expr)          = inferTypeFromAst ast expr
inferTypeFromAst ast (Syntax.Var name)               = getVarTypeByName' ast (AST.Name name)
inferTypeFromAst ast (Syntax.If _ thenb elseb)       = fst $ inferTypes "if-else" (inferTypeFromAst ast thenb) (inferTypeFromAst ast elseb)
inferTypeFromAst ast (Syntax.While _ b)              = inferTypeFromAst ast b
inferTypeFromAst ast (Syntax.For _ _ _ b)            = inferTypeFromAst ast b
inferTypeFromAst ast (Syntax.Call fname _)           = getFnRetTypeByName' ast (AST.Name fname)
inferTypeFromAst ast (Syntax.BinOp op lhs rhs)       = fst $ inferTypes (show op) (inferTypeFromAst ast lhs) (inferTypeFromAst ast rhs)
