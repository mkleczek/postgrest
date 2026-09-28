{-# LANGUAGE LambdaCase #-}

module Unit.RemoteKeysSpec (spec) where

import Control.Concurrent.Async (forConcurrently)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Protolude
import System.IO.Error (userError)
import System.Timeout (timeout)
import Test.Hspec

import Jose.Jwk qualified as JWT
import Jose.Jwt qualified as JWT

import PostgREST.Auth.RemoteKeys

data Harness = Harness
  { hKeys :: RemoteKeys,
    hClock :: IORef Double,
    hFetches :: IORef Int,
    hEvents :: Chan RemoteKeysEvent
  }

spec :: Spec
spec = describe "Remote JWT keys" $ do
  it "fetches the keys when created and uses them until they expire" $
    withRemoteKeys (const . pure $ Right (keys1, Nothing)) $ \h@Harness{hKeys} -> do
      fetched h `shouldReturn` (keys1, True)
      replicateM_ 3 $ getKeys hKeys `shouldReturn` Right keys1
      fetchedKeys hKeys `shouldReturn` Just keys1
      fetches h `shouldReturn` 1

  it "refreshes expired keys in the background and uses the old ones meanwhile" $
    withRemoteKeys (\n -> pure $ Right (if n == 1 then keys1 else keys2, Nothing)) $ \h@Harness{hKeys} -> do
      void $ fetched h
      advance h $ keysTtl Nothing
      getKeys hKeys `shouldReturn` Right keys1
      fetched h `shouldReturn` (keys2, True)
      getKeys hKeys `shouldReturn` Right keys2
      fetches h `shouldReturn` 2

  it "uses the keys for their max-age" $
    withRemoteKeys (const . pure $ Right (keys1, Just 3600)) $ \h@Harness{hKeys} -> do
      void $ fetched h
      advance h $ keysTtl Nothing
      getKeys hKeys `shouldReturn` Right keys1
      fetches h `shouldReturn` 1
      advance h 3600
      getKeys hKeys `shouldReturn` Right keys1
      void $ fetched h
      fetches h `shouldReturn` 2

  it "tells the fetched keys without waiting for a fetch" $ do
    gate <- newEmptyMVar
    withRemoteKeys (const $ readMVar gate $> Right (keys1, Nothing)) $ \Harness{hKeys} -> do
      fetchedKeys hKeys `shouldReturn` Nothing
      putMVar gate ()

  it "shares a running fetch between the requests waiting for keys" $ do
    gate <- newEmptyMVar
    withRemoteKeys (const $ readMVar gate $> Right (keys1, Nothing)) $ \h@Harness{hKeys} -> do
      results <- withAsync (forConcurrently [1 .. 20 :: Int] . const $ getKeys hKeys) $ \waiting -> do
        threadDelay 100_000
        putMVar gate ()
        wait waiting
      results `shouldBe` replicate 20 (Right keys1)
      fetches h `shouldReturn` 1

  it "refreshes the keys on request at most once per interval" $
    withRemoteKeys (\n -> pure $ Right (if n == 1 then keys1 else keys2, Nothing)) $ \h@Harness{hKeys} -> do
      void $ fetched h
      refreshKeys hKeys `shouldReturn` Right keys1
      fetches h `shouldReturn` 1
      advance h minFetchInterval
      refreshKeys hKeys `shouldReturn` Right keys2
      fetches h `shouldReturn` 2

  it "keeps the keys when a refresh fails" $
    withRemoteKeys (\n -> pure $ if n == 1 then Right (keys1, Nothing) else Left "the provider is down") $ \h@Harness{hKeys} -> do
      void $ fetched h
      advance h $ keysTtl Nothing
      refreshKeys hKeys `shouldReturn` Right keys1
      nextEvent h >>= \case
        KeysFetchFailed err -> err `shouldBe` "the provider is down"
        KeysFetched{} -> expectationFailure "expected the refresh to fail"
      getKeys hKeys `shouldReturn` Right keys1

  it "reports why there are no keys until a fetch succeeds" $
    withRemoteKeys (\n -> pure $ if n == 1 then Left "the provider is down" else Right (keys1, Nothing)) $ \h@Harness{hKeys} -> do
      void $ nextEvent h
      -- the failed fetch started just now, so it's not retried yet
      getKeys hKeys `shouldReturn` Left "the provider is down"
      fetches h `shouldReturn` 1
      advance h minFetchInterval
      getKeys hKeys `shouldReturn` Right keys1

  it "reports a fetch that fails with an exception" $
    withRemoteKeys (const $ throwIO (userError "boom")) $ \h@Harness{hKeys} -> do
      nextEvent h >>= \case
        KeysFetchFailed err -> err `shouldBe` "user error (boom)"
        KeysFetched{} -> expectationFailure "expected the fetch to fail"
      getKeys hKeys `shouldReturn` Left "user error (boom)"
  where
    keys1 = JWT.JwkSet [JWT.SymmetricJwk "the first secret with 32 characters" (Just $ JWT.KeyId "k1") Nothing Nothing]
    keys2 = JWT.JwkSet [JWT.SymmetricJwk "the second secret with 32 characters" (Just $ JWT.KeyId "k2") Nothing Nothing]

    fetches = readIORef . hFetches
    advance h seconds = modifyIORef' (hClock h) (+ seconds)

    nextEvent h =
      timeout 5_000_000 (readChan $ hEvents h) >>= \case
        Just event -> pure event
        Nothing -> expectationFailure "no fetch finished" $> panic "unreachable"

    fetched h =
      nextEvent h >>= \case
        KeysFetched keySet changed -> pure (keySet, changed)
        KeysFetchFailed err -> expectationFailure (toS err) $> panic "unreachable"

-- | A key source whose nth fetch returns the given result, on a fake clock
withRemoteKeys :: (Int -> IO (Either Text (JWT.JwkSet, Maybe Int))) -> (Harness -> IO a) -> IO a
withRemoteKeys respond test = do
  clock <- newIORef 0
  fetchCount <- newIORef 0
  events <- newChan
  let fetch = atomicModifyIORef' fetchCount (\n -> (n + 1, n + 1)) >>= respond
  remoteKeys <- newRemoteKeys (writeChan events) (readIORef clock) fetch
  test $ Harness remoteKeys clock fetchCount events
