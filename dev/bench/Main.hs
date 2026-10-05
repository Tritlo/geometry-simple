-- | Measure public geometry operations and coordinate containers.
module Main (main) where

import qualified Audit
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import Data.Geometry (Coordinates (..), Geometry (..), Point (..), PolygonRings (..), XY (..))
import qualified Data.Geometry.SimpleFeatures as S
import Data.Geometry.WKB (decodeWKB, encodeWKB)
import Data.Geometry.WKT (decodeWKT, encodeWKT)
import Data.IORef (newIORef, readIORef)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (RTSStats (allocated_bytes), getRTSStats, getRTSStatsEnabled)
import Numeric (showEFloat)
import System.Environment (getArgs)
import System.Mem (performMajorGC)
import Text.Printf (printf)
import Text.Read (readMaybe)

-- | Prepare inputs once and run each workload after one warmup.
main :: IO ()
main = do
    enabled <- getRTSStatsEnabled
    unless enabled (fail "Enable allocation statistics with +RTS -T -RTS")
    args <- getArgs
    case args of
        "--audit" : rest -> Audit.runAudit rest
        _ -> do
            putStrLn "workload,points,run,milliseconds,allocated_bytes,checksum"
            runBenchmarks args

-- | Dispatch the smaller codec and topology benchmark sets.
runBenchmarks :: [String] -> IO ()
runBenchmarks args = case args of
    [] -> codecBenchmarks 1000000
    [arg] | Just n <- readMaybe arg, n >= 2 -> codecBenchmarks n
    ["--topology"] -> forM_ [100, 200, 400, 1000] topologyBenchmarks
    ["--topology", arg] | Just n <- readMaybe arg, n >= 4 -> topologyBenchmarks n
    ["--arrangements"] -> forM_ [100, 400, 1600] arrangementBenchmarks
    ["--arrangements", arg] | Just n <- readMaybe arg, n >= 4 -> arrangementBenchmarks n
    _ -> fail "Usage: geometry-simple-bench [point count >= 2 | --topology [vertices >= 4] | --arrangements [vertices >= 4] | --audit [size | selection size [seconds]]] +RTS -T -RTS"

-- | Compare codec and vector costs with the same prepared coordinate sequence.
codecBenchmarks :: Int -> IO ()
codecBenchmarks count = do
    let coordinate i = let x = fromIntegral i in XY x (2 * x)
        unboxed = U.generate count coordinate
        boxed = V.generate count coordinate
        n = fromIntegral count
        expected = 3 * n * (n - 1) / 2
        textLength = 13 + U.foldl' (\total (XY x y) -> total + length (showEFloat Nothing x "") + 1 + length (showEFloat Nothing y "")) 0 unboxed + 2 * (count - 1)
    evaluate (U.foldl' checksum 0 unboxed) >>= check expected
    evaluate (V.foldl' checksum 0 boxed) >>= check expected
    _ <- evaluate textLength
    bytes <- checked (encodeWKB (LineString (CoordinatesXY unboxed)))
    _ <- evaluate (BS.length bytes)
    wkt <- checked (encodeWKT (LineString (CoordinatesXY unboxed)))
    _ <- evaluate (Text.length wkt)
    bytesRef <- newIORef bytes
    wktRef <- newIORef wkt
    geometryRef <- newIORef (LineString (CoordinatesXY unboxed))
    unboxedRef <- newIORef unboxed
    boxedRef <- newIORef boxed
    benchmark "decode-wkb" count expected $ do
        input <- readIORef bytesRef
        geometry <- checked (decodeWKB input)
        case geometry of
            LineString (CoordinatesXY coordinates) -> evaluate (U.foldl' checksum 0 coordinates)
            _ -> fail "Expected a decoded line"
    benchmark "encode-wkb" count (fromIntegral (9 + 16 * count)) $ do
        input <- readIORef geometryRef
        output <- checked (encodeWKB input)
        evaluate (fromIntegral (BS.length output))
    benchmark "decode-wkt" count expected $ do
        input <- readIORef wktRef
        geometry <- checked (decodeWKT input)
        case geometry of
            LineString (CoordinatesXY coordinates) -> evaluate (U.foldl' checksum 0 coordinates)
            _ -> fail "Expected a decoded line"
    benchmark "render-wkt" count (fromIntegral textLength) $ do
        input <- readIORef geometryRef
        output <- checked (encodeWKT input)
        evaluate (fromIntegral (Text.length output))
    benchmark "unboxed-map-fold" count (expected + 2 * n) $ do
        input <- readIORef unboxedRef
        evaluate (U.foldl' checksum 0 (U.map translate input))
    benchmark "boxed-map-fold" count (expected + 2 * n) $ do
        input <- readIORef boxedRef
        evaluate (V.foldl' checksum 0 (V.map translate input))

-- | Compare early contact, disjoint envelopes, overlapping envelopes, and point queries.
topologyBenchmarks :: Int -> IO ()
topologyBenchmarks count = do
    let circle cx cy =
            let points = [XY (cx + cos angle) (cy + sin angle) | i <- [0 .. count - 1], let angle = 2 * pi * fromIntegral i / fromIntegral count]
             in Polygon (PolygonRings (CoordinatesXY (U.fromList (points ++ take 1 points))) V.empty)
        origin = circle 0 0
        inside = PointGeometry (PointXY (XY 0 0))
        boundary = PointGeometry (PointXY (XY 1 0))
        crossingA = LineString (CoordinatesXY (U.fromList [XY (-2) (-2), XY 2 2]))
        crossingB = LineString (CoordinatesXY (U.fromList [XY (-2) 2, XY 2 (-2)]))
        cases =
            [ ("intersects-overlap", S.intersects, origin, circle 0.5 0, True)
            , ("intersects-disjoint-bounds", S.intersects, origin, circle 3 0, False)
            , ("intersects-overlapping-bounds", S.intersects, origin, circle 1.5 1.5, False)
            , ("disjoint-overlapping-bounds", S.disjoint, origin, circle 1.5 1.5, True)
            , ("contains-point", S.contains, origin, inside, True)
            , ("within-point", S.within, inside, origin, True)
            , ("contains-boundary-point", S.contains, origin, boundary, False)
            , ("covers-boundary-point", S.covers, origin, boundary, True)
            , ("intersects-crossing-lines", S.intersects, crossingA, crossingB, True)
            ]
    forM_ cases $ \(name, predicate, first, second, expected) -> do
        inputs <- evaluate (force (first, second)) >>= newIORef
        benchmark name (if name == "intersects-crossing-lines" then 2 else count) (if expected then 1 else 0) $ do
            (a, b) <- readIORef inputs
            evaluate (if predicate a b then 1 else 0)

-- | Measure full relations, polygon predicates, distance, overlay, and buffering.
arrangementBenchmarks :: Int -> IO ()
arrangementBenchmarks count = do
    let circle cx radius =
            let points = [XY (cx + radius * cos angle) (radius * sin angle) | i <- [0 .. count - 1], let angle = 2 * pi * fromIntegral i / fromIntegral count]
             in Polygon (PolygonRings (CoordinatesXY (U.fromList (points ++ take 1 points))) V.empty)
        origin = circle 0 1
        overlap = circle 0.5 1
        nested = circle 0 0.5
        -- Reflect the second polygon so its nearest vertex is always on the X axis.
        disjoint = circle 3 (-1)
        predicates =
            [ ("contains-overlap", S.contains, overlap, False)
            , ("contains-nested", S.contains, nested, True)
            , ("covers-nested", S.covers, nested, True)
            , ("touches-overlap", S.touches, overlap, False)
            , ("equals-overlap", S.equals, overlap, False)
            ]
    forM_ predicates $ \(name, predicate, second, expected) -> do
        inputs <- evaluate (force (origin, second)) >>= newIORef
        benchmarkTrials 3 name count (if expected then 1 else 0) $ do
            (a, b) <- readIORef inputs
            evaluate (if predicate a b then 1 else 0)
    overlapping <- evaluate (force (origin, overlap)) >>= newIORef
    separated <- evaluate (force (origin, disjoint)) >>= newIORef
    benchmarkTrials 3 "relate-overlap" count 1 $ do
        (a, b) <- readIORef overlapping
        evaluate (if S.relate a b == "212101212" then 1 else 0)
    benchmarkTrials 3 "distance-disjoint" count 1 $ do
        (a, b) <- readIORef separated
        evaluate (S.distance a b)
    benchmarkTrials 3 "intersection-overlap" count 1 $ do
        (a, b) <- readIORef overlapping
        result <- either (fail . show) (evaluate . force) (S.intersection a b)
        evaluate (if S.area result > 0 && S.area result < S.area a then 1 else 0)
    benchmarkTrials 3 "buffer-positive" count 1 $ do
        (a, _) <- readIORef overlapping
        result <- either (fail . show) (evaluate . force) (S.buffer 0.1 a)
        evaluate (if S.area result > S.area a && S.area result < 4 then 1 else 0)

-- | Measure seven trials for the short workloads.
benchmark :: String -> Int -> Double -> IO Double -> IO ()
benchmark = benchmarkTrials 7

-- | Measure repeated trials. Input reads stay inside each action.
benchmarkTrials :: Int -> String -> Int -> Double -> IO Double -> IO ()
benchmarkTrials trials name count expected action = do
    action >>= check expected
    forM_ [1 .. trials] $ \trial -> do
        performMajorGC
        before <- getRTSStats
        start <- getMonotonicTimeNSec
        actual <- action
        end <- getMonotonicTimeNSec
        -- Allocation totals update at GC. Exclude that GC from elapsed time.
        performMajorGC
        after <- getRTSStats
        check expected actual
        printf "%s,%d,%d,%.3f,%d,%.0f\n" name count trial (fromIntegral (end - start) / 1000000 :: Double) (allocated_bytes after - allocated_bytes before) actual

-- | Sum both ordinates and force each coordinate.
checksum :: Double -> XY -> Double
checksum total (XY x y) = total + x + y

-- | Apply the same operation to boxed and unboxed coordinates.
translate :: XY -> XY
translate (XY x y) = XY (x + 1) (y + 1)

-- | Stop on an unexpected result before reporting measurements.
check :: Double -> Double -> IO ()
check expected actual = unless (actual == expected) (fail ("Expected " ++ show expected ++ ", got " ++ show actual))

-- | Report a codec error as a failed benchmark.
checked :: Either String a -> IO a
checked = either fail pure
