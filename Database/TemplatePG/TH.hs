{-# LANGUAGE PatternGuards, ScopedTypeVariables, FlexibleContexts #-}
-- |
-- Module: Database.TemplatePG.TH
-- Copyright: 2015 Dylan Simon
-- 
-- Support functions for compile-time PostgreSQL connection and state management.
-- Although this is meant to be used from other TH code, it will work during normal runtime if just want simple PGConnection management.

module Database.TemplatePG.TH
  ( getTPGDatabase
  , withTPGConnection
  , useTPGDatabase
  , PGTypeInfo(..)
  , getPGTypeInfo
  , tpgDescribe
  , pgTypeDecoder
  , pgTypeDecoderNotNull
  , pgTypeEncoder
  , pgTypeEscaper
  ) where

import Control.Applicative ((<$>), (<$), (<|>))
import Control.Concurrent.MVar (MVar, newMVar, modifyMVar, swapMVar)
import Control.Monad ((>=>), void, liftM2)
import Data.Foldable (toList)
import Data.Maybe (isJust, fromMaybe)
import qualified Language.Haskell.TH as TH
import Network (PortID(UnixSocket, PortNumber), PortNumber)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Database.TemplatePG.Types
import Database.TemplatePG.Protocol

-- |Generate a 'PGDatabase' based on the environment variables:
-- @TPG_HOST@ (localhost); @TPG_SOCK@ or @TPG_PORT@ (5432); @TPG_DB@ or user; @TPG_USER@ or @USER@ (postgres); @TPG_PASS@ ()
getTPGDatabase :: IO PGDatabase
getTPGDatabase = do
  user <- fromMaybe "postgres" <$> liftM2 (<|>) (lookupEnv "TPG_USER") (lookupEnv "USER")
  db   <- fromMaybe user <$> lookupEnv "TPG_DB"
  host <- fromMaybe "localhost" <$> lookupEnv "TPG_HOST"
  pnum <- maybe (5432 :: PortNumber) ((fromIntegral :: Int -> PortNumber) . read) <$> lookupEnv "TPG_PORT"
  port <- maybe (PortNumber pnum) UnixSocket <$> lookupEnv "TPG_SOCK"
  pass <- fromMaybe "" <$> lookupEnv "TPG_PASS"
  debug <- isJust <$> lookupEnv "TPG_DEBUG"
  return $ defaultPGDatabase
    { pgDBHost = host
    , pgDBPort = port
    , pgDBName = db
    , pgDBUser = user
    , pgDBPass = pass
    , pgDBDebug = debug
    }

tpgConnection :: MVar (Either (IO PGConnection) PGConnection)
tpgConnection = unsafePerformIO $ newMVar $ Left $ pgConnect =<< getTPGDatabase

-- |Run an action using the TemplatePG connection.
withTPGConnection :: (PGConnection -> IO a) -> IO a
withTPGConnection f = modifyMVar tpgConnection $ either id return >=> (\c -> (,) (Right c) <$> f c)

setTPGConnection :: Either (IO PGConnection) PGConnection -> IO ()
setTPGConnection = void . swapMVar tpgConnection

-- |Specify an alternative database to use during TemplatePG compilation.
-- This lets you override the default connection parameters that are based on TPG environment variables.
-- This should be called as a top-level declaration and produces no code.
-- It will also clear all types registered with 'registerTPGType'.
useTPGDatabase :: PGDatabase -> TH.Q [TH.Dec]
useTPGDatabase db = [] <$ TH.runIO (setTPGConnection $ Left $ pgConnect db)

data PGTypeInfo = PGTypeInfo
  { pgTypeOID :: OID
  , pgTypeName :: String
  }

-- |Lookup a type by OID, internal or formatted name (case sensitive).
-- Fail if not found.
getPGTypeInfo :: PGConnection -> Either OID String -> IO PGTypeInfo
getPGTypeInfo c t = do
  (_, r) <- pgSimpleQuery c $ "SELECT oid, typname FROM pg_catalog.pg_type WHERE " ++ either
    (\o -> "oid = " ++ pgLiteral pgOIDType o)
    (\n -> "typname = " ++ pgQuote n ++ " OR format_type(oid, -1) = " ++ pgQuote n)
    t
  case toList r of
    [[Just o, Just n]] -> return $ PGTypeInfo (pgDecode pgOIDType o) (pgDecode pgNameType n)
    _ -> fail $ "Unknown PostgreSQL type: " ++ either show id t

-- |A type-aware wrapper to 'pgDescribe'
tpgDescribe :: PGConnection -> String -> [String] -> Bool -> IO ([PGTypeInfo], [(String, PGTypeInfo, Bool)])
tpgDescribe conn sql types nulls = do
  at <- mapM (fmap pgTypeOID . getPGTypeInfo conn . Right) types
  (pt, rt) <- pgDescribe conn sql at nulls
  pth <- mapM (getPGTypeInfo conn . Left) pt
  rth <- mapM (\(c, t, n) -> do
    th <- getPGTypeInfo conn (Left t)
    return (c, th, n)) rt
  return (pth, rth)


typeApply :: TH.Name -> PGTypeInfo -> TH.Exp
typeApply f PGTypeInfo{ pgTypeName = n } = TH.AppE (TH.VarE f) $
  TH.ConE 'PGTypeProxy `TH.SigE` (TH.ConT ''PGTypeName `TH.AppT` TH.LitT (TH.StrTyLit n))


-- |TH expression to decode a 'Maybe' 'L.ByteString' to a 'Maybe' 'PGColumn' value.
pgTypeDecoder :: PGTypeInfo -> TH.Exp
pgTypeDecoder = typeApply 'pgDecodeColumn

-- |TH expression to decode a 'Maybe' 'L.ByteString' to a 'PGColumn' value.
pgTypeDecoderNotNull :: PGTypeInfo -> TH.Exp
pgTypeDecoderNotNull = typeApply 'pgDecodeColumnNotNull

-- |TH expression to encode a 'PGParameter' value to a 'Maybe' 'L.ByteString'.
pgTypeEncoder :: PGTypeInfo -> TH.Exp
pgTypeEncoder = typeApply 'pgEncodeParameter

-- |TH expression to escape a 'PGParameter' value to a SQL literal.
pgTypeEscaper :: PGTypeInfo -> TH.Exp
pgTypeEscaper = typeApply 'pgEscapeParameter

