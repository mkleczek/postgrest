module Unit.OidcDiscoverySpec (spec, testKeyPair) where

import Network.HTTP.Types (hCacheControl, hLocation, status200, status302, status404)
import Protolude
import Test.Hspec

import Data.Aeson qualified as JSON
import Data.Aeson.Key qualified as K
import Data.Aeson.Types qualified as JSON
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Jose.Jwk qualified as JWT
import Jose.Jwt qualified as JWT
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp

import PostgREST.Auth.OidcDiscovery

spec :: Spec
spec = describe "OpenID Connect discovery" $ do
  it "fetches the public signing keys of the issuer, with their max-age" $ do
    (public, private) <- testKeyPair "k1"
    let
      symmetric = JWT.SymmetricJwk "a secret with at least 32 characters" (Just $ JWT.KeyId "k2") (Just JWT.Sig) Nothing
      keySet = JWT.JwkSet [public, private, symmetric]
    withIdentityProvider (\issuer -> discovery issuer (issuer <> "/jwks")) (jwks [(hCacheControl, "max-age=600")] keySet) $ \issuer -> do
      manager <- newDiscoveryManager 5
      fetchIssuerKeys manager issuer `shouldReturn` Right (JWT.JwkSet [public], Just 600)

  it "fails for a discovery document of another issuer" $ do
    (public, _) <- testKeyPair "k1"
    withIdentityProvider (const $ discovery "https://other.example.com" "https://other.example.com/jwks") (jwks [] $ JWT.JwkSet [public]) $ \issuer -> do
      manager <- newDiscoveryManager 5
      fetchIssuerKeys manager issuer `shouldReturn` Left "the discovery document is for issuer https://other.example.com"

  it "fails for a key set without public signing keys" $ do
    (_, private) <- testKeyPair "k1"
    withIdentityProvider (\issuer -> discovery issuer (issuer <> "/jwks")) (jwks [] $ JWT.JwkSet [private]) $ \issuer -> do
      manager <- newDiscoveryManager 5
      fetchIssuerKeys manager issuer `shouldReturn` Left "the key set has no public signing keys"

  it "fails when the provider doesn't answer with the documents" $ do
    let
      notFound = Wai.responseLBS status404 [] mempty
      redirect = Wai.responseLBS status302 [(hLocation, "https://example.com/jwks")] mempty
    withIdentityProvider (const notFound) notFound $ \issuer -> do
      manager <- newDiscoveryManager 5
      fetchIssuerKeys manager issuer `shouldReturn` Left (discoveryUrl issuer <> " responded with status 404")
    -- redirects are not followed
    withIdentityProvider (\issuer -> discovery issuer (issuer <> "/jwks")) redirect $ \issuer -> do
      manager <- newDiscoveryManager 5
      fetchIssuerKeys manager issuer `shouldReturn` Left (issuer <> "/jwks responded with status 302")
    withIdentityProvider (const $ Wai.responseLBS status200 [] $ LBS.replicate 1_100_000 32) notFound $ \issuer -> do
      manager <- newDiscoveryManager 5
      fetchIssuerKeys manager issuer `shouldReturn` Left ("the response of " <> discoveryUrl issuer <> " is too large")

  it "fails when the provider can't be reached" $ do
    manager <- newDiscoveryManager 1
    fetchIssuerKeys manager "http://127.0.0.1:1" >>= (`shouldSatisfy` isLeft)
  where
    discovery :: Text -> Text -> Wai.Response
    discovery issuer jwksUri = Wai.responseLBS status200 [] . JSON.encode $ JSON.object ["issuer" JSON..= issuer, "jwks_uri" JSON..= jwksUri]

    jwks headers keySet = Wai.responseLBS status200 headers $ JSON.encode keySet

    -- serve the discovery document at the well-known path and the key set at /jwks
    withIdentityProvider :: (Text -> Wai.Response) -> Wai.Response -> (Text -> IO a) -> IO a
    withIdentityProvider document keySet action = do
      issuerVar <- newEmptyMVar
      let app req respond = do
            issuer <- readMVar issuerVar
            respond $ case Wai.pathInfo req of
              [".well-known", "openid-configuration"] -> document issuer
              ["jwks"] -> keySet
              _ -> Wai.responseLBS status404 [] mempty
      Warp.testWithApplication (pure app) $ \port -> do
        let issuer = "http://127.0.0.1:" <> T.pack (show port)
        putMVar issuerVar issuer
        action issuer

-- | The public and private JWK of an RSA test key (generating keys is slow)
testKeyPair :: Text -> IO (JWT.Jwk, JWT.Jwk)
testKeyPair kid = do
  keys <- either (panic . T.pack) identity <$> JSON.eitherDecodeFileStrict' "test/spec/fixtures/oidc_keys.json"
  either (panic . T.pack) pure $ JSON.parseEither (\o -> o JSON..: K.fromText kid >>= \k -> (,) <$> k JSON..: "public" <*> k JSON..: "private") (keys :: JSON.Object)
