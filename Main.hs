{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Lazy
import Control.Monad.Trans.Writer.Lazy
import Language.C
import Language.C.Data.Ident
import Language.C.System.GCC
import Language.Rust.Corrode.C
import System.Environment
import Text.PrettyPrint.HughesPJClass

data RustType
    = VoidType
    | BoolType
    | IntType Signed IntWidth
    | FloatType Int

instance Show RustType where
    show VoidType = "()"
    show BoolType = "bool"
    show (IntType s w) = (case s of Signed -> 'i'; Unsigned -> 'u') : (case w of BitWidth b -> show b; WordWidth -> "size")
    show (FloatType w) = 'f' : show w

rustTypeOf :: Show a => [CDeclarationSpecifier a] -> RustType
rustTypeOf = foldr go (IntType Signed (BitWidth 32))
    where
    go (CTypeSpec (CSignedType _)) (IntType _ width) = IntType Signed width
    go (CTypeSpec (CUnsigType _)) (IntType _ width) = IntType Unsigned width
    go (CTypeSpec (CCharType _)) (IntType s _) = IntType s (BitWidth 8)
    go (CTypeSpec (CShortType _)) (IntType s _) = IntType s (BitWidth 16)
    go (CTypeSpec (CIntType _)) (IntType s _) = IntType s (BitWidth 32)
    go (CTypeSpec (CLongType _)) (IntType s _) = IntType s WordWidth
    go (CTypeSpec (CFloatType _)) _ = FloatType 32
    go (CTypeSpec (CDoubleType _)) _ = FloatType 64
    go (CTypeSpec (CVoidType _)) _ = VoidType
    go (CTypeSpec (CBoolType _)) _ = BoolType
    go spec _ = error ("rustTypeOf: unsupported declaration specifier " ++ show spec)

translateStatement :: Show a => CStatement a -> WriterT String EnvMonad ()
translateStatement (CCompound [] items _) = do
    -- Push a new declaration scope for this block.
    lift $ modify ([] :)
    forM_ items $ \ item -> case item of
        CBlockStmt stmt -> translateStatement stmt
        _ -> error ("translateStatement: unsupported statement " ++ show item)
    -- Pop this block's declaration scope.
    lift $ modify tail
translateStatement (CReturn Nothing _) = tell "    return;\n"
translateStatement (CReturn (Just expr) _) = do
    (_, expr') <- lift $ interpretExpr expr
    tell ("    return " `mappend` prettyShow expr' `mappend` ";\n")
translateStatement stmt = error ("translateStatement: unsupported statement " ++ show stmt)

translateFunction :: Show a => CFunctionDef a -> IO ()
translateFunction (CFunDef specs (CDeclr (Just (Ident name _ _)) [CFunDeclr (Right (args, False)) _ _] _asm _attrs _) _ body _) = do
    putStrLn ("fn " ++ name ++ "(")
    args' <- forM args $ \ (CDecl argspecs [(Just (CDeclr (Just argname) [] _ _ _), Nothing, Nothing)] _) -> do
        let ty = rustTypeOf argspecs
        let nm = identToString argname
        putStrLn (nm ++ " : " ++ show ty)
        return $ (,) argname $ case ty of
            IntType s w -> IsInt s w
            FloatType w -> IsFloat w
            _ -> error ("translateFunction: unsupported argument type " ++ show ty)
    putStrLn (") -> " ++ show (rustTypeOf specs) ++ " {")
    let ((), body') = evalState (runWriterT (translateStatement body)) [args']
    putStr body'
    putStrLn "}"

main :: IO ()
main = do
    args <- getArgs
    forM_ args $ \ arg -> do
        Right (CTranslUnit decls _node) <- parseCFile (newGCC "gcc") Nothing [] arg
        forM_ decls $ \ decl -> case decl of
            CFDefExt f -> translateFunction f
            _ -> print decl