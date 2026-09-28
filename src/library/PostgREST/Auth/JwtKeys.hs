{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

-- |
-- Module      : PostgREST.Auth.JwtKeys
-- Description : The keys JWTs are verified with.
--
-- The JWT cache verifies tokens with the keys of a key source rather than
-- with a fixed key set, so the keys can come from elsewhere than jwt-secret.
-- With jwt-oidc-discovery, they also come from the jwt-iss issuer, which
-- publishes them through OpenID Connect discovery.
module PostgREST.Auth.JwtKeys
  ( JwtKeys
  , KeysManager
  , newKeysManager
  , configJwtKeys
  , currentKeys
  , decodeWithKeys
  )
where

import GHC.Clock (getMonotonicTime)
import Jose.Jwk (Jwk, JwkSet (..), canDecodeJws)
import Jose.Jwt (JwtHeader (..), parseHeader)
import Protolude

import Data.Aeson qualified as JSON
import Data.ByteString qualified as BS
import Data.ByteString.Base64.URL qualified as B64URL
import Data.ByteString.Internal qualified as BS
import Network.HTTP.Client qualified as HC

import PostgREST.Auth.Jwt (parseAndDecodeClaims)
import PostgREST.Auth.OidcDiscovery (fetchIssuerKeys, newDiscoveryManager)
import PostgREST.Auth.RemoteKeys (RemoteKeys, RemoteKeysEvent (..), fetchedKeys, getKeys, newRemoteKeys, refreshKeys)
import PostgREST.Config (AppConfig (..))
import PostgREST.Error (Error (..), JwtError (..))
import PostgREST.Observation (Observation (..), ObservationHandler)

-- | The keys to verify JWTs with
data JwtKeys = JwtKeys
  { -- | the keys of jwt-secret
    keysStatic :: Maybe JwkSet,
    -- | the keys of the issuer, with jwt-oidc-discovery
    keysIssuer :: Maybe (Text, RemoteKeys)
  }

-- | The connection manager the keys of all the issuers are fetched with, so
-- that their number doesn't grow with the number of issuers
newtype KeysManager = KeysManager (IO HC.Manager)

-- | A connection manager created on first use: creating one loads the
-- system's CA certificates, which isn't needed without jwt-oidc-discovery
newKeysManager :: IO KeysManager
newKeysManager = do
  manager <- newMVar Nothing
  pure . KeysManager . modifyMVar manager $ \case
    Just m -> pure (Just m, m)
    Nothing -> (\m -> (Just m, m)) <$> newDiscoveryManager 10

-- | The keys of a config, if JWTs can be verified with it. The keys of the
-- issuer of the current keys are kept when the issuer didn't change.
configJwtKeys :: KeysManager -> ObservationHandler -> Maybe JwtKeys -> AppConfig -> IO (Maybe JwtKeys)
configJwtKeys (KeysManager getManager) observer current AppConfig{configJWKS, configJwtIssuer, configJwtOidcDiscovery} = do
  issuerKeys <- case configJwtIssuer of
    Just issuer | configJwtOidcDiscovery -> case keysIssuer =<< current of
      Just (currentIssuer, remoteKeys) | currentIssuer == issuer -> pure $ Just (issuer, remoteKeys)
      _ -> Just . (issuer,) <$> newIssuerKeys issuer
    _ -> pure Nothing
  pure $
    if isNothing configJWKS && isNothing issuerKeys then
      Nothing
    else
      Just $ JwtKeys configJWKS issuerKeys
  where
    newIssuerKeys issuer =
      newRemoteKeys (onEvent issuer) getMonotonicTime (getManager >>= (`fetchIssuerKeys` issuer))

    onEvent issuer = \case
      KeysFetched (JwkSet keys) changed ->
        when changed . observer . JwtKeysFetchedObs issuer $ length keys
      KeysFetchFailed reason -> observer $ JwtKeysFetchFailedObs issuer reason

-- | The keys a JWT can currently be verified with, without fetching any
currentKeys :: JwtKeys -> IO JwkSet
currentKeys JwtKeys{keysStatic, keysIssuer} = do
  issuerKeys <- maybe (pure Nothing) (fetchedKeys . snd) keysIssuer
  pure . JwkSet $ foldMap keys keysStatic <> foldMap keys issuerKeys

-- | Verify a JWT and decode its claims; also returns the key that verified it
--
-- A JWT signed with a key the issuer keys don't have refreshes them first:
-- the issuer may have rotated its keys.
decodeWithKeys :: (MonadError Error m, MonadIO m) => JwtKeys -> ByteString -> m (JSON.Object, Maybe Jwk)
decodeWithKeys JwtKeys{keysStatic, keysIssuer} token = case keysIssuer of
  Nothing -> parseAndDecodeClaims (withStatic []) token
  Just (_, remoteKeys) -> do
    fetched <- liftIO $ getKeys remoteKeys
    issuerKeys <-
      if hasKeyFor . withStatic $ keysOf fetched then
        pure fetched
      else
        liftIO $ refreshKeys remoteKeys
    case issuerKeys of
      Left reason
        | not . hasKeyFor $ withStatic [] -> throwError . JwtErr $ JwtKeysUnavailable reason
      _ -> parseAndDecodeClaims (withStatic $ keysOf issuerKeys) token
  where
    withStatic = JwkSet . (maybe [] keys keysStatic <>)
    keysOf = either (const []) keys

    -- whether a key could verify the token; a token that is not a JWS is
    -- left to decoding to reject
    hasKeyFor (JwkSet ks) = maybe True (\header -> any (canDecodeJws header) ks) jwsHeader

    jwsHeader = case BS.split (BS.c2w '.') token of
      [header, _, _]
        | Right bytes <- B64URL.decodeUnpadded header,
          Right (JwsH jws) <- parseHeader bytes ->
            Just jws
      _ -> Nothing
