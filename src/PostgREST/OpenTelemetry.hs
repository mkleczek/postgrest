{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ImpredicativeTypes #-}

module PostgREST.OpenTelemetry (
    initOpenTelemetry,
    withTracer
) where

import Data.ByteString (ByteString)
import Effectful (Eff, IOE, (:>), MonadIO (liftIO))

import Data.Text (Text, unpack, pack)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Typeable (Typeable, typeOf)
import Effectful.Dispatch.Dynamic (interpose, localSeqUnlift, send)
import Effectful.Error.Static (prettyCallStack)
import qualified Effectful.Error.Static as E
import Effectful.Reader.Static (Reader, ask, runReader)
import Hasql.Api.Eff (SqlEff (..))
import Hasql.Statement (Statement (Statement))
import OpenTelemetry.Trace (Attribute, NewEvent (..), SpanArguments (..), SpanKind (..), ToAttribute (..), Tracer, addEvent, inSpan', setStatus, InstrumentationLibrary (..), TracerOptions (..), getGlobalTracerProvider, makeTracer, TracerProvider)
import qualified OpenTelemetry.Trace as OT
import Prelude
import Hasql.Api.Eff.WithResource (Connection)
import qualified Database.PostgreSQL.LibPQ as LibPQ
import Data.IP (IP(..))
import Protolude (catMaybes)
import OpenTelemetry.Resource ((.=?), (.=))
import Text.Read (readMaybe)
import Hasql.Connection (withLibPQConnection)
import qualified Data.ByteString.Char8 as C
import Hasql.Session (QueryError)
import qualified Data.Text.Encoding as TE
import PostgREST.Version (prettyVersion)

newtype ConnectionAttributes = ConnectionAttributes [(Text, Attribute)]

withTracer :: forall es a. (SqlEff ByteString Statement :> es, Reader Connection :> es, E.Error QueryError :> es, IOE :> es) => Eff es a -> Eff es a
withTracer eff = do
    tp <- getGlobalTracerProvider
    initOpenTelemetry tp eff


initOpenTelemetry :: forall es a. (SqlEff ByteString Statement :> es, Reader Connection :> es, E.Error QueryError :> es, IOE :> es) => TracerProvider -> Eff es a -> Eff es a
initOpenTelemetry tracerProvider eff = 
    let tracer =  makeTracer
                    tracerProvider
                    InstrumentationLibrary {libraryVersion= TE.decodeUtf8 prettyVersion, libraryName= T.pack "hs-opentelemetry-instrumentation-postgrest"}
                    TracerOptions {tracerSchema=Nothing}
    in
        connectionAttributes >>= \attrs -> traceSql @QueryError tracer attrs eff

traceSql :: forall ex es a. (Show ex, Typeable ex, E.Error ex :> es, IOE :> es, SqlEff ByteString Statement :> es) => Tracer -> ConnectionAttributes -> Eff es a -> Eff es a
traceSql tracer (ConnectionAttributes attrs) = interpose @(SqlEff ByteString Statement) $ \env e -> do
    let (query, attr) = case e of
            (SqlCommand sqlQuery) -> (\decoded -> (decoded, toAttribute decoded)) $ decodeUtf8 sqlQuery
            (SqlStatement _ (Statement sqlQuery _ _ _)) -> (\decoded -> (decoded, toAttribute decoded)) $ decodeUtf8 sqlQuery
    inSpan'
        tracer
        query
        (SpanArguments Client (("db.statement", attr) : attrs) [] Nothing)
        ( \otspan ->
            E.catchError @ex
                ( runReader otspan $ do
                    localSeqUnlift env $
                        \unlift -> unlift $ send e
                )
                ( \cs exc -> do
                    setStatus otspan $ OT.Error $ T.pack $ show exc
                    addEvent otspan $
                        NewEvent
                            { newEventName = "exception"
                            , newEventAttributes =
                                [ ("exception.type", toAttribute $ T.pack $ show $ typeOf exc)
                                , ("exception.message", toAttribute $ T.pack $ show exc)
                                , ("exception.stacktrace", toAttribute $ T.pack $ prettyCallStack cs)
                                ]
                            , newEventTimestamp = Nothing
                            }
                    E.throwError exc
                )
        )

connectionAttributes :: (Reader Connection :> es, IOE :> es) =>  Eff es ConnectionAttributes
connectionAttributes = do
    c <- ask
    (mDb, mUser, mHost, mPort) <- liftIO $ withLibPQConnection c $ \pqConn -> do
      (,,,)
        <$> LibPQ.db pqConn
        <*> LibPQ.user pqConn
        <*> LibPQ.host pqConn
        <*> LibPQ.port pqConn
    pure (ConnectionAttributes $
      ("db.system", toAttribute ("postgresql" :: Text))
        : catMaybes
          [ "db.user" .=? (decodeUtf8 <$> mUser)
          , "db.name" .=? (decodeUtf8 <$> mDb)
          , "net.peer.port"
              .=? ( do
                      port <- decodeUtf8 <$> mPort
                      (readMaybe $ unpack port) :: Maybe Int
                  )
          , case (readMaybe . C.unpack) =<< mHost of
              Nothing -> "net.peer.name" .=? (decodeUtf8 <$> mHost)
              Just (IPv4 ip4) -> "net.peer.ip" .= pack (show ip4)
              Just (IPv6 ip6) -> "net.peer.ip" .= pack (show ip6)
          ])

