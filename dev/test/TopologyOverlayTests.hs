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
import Test.Tasty.QuickCheck (chooseInt, conjoin, counterexample, elements, forAll, testProperty, (===))

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
        , testGroup
            "line results preserve every selected edge"
            [ testCase name $
                forM_ [(geometry first, geometry second), (geometry second, geometry first)] $ \(a, b) -> do
                    let actual = S.intersection a b
                        expected = geometry output
                    assertBool "valid line result" (S.isValid actual)
                    S.coordinateDimension actual @?= 2
                    lineEdges actual @?= lineEdges expected
            | (name, first, second, output) <-
                [ ("polygon corner contact", "POLYGON ((-7 -5,-5 -5,-5 -3,-6 -3,-6 -1,-7 -1,-7 -5))", "POLYGON ZM ((-6 -3 16 34,-4 -3 20 36,-4 1 24 24,-6 1 20 22,-6 -3 16 34))", "MULTILINESTRING ((-5 -3,-6 -3),(-6 -3,-6 -1))")
                , ("collinear polygon contact", "POLYGON ((0 0,2 0,2 1,2 2,0 2,0 0))", "POLYGON ((2 0,4 0,4 2,2 2,2 0))", "MULTILINESTRING ((2 0,2 1),(2 1,2 2))")
                , ("coincident bent lines", "LINESTRING (0 0,2 0,2 2)", "LINESTRING (2 2,2 0,0 0)", "MULTILINESTRING ((0 0,2 0),(2 0,2 2))")
                , ("line follows polygon corner", "LINESTRING (0 0,2 0,2 2)", "POLYGON ((0 0,2 0,2 2,0 2,0 0))", "MULTILINESTRING ((0 0,2 0),(2 0,2 2))")
                , ("interior bend stays connected", "LINESTRING (0 0,2 0,2 2)", "POLYGON ((-1 -1,3 -1,3 3,-1 3,-1 -1))", "LINESTRING (0 0,2 0,2 2)")
                , ("closed interior line stays connected", "LINESTRING (0 0,2 0,2 2,0 0)", "POLYGON ((-1 -1,3 -1,3 3,-1 3,-1 -1))", "LINESTRING (0 0,2 0,2 2,0 0)")
                , ("covered polygon edges do not split a line", "GEOMETRYCOLLECTION (POLYGON ((0 0,4 0,4 4,0 4,0 0)),POLYGON ((2 2,6 2,6 6,2 6,2 2)))", "LINESTRING (-1 3,7 3)", "LINESTRING (0 3,2 3,4 3,6 3)")
                , ("repeated adjacent vertices do not create extra nodes", "LINESTRING (0 0,0 0,2 0,2 0,2 2)", "POLYGON ((-1 -1,3 -1,3 3,-1 3,-1 -1))", "LINESTRING (0 0,2 0,2 2)")
                , ("self-contact retains a node inside a polygon", "LINESTRING (0 0,2 0,2 2,0 0,0 2)", "POLYGON ((-1 -1,3 -1,3 3,-1 3,-1 -1))", "MULTILINESTRING ((0 0,2 0,2 2,0 0),(0 0,0 2))")
                , ("line follows a hole corner", "LINESTRING (2 2,8 2,8 8)", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2))", "MULTILINESTRING ((2 2,8 2),(8 2,8 8))")
                ]
            ]
        , testCase "coincident bent lines retain their edges in union" $ do
            let line = geometry "LINESTRING (0 0,2 0,2 2)"
            lineEdges (S.union line line) @?= lineEdges (geometry "MULTILINESTRING ((0 0,2 0),(2 0,2 2))")
        , testProperty "coincident curves retain each source segment exactly once" $
            forAll (chooseInt (2, 64)) $ \count ->
                let points = [(fromIntegral i, fromIntegral (i `mod` 2)) | i <- [0 .. count - 1]]
                    line = LineString (CoordinatesXY (U.fromList [XY x y | (x, y) <- points]))
                    expected = sort [[a, b] | (a, b) <- zip points (drop 1 points)]
                 in (lineEdges (S.intersection line line), lineEdges (S.union line line)) === (expected, expected)
        , testCase "a crossing with nonintegral coordinates is retained" $
            S.intersection (geometry "LINESTRING (0 0,3 3)") (geometry "LINESTRING (0 2,3 0)") @?= geometry "POINT (1.2 1.2)"
        , testCase "near-coincident triangles do not produce crossing slivers" $ do
            let first = geometry "POLYGON ((-0.5 17,-18.5 1.5,40.5 35.5,-0.5 17))"
                second = geometry "POLYGON ((-0.499999999999993 17.00000000000001,-18.499999999999993 1.50000000000001,40.50000000000001 35.50000000000001,-0.499999999999993 17.00000000000001))"
            forM_ [(first, second), (second, first)] $ \(a, b) ->
                forM_ [S.union, S.intersection, S.difference, S.symmetricDifference] $ \operation ->
                    assertBool "valid rounded overlay" (S.isValid (operation a b))
            S.difference first second @?= geometry "POLYGON EMPTY"
            S.symmetricDifference first second @?= geometry "POLYGON EMPTY"
            let far = geometry "POINT (1e100 1e100)"
                mixed = S.union (GeometryCollection (V.fromList [first, far])) second
            assertBool "unrelated point does not set the rounding scale" (abs (S.area mixed - 151.25) < 1e-10)
            assertBool "unrelated point remains present" (S.covers mixed far)
        , testCase "valid sub-tolerance detail keeps its exact coordinates" $ do
            let width = 2 ** (-50)
                result = S.difference (rectangle 0 0 1 1) (rectangle width 0 1 1)
            S.area result @?= width
            assertBool "valid narrow rectangle" (S.isValid result)
            assertBool "same point set" (S.equals result (rectangle 0 0 width 1))
        , testCase "a separate polygon keeps its vertices during a local retry" $ do
            let first = geometry "POLYGON ((-0.5 17,-18.5 1.5,40.5 35.5,-0.5 17))"
                second = geometry "POLYGON ((-0.499999999999993 17.00000000000001,-18.499999999999993 1.50000000000001,40.50000000000001 35.50000000000001,-0.499999999999993 17.00000000000001))"
                distant = rectangle 1e100 1e100 (1e100 + 1e86) (1e100 + 1e86)
                result = S.union (GeometryCollection (V.fromList [first, distant])) second
            assertBool "distant component retained" (S.covers result distant)
            assertBool "local component retained" (S.covers result first)
            assertBool "valid separate polygons" (S.isValid result)
        , testProperty "near-coincident overlays stay valid across translations and scales" $
            forAll (elements [-40, -10, 0, 10, 40 :: Int]) $ \power ->
                forAll (chooseInt (-8, 8)) $ \dx -> forAll (chooseInt (-8, 8)) $ \dy ->
                    let scale = 2 ** fromIntegral power
                        polygon points = Polygon (PolygonRings (CoordinatesXY (U.fromList [XY (scale * (x + fromIntegral dx)) (scale * (y + fromIntegral dy)) | (x, y) <- points])) V.empty)
                        first = polygon [(-0.5, 17), (-18.5, 1.5), (40.5, 35.5), (-0.5, 17)]
                        second = polygon [(-0.499999999999993, 17.00000000000001), (-18.499999999999993, 1.50000000000001), (40.50000000000001, 35.50000000000001), (-0.499999999999993, 17.00000000000001)]
                        outcomes = [operation a b | (a, b) <- [(first, second), (second, first)], operation <- [S.intersection, S.union, S.difference, S.symmetricDifference]]
                     in conjoin [counterexample (show result) (S.isValid result) | result <- outcomes]
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
        , testCase "hole-assignment excludes an island touching a hole vertex" $ do
            let donut = geometry "POLYGON ((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2))"
                island = geometry "POLYGON ((2 2,5 4,4 5,2 2))"
                collection = geometry "MULTIPOLYGON (((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2)),((2 2,5 4,4 5,2 2)))"
            assertBool "valid input" (S.isValid collection)
            forM_ [S.union donut island, S.union island donut, S.buffer 0 collection] $ \result -> do
                assertBool "valid output" (S.isValid result)
                S.area result @?= 66.5
                assertBool "hole remains empty" (not (S.contains result (geometry "POINT (5 5)")))
                assertBool "island remains filled" (S.contains result (geometry "POINT (3 3)"))
        , testCase "point intersection projects stored Z and M onto XY" $
            S.intersection (geometry "POINT M (1 1 9)") (geometry "LINESTRING Z (0 0 2,2 2 4)") @?= geometry "POINT (1 1)"
        , testCase "empty results use XY" $ do
            let first = geometry "POINT ZM (1 1 3 9)"
            S.difference first first @?= geometry "POINT EMPTY"
        , testCase "clipped boundaries retain their XY segments" $ do
            let first = geometry "POLYGON ZM ((0.25 -7 0.5 28.25,2.25 -7 4.5 30.25,4 0 15 11,2 0 11 9,0.25 -7 0.5 28.25),(1.1875 -5.25 4.125 23.9375,2.1875 -5.25 6.125 24.9375,3.0625 -1.75 11.375 15.3125,2.0625 -1.75 9.375 14.3125,1.1875 -5.25 4.125 23.9375))"
                second = geometry "POLYGON ((3 -4,5 -4,6.75 3,4.75 3,3 -4))"
            S.intersection first second @?= geometry "LINESTRING (3 -4,4 0)"
        , testCase "shared vertices do not join polygon interiors" $ do
            let result = S.union (geometry "POLYGON Z ((0 0 1,2 0 1,2 2 1,0 2 1,0 0 1))") (geometry "POLYGON Z ((2 -2 2,4 -2 2,4 0 2,2 0 2,2 -2 2))")
            S.geometryType result @?= "MULTIPOLYGON"
            S.numGeometries result @?= 2
            S.area result @?= 8
            S.coordinateDimension result @?= 2
            assertBool "valid disjoint interiors" (S.isValid result)
        , testCase "coincident shells ignore conflicting source ordinates" $ do
            let result =
                    S.union
                        (geometry "POLYGON ZM ((6 2 21 7,7 2 23 8,6 4 23 1,5 4 21 0,6 2 21 7),(6 2.5 21.5 5.5,6.5 2.5 22.5 6,6 3.5 22.5 2.5,5.5 3.5 21.5 2,6 2.5 21.5 5.5))")
                        (geometry "POLYGON ZM ((6 2 45 31,7 2 47 32,6 4 47 25,5 4 45 24,6 2 45 31))")
            S.coordinateDimension result @?= 2
            assertBool "same XY hull" (S.equals result (geometry "POLYGON ((6 2,7 2,6 4,5 4,6 2))"))
            assertBool "valid polygon" (S.isValid result)
        , testCase "constructed shells and holes have opposite standard winding" $ do
            let result = S.difference (rectangle 0 0 4 4) (rectangle 1 1 3 3)
                signed points = sum [toRational x * toRational v - toRational u * toRational y | (XY x y, XY u v) <- zip (U.toList points) (drop 1 (U.toList points))]
            case result of
                Polygon (PolygonRings (CoordinatesXY shell) holes) -> do
                    assertBool "counterclockwise shell" (signed shell > 0)
                    forM_ (V.toList holes) $ \hole -> case hole of
                        CoordinatesXY points -> assertBool "clockwise hole" (signed points < 0)
                        _ -> assertBool "expected XY hole" False
                _ -> assertBool "expected XY polygon" False
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

-- | Compare every XY edge, allowing different grouping into line components.
lineEdges :: Geometry -> [[(Double, Double)]]
lineEdges shape = sort [min [a, b] [b, a] | points <- components shape, (a, b) <- zip points (drop 1 points)]
  where
    components (LineString (CoordinatesXY points)) = [map (\(XY x y) -> (x, y)) (U.toList points)]
    components (MultiLineString lines') = concatMap (components . LineString) (V.toList lines')
    components _ = error "Expected an XY line result"

-- | Construct a rectangle from independent coordinate bounds.
rectangle :: Double -> Double -> Double -> Double -> Geometry
rectangle left bottom right top = Polygon (PolygonRings (CoordinatesXY (U.fromList [XY left bottom, XY right bottom, XY right top, XY left top, XY left bottom])) V.empty)
