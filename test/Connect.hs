{-# LANGUAGE CPP               #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
module Connect where

#ifdef HAVE_TLS
import           Control.Exception                  (throwIO)
import qualified Data.ByteString.Char8              as BSC
#endif
import           Data.Maybe                         (fromMaybe, isJust)
import           Database.PostgreSQL.Typed          (PGDatabase (..),
                                                     defaultPGDatabase)
#ifdef HAVE_TLS
import           Database.PostgreSQL.Typed.Protocol (PGTlsMode (..),
                                                     PGTlsValidateMode (..),
                                                     pgTlsValidate)
#endif
import           Network.Socket                     (SockAddr (SockAddrUnix))
import           System.Environment                 (lookupEnv)
import           System.IO.Unsafe                   (unsafePerformIO)

db :: PGDatabase
db = unsafePerformIO $ do
  mPort <- lookupEnv "PGPORT"
  pgDBAddr <- case mPort of
    Nothing ->
      Right . SockAddrUnix . fromMaybe "/tmp/.s.PGSQL.5432" <$> lookupEnv "PGSOCK"
    Just port -> pure $ Left ("localhost", port)
#ifdef HAVE_TLS
  pgDBTLS <- do
    enabled <- isJust <$> lookupEnv "PGTLS"
    validateFull <- isJust <$> lookupEnv "PGTLS_VALIDATEFULL"
    rootcert <- fmap BSC.pack <$> lookupEnv "PGTLS_ROOTCERT"
    case (enabled,validateFull,rootcert) of
      (False,_,_) -> pure TlsDisabled
      (True,False,Nothing) -> pure TlsNoValidate
      (True,True,Just cert) -> either (throwIO . userError) pure $ pgTlsValidate TlsValidateFull cert
      (True,True,Nothing) -> throwIO $ userError "Need to pass the root certificate on the PGTLS_ROOTCERT environment variable to validate FQHN"
      (True,False,Just cert) -> either (throwIO . userError) pure $ pgTlsValidate TlsValidateCA cert
#endif
  pgDBDebug <- isJust <$> lookupEnv "PG_DEBUG"
  pure $ defaultPGDatabase
    { pgDBName = "templatepg"
    , pgDBUser = "templatepg"
    , pgDBParams = [("TimeZone", "UTC")]
    , pgDBDebug
#ifdef HAVE_TLS
    , pgDBTLS
#endif
#ifndef mingw32_HOST_OS
    , pgDBAddr
#endif
    }
{-# NOINLINE db #-}
