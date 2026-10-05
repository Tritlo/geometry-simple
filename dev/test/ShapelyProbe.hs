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
import Data.Geometry.Internal (coordinateComponents, coordinateDimensions, geometryDimensions)
import qualified Data.Geometry.SimpleFeatures as S
import qualified Data.Geometry.WKB as WKB
import qualified Data.Geometry.WKT as WKT
import Data.Maybe (fromMaybe, maybeToList)
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
        output <- case T.splitOn "\t" request of
            [format, phase, first, second]
                | "PAIR-" `T.isPrefixOf` format ->
                    operationResponse (pairFields phase) (decodeInput (T.drop 5 format) first) (decodeInput (T.drop 5 format) second)
            [format, phase, payload]
                | "TOPO-" `T.isPrefixOf` format ->
                    operationResponse (\shape _ -> topologyFields phase shape) (decodeInput (T.drop 5 format) payload) (Right (GeometryCollection V.empty))
            _ -> pure (response request)
        forced <- try (evaluate (T.length output)) :: IO (Either SomeException Int)
        T.putStrLn $ case forced of
            Left failure -> "ERROR\t" <> T.pack (show failure)
            Right _ -> output

-- | Decode each operand before evaluating any operation.
decodeInput :: Text -> Text -> Either String Geometry
decodeInput "WKT" = WKT.decodeWKT
decodeInput "WKB" = \payload -> unhex payload >>= WKB.decodeWKB
decodeInput _ = const (Left "Expected WKT or WKB")

-- | Isolate operation exceptions so one failure does not hide other results.
operationResponse :: (Geometry -> Geometry -> [(Text, Text)]) -> Either String Geometry -> Either String Geometry -> IO Text
operationResponse operations first second = case (first, second) of
    (Right a, Right b) -> do
        results <- mapM forceField (operations a b)
        pure (T.intercalate "\t" ("OK" : results))
    (Left failure, _) -> pure ("ERROR\tfirst: " <> T.pack failure)
    (_, Left failure) -> pure ("ERROR\tsecond: " <> T.pack failure)
  where
    forceField (key, value) = do
        forced <- try (evaluate (T.length value)) :: IO (Either SomeException Int)
        pure (key <> "=" <> either (\failure -> "!exception: " <> T.replace "\n" " " (T.pack (show failure))) (const value) forced)

-- | Evaluate unary topology and round buffers with explicit parameters.
topologyFields :: Text -> Geometry -> [(Text, Text)]
topologyFields phase shape =
    ( if phase `elem` ["all", "unary"]
        then
            [ ("boundary", optional structure (S.boundary shape))
            , ("isSimple", shown (S.isSimple shape))
            , ("isRing", shown (S.isRing shape))
            , ("isValid", shown (S.isValid shape))
            , ("pointOnSurface", structure (PointGeometry (S.pointOnSurface shape)))
            ]
        else []
    )
        ++ [("buffer.0.0", topologyResult (S.buffer 0 shape)) | phase == "buffer-zero"]
        ++ if phase `elem` ["all", "buffer"]
            then
                [("buffer." <> shown radius, topologyResult (S.buffer radius shape)) | radius <- [-1, 0, 0.5, 2]]
                    ++ [("bufferWithSegments." <> shown segments <> "." <> shown radius, topologyResult (S.bufferWithSegments segments radius shape)) | segments <- [1, 2, 8, 16], radius <- [-0.5, 0.5]]
            else []

-- | Compare each binary predicate, relation pattern, distance, and set operation.
pairFields :: Text -> Geometry -> Geometry -> [(Text, Text)]
pairFields phase first second =
    ( if phase `elem` ["all", "relations"]
        then
            [("relate", T.pack (S.relate first second)), ("distance", shown (S.distance first second))]
                ++ [(name, shown (predicate first second)) | (name, predicate) <- [("equals", S.equals), ("disjoint", S.disjoint), ("intersects", S.intersects), ("touches", S.touches), ("crosses", S.crosses), ("within", S.within), ("contains", S.contains), ("overlaps", S.overlaps), ("covers", S.covers), ("coveredBy", S.coveredBy)]]
                ++ [("relatePattern." <> T.pack patternText, shown (S.relatePattern patternText first second)) | patternText <- ["*********", "T********", "FF*FF****", "T*F**F***", "T*****FF*", "0********", "1********", "2********", "F********", "FT*******", "F**T*****", "F***T****"]]
        else []
    )
        ++ if phase `elem` ["all", "overlay"]
            then [(name, topologyResult (operation first second)) | (name, operation) <- [("intersection", S.intersection), ("union", S.union), ("difference", S.difference), ("symmetricDifference", S.symmetricDifference)]]
            else []

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
    , ("pointX", optional shown (pointOrdinate S.pointX))
    , ("pointY", optional shown (pointOrdinate S.pointY))
    , ("pointZ", optional shown (pointOrdinate S.pointZ))
    , ("pointM", optional shown (pointOrdinate S.pointM))
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
        ++ [("pointN." <> shown i, optional (structure . PointGeometry) (S.pointN i shape)) | i <- [-1 .. fromMaybe 0 (S.numPoints shape) + 1]]
        ++ [("interiorRingN." <> shown i, optional (structure . LineString) (S.interiorRingN i shape)) | i <- [-1 .. fromMaybe 0 (S.numInteriorRings shape) + 1]]
        ++ concat
            [ [(method <> "." <> shown i, value) | (method, value) <- zip ["x", "y", "z", "m"] row]
            | (i, row) <- zip [0 :: Int ..] (ordinateResults shape)
            ]
  where
    pointOrdinate accessor = case shape of
        PointGeometry point -> accessor point
        _ -> Nothing

-- | Retain each stored layout and coordinate. Do not call either codec.
structure :: Geometry -> Text
structure shape = array [shown family, quote (layout (geometryDimensions shape)), body]
  where
    (family, body) = case shape of
        PointGeometry point -> (0 :: Int, array (maybeToList (withPoint rawRow point)))
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
    PointGeometry point -> maybeToList (withPoint row point)
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

-- | Keep explicit topology failures distinct from successful geometry results.
topologyResult :: Either S.TopologyException Geometry -> Text
topologyResult = either (\failure -> "!error: " <> shown failure) structure
