-- | Independent set identities and native-derived overlay regressions.
module TopologyOverlayTests (tests) where

import Control.Monad (forM_)
import Data.Geometry
import Data.Geometry.Internal (coordinateComponents, withCoordinates)
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
        , testCase "clipped polygon boundaries lose M as in GEOS" $ do
            let first = geometry "POLYGON ZM ((0.25 -7 0.5 28.25,2.25 -7 4.5 30.25,4 0 15 11,2 0 11 9,0.25 -7 0.5 28.25),(1.1875 -5.25 4.125 23.9375,2.1875 -5.25 6.125 24.9375,3.0625 -1.75 11.375 15.3125,2.0625 -1.75 9.375 14.3125,1.1875 -5.25 4.125 23.9375))"
                second = geometry "POLYGON ((3 -4,5 -4,6.75 3,4.75 3,3 -4))"
            case S.intersection first second of
                LineString (CoordinatesXYZM points) -> do
                    U.toList (U.map (\(XYZM x y z _) -> (x, y, z)) points) @?= [(3, -4, 9), (4, 0, 15)]
                    assertBool "missing measures" (U.all (\(XYZM _ _ _ m) -> isNaN m) points)
                _ -> assertBool "expected XYZM line" False
        , testCase "an intersection point omits a missing clipped measure" $
            S.intersection
                (geometry "POLYGON M ((-1 6 -12,1 6 -10,1 9.5 -20.5,0 9.5 -21.5,0 13 -32,-1 13 -33,-1 6 -12))")
                (geometry "POLYGON ZM ((1 -1 32 35,3 -1 36 37,3 6 43 16,1 6 39 14,1 -1 32 35))")
                @?= geometry "POINT Z (1 6 39)"
        , testCase "an original split-edge endpoint uses the elevation grid" $ do
            let result =
                    S.intersection
                        (geometry "POLYGON ((-15 -7,-12 -7,-9 -4,-10.5 -4,-7.5 -1,-9 -1,-15 -7))")
                        (geometry "POLYGON Z ((-11 -1 8,-8 -1 14,-2 5 32,-5 5 26,-11 -1 8))")
            result @?= geometry "LINESTRING Z (-9 -1 14,-8 -1 14)"
        , testCase "a shared vertex uses the noding order in both polygon rings" $ do
            let result =
                    S.union
                        (geometry "POLYGON Z ((0 0 1,2 0 1,2 2 1,0 2 1,0 0 1))")
                        (geometry "POLYGON Z ((2 -2 2,4 -2 2,4 0 2,2 0 2,2 -2 2))")
            case result of
                MultiPolygon polygons -> forM_ (V.toList polygons) $ \(PolygonRings shell _) ->
                    withCoordinates (\values -> [z | coordinate <- U.toList values, let (x, y, z, _) = coordinateComponents coordinate, x == 2, y == 0]) shell @?= [2]
                _ -> assertBool "expected two polygons" False
        , testCase "collinear shared edges retain the selected endpoint Z" $ do
            let result =
                    S.union
                        (geometry "POLYGON Z ((-4 7 6,-3 7 8,-3 11 12,-4 11 10,-4 7 6),(-3.75 8 7.5,-3.25 8 8.5,-3.25 10 10.5,-3.75 10 9.5,-3.75 8 7.5))")
                        (geometry "POLYGON ZM ((-3 7 32 7,-2 7 34 8,-2 11 38 -4,-3 11 36 -5,-3 7 32 7))")
            case S.exteriorRing result of
                Just shell -> withCoordinates (\values -> [z | coordinate <- U.toList values, let (x, y, z, _) = coordinateComponents coordinate, x == -3, y == 7]) shell @?= [32]
                _ -> assertBool "expected a polygon" False
        , testCase "coincident shells choose deterministic source ordinates" $ do
            let result =
                    S.union
                        (geometry "POLYGON ZM ((6 2 21 7,7 2 23 8,6 4 23 1,5 4 21 0,6 2 21 7),(6 2.5 21.5 5.5,6.5 2.5 22.5 6,6 3.5 22.5 2.5,5.5 3.5 21.5 2,6 2.5 21.5 5.5))")
                        (geometry "POLYGON ZM ((6 2 45 31,7 2 47 32,6 4 47 25,5 4 45 24,6 2 45 31))")
            case S.exteriorRing result of
                Just shell ->
                    withCoordinates (sort . map coordinateComponents . U.toList . U.init) shell
                        @?= [(5, 4, 45, 24), (6, 2, 45, 31), (6, 4, 47, 25), (7, 2, 47, 32)]
                _ -> assertBool "expected a polygon" False
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
