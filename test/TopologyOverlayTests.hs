-- | Independent set identities and native-derived overlay regressions.
module TopologyOverlayTests (tests) where

import Control.Monad (forM_)
import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import Data.Geometry.WKT (decodeWKT)
import Data.List (sort)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (chooseInt, forAll, testProperty, (===))

-- | Check output structure, intersections of every dimension, and set laws.
tests :: TestTree
tests =
    testGroup
        "planar overlays"
        [ testCase "overlapping squares produce independent expected areas" $ do
            let first = rectangle 0 0 4 4
                second = rectangle 2 2 6 6
            forM_ [(S.intersection, 4), (S.union, 28), (S.difference, 12), (S.symmetricDifference, 24)] $ \(operation, expected) -> do
                let result = operation first second
                S.area result @?= expected
                assertBool "output topology" (S.isValid result)
        , testCase "shared polygon edge is a line" $
            assertBool "shared edge" (S.equals (S.intersection (rectangle 0 0 4 4) (rectangle 4 0 8 4)) (geometry "LINESTRING (4 0,4 4)"))
        , testCase "shared polygon corner is a point" $
            S.intersection (rectangle 0 0 4 4) (rectangle 4 4 8 8) @?= geometry "POINT (4 4)"
        , testCase "a crossing with nonintegral coordinates is retained" $
            S.intersection (geometry "LINESTRING (0 0,3 3)") (geometry "LINESTRING (0 2,3 0)") @?= geometry "POINT (1.2 1.2)"
        , testCase "mixed output has flat atomic members" $ do
            let result = S.union (geometry "LINESTRING (0 0,4 4)") (geometry "MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((5 5,7 5,7 7,5 7,5 5)))")
            case result of
                GeometryCollection children -> sort (map S.geometryType (V.toList children)) @?= ["LINESTRING", "POLYGON", "POLYGON"]
                _ -> assertBool "expected a collection" False
        , testCase "symmetric difference retains unrelated collection members" $ do
            let first = geometry "POINT (2 2)"
                second = geometry "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"
                result = S.symmetricDifference first second
            assertBool "isolated point" (S.intersects result (geometry "POINT (6 6)"))
            assertBool "external line" (S.covers result (geometry "LINESTRING (2 2,4 2)"))
            S.area result @?= 4
        , testCase "a hole touching the shell remains a separate ring" $ do
            let source = geometry "POLYGON ((0 0,6 0,6 6,0 6,0 0),(0 3,2 2,2 4,0 3))"
                result = S.union source (geometry "POLYGON EMPTY")
            assertBool "valid touching rings" (S.isValid result)
            S.numInteriorRings result @?= Just 1
            S.area result @?= 34
        , testCase "point intersection retains M and fills source elevation" $
            S.intersection (geometry "POINT M (1 1 9)") (geometry "LINESTRING Z (0 0 2,2 2 4)") @?= geometry "POINT ZM (1 1 3 9)"
        , testCase "empty point difference drops M and retains Z" $ do
            let first = geometry "POINT ZM (1 1 3 9)"
            S.difference first first @?= geometry "POINT Z EMPTY"
        , testCase "overlay closes measured rings without losing the measure" $ do
            let result = S.union (geometry "POINT M (1 1 9)") (geometry "POLYGON M ((0 0 4,2 0 4,2 2 4,0 2 4,0 0 4))")
            case S.exteriorRing result of
                Just (CoordinatesXYM points) -> U.head points @?= U.last points
                _ -> assertBool "expected a measured ring" False
        , testProperty "rectangle intersection area follows independent interval lengths" $
            forAll (chooseInt (-8, 8)) $ \x -> forAll (chooseInt (-8, 8)) $ \y ->
                let first = rectangle 0 0 4 4
                    second = rectangle (fromIntegral x) (fromIntegral y) (fromIntegral x + 3) (fromIntegral y + 5)
                    width = max 0 (min 4 (x + 3) - max 0 x)
                    height = max 0 (min 4 (y + 5) - max 0 y)
                 in S.area (S.intersection first second) === fromIntegral (width * height)
        , testProperty "union plus intersection conserves area" $
            forAll (chooseInt (-8, 8)) $ \x -> forAll (chooseInt (-8, 8)) $ \y ->
                let first = rectangle 0 0 4 4
                    second = rectangle (fromIntegral x) (fromIntegral y) (fromIntegral x + 3) (fromIntegral y + 5)
                 in S.area (S.union first second) + S.area (S.intersection first second) === 31
        ]

-- | Decode a fixed, valid WKT fixture.
geometry :: String -> Geometry
geometry = either error id . decodeWKT . Text.pack

-- | Construct a rectangle from independent coordinate bounds.
rectangle :: Double -> Double -> Double -> Double -> Geometry
rectangle left bottom right top = Polygon (PolygonRings (CoordinatesXY (U.fromList [XY left bottom, XY right bottom, XY right top, XY left top, XY left bottom])) V.empty)
