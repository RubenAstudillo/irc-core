{-# LANGUAGE OverloadedStrings #-}

-- | This module is responsible for creating 'Connection' values
-- for a particular server as specified by its 'ServerSettings'
module Connection
  ( -- * Settings
    ServerSettings(..)
  , ssHostName
  , ssPort
  , ssTls
  , ssTlsClientCert
  , ssTlsClientKey

  -- * Operations
  , connect
  , getRawIrcLine
  ) where

import Control.Lens
import Data.ByteString    (ByteString)
import Data.Default.Class (def)
import Data.Maybe         (fromMaybe)
import Data.Monoid        ((<>))
import Data.X509          (CertificateChain(..))
import Data.X509.CertificateStore (CertificateStore, makeCertificateStore)
import Data.X509.File     (readSignedObject, readKeyFile)
import Network.Connection
import Network.Socket     (PortNumber)
import Network.TLS
import Network.TLS.Extra  (ciphersuite_strong)
import System.X509        (getSystemCertificateStore)
import qualified Data.ByteString.Char8 as B8

import ServerSettings

-- | This behaves like 'connectionGetLine' but it strips off the @'\r'@
-- IRC calls for 512 byte packets  I rounded off to 1024.
getRawIrcLine :: Connection -> IO ByteString
getRawIrcLine h =
  do b <- connectionGetLine 1024 h
     return (if B8.null b then b else B8.init b)
        -- empty lines will still fail, just later and nicely

buildConnectionParams :: ServerSettings -> IO ConnectionParams
buildConnectionParams args =
  do useSecure <- if view ssTls args
                     then fmap Just (buildTlsSettings args)
                     else return Nothing

     let proxySettings = fmap (uncurry SockSettingsSimple)
                              (view ssSocksProxy args)

     return ConnectionParams
       { connectionHostname  = view ssHostName args
       , connectionPort      = ircPort args
       , connectionUseSecure = useSecure
       , connectionUseSocks  = proxySettings
       }

ircPort :: ServerSettings -> PortNumber
ircPort args =
  case view ssPort args of
    Just p -> fromIntegral p
    Nothing | view ssTls args -> 6697
            | otherwise       -> 6667

buildCertificateStore :: ServerSettings -> IO CertificateStore
buildCertificateStore args =
  do systemStore <- getSystemCertificateStore
     userCerts   <- traverse readSignedObject (view ssServerCerts args)
     let userStore = makeCertificateStore (concat userCerts)
     return (userStore <> systemStore)

buildTlsSettings :: ServerSettings -> IO TLSSettings
buildTlsSettings args =
  do store <- buildCertificateStore args

     let portString = B8.pack (show (view ssPort args))
         paramsClient = defaultParamsClient (view ssHostName args) portString
         validationCache
           | view ssTlsInsecure args = ValidationCache
                                         (\_ _ _ -> return ValidationCachePass)
                                         (\_ _ _ -> return ())
           | otherwise = exceptionValidationCache []

     return $ TLSSettings paramsClient
       { clientSupported = def
           { supportedCiphers           = ciphersuite_strong }

       , clientHooks = def
           { onCertificateRequest       = \_ -> loadClientCredentials args }

       , clientShared = def
           { sharedCAStore              = store
           , sharedValidationCache      = validationCache
           }
       }


loadClientCredentials :: ServerSettings -> IO (Maybe (CertificateChain, PrivKey))
loadClientCredentials args =
  case view ssTlsClientCert args of
    Nothing       -> return Nothing
    Just certPath ->
      do cert  <- readSignedObject certPath
         keys  <- readKeyFile (fromMaybe certPath (view ssTlsClientKey args))
         case keys of
           [key] -> return (Just (CertificateChain cert, key))
           []    -> fail "No private keys found"
           _     -> fail "Too many private keys found"

connect :: ServerSettings -> IO Connection
connect args = do
  connectionContext <- initConnectionContext
  connectionParams  <- buildConnectionParams args
  connectTo connectionContext connectionParams
