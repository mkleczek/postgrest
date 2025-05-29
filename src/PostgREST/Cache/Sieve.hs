{-|
Module      : PostgREST.Cache.Sieve
Description : PostgREST cache implementation based on Sieve algorithm.

This module provides implementation of a mutable cache on Sieve algorithm.
-}
{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE GADTs           #-}
{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE PolyKinds       #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RecursiveDo     #-}
{-# LANGUAGE StrictData      #-}
{-# LANGUAGE TupleSections   #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use newtype instead of data" #-}

module PostgREST.Cache.Sieve (
      Cache
    , CacheConfig (..)
    , Discard (..)
    , alwaysValid
    , cache
    , cacheIO
    , cached
)
where

import           Control.Concurrent.STM
import           Data.Some
import qualified Focus                  as F
import           Protolude              hiding (elem, head)
import qualified StmHamt.SizedHamt      as SH
import Control.Monad.Fix (MonadFix)

data ListNode k v (b :: Bool) = ListNode {
        nextPtr        :: NodePtr k v,
        prevNextPtrPtr :: NodePtrPtr k v,
        elem           :: NodeElem k v b
    }

data NodeElem :: Type -> Type -> Bool -> Type where
    Head :: {
            entries          :: SH.SizedHamt (HamtEntry k v),
            finger           :: NodePtrPtr k v
        } -> NodeElem k v False
    Entry :: Hashable k => {
            visited :: TVar Bool,
            ekey :: k,
            entryValue :: Lazy v
        } -> NodeElem k v True

type HamtEntry k v = ListNode k v True
type AnyNode k v = Some (ListNode k v)
type NodePtr k v = TVar (AnyNode k v)
type NodePtrPtr k v = TVar (NodePtr k v)

data Discard m v = Refresh (m ()) | Invalid (m v)

data Cache m k v = (MonadIO m, MonadFix m, Hashable k) => Cache (ListNode k v False) (CacheConfig m k v)

data CacheConfig m k v = CacheConfig {
        maxSize          :: STM Int,
        load             :: k -> m v,
        requestListener  :: Bool -> m (),
        evictionListener :: k -> v -> m (),
        validator        :: m (k -> v -> Maybe (Discard m v))
}

alwaysValid :: Applicative m => m (k -> v -> Maybe (Discard m v))
alwaysValid = pure (const . const Nothing)

cacheIO :: (MonadIO m, MonadFix m, Hashable k) => CacheConfig m k v -> IO (Cache m k v)
cacheIO = atomically . cache

cache :: (MonadIO m, MonadFix m, Hashable k) => CacheConfig m k v -> STM (Cache m k v)
cache cacheConfig = mdo
    tail <- newTVar (Some head)
    entries <- SH.new
    finger <- newTVar tail
    head <- ListNode tail <$> newTVar tail <*> pure Head {..}
    pure $ Cache head cacheConfig

data Lazy a = Lazy {getLazy :: ~a}

cached :: Cache m k v -> k -> m v
cached (Cache head@ListNode{prevNextPtrPtr=neck, elem=Head{..}} CacheConfig{..}) k = mdo
    mbox <- whileNothing $ do
        (result, evicted) <- (liftIO . atomically) $ do
            (result, maybeEvicted) <- SH.focus (focus $ Lazy eresult) (ekey . elem) k entries
            maybe (pure (result, pure ())) (\Entry{ekey=evictedKey, entryValue} -> do
                SH.focus F.delete (ekey . elem) evictedKey entries
                pure (result, evictionListener evictedKey $ getLazy entryValue)) maybeEvicted
        evicted $> result
    eresult <- maybe
                (load k)
                (liftIO . evaluate . getLazy)
                mbox
    requestListener (isJust mbox)

    pure eresult

    where
        focus lazyResult = F.Focus
                    -- entry not found
                    -- check space and either
                    -- insert an entry and return (Just Nothing) to trigger loading of eresult
                    -- or return Nothing to retry and perform another eviction
                    (do
                        (hasSpace, evicted) <- evictionStep
                        if hasSpace then do
                            newEntry <- newLinkedEntry lazyResult
                            pure ((Just Nothing, evicted), F.Set newEntry)
                        else
                            pure ((Nothing, evicted), F.Leave)
                    )
                    -- entry found - mark it as visited and return (Just Just value to lazilly compute it)
                    (\ListNode{elem=Entry{..}} -> do
                        mark visited True
                        pure ((Just $ Just entryValue, Nothing), F.Leave))

        whileNothing f = f >>= maybe (whileNothing f) pure

        mark t b = whenM ((/= b) <$> readTVar t) (writeTVar t b)

        evictionStep = do
            currDiff <- liftA2 (-) (SH.size entries) (max 1 <$> maxSize)
            if currDiff >= 0 then do
                -- no space in the cache
                -- need to evict an entry
                (nextFinger, evictedKey) <- readTVar finger >>= evict
                writeTVar finger nextFinger
                -- return if enough space and evicted key if any
                pure (isJust evictedKey && currDiff == 0, evictedKey)
            else
                -- there is space in the cache
                pure (True, Nothing)

        evict :: TVar (Some (ListNode k v)) -> STM (NodePtr k v, Maybe (NodeElem k v True))
        evict = readTVar >=> \case
            (Some e@ListNode{nextPtr, prevNextPtrPtr, elem=elem@Entry{visited}}) -> do
                ifM (readTVar visited)

                    (writeTVar visited False $> (nextPtr, Nothing))

                    (unlinkEntry e *> fmap (, Just elem) (readTVar prevNextPtrPtr))
            -- skip head
            (Some ListNode{nextPtr, elem=Head{}}) -> evict nextPtr

        unlinkEntry :: HamtEntry k v -> STM ()
        unlinkEntry (ListNode{nextPtr, prevNextPtrPtr=currPrev}) = do
            nextEntry <- readTVar nextPtr
            withSome nextEntry $ \e -> do
                prevNextPtr <- readTVar currPrev
                writeTVar (prevNextPtrPtr e) prevNextPtr
                writeTVar prevNextPtr nextEntry

        newLinkedEntry v = do
            oldNeckNextPtr <- readTVar neck
            newNeckNextPtr <- newTVar (Some head)
            newNeck <- ListNode newNeckNextPtr <$>
                newTVar oldNeckNextPtr <*>
                (Entry <$> newTVar False <*> pure k <*> pure v)
            -- update pointers
            writeTVar oldNeckNextPtr (Some newNeck)
            writeTVar neck newNeckNextPtr
            -- return HAMT entry
            pure newNeck
