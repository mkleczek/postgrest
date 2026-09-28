{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : PostgREST.Auth.JwtCache
-- Description : PostgREST JWT validation results Cache.
--
-- This module provides functions to deal with the JWT cache.
module PostgREST.Auth.JwtCache
  ( init
  , update
  , JwtCacheState
  , lookupJwtCache
  )
where

import Control.Concurrent.STM (newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Concurrent.STM.TVar (TVar)
import Control.Monad.Error.Class (liftEither)
import Data.ByteString hiding (all, elem, init)
import Data.IORef
  ( IORef
  , newIORef
  , readIORef
  , writeIORef
  )
import Jose.Jwk (Jwk, JwkSet (..))
import Protolude

import Data.Aeson qualified as JSON

import PostgREST.Auth.JwtKeys (JwtKeys, KeysManager, configJwtKeys, currentKeys, decodeWithKeys, newKeysManager)
import PostgREST.Cache.Sieve (Discard (..))
import PostgREST.Config (AppConfig (..))
import PostgREST.Error (Error (..), JwtError (JwtSecretMissing))
import PostgREST.Observation
  ( Observation (JwtCacheEviction, JwtCacheLookup)
  , ObservationHandler
  )

import PostgREST.Cache.Sieve qualified as SC

data JwtCacheState = JwtCacheState KeysManager ObservationHandler (IORef JwtCache)

-- |
-- Jwt caching can have three different configurations:
-- * missing JWT Key (no caching and throw error when JWT token present in the request)
-- * JWT cache turned off
-- * JWT cache turned on
--
-- All three options are represented by JwtCache data type.
--
-- Handling of reconfiguration is centralized in this module.
data JwtCache
  = JwtNoJwks
  | JwtNoCache JwtKeys
  | JwtCache (TVar JwtKeys) (TVar Int) (SC.Cache (ExceptT Error IO) ByteString (JSON.Object, Maybe Jwk))

decode :: (MonadError Error m, MonadIO m) => JwtCache -> ByteString -> m JSON.Object
decode JwtNoJwks = const $ throwError (JwtErr JwtSecretMissing)
decode (JwtNoCache key) = fmap fst . decodeWithKeys key
decode (JwtCache _ _ c) = fmap fst . (liftIO . runExceptT . SC.cached c >=> liftEither)

-- | Reconfigure JWT caching and update JwtCacheState accordingly
update :: JwtCacheState -> AppConfig -> IO ()
update (JwtCacheState keysManager observationHandler jwtCacheState) config@AppConfig{configJwtCacheMaxEntries} = do
  jwtKeys <- readIORef jwtCacheState >>= cacheKeys >>= \current -> configJwtKeys keysManager observationHandler current config
  let reinitialize =
        newJwtCache jwtKeys config observationHandler
          >>= writeIORef jwtCacheState
  readIORef jwtCacheState >>= \case
    (JwtCache decodingKey maxSize _) ->
      if isNothing jwtKeys || configJwtCacheMaxEntries <= 0 then
        -- reinitialize if key removed or cache disabled
        reinitialize
      else
        -- key or max size changed - set them and let the cache shrink itself if necessary
        -- (cached JWTs verified with a key that is gone are verified again)
        atomically $ traverse_ (writeTVar decodingKey) jwtKeys *> writeTVar maxSize configJwtCacheMaxEntries
    _ -> reinitialize

init :: AppConfig -> ObservationHandler -> IO JwtCacheState
init config observationHandler = do
  keysManager <- newKeysManager
  jwtKeys <- configJwtKeys keysManager observationHandler Nothing config
  JwtCacheState keysManager observationHandler <$> (newJwtCache jwtKeys config observationHandler >>= newIORef)

-- | The keys of the JWT cache, if any
cacheKeys :: JwtCache -> IO (Maybe JwtKeys)
cacheKeys = \case
  JwtNoJwks -> pure Nothing
  JwtNoCache jwtKeys -> pure $ Just jwtKeys
  JwtCache jwtKeys _ _ -> Just <$> readTVarIO jwtKeys

-- | Initialize JwtCacheState
newJwtCache :: Maybe JwtKeys -> AppConfig -> ObservationHandler -> IO JwtCache
newJwtCache jwtKeys AppConfig{configJwtCacheMaxEntries} observationHandler = do
  maybe (pure JwtNoJwks) initCache jwtKeys
  where
    initCache key = if configJwtCacheMaxEntries <= 0 then pure (JwtNoCache key) else createCache key configJwtCacheMaxEntries

    createCache key maxSize = do
      maxSizeTVar <- newTVarIO maxSize
      keyTVar <- newTVarIO key
      JwtCache keyTVar maxSizeTVar
        <$> notCachingErrors (readTVar maxSizeTVar) keyTVar

    notCachingErrors :: STM Int -> TVar JwtKeys -> IO (SC.Cache (ExceptT Error IO) ByteString (JSON.Object, Maybe Jwk))
    notCachingErrors maxSize key =
      SC.cacheIO
        ( SC.CacheConfig
            maxSize
            copy
            (\token -> liftIO (readTVarIO key) >>= (`decodeWithKeys` token))
            (lift . observationHandler . JwtCacheLookup) -- lookup metrics
            (const . const $ lift $ observationHandler JwtCacheEviction) -- evictions metrics
            -- a JWT verified with a key that is not a current key anymore is verified again
            (const . liftIO $ (\current (_, verifiedWith) -> pure $ if maybe False (`elem` keys current) verifiedWith then Nothing else Just (Refresh pass)) <$> (readTVarIO key >>= currentKeys))
        )

lookupJwtCache :: (MonadError Error m, MonadIO m) => JwtCacheState -> ByteString -> m JSON.Object
lookupJwtCache (JwtCacheState _ _ cacheState) k = liftIO (readIORef cacheState) >>= (`decode` k)
