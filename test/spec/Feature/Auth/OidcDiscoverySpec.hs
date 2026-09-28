{-# LANGUAGE LambdaCase #-}

module Feature.Auth.OidcDiscoverySpec where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Network.HTTP.Types
import Network.Wai.Test (SResponse (..))
import Protolude hiding (get)
import Test.Hspec
import Test.Hspec.Wai
import Test.Hspec.Wai.JSON

import Data.Aeson qualified as JSON
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Jose.Jwa qualified as JWT
import Jose.Jwk qualified as JWT
import Jose.Jwt qualified as JWT
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp

import PostgREST.Config (AppConfig (..))
import SpecHelper
import Unit.OidcDiscoverySpec (testKeyPair)

-- these tests will stop working 9999999999s after the UNIX EPOCH
spec :: SpecWithConfig
spec withConfig = do
  (public1, private1) <- runIO $ testKeyPair "k1"
  (public2, private2) <- runIO $ testKeyPair "k2"
  (issuer, _) <- runIO $ identityProvider [public1]
  (rotatingIssuer, rotatingKeys) <- runIO $ identityProvider [public1]
  (revokingIssuer, revokingKeys) <- runIO $ identityProvider [public1, public2]

  let
    discoveryCfg iss =
      baseCfg
        { configJwtSecret = Nothing,
          configJWKS = Nothing,
          configJwtIssuer = Just iss,
          configJwtOidcDiscovery = True
        }
    token :: (MonadIO m) => JWT.Jwk -> Text -> m Header
    token key iss = liftIO $ signed key [json|{"exp": 9999999999, "role": "postgrest_test_author", "iss": #{iss}}|]

  describe "verifying JWTs with the keys of the issuer" $ do
    withConfig (discoveryCfg issuer) $ do
      it "succeeds with a JWT signed with a key of the issuer" $ do
        auth <- token private1 issuer
        request methodGet "/authors_only" [auth] ""
          `shouldRespondWith` 200

      it "fails with a JWT from another issuer" $ do
        auth <- token private1 "https://other.example.com"
        request methodGet "/authors_only" [auth] ""
          `shouldRespondWith` [json|{"code":"PGRST303","details":null,"hint":null,"message":"JWT issuer does not match"}|]
            { matchStatus = 401
            }

      it "fails with a JWT signed with a key the issuer doesn't have" $ do
        auth <- token private2 issuer
        request methodGet "/authors_only" [auth] ""
          `shouldRespondWith` 401

      it "succeeds without a JWT" $
        get "/has_count_column" `shouldRespondWith` 200

    withConfig (discoveryCfg rotatingIssuer) $
      it "succeeds with a JWT signed with a key the issuer added after the keys were fetched" $
        do
          auth <- token private2 rotatingIssuer
          liftIO $ do
            writeIORef rotatingKeys [public1, public2]
            -- a fetch for an unknown key waits for the interval between fetches
            threadDelay 5_500_000
          request methodGet "/authors_only" [auth] ""
            `shouldRespondWith` 200

    withConfig (discoveryCfg revokingIssuer) $
      it "fails with a cached JWT signed with a key the issuer removed" $
        do
          auth <- token private2 revokingIssuer
          request methodGet "/authors_only" [auth] ""
            `shouldRespondWith` 200
          -- a JWT with an unknown key makes PostgREST fetch the keys again
          unknownKeyAuth <- token (withKeyId "k3" private1) revokingIssuer
          liftIO $ do
            writeIORef revokingKeys [public1]
            threadDelay 5_500_000
          request methodGet "/authors_only" [unknownKeyAuth] ""
            `shouldRespondWith` 401
          request methodGet "/authors_only" [auth] ""
            `shouldRespondWith` 401

    withConfig (discoveryCfg issuer){configJwtSecret = Just generateSecret, configJWKS = configJWKS baseCfg} $
      it "succeeds with JWTs signed with jwt-secret and with a key of the issuer" $ do
        auth <- token private1 issuer
        request methodGet "/authors_only" [auth] ""
          `shouldRespondWith` 200
        let secretAuth = authHeaderJWT $ generateJWT [json|{"exp": 9999999999, "role": "postgrest_test_author", "iss": #{issuer}}|]
        request methodGet "/authors_only" [secretAuth] ""
          `shouldRespondWith` 200

    withConfig (discoveryCfg "http://127.0.0.1:1") $ do
      it "responds with 503 while the keys of the issuer can't be fetched" $ do
        auth <- token private1 "http://127.0.0.1:1"
        response <- request methodGet "/authors_only" [auth] ""
        liftIO $ do
          simpleStatus response `shouldBe` status503
          let body = JSON.decode (simpleBody response) :: Maybe JSON.Object
          (KM.lookup "code" =<< body) `shouldBe` Just (JSON.String "PGRST304")
          (KM.lookup "message" =<< body) `shouldBe` Just (JSON.String "The keys to verify the JWT could not be fetched")

      it "succeeds without a JWT while the keys of the issuer can't be fetched" $
        get "/has_count_column" `shouldRespondWith` 200
  where
    withKeyId kid = \case
      JWT.RsaPrivateJwk key _ use alg -> JWT.RsaPrivateJwk key (Just $ JWT.KeyId kid) use alg
      key -> key

    signed :: JWT.Jwk -> LBS.ByteString -> IO Header
    signed key claims =
      JWT.encode [key] (JWT.JwsEncoding JWT.RS256) (JWT.Claims $ LBS.toStrict claims)
        >>= either (panic . show) (pure . authHeaderJWT . JWT.unJwt)

-- | Serve the discovery document and the given keys at a free port, for the
-- rest of the test run. The keys can be changed.
identityProvider :: [JWT.Jwk] -> IO (Text, IORef [JWT.Jwk])
identityProvider initialKeys = do
  keysRef <- newIORef initialKeys
  (port, socket) <- Warp.openFreePort
  let
    issuer = "http://127.0.0.1:" <> T.pack (show port)
    app req respond = case Wai.pathInfo req of
      [".well-known", "openid-configuration"] ->
        respond . Wai.responseLBS status200 [] . JSON.encode $ JSON.object ["issuer" JSON..= issuer, "jwks_uri" JSON..= (issuer <> "/jwks")]
      ["jwks"] -> readIORef keysRef >>= respond . Wai.responseLBS status200 [] . JSON.encode . JWT.JwkSet
      _ -> respond $ Wai.responseLBS status404 [] mempty
  void . forkIO $ Warp.runSettingsSocket Warp.defaultSettings socket app
  pure (issuer, keysRef)
