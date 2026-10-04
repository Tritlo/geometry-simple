{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Serve named Simple Features and codec results for the optional Shapely check.
module Main (main) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Char (digitToInt, isHexDigit)
import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import qualified Data.Geometry.WKB as WKB
import qualified Data.Geometry.WKT as WKT
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Numeric (showHex)

-- | Read FORMAT-tab-payload requests. Write one tab-separated response per line.
main :: IO ()
main = do
    requests <- T.lines <$> T.getContents
    forM_ requests $ \request -> do
        let output = response request
        forced <- try (evaluate (T.length output)) :: IO (Either SomeException Int)
        T.putStrLn $ case forced of
            Left failure -> "ERROR\t" <> T.pack (show failure)
            Right _ -> output

-- | Decode either text or hex ISO WKB and retain the declared coordinate type.
response :: Text -> Text
response request =
    let (format, rest) = T.breakOn "\t" request
        payload = T.drop 1 rest
        bytes = unhex payload
        decoded = case format of
            "WKT" -> WKT.decodeAnyWKT payload
            "WKB" -> bytes >>= WKB.decodeAnyWKB
            _ -> Left "Expected WKT or WKB"
        report :: (Coordinate c) => Geometry c -> Text
        report shape =
            let typed = case format of
                    "WKT" -> WKT.decodeWKT payload
                    _ -> bytes >>= WKB.decodeWKB
                typedResult = render <$> (typed `asTypeOf` Right shape)
                codec = if format == "WKT" then "decodeWKT" else "decodeWKB"
             in T.intercalate "\t" ("OK" : [key <> "=" <> value | (key, value) <- (codec, either errorText id typedResult) : (T.replace "decode" "decodeAny" codec, render shape) : fields shape])
     in case decoded of
            Left failure -> "ERROR\t" <> T.pack failure
            Right (GeometryXY shape) -> report shape
            Right (GeometryXYZ shape) -> report shape
            Right (GeometryXYM shape) -> report shape
            Right (GeometryXYZM shape) -> report shape

-- | Evaluate every public accessor and planar operation. Keep absent values explicit.
fields :: (Coordinate c) => Geometry c -> [(Text, Text)]
fields shape =
    [ ("geometryType", T.pack (S.geometryType shape))
    , ("dimension", shown (S.dimension shape))
    , ("coordinateDimension", shown (S.coordinateDimension shape))
    , ("spatialDimension", shown (S.spatialDimension shape))
    , ("is3D", shown (S.is3D shape))
    , ("isMeasured", shown (S.isMeasured shape))
    , ("isEmpty", shown (S.isEmpty shape))
    , ("numGeometries", shown (S.numGeometries shape))
    , ("numPoints", optional shown (S.numPoints shape))
    , ("startPoint", optional renderCoordinate (S.startPoint shape))
    , ("endPoint", optional renderCoordinate (S.endPoint shape))
    , ("isClosed", shown (S.isClosed shape))
    , ("exteriorRing", optional (render . LineString) (S.exteriorRing shape))
    , ("numInteriorRings", optional shown (S.numInteriorRings shape))
    , ("envelope", render (S.envelope shape))
    , ("area", shown (S.area shape))
    , ("curveLength", shown (S.curveLength shape))
    , ("perimeter", shown (S.perimeter shape))
    , ("centroid", render (PointGeometry (S.centroid shape)))
    , ("convexHull", render (S.convexHull shape))
    , ("encodeWKT", render shape)
    , ("encodeWKB", either errorText hex (WKB.encodeWKB shape))
    ]
        ++ [("geometryN." <> shown i, optional render (S.geometryN i shape)) | i <- [0 .. S.numGeometries shape + 1]]
        ++ [("pointN." <> shown i, optional renderCoordinate (S.pointN i shape)) | i <- [0 .. maybe 0 id (S.numPoints shape) + 1]]
        ++ [("interiorRingN." <> shown i, optional (render . LineString) (S.interiorRingN i shape)) | i <- [0 .. maybe 0 id (S.numInteriorRings shape) + 1]]
        ++ concat
            [ [("x." <> shown i, shown (S.x c)), ("y." <> shown i, shown (S.y c)), ("z." <> shown i, optional shown (S.z c)), ("m." <> shown i, optional shown (S.m c))]
            | (i, c) <- zip [0 :: Int ..] (coordinates shape)
            ]

-- | Collect stored coordinates without using the accessors under test.
coordinates :: (Coordinate c) => Geometry c -> [c]
coordinates shape = case shape of
    PointGeometry EmptyPoint -> []
    PointGeometry (Point c) -> [c]
    LineString points -> U.toList points
    Polygon rings -> concatMap U.toList (V.toList rings)
    MultiPoint points -> [c | Point c <- U.toList points]
    MultiLineString lineStrings -> concatMap U.toList (V.toList lineStrings)
    MultiPolygon polygons -> concatMap (concatMap U.toList . V.toList) (V.toList polygons)
    GeometryCollection children -> concatMap coordinates (V.toList children)

-- | Render a selected coordinate through the public WKT encoder.
renderCoordinate :: (Coordinate c) => c -> Text
renderCoordinate = render . PointGeometry . Point

-- | Retain encoder errors as values so one failure does not stop the comparison.
render :: (Coordinate c) => Geometry c -> Text
render = either errorText id . WKT.encodeWKT

-- | Mark an error without confusing it with WKT or a missing optional value.
errorText :: String -> Text
errorText message = "!" <> T.pack message

-- | Render a scalar with Haskell's standard representation.
shown :: (Show a) => a -> Text
shown = T.pack . show

-- | Use a single tilde for an absent optional result.
optional :: (a -> Text) -> Maybe a -> Text
optional = maybe "~"

-- | Encode bytes in lowercase hexadecimal.
hex :: ByteString -> Text
hex = T.pack . concatMap (\byte -> let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits) . BS.unpack

-- | Reject malformed hex before calling the WKB decoder.
unhex :: Text -> Either String ByteString
unhex input
    | odd (T.length input) || not (T.all isHexDigit input) = Left "Invalid hexadecimal input"
    | otherwise = BS.pack <$> go (T.unpack input)
  where
    go [] = Right []
    go (a : b : rest) = (fromIntegral (16 * digitToInt a + digitToInt b) :) <$> go rest
    go _ = Left "Invalid hexadecimal input"
