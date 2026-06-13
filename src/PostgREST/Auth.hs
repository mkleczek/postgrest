{-|
Module      : PostgREST.Auth
Description : PostgREST authentication functions.

This module provides functions to deal with the JWT authentication (http://jwt.io).
It also can be used to define other authentication functions,
in the future Oauth, LDAP and similar integrations can be coded here.

Authentication should always be implemented in an external service.
In the test suite there is an example of simple login function that can be used for a
very simple authentication system inside the PostgreSQL database.
-}
{-# LANGUAGE DeriveGeneric    #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase       #-}
{-# LANGUAGE NamedFieldPuns   #-}
module PostgREST.Auth
  ( authenticate )
  where

import           Control.Monad.Error.Class
import qualified Data.Aeson                as JSON
import           Data.Aeson.Types
import qualified Data.ByteString           as BS
import qualified Data.ByteString.Lazy      as LBS
import qualified Data.Scientific           as Sci
import           Data.Time
import           Data.Time.Clock.POSIX
import           PostgREST.AppState        (AppState,
                                            getJwtCacheState, getTime)
import           PostgREST.Auth.JwtCache   (lookupJwtCache)
import           PostgREST.Auth.Types      (AuthResult (..))
import           PostgREST.Config
import           PostgREST.Config.JSPath
import           PostgREST.Error           (Error (..),
                                            JwtClaimsError (..),
                                            JwtError (..))

import Protolude

-- | Perform authentication and authorization
--   Parse JWT and return AuthResult
authenticate :: (MonadError Error m, MonadIO m, MonadReader AppConfig m) => AppState -> Maybe ByteString -> m AuthResult
authenticate appState token = do
  cfg@AppConfig{configJwtRoleClaimKey, configDbAnonRole} <- ask
  time <- liftIO $ getTime appState
  let
    parseClaims mclaims = do
      liftEither . maybeToLeft () $ validateClaims
      -- role defaults to anon if not specified in jwt
      role <- liftEither . maybeToRight (JwtErr JwtTokenRequired) $
        unquoted <$> walkJSPath (Just $ JSON.Object mclaims) configJwtRoleClaimKey <|> configDbAnonRole
      pure AuthResult
              { authClaims = mclaims
              , authRole = role
              }
      where
        validateClaims = fmap JwtErr . getAlt $ JwtClaimsErr <$> checkForErrors time (audMatchesCfg cfg) mclaims

        unquoted :: JSON.Value -> BS.ByteString
        unquoted (JSON.String t) = encodeUtf8 t
        unquoted v               = LBS.toStrict $ JSON.encode v

  parseClaims =<< lookupJwtCache (getJwtCacheState appState) token
{-# INLINABLE authenticate #-}

data ValidAud = VAString Text | VAArray [Text] deriving Generic
instance JSON.FromJSON ValidAud where
  parseJSON = JSON.genericParseJSON JSON.defaultOptions { JSON.sumEncoding = JSON.UntaggedValue }

checkForErrors :: (Applicative m, Monoid (m JwtClaimsError)) => UTCTime -> (Text -> Bool) -> JSON.Object -> m JwtClaimsError
checkForErrors time audMatches = mconcat
  [
    claim "exp" ExpClaimNotNumber $ inThePast JWTExpired
  , claim "nbf" NbfClaimNotNumber $ inTheFuture JWTNotYetValid
  , claim "iat" IatClaimNotNumber $ inTheFuture JWTIssuedAtFuture
  , claim "aud" AudClaimNotStringOrArray $ checkValue (not . validAud) JWTNotInAudience
  ]
  where
      allowedSkewSeconds = 30 :: Int64
      sciToInt = fromMaybe 0 . Sci.toBoundedInteger
      toSec = floor . nominalDiffTimeToSeconds . utcTimeToPOSIXSeconds
      now = toSec time

      inTheFuture = checkTime ((now + allowedSkewSeconds) <)
      inThePast = checkTime ((now - allowedSkewSeconds) >)

      checkTime cond = checkValue (cond. sciToInt)

      validAud = \case
        (VAString aud) -> audMatches aud
        (VAArray auds) -> null auds || any audMatches auds

      checkValue invalid msg val =
        if invalid val then
          pure msg
        else
          mempty

      claim key parseError checkParsed = maybe (pure parseError) (maybe mempty checkParsed) . parseMaybe (.:? key)
