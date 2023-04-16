<<<<<<< HEAD
{-# LANGUAGE RecordWildCards #-}

module PostgREST.AppState (
  AppState,
  destroy,
  flushPool,
  getConfig,
  getSchemaCache,
  getIsListenerOn,
  getMainThreadId,
  getPgVersion,
  getRetryNextIn,
  getTime,
  getWorkerSem,
  init,
  initWithPool,
  logWithZTime,
  logPgrstError,
  putConfig,
  putSchemaCache,
  putIsListenerOn,
  putPgVersion,
  putRetryNextIn,
  signalListener,
  usePool,
  waitListener,
  debounceLogAcquisitionTimeout,
) where
=======
{-# LANGUAGE AllowAmbiguousTypes #-}
module PostgREST.AppState
  ( AppState
  , destroy
  , flushPool
  , getConfig
  , getSchemaCache
  , getIsListenerOn
  , getMainThreadId
  , getPgVersion
  , getRetryNextIn
  , getTime
  , getWorkerSem
  , init
  , initWithPool
  , logWithZTime
  , logPgrstError
  , putConfig
  , putSchemaCache
  , putIsListenerOn
  , putPgVersion
  , putRetryNextIn
  , signalListener
  , usePool
  , waitListener
  , debounceLogAcquisitionTimeout
  , application
  ) where
>>>>>>> eff

import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as T
import qualified Hasql.Pool as SQL
import qualified Hasql.Session as SQL
import qualified PostgREST.Error as Error

<<<<<<< HEAD
import Control.AutoUpdate (
  defaultUpdateSettings,
  mkAutoUpdate,
  updateAction,
 )
import Control.Debounce
import Data.IORef (
  IORef,
  atomicWriteIORef,
  newIORef,
  readIORef,
 )
import Data.Time (
  ZonedTime,
  defaultTimeLocale,
  formatTime,
  getZonedTime,
 )
import Data.Time.Clock (UTCTime, getCurrentTime)
=======
import qualified Control.AutoUpdate as CAU
import Data.IORef         (IORef, writeIORef)
import Data.Time          (ZonedTime, defaultTimeLocale, formatTime,
                           getZonedTime)
import Data.Time.Clock    (UTCTime, getCurrentTime)
>>>>>>> eff

import PostgREST.Config (AppConfig (..))
import PostgREST.Config.PgVersion (PgVersion (..), minimumPgVersion)
import PostgREST.SchemaCache (SchemaCache)

<<<<<<< HEAD
import qualified Hasql.Api.Eff.Session.Legacy as L
import qualified Hasql.Api.Eff.Session.Run as R
import Protolude

data AppState = AppState
  { statePool :: SQL.Pool
  -- ^ Database connection pool
  , statePgVersion :: IORef PgVersion
  -- ^ Database server version, will be updated by the connectionWorker
  , stateSchemaCache :: IORef (Maybe SchemaCache)
  -- ^ No schema cache at the start. Will be filled in by the connectionWorker
  , stateWorkerSem :: MVar ()
  -- ^ Binary semaphore to make sure just one connectionWorker can run at a time
  , stateListener :: MVar ()
  -- ^ Binary semaphore used to sync the listener(NOTIFY reload) with the connectionWorker.
  , stateIsListenerOn :: IORef Bool
  -- ^ State of the LISTEN channel, used for the admin server checks
  , stateConf :: IORef AppConfig
  -- ^ Config that can change at runtime
  , stateGetTime :: IO UTCTime
  -- ^ Time used for verifying JWT expiration
  , stateGetZTime :: IO ZonedTime
  -- ^ Time with time zone used for worker logs
  , stateMainThreadId :: ThreadId
  -- ^ Used for killing the main thread in case a subthread fails
  , stateRetryNextIn :: IORef Int
  -- ^ Keeps track of when the next retry for connecting to database is scheduled
  , debounceLogAcquisitionTimeout :: IO ()
  -- ^ Logs a pool error with a debounce
=======
import Protolude hiding (IO, newEmptyMVar, takeMVar, tryPutMVar, myThreadId)
import qualified Protolude as P
import Hasql.Session
    ( QueryError, toEff )
import Effectful (IOE, Eff, (:>), inject)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Api.Session (runSessionWithConnectionReader)
import Hasql.Api.Eff.WithResource (runReaderWithResource)
import qualified Hasql.Connection as S
import OpenTelemetry.Trace (getGlobalTracerProvider, shutdownTracerProvider)
import qualified Network.Wai as Wai
import Network.Wai (responseLBS)
import Network.HTTP.Types.Status (status503)
import qualified Data.IORef as DI
import Control.AutoUpdate (UpdateSettings (..), defaultUpdateSettings)
import qualified Effectful as Eff
import qualified Control.Debounce as CAU
import Control.Debounce (DebounceSettings(..), defaultDebounceSettings, leadingEdge)
import qualified Effectful.Reader.Static as Eff
import qualified Effectful.Error.Static as Eff
import PostgREST.Eff (DelayedRetry (..))
import Hasql.Pool.Eff (runPoolHandler')
import PostgREST.OpenTelemetry (withTracer)

type IO a = Eff '[IOE] a

runEff a = a
newIORef = liftIO . DI.newIORef
newEmptyMVar = liftIO P.newEmptyMVar
readIORef = liftIO . DI.readIORef
atomicWriteIORef r = liftIO . DI.atomicWriteIORef r
takeMVar = liftIO . P.takeMVar
tryPutMVar v = liftIO . P.tryPutMVar v
mkAutoUpdate s = (liftIO . CAU.mkAutoUpdate) s <&> liftIO
mkDebounce s = (liftIO . CAU.mkDebounce) s <&> liftIO
myThreadId = liftIO P.myThreadId

data AppHandlers = AppHandlers
  -- the actual Application - dynamically reloaded
  { waiApplication :: Wai.Application
  -- handler for database access - dynamically reloaded
  , appUsePool  :: forall a. SQL.Session a -> IO (Either SQL.UsageError a)
  , appReleasePool :: IO ()
  }

data AppState = AppState
  -- | Database connection pool
  { --statePool                     :: SQL.Pool
  -- | Database server version, will be updated by the connectionWorker
   statePgVersion                :: IORef PgVersion
  -- | No schema cache at the start. Will be filled in by the connectionWorker
  , stateSchemaCache              :: IORef (Maybe SchemaCache)
  -- | Binary semaphore to make sure just one connectionWorker can run at a time
  , stateWorkerSem                :: MVar ()
  -- | Binary semaphore used to sync the listener(NOTIFY reload) with the connectionWorker.
  , stateListener                 :: MVar ()
  -- | State of the LISTEN channel, used for the admin server checks
  , stateIsListenerOn             :: IORef Bool
  -- | Config that can change at runtime
  , stateConf                     :: IORef AppConfig
  -- | Time used for verifying JWT expiration
  , stateGetTime                  :: IO UTCTime
  -- | Time with time zone used for worker logs
  , stateGetZTime                 :: IO ZonedTime
  -- | Used for killing the main thread in case a subthread fails
  , stateMainThreadId             :: ThreadId
  -- | Keeps track of when the next retry for connecting to database is scheduled
  , stateRetryNextIn              :: IORef Int
  -- | Logs a pool error with a debounce
  , debounceLogAcquisitionTimeout :: IO ()
  -- | Open Telemetry Tracer
  , appHandlers                   :: IORef AppHandlers
>>>>>>> eff
  }

init :: AppConfig -> IO AppState
init conf = do
  pool <- initPool conf
  initWithPool pool conf

responseUnavailable :: Wai.Response
responseUnavailable = responseLBS status503 [] mempty

initWithPool :: SQL.Pool -> AppConfig -> IO AppState
initWithPool pool conf = do
<<<<<<< HEAD
  appState <-
    AppState pool
      <$> newIORef minimumPgVersion -- assume we're in a supported version when starting, this will be corrected on a later step
      <*> newIORef Nothing
      <*> newEmptyMVar
      <*> newEmptyMVar
      <*> newIORef False
      <*> newIORef conf
      <*> mkAutoUpdate defaultUpdateSettings{updateAction = getCurrentTime}
      <*> mkAutoUpdate defaultUpdateSettings{updateAction = getZonedTime}
      <*> myThreadId
      <*> newIORef 0
      <*> pure (pure ())

  deb <-
    let oneSecond = 1000000
     in mkDebounce
          defaultDebounceSettings
            { debounceAction = logPgrstError appState SQL.AcquisitionTimeoutUsageError
            , debounceFreq = 5 * oneSecond
            , debounceEdge = leadingEdge -- logs at the start and the end
            }
=======
  appState <- AppState -- pool
    <$> newIORef minimumPgVersion -- assume we're in a supported version when starting, this will be corrected on a later step
    <*> newIORef Nothing
    <*> newEmptyMVar
    <*> newEmptyMVar
    <*> newIORef False
    <*> newIORef conf
    <*> mkAutoUpdate defaultUpdateSettings { updateAction = getCurrentTime }
    <*> mkAutoUpdate defaultUpdateSettings { updateAction = getZonedTime }
    <*> myThreadId
    <*> newIORef 0
    <*> pure (pure ())
    <*> newIORef (AppHandlers (\_ respond -> respond responseUnavailable) (simpleUsePool pool) (liftIO $ SQL.release pool))

  deb <-
    let oneSecond = 1000000 in
    mkDebounce defaultDebounceSettings
       { debounceAction = Eff.runEff $ logPgrstError appState SQL.AcquisitionTimeoutUsageError
       , debounceFreq = 5*oneSecond
       , debounceEdge = leadingEdge -- logs at the start and the end
       }
>>>>>>> eff

  return appState{debounceLogAcquisitionTimeout = deb}

destroy :: AppState -> IO ()
destroy appstate = do
  destroyPool appstate
  getGlobalTracerProvider >>= shutdownTracerProvider

initPool :: AppConfig -> IO SQL.Pool
initPool AppConfig{..} =
<<<<<<< HEAD
  SQL.acquire configDbPoolSize timeoutMicroseconds $ toUtf8 configDbUri
 where
  timeoutMicroseconds = (* oneSecond) <$> configDbPoolAcquisitionTimeout
  oneSecond = 1000000
=======
  liftIO $ SQL.acquire configDbPoolSize timeoutMicroseconds $ toUtf8 configDbUri
  where
    timeoutMicroseconds = (* oneSecond) <$> configDbPoolAcquisitionTimeout
    oneSecond = 1000000
>>>>>>> eff

simpleUsePool :: SQL.Pool -> SQL.Session a -> IO (Either SQL.UsageError a)
simpleUsePool pool = runEff -- run IOE effect in IO monad
  . runWithPoolEither pool-- pooled WithConnection implementation - it wraps QueryError and handles Error UsageError
  . runReaderWithResource @S.Connection @'[Eff.Error QueryError, IOE] -- WithConnection to Reader Connection
  . runSessionWithConnectionReader -- @'[Eff.Reader S.Connection, Eff.Error QueryError, IOE] -- SqlEff (runs the actual SQL session)
  . toEff  -- get Eff from Session
  where
    runWithPoolEither pool = runErrorNoCallStack . runPoolHandler' pool inject Eff.throwError


-- | Run an action with a database connection.
<<<<<<< HEAD
usePool :: AppState -> SQL.Session a -> IO (Either SQL.UsageError a)
usePool AppState{..} session = SQL.use statePool $ R.Session $ \c -> L.run session c
=======
tracingUsePool :: SQL.Pool -> SQL.Session a -> IO (Either SQL.UsageError a)
tracingUsePool pool = runEff -- run IOE effect in IO monad
  . runWithPoolEither pool -- pooled WithConnection implementation - it wraps QueryError and handles Error UsageError
  . runReaderWithResource @S.Connection @'[Eff.Error QueryError, IOE] -- WithConnection to Reader Connection
  . runSessionWithConnectionReader -- SqlEff (runs the actual SQL session)
  . withTracer
  . toEff  -- get Eff from Session
  where
    runWithPoolEither pool = runErrorNoCallStack . runPoolHandler' pool inject Eff.throwError

usePool :: (Eff.Reader AppState :> es, IOE :> es) => SQL.Session a -> Eff es (Either SQL.UsageError a)
usePool session = Eff.ask >>= \AppState {..} -> do
  handlers <- liftIO $ DI.readIORef appHandlers
  inject $ appUsePool handlers session

application :: AppState -> IO Wai.Application
application AppState {..} = do
  handlers <- readIORef appHandlers
  pure $ waiApplication handlers
>>>>>>> eff

{- | Flush the connection pool so that any future use of the pool will
 use connections freshly established after this call.
-}
flushPool :: AppState -> IO ()
flushPool AppState{..} = readIORef appHandlers >>= appReleasePool

-- | Destroy the pool on shutdown.
destroyPool :: AppState -> IO ()
destroyPool AppState{..} = readIORef appHandlers >>= appReleasePool

getPgVersion :: (IOE :> es) => AppState -> Eff es PgVersion
getPgVersion = inject . readIORef . statePgVersion

putPgVersion :: AppState -> PgVersion -> IO ()
putPgVersion = atomicWriteIORef . statePgVersion

getSchemaCache :: (IOE :> es) => AppState -> Eff es (Maybe SchemaCache)
getSchemaCache = inject . readIORef . stateSchemaCache

putSchemaCache :: AppState -> Maybe SchemaCache -> IO ()
putSchemaCache appState = atomicWriteIORef (stateSchemaCache appState)

getWorkerSem :: AppState -> MVar ()
getWorkerSem = stateWorkerSem

putRetryNextIn :: AppState -> Int -> P.IO ()
putRetryNextIn = atomicWriteIORef . stateRetryNextIn

getConfig :: (IOE :> es) => AppState -> Eff es AppConfig
getConfig = inject . readIORef . stateConf

putConfig :: (IOE :> es) => AppState -> AppConfig -> Eff es ()
putConfig = atomicWriteIORef . stateConf

getTime :: (IOE :> es) => AppState -> Eff es UTCTime
getTime = inject . stateGetTime

-- | Log to stderr with local time
logWithZTime :: AppState -> Text -> IO ()
logWithZTime appState txt = do
  zTime <- stateGetZTime appState
  hPutStrLn stderr $ toS (formatTime defaultTimeLocale "%d/%b/%Y:%T %z: " zTime) <> txt

logPgrstError :: AppState -> SQL.UsageError -> IO ()
logPgrstError appState e = logWithZTime appState . T.decodeUtf8 . LBS.toStrict $ Error.errorPayload $ Error.PgError False e

getMainThreadId :: AppState -> ThreadId
getMainThreadId = stateMainThreadId

{- | As this IO action uses `takeMVar` internally, it will only return once
 `stateListener` has been set using `signalListener`. This is currently used
 to syncronize workers.
-}
waitListener :: AppState -> IO ()
waitListener = takeMVar . stateListener

-- tryPutMVar doesn't lock the thread. It should always succeed since
-- the connectionWorker is the only mvar producer.
signalListener :: AppState -> IO ()
signalListener appState = void $ tryPutMVar (stateListener appState) ()

getIsListenerOn :: AppState -> IO Bool
getIsListenerOn = readIORef . stateIsListenerOn

putIsListenerOn :: AppState -> Bool -> IO ()
putIsListenerOn = atomicWriteIORef . stateIsListenerOn

effApp :: Eff '[Eff.Reader Wai.Request, IOE] Wai.Response -> Wai.Application
effApp app req respond = do
  resp <- Eff.runEff . Eff.runReader req $ app
  respond resp

instance (Eff.Reader AppState :> es, IOE :> es) => DelayedRetry (Eff es) where
  getRetryNextIn = do
    appState <- Eff.ask
    inject $ readIORef $ stateRetryNextIn appState

reloadApplication :: (IOE :> es) => AppState -> Eff es ()
reloadApplication appState@AppState {..} = do
  handlers <- inject $ readIORef appHandlers
  liftIO $ writeIORef appHandlers $ handlers {waiApplication = effApp $ Eff.runReader appState $ pure responseUnavailable }
