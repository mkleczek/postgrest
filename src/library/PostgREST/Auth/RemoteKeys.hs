{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : PostgREST.Auth.RemoteKeys
-- Description : JWT keys fetched from elsewhere, memoized and refreshed on demand.
--
-- The keys are fetched when the key source is created. They are used until
-- their time to live runs out, and then refreshed in the background while
-- requests keep using them; a JWT signed with a key they don't have (the
-- provider may have rotated its keys) refreshes them right away. When a
-- fetch fails, the previous keys are kept.
--
-- At most one fetch runs at a time, and fetches start at least
-- 'minFetchInterval' seconds apart, however many requests ask for one: a
-- flood of JWTs with unknown keys can't make PostgREST flood the provider.
-- There is no background thread; a fetch runs in a thread of its own only
-- while it runs.
module PostgREST.Auth.RemoteKeys
  ( RemoteKeys
  , RemoteKeysEvent (..)
  , newRemoteKeys
  , getKeys
  , fetchedKeys
  , refreshKeys
  , minFetchInterval
  , keysTtl
  )
where

import Control.Concurrent.STM (TMVar, TVar, newEmptyTMVar, newTVarIO, putTMVar, readTMVar, readTVar, readTVarIO, writeTVar)
import Jose.Jwk (JwkSet)
import Protolude
import System.Timeout (timeout)

-- | What happened to the keys, for observations
data RemoteKeysEvent
  = -- | Keys were fetched, and whether they differ from the previous ones
    KeysFetched JwkSet Bool
  | -- | A fetch failed; the previous keys, if any, are still used
    KeysFetchFailed Text

data Keys = Keys
  { keysSet :: JwkSet,
    keysExpireAt :: Double
  }

data RemoteKeys = RemoteKeys
  { -- | Fetches the keys and how long they may be cached for, in seconds
    rkFetch :: IO (Either Text (JwkSet, Maybe Int)),
    -- | Monotonic time in seconds
    rkClock :: IO Double,
    rkOnEvent :: RemoteKeysEvent -> IO (),
    rkKeys :: TVar (Maybe Keys),
    rkLastError :: TVar Text,
    rkLastAttempt :: TVar (Maybe Double),
    -- | Filled when the running fetch is done
    rkInFlight :: TVar (Maybe (TMVar ()))
  }

-- | Seconds between the starts of two fetches
minFetchInterval :: Double
minFetchInterval = 5

-- | Seconds the keys are used for before they are refreshed: the max-age of
-- the response, between one minute and a day, or five minutes without one.
--
-- >>> import Protolude
-- >>> keysTtl Nothing
-- 300.0
--
-- >>> keysTtl (Just 10)
-- 60.0
--
-- >>> keysTtl (Just 3600)
-- 3600.0
keysTtl :: Maybe Int -> Double
keysTtl = fromIntegral . max 60 . min 86400 . fromMaybe 300

-- | Seconds a fetch may take
fetchTimeout :: Int
fetchTimeout = 10

-- | Create a key source and start fetching its keys.
newRemoteKeys :: (RemoteKeysEvent -> IO ()) -> IO Double -> IO (Either Text (JwkSet, Maybe Int)) -> IO RemoteKeys
newRemoteKeys onEvent clock fetch = do
  remoteKeys <-
    RemoteKeys fetch clock onEvent
      <$> newTVarIO Nothing
      <*> newTVarIO "the keys have not been fetched yet"
      <*> newTVarIO Nothing
      <*> newTVarIO Nothing
  void $ startFetch remoteKeys
  pure remoteKeys

-- | The keys, waiting for them if none were fetched yet. Keys past their
-- time to live are returned while they are refreshed in the background.
getKeys :: RemoteKeys -> IO (Either Text JwkSet)
getKeys remoteKeys@RemoteKeys{..} = do
  now <- rkClock
  readTVarIO rkKeys >>= \case
    Just Keys{..}
      | now < keysExpireAt -> pure $ Right keysSet
      | otherwise -> startFetch remoteKeys $> Right keysSet
    Nothing -> refreshKeys remoteKeys

-- | The keys fetched last, if any, without fetching or waiting for them
fetchedKeys :: RemoteKeys -> IO (Maybe JwkSet)
fetchedKeys RemoteKeys{rkKeys} = fmap keysSet <$> readTVarIO rkKeys

-- | Fetch the keys again and wait for them, unless the last fetch started
-- less than 'minFetchInterval' ago; then the current keys are returned.
refreshKeys :: RemoteKeys -> IO (Either Text JwkSet)
refreshKeys remoteKeys@RemoteKeys{..} = do
  startFetch remoteKeys >>= traverse_ (void . timeout ((fetchTimeout + 1) * 1_000_000) . atomically . readTMVar)
  atomically $ readTVar rkKeys >>= maybe (Left <$> readTVar rkLastError) (pure . Right . keysSet)

-- | Start a fetch, unless one is running (then that one is returned) or the
-- last one started too recently (then there is nothing to wait for).
startFetch :: RemoteKeys -> IO (Maybe (TMVar ()))
startFetch remoteKeys@RemoteKeys{..} = do
  now <- rkClock
  (started, running) <-
    atomically $
      readTVar rkInFlight >>= \case
        Just done -> pure (False, Just done)
        Nothing -> do
          recent <- maybe False (\t -> now - t < minFetchInterval) <$> readTVar rkLastAttempt
          if recent then
            pure (False, Nothing)
          else do
            done <- newEmptyTMVar
            writeTVar rkInFlight $ Just done
            writeTVar rkLastAttempt $ Just now
            pure (True, Just done)
  -- unmasked, so the fetch can time out even when started from masked code
  when started $
    void $
      forkIOWithUnmask $
        \unmask -> unmask $ traverse_ (runFetch remoteKeys) running
  pure running

-- The fetch runs in its own thread, so a request that gives up waiting
-- (e.g. its client disconnected) doesn't cancel it for the others.
runFetch :: RemoteKeys -> TMVar () -> IO ()
runFetch RemoteKeys{..} done = do
  result <- try (timeout (fetchTimeout * 1_000_000) rkFetch)
  now <- rkClock
  event <- atomically $ do
    event <- case result of
      Left (err :: SomeException) -> failed $ show err
      Right Nothing -> failed "fetching the keys timed out"
      Right (Just (Left err)) -> failed err
      Right (Just (Right (keySet, maxAge))) -> do
        previous <- readTVar rkKeys
        writeTVar rkKeys . Just $ Keys keySet (now + keysTtl maxAge)
        pure . KeysFetched keySet $ (keysSet <$> previous) /= Just keySet
    writeTVar rkInFlight Nothing
    putTMVar done ()
    pure event
  rkOnEvent event
  where
    failed err = writeTVar rkLastError err $> KeysFetchFailed err
