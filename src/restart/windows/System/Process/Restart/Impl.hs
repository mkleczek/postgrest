{-# LANGUAGE RankNTypes #-}

module System.Process.Restart.Impl
  ( runRestartable
  , runRestartableWithSIGHUP
  ) where

import System.Process.Restart.Shared

import Protolude

-- | Run an application without handover support on platforms where the
-- replacement protocol is unavailable.
runRestartable ::
  ReplacementConfig ->
  AppRun a ->
  IO a
runRestartable _ runApp =
  runApp (HandoverMode False) (const $ const $ pure Nothing)

-- | Run an application without SIGHUP handover support on platforms where the
-- replacement protocol is unavailable.
runRestartableWithSIGHUP ::
  ReplacementConfig ->
  (HandoverMode -> (forall b. IO b -> IO ()) -> IO a) ->
  IO a
runRestartableWithSIGHUP _ runApp =
  runApp (HandoverMode False) (const pass)
