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
import Data.Geometry.Internal (coordinateComponents, coordinateDimensions, geometryDimensions, withCoordinates, withPoint)
import qualified Data.Geometry.SimpleFeatures as S
import qualified Data.Geometry.WKB as WKB
import qualified Data.Geometry.WKT as WKT
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Numeric (showHex)

-- | Read FORMAT-tab-payload requests. CODEC- formats omit numerical operations.
main :: IO ()
main = do
    requests <- T.lines <$> T.getContents
    forM_ requests $ \request -> do
        let output = response request
        forced <- try (evaluate (T.length output)) :: IO (Either SomeException Int)
        T.putStrLn $ case forced of
            Left failure -> "ERROR\t" <> T.pack (show failure)
            Right _ -> output

-- | Decode text or ISO WKB. Named fixtures exercise direct constructors.
response :: Text -> Text
response request =
    let (requestedFormat, rest) = T.breakOn "\t" request
        codecOnly = T.isPrefixOf "CODEC-" requestedFormat
        format = if codecOnly then T.drop 6 requestedFormat else requestedFormat
        payload = T.drop 1 rest
        bytes = unhex payload
        decoded = case format of
            "WKT" -> WKT.decodeWKT payload
            "WKB" -> bytes >>= WKB.decodeWKB
            "CONSTRUCT" -> fixture payload
            _ -> Left "Expected WKT, WKB, or CONSTRUCT"
        report :: Geometry -> Text
        report shape =
            let codec = if format == "CONSTRUCT" then "constructGeometry" else "decode" <> format
                results =
                    [(codec, structure shape)]
                        ++ [("encodeWKT", render shape), ("encodeWKB", either errorText hex (WKB.encodeWKB shape))]
                        ++ if codecOnly then [] else fields shape
             in T.intercalate "\t" ("OK" : [key <> "=" <> value | (key, value) <- results])
     in case decoded of
            Left failure -> "ERROR\t" <> T.pack failure
            Right shape -> report shape

-- | Evaluate every public accessor and planar operation. Keep absent values explicit.
fields :: Geometry -> [(Text, Text)]
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
    , ("startPoint", optional (structure . PointGeometry) (S.startPoint shape))
    , ("endPoint", optional (structure . PointGeometry) (S.endPoint shape))
    , ("isClosed", shown (S.isClosed shape))
    , ("exteriorRing", optional (structure . LineString) (S.exteriorRing shape))
    , ("numInteriorRings", optional shown (S.numInteriorRings shape))
    , ("envelope", structure (S.envelope shape))
    , ("area", shown (S.area shape))
    , ("geometryLength", shown (S.geometryLength shape))
    , ("curveLength", shown (S.curveLength shape))
    , ("perimeter", shown (S.perimeter shape))
    , ("centroid", structure (PointGeometry (S.centroid shape)))
    , ("convexHull", structure (S.convexHull shape))
    ]
        ++ [("geometryN." <> shown i, optional structure (S.geometryN i shape)) | i <- [-1 .. S.numGeometries shape + 1]]
        ++ [("pointN." <> shown i, optional (structure . PointGeometry) (S.pointN i shape)) | i <- [-1 .. maybe 0 id (S.numPoints shape) + 1]]
        ++ [("interiorRingN." <> shown i, optional (structure . LineString) (S.interiorRingN i shape)) | i <- [-1 .. maybe 0 id (S.numInteriorRings shape) + 1]]
        ++ concat
            [ [(method <> "." <> shown i, value) | (method, value) <- zip ["x", "y", "z", "m"] row]
            | (i, row) <- zip [0 :: Int ..] (ordinateResults shape)
            ]

-- | Retain each stored layout and coordinate. Do not call either codec.
structure :: Geometry -> Text
structure shape = array [shown family, quote (layout (geometryDimensions shape)), body]
  where
    (family, body) = case shape of
        PointGeometry point -> (0 :: Int, array (maybe [] (: []) (withPoint rawRow point)))
        LineString points -> (1, withCoordinates (array . map rawRow . U.toList) points)
        Polygon (PolygonRings shell holes) -> (3, array (map (structure . LineString) (shell : V.toList holes)))
        MultiPoint points -> (4, array (map (structure . PointGeometry) (U.toList points)))
        MultiLineString lineStrings -> (5, array (map (structure . LineString) (V.toList lineStrings)))
        MultiPolygon polygons -> (6, array (map (structure . Polygon) (V.toList polygons)))
        GeometryCollection children -> (7, array (map structure (V.toList children)))

-- | Serialize ordinates as decimal strings that retain finite Double values.
rawRow :: forall c. (Coordinate c) => c -> Text
rawRow coordinate = array (map (quote . shown) ordinates)
  where
    (a, b, c, d) = coordinateComponents coordinate
    ordinates = case coordinateDimensions (Proxy :: Proxy c) of
        DimXY -> [a, b]
        DimXYZ -> [a, b, c]
        DimXYM -> [a, b, d]
        DimXYZM -> [a, b, c, d]

-- | Evaluate coordinate accessors with each coordinate's stored type.
ordinateResults :: Geometry -> [[Text]]
ordinateResults shape = case shape of
    PointGeometry point -> maybe [] (: []) (withPoint row point)
    LineString points -> withCoordinates (map row . U.toList) points
    Polygon (PolygonRings shell holes) -> concatMap (ordinateResults . LineString) (shell : V.toList holes)
    MultiPoint points -> concatMap (ordinateResults . PointGeometry) (U.toList points)
    MultiLineString lineStrings -> concatMap (ordinateResults . LineString) (V.toList lineStrings)
    MultiPolygon polygons -> concatMap (ordinateResults . Polygon) (V.toList polygons)
    GeometryCollection children -> concatMap ordinateResults (V.toList children)
  where
    row :: (Coordinate c) => c -> [Text]
    row c = [shown (S.x c), shown (S.y c), optional shown (S.z c), optional shown (S.m c)]

-- | Name the dimensions in the raw JSON protocol.
layout :: Dimensions -> Text
layout DimXY = "XY"
layout DimXYZ = "XYZ"
layout DimXYM = "XYM"
layout DimXYZM = "XYZM"

-- | Join already encoded JSON values.
array :: [Text] -> Text
array values = "[" <> T.intercalate "," values <> "]"

-- | Quote fixed layout names and numeric strings.
quote :: Text -> Text
quote value = "\"" <> value <> "\""

-- | Build ring layouts that a single polygon WKT or WKB cannot retain.
fixture :: Text -> Either String Geometry
fixture name = case name of
    "xy-z-rings" -> Right (Polygon (PolygonRings shellXY (V.singleton holeZ)))
    "z-m-rings" -> Right (Polygon (PolygonRings shellZ (V.singleton holeM)))
    "empty-z-m-rings" -> Right (Polygon (PolygonRings (CoordinatesXYZ U.empty) (V.singleton (CoordinatesXYM U.empty))))
    _ -> Left "Unknown constructor fixture"
  where
    shellXY = CoordinatesXY (U.fromList [XY 0 0, XY 6 0, XY 6 6, XY 0 6, XY 0 0])
    shellZ = CoordinatesXYZ (U.fromList [XYZ 0 0 1, XYZ 6 0 2, XYZ 6 6 3, XYZ 0 6 4, XYZ 0 0 1])
    holeZ = CoordinatesXYZ (U.fromList [XYZ 1 1 3, XYZ 2 1 4, XYZ 2 2 5, XYZ 1 1 3])
    holeM = CoordinatesXYM (U.fromList [XYM 1 1 3, XYM 2 1 4, XYM 2 2 5, XYM 1 1 3])

-- | Retain encoder errors as values so one failure does not stop the comparison.
render :: Geometry -> Text
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
