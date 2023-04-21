{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ImpredicativeTypes #-}

module PostgREST.OpenTelemetry (
    withTracer
) where

import Data.ByteString (ByteString)
import Effectful (Eff, IOE, (:>), MonadIO (liftIO))

import Data.Text (Text, unpack, pack)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Typeable (Typeable, typeOf)
import Effectful.Dispatch.Dynamic (interpose, send)
import Effectful.Reader.Static (Reader, ask)
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
import Hasql.Api.Eff.Throws
import GHC.Exception (prettyCallStackLines)

newtype ConnectionAttributes = ConnectionAttributes [(Text, Attribute)]

withTracer :: forall es a. (SqlEff ByteString Statement :> es, Reader Connection :> es, Throws QueryError :> es, IOE :> es) => Eff es a -> Eff es a
withTracer eff = do
    tracerProvider <- getGlobalTracerProvider
    let tracer =  makeTracer
                    tracerProvider
                    InstrumentationLibrary {libraryVersion= TE.decodeUtf8 prettyVersion, libraryName= T.pack "hs-opentelemetry-instrumentation-postgrest"}
                    TracerOptions {tracerSchema=Nothing}
    attrs <- connectionAttributes
    traceSql @QueryError tracer attrs eff


traceSql :: forall ex es a. (Show ex, Typeable ex, Throws ex :> es, IOE :> es, SqlEff ByteString Statement :> es) => Tracer -> ConnectionAttributes -> Eff es a -> Eff es a
traceSql tracer (ConnectionAttributes attrs) = interpose @(SqlEff ByteString Statement) $ \_ e -> do
    let (query, attr, locale) = case e of
            (SqlCommand sqlQuery) -> (\decoded -> (decoded, toAttribute decoded, SqlCommand sqlQuery)) $ decodeUtf8 sqlQuery
            (SqlStatement params (Statement sqlQuery a b c)) -> (\decoded -> (decoded, toAttribute decoded, SqlStatement params (Statement sqlQuery a b c))) $ decodeUtf8 sqlQuery
    inSpan'
        tracer
        query
        (SpanArguments Client (("db.statement", attr) : attrs) [] Nothing)
        ( \otspan ->
            catchError @ex
                ( send @(SqlEff ByteString Statement) locale)
                ( \cs exc -> do
                    setStatus otspan $ OT.Error $ T.pack $ show exc
                    addEvent otspan $
                        NewEvent
                            { newEventName = "exception"
                            , newEventAttributes =
                                [ ("exception.type", toAttribute $ T.pack $ show $ typeOf exc)
                                , ("exception.message", toAttribute $ T.pack $ show exc)
                                , ("exception.stacktrace", toAttribute (T.pack <$> prettyCallStackLines cs))
                                ]
                            , newEventTimestamp = Nothing
                            }
                    throwError exc
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

