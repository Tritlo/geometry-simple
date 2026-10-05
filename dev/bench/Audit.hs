-- | Benchmark every stable public function on prepared geometry workloads.
module Audit (runAudit) where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import Control.Monad (forM_, replicateM_, when)
import qualified Data.ByteString as BS
import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import qualified Data.Geometry.WKB as WKB
import qualified Data.Geometry.WKT as WKT
import Data.IORef (newIORef, readIORef)
import Data.List (isPrefixOf)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (allocated_bytes), getRTSStats)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Text.Printf (printf)
import Text.Read (readMaybe)

-- | One fully evaluated action over an input stored outside the timed section.
data Workload = Workload
    { groupName :: String
    , operationName :: String
    , caseName :: String
    , prepareAction :: IO (IO ())
    }

-- | Select a group/operation/case prefix and size. Seconds bound each batch.
runAudit :: [String] -> IO ()
runAudit arguments = do
    (selected, sizes, seconds) <- case arguments of
        [] -> pure ("", [100, 400, 1600], 10)
        [size] | Just n <- readMaybe size, n >= 4 -> pure ("", [n], 10)
        [group, size] | Just n <- readMaybe size, n >= 4 -> pure (group, [n], 10)
        [group, size, limit] | Just n <- readMaybe size, n >= 4, Just budget <- readMaybe limit, budget > 0 -> pure (group, [n], budget)
        _ -> fail "Usage: --audit [size | group/operation/case-prefix size [seconds per batch]]"
    hSetBuffering stdout LineBuffering
    putStrLn "group,operation,case,size,iterations,trial,ns_per_call,allocated_bytes_per_call,status"
    forM_ sizes $ \size -> do
        workloads <- cases size
        let selectedCases = filter (\entry -> selected `isPrefixOf` (groupName entry ++ "/" ++ operationName entry ++ "/" ++ caseName entry)) workloads
        when (null selectedCases) (fail ("Unknown audit selection: " ++ selected))
        forM_ selectedCases (measure size seconds)

-- | Force inputs once. Read them through an IORef so repeated calls recompute results.
workload :: (NFData a, NFData b) => String -> String -> String -> (a -> b) -> a -> IO Workload
workload group operation name function input = preparedWorkload group operation name function (pure input)

-- | Delay fixture preparation until the workload is selected.
preparedWorkload :: (NFData a, NFData b) => String -> String -> String -> (a -> b) -> IO a -> IO Workload
preparedWorkload group operation name function prepareInput = pure (Workload group operation name prepare)
  where
    prepare = do
        reference <- prepareInput >>= evaluate . force >>= newIORef
        pure (readIORef reference >>= evaluate . force . function >> pure ())

-- | Measure fast calls in batches; retain one sample for calls above 200 ms.
measure :: Int -> Int -> Workload -> IO ()
measure size seconds entry = do
    action <- prepareAction entry
    pilot <- timed action 1
    case pilot of
        Nothing -> report 1 1 (fromIntegral seconds * 1e9) 0 "timeout"
        Just (elapsed, allocated)
            | elapsed >= 2e8 -> report 1 1 elapsed allocated "ok"
            | otherwise -> do
                let iterations = max 1 (min 100000 (floor (1e7 / max 1 elapsed)))
                forM_ [1 .. 3 :: Int] $ \trial -> do
                    measured <- timed action iterations
                    case measured of
                        Nothing -> report iterations trial (fromIntegral seconds * 1e9) 0 "timeout"
                        Just (duration, bytes) -> report iterations trial duration bytes "ok"
  where
    timed action iterations = do
        performMajorGC
        before <- getRTSStats
        result <- timeout (seconds * 1000000) $ do
            start <- getMonotonicTimeNSec
            replicateM_ iterations action
            end <- getMonotonicTimeNSec
            pure (fromIntegral (end - start))
        performMajorGC
        after <- getRTSStats
        pure ((\elapsed -> (elapsed, fromIntegral (allocated_bytes after - allocated_bytes before))) <$> result)
    report :: Int -> Int -> Double -> Double -> String -> IO ()
    report iterations trial elapsed allocated status =
        printf "%s,%s,%s,%d,%d,%d,%.3f,%.3f,%s\n" (groupName entry) (operationName entry) (caseName entry) size iterations trial (elapsed / fromIntegral iterations) (allocated / fromIntegral iterations) status

-- | Prepare representative families, layouts, and geometric relationships.
cases :: Int -> IO [Workload]
cases size = do
    let n = fromIntegral size
        coordinate = XYZM 1 2 3 4
        samplePoint = PointXYZM coordinate
        linePoints = U.generate size (\i -> XY (fromIntegral i) (sin (fromIntegral i / 10)))
        line = LineString (CoordinatesXY linePoints)
        measuredPoints = U.imap (\i (XY x y) -> XYZM x y (x / 2) (fromIntegral i)) linePoints
        measuredLine = LineString (CoordinatesXYZM measuredPoints)
        constantLine = LineString (CoordinatesXYZM (U.map (\(XYZM x y z _) -> XYZM x y z 0) measuredPoints))
        alternatingLine = LineString (CoordinatesXYZM (U.imap (\i (XYZM x y z _) -> XYZM x y z (fromIntegral (i `mod` 2))) measuredPoints))
        circle cx cy radius =
            let points = [XY (cx + radius * cos angle) (cy + radius * sin angle) | i <- [0 .. size - 1], let angle = 2 * pi * fromIntegral i / n]
             in CoordinatesXY (U.fromList (points ++ take 1 points))
        shell = circle 0 0 1
        polygon = Polygon (PolygonRings shell V.empty)
        holed = Polygon (PolygonRings shell (V.singleton (circle 0 0 0.4)))
        multiPoint = MultiPoint (U.map PointXY linePoints)
        measuredMultiPoint = MultiPoint (U.map PointXYZM measuredPoints)
        manyLines = MultiLineString (V.generate (max 1 (size `div` 2)) (\i -> CoordinatesXY (U.fromList [XY (fromIntegral (3 * i)) 0, XY (fromIntegral (3 * i + 1)) 1])))
        smallPolygon i = PolygonRings (CoordinatesXY (U.fromList [XY x 0, XY (x + 1) 0, XY x 1, XY x 0])) V.empty
          where
            x = fromIntegral (3 * i)
        manyPolygons = MultiPolygon (V.generate (max 1 (size `div` 4)) smallPolygon)
        flat = GeometryCollection (V.generate size (\i -> PointGeometry (if even i then PointXY (XY (fromIntegral i) 0) else PointXYZM (XYZM (fromIntegral i) 1 2 3))))
        emptyMembers = GeometryCollection (V.replicate size (PointGeometry (EmptyPoint DimXYZM)))
        nested = iterate (GeometryCollection . V.singleton) (PointGeometry samplePoint) !! size
        hole i = let x = fromIntegral (3 * i) + 1 in CoordinatesXY (U.fromList [XY x 1, XY (x + 1) 1, XY (x + 1) 2, XY x 2, XY x 1])
        manyHoles = Polygon (PolygonRings (rectangle 0 0 (3 * n + 2) 3) (V.generate (max 1 (size `div` 4)) hole))
        overlap = Polygon (PolygonRings (circle 0.5 0 1) V.empty)
        inside = Polygon (PolygonRings (circle 0 0 0.5) V.empty)
        apart = Polygon (PolygonRings (circle 3 0 (-1)) V.empty)
        diagonal sign = LineString (CoordinatesXY (U.generate size (\i -> let x = 4 * fromIntegral i / fromIntegral (size - 1) - 2 in XY x (sign * x))))
        box offset =
            let points = U.generate size $ \i ->
                    let t = 4 * fromIntegral i / n
                     in case floor t :: Int of
                            0 -> XY (offset + t) 0
                            1 -> XY (offset + 1) (t - 1)
                            2 -> XY (offset + 3 - t) 1
                            _ -> XY offset (4 - t)
             in Polygon (PolygonRings (CoordinatesXY (U.snoc points (XY offset 0))) V.empty)
        pairs = [("overlap", polygon, overlap), ("contained", polygon, inside), ("inside", inside, polygon), ("disjoint", polygon, apart), ("equal", polygon, polygon), ("touching", box 0, box 1), ("crossing-lines", diagonal 1, diagonal (-1)), ("line-polygon", diagonal 1, polygon)]
        shapes = [("line", line), ("polygon", polygon), ("hole", holed), ("many-holes", manyHoles), ("multipoint", multiPoint), ("multiline", manyLines), ("multipolygon", manyPolygons), ("collection", flat)]
        unary name function = mapM (\(label, shape) -> workload "unary" name label function shape) shapes
        measurement name function labels = mapM (\(label, shape) -> workload "measurements" name label function shape) labels
        binary group name function = mapM (\(label, a, b) -> workload group name label (uncurry function) (a, b)) pairs
        metadata name function = mapM (\(label, shape) -> workload "accessors" name label function shape) [("polygon", polygon), ("collection", flat), ("empty-members", emptyMembers), ("nested", nested)]
    accessors <-
        sequence
            [ workload "accessors" "x" "scalar" S.x coordinate
            , workload "accessors" "y" "scalar" S.y coordinate
            , workload "accessors" "z" "scalar" S.z coordinate
            , workload "accessors" "m" "scalar" S.m coordinate
            , workload "accessors" "pointX" "scalar" S.pointX samplePoint
            , workload "accessors" "pointY" "scalar" S.pointY samplePoint
            , workload "accessors" "pointZ" "scalar" S.pointZ samplePoint
            , workload "accessors" "pointM" "scalar" S.pointM samplePoint
            , workload "accessors" "withPoint" "scalar" (withPoint S.x) samplePoint
            , workload "accessors" "withCoordinates" "line" (withCoordinates U.length) (CoordinatesXY linePoints)
            , workload "accessors" "numGeometries" "collection" S.numGeometries flat
            , workload "accessors" "geometryN" "collection" (S.geometryN (size `div` 2)) flat
            , workload "accessors" "numPoints" "line" S.numPoints line
            , workload "accessors" "pointN" "line" (S.pointN (size `div` 2)) measuredLine
            , workload "accessors" "startPoint" "line" S.startPoint line
            , workload "accessors" "endPoint" "line" S.endPoint line
            , workload "accessors" "isClosed" "line" S.isClosed line
            , workload "accessors" "isClosed" "multiline" S.isClosed manyLines
            , workload "accessors" "isClosed" "closed-multiline" S.isClosed (MultiLineString (V.replicate (max 1 (size `div` 4)) (rectangle 0 0 1 1)))
            , workload "accessors" "exteriorRing" "polygon" S.exteriorRing polygon
            , workload "accessors" "numInteriorRings" "many-holes" S.numInteriorRings manyHoles
            , workload "accessors" "interiorRingN" "many-holes" (S.interiorRingN 0) manyHoles
            , workload "harness" "baseline" "scalar" id coordinate
            ]
    properties <-
        sequence
            [ metadata "geometryType" S.geometryType
            , metadata "dimension" S.dimension
            , metadata "coordinateDimension" S.coordinateDimension
            , metadata "spatialDimension" S.spatialDimension
            , metadata "is3D" S.is3D
            , metadata "isMeasured" S.isMeasured
            , metadata "isEmpty" S.isEmpty
            ]
    measurements <-
        sequence
            [ measurement "envelope" S.envelope shapes
            , measurement "area" S.area [("polygon", polygon), ("many-holes", manyHoles), ("multipolygon", manyPolygons)]
            , measurement "geometryLength" S.geometryLength shapes
            , measurement "curveLength" S.curveLength [("line", line), ("multiline", manyLines), ("collection", flat)]
            , measurement "perimeter" S.perimeter [("polygon", polygon), ("many-holes", manyHoles), ("multipolygon", manyPolygons)]
            , measurement "centroid" S.centroid shapes
            , measurement "convexHull" S.convexHull shapes
            ]
    topology <- sequence [unary "boundary" S.boundary, unary "isSimple" S.isSimple, unary "isValid" S.isValid, unary "pointOnSurface" S.pointOnSurface]
    rings <- sequence [workload "unary" "isRing" "closed-line" S.isRing (LineString shell), workload "unary" "isRing" "open-line" S.isRing line]
    relations <-
        sequence
            [ binary "relations" "relate" S.relate
            , binary "relations" "relatePattern" (S.relatePattern "T*****FF*")
            , binary "relations" "equals" S.equals
            , binary "relations" "disjoint" S.disjoint
            , binary "relations" "intersects" S.intersects
            , binary "relations" "touches" S.touches
            , binary "relations" "crosses" S.crosses
            , binary "relations" "within" S.within
            , binary "relations" "contains" S.contains
            , binary "relations" "overlaps" S.overlaps
            , binary "relations" "covers" S.covers
            , binary "relations" "coveredBy" S.coveredBy
            , binary "relations" "distance" S.distance
            ]
    overlays <-
        sequence
            [ binary "construction" "intersection" S.intersection
            , binary "construction" "union" S.union
            , binary "construction" "difference" S.difference
            , binary "construction" "symmetricDifference" S.symmetricDifference
            ]
    buffers <-
        sequence
            [ workload "construction" "buffer" "polygon-positive" (S.buffer 0.1) polygon
            , workload "construction" "buffer" "polygon-negative" (S.buffer (-0.1)) polygon
            , workload "construction" "buffer" "polygon-zero" (S.buffer 0) polygon
            , workload "construction" "buffer" "line-positive" (S.buffer 0.1) line
            , workload "construction" "bufferWithSegments" "polygon-2-quadrant" (S.bufferWithSegments 2 0.1) polygon
            , workload "construction" "bufferWithSegments" "line-16-quadrant" (S.bufferWithSegments 16 0.1) line
            ]
    measures <-
        sequence
            [ workload "measures" "locateAlong" "varying-M" (S.locateAlong (n / 2)) measuredLine
            , workload "measures" "locateAlong" "constant-M" (S.locateAlong 0) constantLine
            , workload "measures" "locateAlong" "alternating-M" (S.locateAlong 0.5) alternatingLine
            , workload "measures" "locateAlong" "multipoint" (S.locateAlong (n / 2)) measuredMultiPoint
            , workload "measures" "locateBetween" "varying-M" (S.locateBetween (n / 3) (2 * n / 3)) measuredLine
            , workload "measures" "locateBetween" "alternating-M" (S.locateBetween 0.25 0.75) alternatingLine
            , workload "measures" "locateBetween" "multipoint" (S.locateBetween (n / 3) (2 * n / 3)) measuredMultiPoint
            ]
    codecs <- mapM codecCases [("line-XY", line), ("line-XYZM", measuredLine), ("polygon-hole", holed), ("mixed-collection", flat), ("nested", nested)]
    pointRelation <- workload "relations" "relate" "multipoint-equal" (uncurry S.relate) (multiPoint, multiPoint)
    pure (accessors ++ concat properties ++ concat measurements ++ concat topology ++ rings ++ concat relations ++ [pointRelation] ++ concat overlays ++ buffers ++ measures ++ concat codecs)

-- | Measure codecs using encoded input prepared outside the timed section.
codecCases :: (String, Geometry) -> IO [Workload]
codecCases (label, geometry) = do
    let bytes = either fail pure (WKB.encodeWKB geometry)
        text = either fail pure (WKT.encodeWKT geometry)
    sequence
        [ workload "codecs" "encodeWKB" label WKB.encodeWKB geometry
        , workload "codecs" "encodeWKT" label WKT.encodeWKT geometry
        , preparedWorkload "codecs" "decodeWKB" label WKB.decodeWKB bytes
        , preparedWorkload "codecs" "decodeWKT" label WKT.decodeWKT text
        , preparedWorkload "codecs" "decodeWKB" (label ++ "-truncated") WKB.decodeWKB ((\input -> BS.take (BS.length input - 1) input) <$> bytes)
        , preparedWorkload "codecs" "decodeWKT" (label ++ "-truncated") WKT.decodeWKT (Text.dropEnd 1 <$> text)
        ]

-- | A closed axis-aligned ring for the many-hole workload.
rectangle :: Double -> Double -> Double -> Double -> Coordinates
rectangle x y u v = CoordinatesXY (U.fromList [XY x y, XY u y, XY u v, XY x v, XY x y])
