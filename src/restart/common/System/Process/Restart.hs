module System.Process.Restart
  ( -- * Process runner
    HandoverMode
  , isStandalone
  , isReplacement
  , AppRun
  , Ready
  , runRestartable
  , runRestartableWithSIGHUP

    -- * Replacement process configuration
  , ReplacementConfig(..)
  , currentReplacementConfig

    -- * Errors
  , HandoverError
  ) where

import System.Process.Restart.Impl   (runRestartable, runRestartableWithSIGHUP)
import System.Process.Restart.Shared
