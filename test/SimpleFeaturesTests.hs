-- | Check Simple Features accessors and planar operations against fixed results.
module SimpleFeaturesTests (tests) where

import Control.Monad (forM_)
import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import Data.List (inits, tails)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (chooseInt, conjoin, forAll, testProperty, (===))

-- | Cover dimensional layouts, empty values, selectors, and planar measurements.
tests :: TestTree
tests =
    testGroup
        "Simple Features"
        [ testGroup
            "metadata"
            [ testCase "family names and inherent dimensions include empty values" $
                forM_ emptyFamilies $ \(name, shape, dimensions) -> do
                    S.geometryType shape @?= name
                    S.dimension shape @?= dimensions
                    S.isEmpty shape @?= True
            , testCase "collections retain their greatest child dimension" $ do
                let shape = GeometryCollection (V.fromList [PointGeometry EmptyPoint, GeometryCollection (V.singleton (Polygon V.empty))]) :: Geometry XY
                S.dimension shape @?= 2
                S.isEmpty shape @?= True
                S.dimension (GeometryCollection (V.singleton (GeometryCollection V.empty)) :: Geometry XY) @?= -1
            , testCase "XY metadata" $ checkDimensions (XY 1 2) 2 2 False False
            , testCase "XYZ metadata" $ checkDimensions (XYZ 1 2 3) 3 3 True False
            , testCase "XYM metadata" $ checkDimensions (XYM 1 2 3) 3 2 False True
            , testCase "XYZM metadata" $ checkDimensions (XYZM 1 2 3 4) 4 3 True True
            , testCase "coordinate accessors distinguish elevation and measure" $ do
                checkCoordinate (XY 1 2) Nothing Nothing
                checkCoordinate (XYZ 1 2 3) (Just 3) Nothing
                checkCoordinate (XYM 1 2 3) Nothing (Just 3)
                checkCoordinate (XYZM 1 2 3 4) (Just 3) (Just 4)
            , testCase "empty members do not make a collection nonempty" $ do
                let emptyShapes =
                        [ MultiPoint (U.fromList [EmptyPoint, EmptyPoint])
                        , MultiLineString (V.fromList [U.empty, U.empty])
                        , Polygon (V.singleton U.empty)
                        , MultiPolygon (V.fromList [V.empty, V.singleton U.empty])
                        ] ::
                            [Geometry XY]
                forM_ emptyShapes $ \shape -> S.isEmpty shape @?= True
                S.isEmpty (GeometryCollection (V.fromList emptyShapes)) @?= True
                S.isEmpty (GeometryCollection (V.fromList (PointGeometry (Point (XY 0 0)) : emptyShapes))) @?= False
            ]
        , testGroup
            "selectors"
            [ testCase "atomic geometries count as one, including empty values" $
                forM_ [PointGeometry EmptyPoint, LineString U.empty, Polygon V.empty] $ \shape -> do
                    S.numGeometries (shape :: Geometry XY) @?= 1
                    S.geometryN 1 shape @?= Just shape
                    S.geometryN 0 shape @?= Nothing
                    S.geometryN 2 shape @?= Nothing
            , testCase "collections use one-based indices and retain immediate children" $ do
                let child = MultiPoint (U.fromList [EmptyPoint, Point (XY 1 2)])
                    shape = GeometryCollection (V.fromList [PointGeometry EmptyPoint, child, GeometryCollection V.empty])
                S.numGeometries shape @?= 3
                S.geometryN 1 shape @?= Just (PointGeometry EmptyPoint)
                S.geometryN 2 shape @?= Just child
                S.geometryN 3 shape @?= Just (GeometryCollection V.empty)
                forM_ [minBound, -1, 0, 4, maxBound] $ \index -> S.geometryN index shape @?= Nothing
                S.numGeometries (GeometryCollection V.empty :: Geometry XY) @?= 0
            , testCase "multi-geometries expose their stored members" $ do
                S.geometryN 1 (MultiPoint (U.fromList [EmptyPoint, Point (XY 1 2)])) @?= Just (PointGeometry EmptyPoint)
                S.geometryN 2 (MultiPoint (U.fromList [EmptyPoint, Point (XY 1 2)])) @?= Just (PointGeometry (Point (XY 1 2)))
                S.geometryN 1 (MultiLineString (V.singleton U.empty) :: Geometry XY) @?= Just (LineString U.empty)
                S.geometryN 1 (MultiPolygon (V.singleton (V.singleton unitSquare))) @?= Just (Polygon (V.singleton unitSquare))
                S.numGeometries (MultiPoint (U.fromList [EmptyPoint, EmptyPoint]) :: Geometry XY) @?= 2
            , testCase "line accessors retain all coordinate ordinates" $ do
                let first = XYZM 1 2 3 4
                    lastPoint = XYZM 5 6 7 8
                    shape = LineString (U.fromList [first, lastPoint])
                S.numPoints shape @?= Just 2
                S.pointN 1 shape @?= Just first
                S.pointN 2 shape @?= Just lastPoint
                S.startPoint shape @?= Just first
                S.endPoint shape @?= Just lastPoint
                forM_ [minBound, -1, 0, 3, maxBound] $ \index -> S.pointN index shape @?= Nothing
            , testCase "line accessors distinguish empty lines and other families" $ do
                let emptyLine = LineString U.empty :: Geometry XY
                    point = PointGeometry (Point (XY 1 2))
                S.numPoints emptyLine @?= Just 0
                S.startPoint emptyLine @?= Nothing
                S.endPoint emptyLine @?= Nothing
                S.pointN 1 emptyLine @?= Nothing
                S.numPoints point @?= Nothing
                S.pointN 1 point @?= Nothing
                S.startPoint point @?= Nothing
                S.endPoint point @?= Nothing
            , testCase "closure compares XY and requires a nonempty line" $ do
                S.isClosed (LineString (U.fromList [XYZM 0 0 1 2, XYZM 1 1 3 4, XYZM 0 0 5 6])) @?= True
                S.isClosed (LineString (U.fromList [XY 0 0, XY 1 1])) @?= False
                S.isClosed (LineString (U.singleton (XY 1 2))) @?= True
                S.isClosed (LineString U.empty :: Geometry XY) @?= False
                S.isClosed (MultiLineString V.empty :: Geometry XY) @?= False
                S.isClosed (MultiLineString (V.fromList [unitSquare, unitSquare])) @?= True
                S.isClosed (MultiLineString (V.fromList [unitSquare, U.empty])) @?= False
                S.isClosed (Polygon (V.singleton unitSquare)) @?= False
            , testCase "polygon ring accessors use one-based hole indices" $ do
                let hole = U.fromList [XY 1 1, XY 3 1, XY 3 3, XY 1 3, XY 1 1]
                    shell = U.fromList [XY 0 0, XY 6 0, XY 6 6, XY 0 6, XY 0 0]
                    shape = Polygon (V.fromList [shell, hole])
                S.exteriorRing shape @?= Just shell
                S.numInteriorRings shape @?= Just 1
                S.interiorRingN 1 shape @?= Just hole
                forM_ [minBound, -1, 0, 2, maxBound] $ \index -> S.interiorRingN index shape @?= Nothing
                S.exteriorRing (Polygon V.empty :: Geometry XY) @?= Nothing
                S.numInteriorRings (Polygon V.empty :: Geometry XY) @?= Just 0
                S.interiorRingN 1 (Polygon V.empty :: Geometry XY) @?= Nothing
                S.exteriorRing (LineString unitSquare) @?= Nothing
                S.numInteriorRings (LineString unitSquare) @?= Nothing
                S.interiorRingN 1 (LineString unitSquare) @?= Nothing
            ]
        , testGroup
            "measurements"
            [ testCase "polygon measurements ignore ring winding" $
                forM_ [False, True] $ \reverseShell -> forM_ [False, True] $ \reverseHole -> do
                    let turn reverseRing ring = if reverseRing then U.reverse ring else ring
                        shape = Polygon (V.fromList [turn reverseShell (holedRings V.! 0), turn reverseHole (holedRings V.! 1)])
                    S.area shape @?= 32
                    S.perimeter shape @?= 32
                    S.centroid shape @?= Point (XY (25 / 8) (25 / 8))
            , testCase "rings close implicitly for area and perimeter" $ do
                let openSquare = Polygon (V.singleton (U.init unitSquare))
                S.area openSquare @?= 1
                S.perimeter openSquare @?= 4
                S.centroid openSquare @?= Point (XY 0.5 0.5)
            , testCase "mixed collections measure only applicable components" $ do
                let shape = GeometryCollection (V.fromList [PointGeometry (Point (XY 100 100)), LineString (U.fromList [XY 0 0, XY 3 4]), GeometryCollection (V.singleton (Polygon (V.singleton unitSquare)))])
                S.area shape @?= 1
                S.curveLength shape @?= 5
                S.perimeter shape @?= 4
                S.centroid shape @?= Point (XY 0.5 0.5)
                S.curveLength holedPolygon @?= 0
                S.perimeter (LineString unitSquare) @?= 0
            , testCase "measurements project Z and M coordinates to XY" $ do
                let line = LineString (U.fromList [XYZM 0 0 100 200, XYZM 3 4 (-100) (-200)])
                    polygon = Polygon (V.singleton (U.map (\(XY a b) -> XYZM a b 100 200) unitSquare))
                S.curveLength line @?= 5
                S.area polygon @?= 1
                S.perimeter polygon @?= 4
                S.centroid polygon @?= Point (XY 0.5 0.5)
            , testCase "translated polygons retain small areas and centroids" $ do
                let offset = 2 ^ (40 :: Int)
                    shape = Polygon (V.singleton (U.map (\(XY a b) -> XY (a + offset) (b + offset)) unitSquare))
                S.area shape @?= 1
                S.centroid shape @?= Point (XY (offset + 0.5) (offset + 0.5))
            , testCase "length avoids intermediate overflow and underflow" $
                forM_ [1e200, 1e-200] $ \distance ->
                    assertNear distance (S.curveLength (LineString (U.fromList [XY 0 0, XY distance 0])))
            , testProperty "rectangles match analytic area, perimeter, and centroid" $
                forAll ((,,,) <$> chooseInt (-100000, 100000) <*> chooseInt (-100000, 100000) <*> chooseInt (1, 10000) <*> chooseInt (1, 10000)) $ \(left, bottom, width, height) ->
                    let minX = fromIntegral left
                        minY = fromIntegral bottom
                        maxX = fromIntegral (left + width)
                        maxY = fromIntegral (bottom + height)
                        shape = Polygon (V.singleton (U.fromList [XY minX minY, XY maxX minY, XY maxX maxY, XY minX maxY]))
                     in conjoin
                            [ S.area shape === fromIntegral (width * height)
                            , S.perimeter shape === fromIntegral (2 * (width + height))
                            , S.centroid shape === Point (XY ((minX + maxX) / 2) ((minY + maxY) / 2))
                            ]
            , testCase "empty values have zero measurements and no centroid" $
                forM_ emptyFamilies $ \(_, shape, _) -> do
                    S.area shape @?= 0
                    S.curveLength shape @?= 0
                    S.perimeter shape @?= 0
                    S.centroid shape @?= EmptyPoint
            ]
        , testGroup
            "centroids"
            [ testCase "point means retain duplicates and ignore empty points" $
                S.centroid (MultiPoint (U.fromList [EmptyPoint, Point (XY 0 0), Point (XY 0 0), Point (XY 6 3)])) @?= Point (XY 2 1)
            , testCase "large point means avoid intermediate overflow" $
                S.centroid (MultiPoint (U.fromList [Point (XY 1e308 0), Point (XY 1e308 2)])) @?= Point (XY 1e308 1)
            , testCase "line centroids weight segments by length" $ do
                let line = LineString (U.fromList [XY 0 0, XY 9 0, XY 9 1])
                assertPointNear (XY 4.95 0.05) (S.centroid line)
                assertPointNear (XY 4.95 0.05) (S.centroid (GeometryCollection (V.fromList [line, PointGeometry (Point (XY 999 999))])))
                let tinyLine = LineString (U.fromList [XY 0 0, XY 1e-100 0])
                assertPointNear (XY 5e-101 0) (S.centroid (GeometryCollection (V.fromList [PointGeometry (Point (XY 1e308 1e308)), tinyLine])))
            , testCase "multipolygon centroids weight components by area" $ do
                let largeSquare = U.fromList [XY 10 0, XY 13 0, XY 13 3, XY 10 3, XY 10 0]
                assertPointNear (XY 10.4 1.4) (S.centroid (MultiPolygon (V.fromList [V.singleton unitSquare, V.singleton largeSquare])))
            , testCase "zero-area polygons fall back to their boundary segments" $
                S.centroid (Polygon (V.singleton (U.fromList [XY 0 0, XY 2 0, XY 0 0]))) @?= Point (XY 1 0)
            , testCase "zero-length lines fall back to their first coordinates" $ do
                S.centroid (LineString (U.replicate 3 (XY 7 8))) @?= Point (XY 7 8)
                S.centroid (GeometryCollection (V.fromList [LineString (U.replicate 3 (XY 1 1)), PointGeometry (Point (XY 3 3))])) @?= Point (XY 2 2)
            ]
        , testGroup
            "envelopes and convex hulls"
            [ testCase "empty values produce empty XY collections" $
                forM_ emptyFamilies $ \(_, shape, _) -> do
                    S.envelope shape @?= GeometryCollection V.empty
                    S.convexHull shape @?= GeometryCollection V.empty
            , testCase "one XY location produces a point" $ do
                let shape = MultiPoint (U.fromList [Point (XYZM 1 2 3 4), EmptyPoint, Point (XYZM 1 2 5 6)])
                S.envelope shape @?= PointGeometry (Point (XY 1 2))
                S.convexHull shape @?= PointGeometry (Point (XY 1 2))
            , testCase "vertical envelopes are lines" $
                assertLineEndpoints (XY 2 (-1)) (XY 2 4) (S.envelope (LineString (U.fromList [XY 2 4, XY 2 (-1), XY 2 0])))
            , testCase "collection envelopes include every component" $ do
                let shape = GeometryCollection (V.fromList [LineString (U.fromList [XY 1 2, XY 3 4]), PointGeometry (Point (XY (-2) 7))])
                assertPolygonVertices [XY (-2) 2, XY 3 2, XY 3 7, XY (-2) 7] (S.envelope shape)
            , testCase "collinear hulls retain only their endpoints" $
                assertLineEndpoints (XY 0 0) (XY 4 4) (S.convexHull (MultiPoint (U.fromList (map Point [XY 2 2, XY 4 4, XY 0 0, XY 2 2, XY 1 1]))))
            , testCase "hulls remove interior, duplicate, and collinear edge points" $ do
                let shape = MultiPoint (U.fromList (map Point [XY 0 0, XY 2 0, XY 2 2, XY 0 2, XY 1 1, XY 1 0, XY 2 2]))
                assertPolygonVertices [XY 0 0, XY 2 0, XY 2 2, XY 0 2] (S.convexHull shape)
            , testCase "hulls retain nearly collinear extreme vertices" $
                assertPolygonVertices slenderTriangle (S.convexHull (MultiPoint (U.fromList (map Point slenderTriangle))))
            ]
        ]

-- | Empty fixtures retain their geometry family and inherent dimension.
emptyFamilies :: [(String, Geometry XY, Int)]
emptyFamilies =
    [ ("POINT", PointGeometry EmptyPoint, 0)
    , ("LINESTRING", LineString U.empty, 1)
    , ("POLYGON", Polygon V.empty, 2)
    , ("MULTIPOINT", MultiPoint U.empty, 0)
    , ("MULTILINESTRING", MultiLineString V.empty, 1)
    , ("MULTIPOLYGON", MultiPolygon V.empty, 2)
    , ("GEOMETRYCOLLECTION", GeometryCollection V.empty, -1)
    ]

-- | Check dimensional metadata for both full and empty points.
checkDimensions :: (Coordinate c) => c -> Int -> Int -> Bool -> Bool -> Assertion
checkDimensions coordinate coordinateCount spatialCount hasZ hasM =
    forM_ [PointGeometry (Point coordinate), PointGeometry EmptyPoint] $ \shape -> do
        S.coordinateDimension shape @?= coordinateCount
        S.spatialDimension shape @?= spatialCount
        S.is3D shape @?= hasZ
        S.isMeasured shape @?= hasM

-- | Check coordinates whose X and Y ordinates are one and two.
checkCoordinate :: (Coordinate c) => c -> Maybe Double -> Maybe Double -> Assertion
checkCoordinate coordinate elevation measure = do
    S.x coordinate @?= 1
    S.y coordinate @?= 2
    S.z coordinate @?= elevation
    S.m coordinate @?= measure

-- | A closed unit square with counterclockwise vertices.
unitSquare :: U.Vector XY
unitSquare = U.fromList [XY 0 0, XY 1 0, XY 1 1, XY 0 1, XY 0 0]

-- | A square with an offset square hole of the same winding.
holedPolygon :: Geometry XY
holedPolygon = Polygon holedRings

-- | The exterior and interior rings of the square fixture.
holedRings :: V.Vector (U.Vector XY)
holedRings =
    V.fromList
        [ U.fromList [XY 0 0, XY 6 0, XY 6 6, XY 0 6, XY 0 0]
        , U.fromList [XY 1 1, XY 3 1, XY 3 3, XY 1 3, XY 1 1]
        ]

-- | The exact determinant is one, although Double products round it to zero.
slenderTriangle :: [XY]
slenderTriangle = [XY 0 0, XY 134217728 134217727, XY 134217729 134217728]

-- | Compare finite measurements with a relative tolerance.
assertNear :: Double -> Double -> Assertion
assertNear expected actual =
    assertBool ("expected " ++ show expected ++ ", got " ++ show actual) (abs (actual - expected) <= abs expected * 1e-12)

-- | Compare both ordinates of a nonempty centroid.
assertPointNear :: XY -> Point XY -> Assertion
assertPointNear (XY expectedX expectedY) point = case point of
    Point (XY actualX actualY) -> assertNear expectedX actualX >> assertNear expectedY actualY
    EmptyPoint -> assertFailure "expected a nonempty centroid"

-- | Accept either orientation of a two-point line.
assertLineEndpoints :: XY -> XY -> Geometry XY -> Assertion
assertLineEndpoints first lastPoint shape = case shape of
    LineString coordinates -> assertBool "unexpected line endpoints" (U.toList coordinates `elem` [[first, lastPoint], [lastPoint, first]])
    _ -> assertFailure ("expected a line, got " ++ show shape)

-- | Compare a counterclockwise polygon boundary without fixing its start vertex.
assertPolygonVertices :: [XY] -> Geometry XY -> Assertion
assertPolygonVertices expected shape = case shape of
    Polygon rings | V.length rings == 1 -> do
        let ring = rings V.! 0
        U.length ring @?= length expected + 1
        U.head ring @?= U.last ring
        assertBool "unexpected polygon cycle" (U.toList (U.init ring) `elem` zipWith (++) (tails expected) (inits expected))
    _ -> assertFailure ("expected a polygon with one ring, got " ++ show shape)
