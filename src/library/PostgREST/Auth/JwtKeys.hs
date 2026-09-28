-- |
-- Module      : PostgREST.Auth.JwtKeys
-- Description : The keys JWTs are verified with.
--
-- The JWT cache verifies tokens with the keys of a key source rather than
-- with a fixed key set, so the keys can come from elsewhere than jwt-secret.
module PostgREST.Auth.JwtKeys
  ( JwtKeys
  , configJwtKeys
  , currentKeys
  , decodeWithKeys
  )
where

import Jose.Jwk (Jwk, JwkSet)
import Protolude

import Data.Aeson qualified as JSON

import PostgREST.Auth.Jwt (parseAndDecodeClaims)
import PostgREST.Config (AppConfig (..))
import PostgREST.Error (Error)

-- | The keys to verify JWTs with: the keys of jwt-secret
newtype JwtKeys = JwtKeys JwkSet

-- | The keys of a config, if JWTs can be verified with it
configJwtKeys :: AppConfig -> Maybe JwtKeys
configJwtKeys = fmap JwtKeys . configJWKS

-- | The keys a JWT can currently be verified with, without fetching any
currentKeys :: JwtKeys -> IO JwkSet
currentKeys (JwtKeys keys) = pure keys

-- | Verify a JWT and decode its claims; also returns the key that verified it
decodeWithKeys :: (MonadError Error m, MonadIO m) => JwtKeys -> ByteString -> m (JSON.Object, Maybe Jwk)
decodeWithKeys (JwtKeys keys) = parseAndDecodeClaims keys
