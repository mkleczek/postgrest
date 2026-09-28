{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : PostgREST.Auth.OidcDiscovery
-- Description : Fetches the JWT signing keys of an OpenID Connect issuer.
--
-- An OpenID Connect provider publishes its metadata at
-- @<issuer>/.well-known/openid-configuration@ (OpenID Connect Discovery 1.0,
-- section 4). The metadata names the issuer, which must be identical to the
-- one the document was fetched for, and the jwks_uri where the provider
-- publishes the keys it signs tokens with.
module PostgREST.Auth.OidcDiscovery
  ( newDiscoveryManager
  , fetchIssuerKeys
  , discoveryUrl
  , isAllowedUrl
  , parseDiscoveryDocument
  , signingKeys
  , cacheMaxAge
  )
where

import Control.Monad.Except (liftEither)
import Data.Aeson ((.:))
import Data.Aeson.Types (parseEither)
import Data.List (lookup)
import Jose.Jwk (Jwk (..), JwkSet (..), KeyUse (..), jwkUse)
import Network.HTTP.Client.TLS (newTlsManagerWith, tlsManagerSettings)
import Network.HTTP.Types.Header (Header, hAccept, hCacheControl, hUserAgent)
import Network.HTTP.Types.Status (statusCode)
import Network.URI (URI (..), URIAuth (..), parseAbsoluteURI)
import Protolude

import Data.Aeson qualified as JSON
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Network.HTTP.Client qualified as HC

import PostgREST.Version (prettyVersion)

-- | A connection manager for the discovery requests, which time out after the given seconds
newDiscoveryManager :: Int -> IO HC.Manager
newDiscoveryManager timeoutSeconds =
  newTlsManagerWith tlsManagerSettings{HC.managerResponseTimeout = HC.responseTimeoutMicro (timeoutSeconds * 1_000_000)}

-- | Fetch the signing keys of an issuer through its discovery document, with
-- the number of seconds the keys may be cached for, if the provider says so.
fetchIssuerKeys :: HC.Manager -> Text -> IO (Either Text (JwkSet, Maybe Int))
fetchIssuerKeys manager issuer = runExceptT $ do
  (document, _) <- fetch $ discoveryUrl issuer
  jwksUri <- liftEither $ parseDiscoveryDocument issuer document
  (jwks, headers) <- fetch jwksUri
  keySet <- liftEither . first (\e -> "the key set at " <> jwksUri <> " is invalid: " <> T.pack e) $ JSON.eitherDecode jwks
  keys <- liftEither $ signingKeys keySet
  pure (keys, cacheMaxAge headers)
  where
    fetch :: Text -> ExceptT Text IO (LBS.ByteString, [Header])
    fetch url = do
      request <- liftEither . first (\(_ :: SomeException) -> "invalid url " <> url) . HC.parseRequest $ T.unpack url
      response <-
        liftIO . try . HC.withResponse (withHeaders request) manager $ \resp -> do
          -- read one byte more than allowed to detect oversized responses
          body <- HC.brReadSome (HC.responseBody resp) (maxResponseSize + 1)
          pure (statusCode $ HC.responseStatus resp, HC.responseHeaders resp, body)
      case response of
        Left err -> throwError $ "requesting " <> url <> " failed: " <> describe err
        Right (st, headers, body)
          | st /= 200 -> throwError $ url <> " responded with status " <> show st
          | LBS.length body > fromIntegral maxResponseSize -> throwError $ "the response of " <> url <> " is too large"
          | otherwise -> pure (body, headers)

    withHeaders request =
      request
        { HC.requestHeaders = [(hAccept, "application/json"), (hUserAgent, "PostgREST " <> prettyVersion)],
          -- a redirect could lead anywhere, e.g. to a plain http url
          HC.redirectCount = 0
        }

    describe = \case
      HC.HttpExceptionRequest _ content -> show content
      HC.InvalidUrlException _ reason -> T.pack reason

    maxResponseSize = 1_048_576

-- | Where the discovery document of an issuer is.
--
-- >>> discoveryUrl "https://auth.example.com/realms/app"
-- "https://auth.example.com/realms/app/.well-known/openid-configuration"
--
-- >>> discoveryUrl "https://auth.example.com/"
-- "https://auth.example.com/.well-known/openid-configuration"
discoveryUrl :: Text -> Text
discoveryUrl issuer = T.dropWhileEnd (== '/') issuer <> "/.well-known/openid-configuration"

-- | Whether keys may be fetched from an url: only over https, except from
-- the local host.
--
-- >>> isAllowedUrl "https://auth.example.com/jwks"
-- True
--
-- >>> isAllowedUrl "http://auth.example.com/jwks"
-- False
--
-- >>> isAllowedUrl "http://localhost:9999/jwks"
-- True
--
-- >>> isAllowedUrl "http://127.0.0.1/jwks"
-- True
--
-- >>> isAllowedUrl "auth.example.com"
-- False
isAllowedUrl :: Text -> Bool
isAllowedUrl url = case parseAbsoluteURI $ T.unpack url of
  Just URI{uriScheme = "https:", uriAuthority = Just _} -> True
  Just URI{uriScheme = "http:", uriAuthority = Just URIAuth{uriRegName}} -> uriRegName `elem` ["localhost", "127.0.0.1", "[::1]"]
  _ -> False

-- | The jwks_uri of a discovery document, which must be for the given issuer.
--
-- >>> parseDiscoveryDocument "https://auth.example.com" "{\"issuer\": \"https://auth.example.com\", \"jwks_uri\": \"https://auth.example.com/jwks\"}"
-- Right "https://auth.example.com/jwks"
--
-- >>> parseDiscoveryDocument "https://auth.example.com" "{\"issuer\": \"https://auth.example.com/\", \"jwks_uri\": \"https://auth.example.com/jwks\"}"
-- Left "the discovery document is for issuer https://auth.example.com/"
--
-- >>> parseDiscoveryDocument "https://auth.example.com" "{\"issuer\": \"https://auth.example.com\", \"jwks_uri\": \"http://auth.example.com/jwks\"}"
-- Left "the jwks_uri http://auth.example.com/jwks is not an https url"
--
-- >>> parseDiscoveryDocument "https://auth.example.com" "{\"issuer\": \"https://auth.example.com\"}"
-- Left "the discovery document is invalid: Error in $: key \"jwks_uri\" not found"
parseDiscoveryDocument :: Text -> LBS.ByteString -> Either Text Text
parseDiscoveryDocument issuer document = do
  (documentIssuer, jwksUri) <-
    first (("the discovery document is invalid: " <>) . T.pack) $
      JSON.eitherDecode document >>= parseEither (JSON.withObject "discovery document" $ \o -> (,) <$> o .: "issuer" <*> o .: "jwks_uri")
  unless (documentIssuer == issuer) . Left $ "the discovery document is for issuer " <> documentIssuer
  unless (isAllowedUrl jwksUri) . Left $ "the jwks_uri " <> jwksUri <> " is not an https url"
  pure jwksUri

-- | The public signing keys of a key set; the other keys (private,
-- symmetric, encryption and unsupported keys) are ignored.
signingKeys :: JwkSet -> Either Text JwkSet
signingKeys (JwkSet keys) = case filter isSigningKey keys of
  [] -> Left "the key set has no public signing keys"
  signing -> Right $ JwkSet signing
  where
    isSigningKey key = isPublic key && jwkUse key /= Just Enc
    isPublic = \case
      RsaPublicJwk{} -> True
      EcPublicJwk{} -> True
      Ed25519PublicJwk{} -> True
      Ed448PublicJwk{} -> True
      _ -> False

-- | The max-age of a Cache-Control header, in seconds.
--
-- >>> cacheMaxAge [("Cache-Control", "public, max-age=3600, must-revalidate")]
-- Just 3600
--
-- >>> cacheMaxAge [("Cache-Control", "no-cache")]
-- Nothing
--
-- >>> cacheMaxAge []
-- Nothing
cacheMaxAge :: [Header] -> Maybe Int
cacheMaxAge headers = do
  value <- lookup hCacheControl headers
  directive <- find ("max-age=" `BS.isPrefixOf`) $ BS.strip <$> BS.split ',' value
  (seconds, rest) <- BS.readInt $ BS.drop (BS.length "max-age=") directive
  guard $ BS.null rest && seconds >= 0
  pure seconds
