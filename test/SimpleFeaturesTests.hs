-- | Check Simple Features accessors and planar operations against fixed results.
module SimpleFeaturesTests (tests) where

import Control.Monad (forM_)
import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import Data.List (inits, permutations, tails)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, chooseInt, conjoin, counterexample, forAll, oneof, testProperty, vectorOf, (===))

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
                S.exteriorRing (Polygon V.empty :: Geometry XY) @?= Just U.empty
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
                S.geometryLength shape @?= 9
                S.centroid shape @?= Point (XY 0.5 0.5)
                S.curveLength holedPolygon @?= 0
                S.geometryLength holedPolygon @?= 32
                S.perimeter (LineString unitSquare) @?= 0
                S.geometryLength (LineString unitSquare) @?= 4
                S.geometryLength (PointGeometry (Point (XY 1 2))) @?= 0
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
                    S.geometryLength shape @?= 0
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
            , testCase "point means retain small terms when large coordinates cancel" $
                forM_ (permutations [1e16, 1, -1e16]) $ \ordinates ->
                    S.centroid (MultiPoint (U.fromList [Point (XY value 0) | value <- ordinates])) @?= Point (XY (1 / 3) 0)
            , testCase "point moments divide after cancellation" $
                forM_ (permutations [1e16, -4999999999999999, -4999999999999999]) $ \ordinates ->
                    S.centroid (MultiPoint (U.fromList [Point (XY value 0) | value <- ordinates])) @?= Point (XY (2 / 3) 0)
            , testCase "overflow in one ordinate does not round the other ordinate early" $
                S.centroid (MultiPoint (U.fromList [Point (XY 1e308 value) | value <- [1e16, -4999999999999999, -4999999999999999]])) @?= Point (XY 1e308 (2 / 3))
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
            , testCase "a distant zero-length member does not move a multiline centroid" $ do
                let zero = U.replicate 2 (XY 1e16 1e16)
                    line = U.fromList [XY 0 0, XY 1 0]
                forM_ [[zero, line], [line, zero]] $ \members ->
                    S.centroid (MultiLineString (V.fromList members)) @?= Point (XY 0.5 0)
            , testCase "a nested zero-length member does not move a line centroid" $ do
                let zero = GeometryCollection (V.singleton (LineString (U.replicate 2 (XY 1e16 1e16))))
                    line = LineString (U.fromList [XY 0 0, XY 1 0])
                forM_ [[zero, line], [line, zero]] $ \members ->
                    S.centroid (GeometryCollection (V.fromList members)) @?= Point (XY 0.5 0)
            , testCase "a distant short line retains its small centroid weight" $ do
                let short = U.fromList [XY 1e16 0, XY 1e16 1e-20]
                    line = U.fromList [XY 0 0, XY 1 0]
                forM_ [[short, line], [line, short]] $ \members ->
                    assertPointNear (XY 0.5001 5e-41) (S.centroid (MultiLineString (V.fromList members)))
            , testCase "a distant thin polygon retains its small centroid weight" $ do
                let thin = V.singleton (U.fromList [XY 1e16 0, XY (1e16 + 2) 0, XY (1e16 + 2) 1e-20, XY 1e16 1e-20, XY 1e16 0])
                    square = V.singleton unitSquare
                forM_ [[thin, square], [square, thin]] $ \members ->
                    assertPointNear (XY 0.5002 0.5) (S.centroid (MultiPolygon (V.fromList members)))
            , testCase "segment endpoints retain offsets before weighted cancellation" $ do
                let firstLine = U.fromList [XY 1e16 0, XY 1e16 1]
                    secondLine = U.fromList [XY (-4999999999999999) 0, XY (-4999999999999999) 2]
                forM_ [[firstLine, secondLine], [secondLine, firstLine]] $ \members ->
                    assertPointNear (XY (2 / 3) (5 / 6)) (S.centroid (MultiLineString (V.fromList members)))
            , testCase "polygon offsets survive cancellation between distant components" $ do
                let rectangle left = V.singleton (U.fromList [XY left 0, XY (left + 2) 0, XY (left + 2) 1, XY left 1, XY left 0])
                forM_ [[rectangle 1e16, rectangle (-1e16)], [rectangle (-1e16), rectangle 1e16]] $ \members ->
                    S.centroid (MultiPolygon (V.fromList members)) @?= Point (XY 1 0.5)
            , testCase "translated thin polygon frames subtract holes locally" $
                forM_ [(1e8, 1e-8), (1e9, 1e-6)] $ \(offset, inset) -> do
                    let square low high = U.fromList [XY low low, XY high low, XY high high, XY low high, XY low low]
                        shell = square offset (offset + 100)
                        hole = square (offset + inset) (offset + 100 - inset)
                    assertPointNear (XY (offset + 50) (offset + 50)) (S.centroid (Polygon (V.fromList [shell, hole])))
            , testCase "ignored zero-length members cannot overflow the centroid" $ do
                let zero = U.replicate 2 (XY 1e308 1e308)
                    line = U.fromList [XY 0 0, XY 1 0]
                forM_ [[zero, line], [line, zero]] $ \members ->
                    S.centroid (MultiLineString (V.fromList members)) @?= Point (XY 0.5 0)
            , testCase "empty polygons do not suppress line and point centroids" $ do
                let empty = Polygon V.empty :: Geometry XY
                S.centroid (GeometryCollection (V.fromList [empty, LineString (U.fromList [XY 0 0, XY 1 0])])) @?= Point (XY 0.5 0)
                S.centroid (GeometryCollection (V.fromList [empty, PointGeometry (Point (XY 3 4))])) @?= Point (XY 3 4)
            ]
        , testGroup
            "envelopes and convex hulls"
            [ testCase "empty envelopes are points and empty hulls are collections" $
                forM_ emptyFamilies $ \(_, shape, _) -> do
                    S.envelope shape @?= PointGeometry EmptyPoint
                    S.convexHull shape @?= GeometryCollection V.empty
            , testCase "one XY location produces a point" $ do
                let shape = MultiPoint (U.fromList [Point (XYZM 1 2 3 4), EmptyPoint, Point (XYZM 1 2 5 6)])
                S.envelope shape @?= PointGeometry (Point (XY 1 2))
                S.convexHull shape @?= PointGeometry (Point (XY 1 2))
            , testCase "vertical envelopes retain repeated polygon corners" $
                S.envelope (LineString (U.fromList [XY 2 4, XY 2 (-1), XY 2 0]))
                    @?= Polygon (V.singleton (U.fromList [XY 2 (-1), XY 2 (-1), XY 2 4, XY 2 4, XY 2 (-1)]))
            , testCase "horizontal envelopes retain repeated polygon corners" $
                S.envelope (LineString (U.fromList [XY 4 2, XY (-1) 2, XY 0 2]))
                    @?= Polygon (V.singleton (U.fromList [XY (-1) 2, XY 4 2, XY 4 2, XY (-1) 2, XY (-1) 2]))
            , testCase "envelopes discard Z and M even on empty input" $ do
                S.envelope (PointGeometry (Point (XYZM 1 2 3 4))) @?= PointGeometry (Point (XY 1 2))
                S.envelope (PointGeometry EmptyPoint :: Geometry XYZM) @?= PointGeometry EmptyPoint
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
        , testGroup
            "geometric properties"
            [ testProperty "collections add each applicable measurement" $
                forAll ((,) <$> geometryGen 1 <*> geometryGen 1) $ \(first, second) ->
                    let collection = GeometryCollection (V.fromList [first, second])
                     in conjoin
                            [ measure collection === measure first + measure second
                            | measure <- [S.area, S.curveLength, S.perimeter]
                            ]
            , testProperty "reversing a line preserves length and centroid" $
                forAll lineGen $ \points ->
                    let first = LineString points
                        reversed = LineString (U.reverse points)
                     in conjoin
                            [ counterexample "length" (near (S.curveLength first) (S.curveLength reversed))
                            , counterexample "centroid" (pointsNear (S.centroid first) (S.centroid reversed))
                            ]
            , testProperty "collection order preserves the centroid" $
                forAll (vectorOf 5 (geometryGen 1)) $ \members ->
                    let centroid = S.centroid . GeometryCollection . V.fromList
                     in counterexample (show (centroid members, centroid (reverse members))) $
                            pointsNear (centroid members) (centroid (reverse members))
            , testProperty "zero-length members have no weight beside a line" $
                forAll (chooseInt (54, 80)) $ \power ->
                    let distant = fromInteger (2 ^ power)
                        zero = U.replicate 2 (XY distant distant)
                        line = U.fromList [XY 0 0, XY 1 0]
                     in S.centroid (MultiLineString (V.fromList [zero, line])) === S.centroid (LineString line)
            , testProperty "translation preserves measurements and translates centroids" $
                forAll (geometryGen 2) $ \shape ->
                    let translate (XY a b) = XY (a + 128) (b - 256)
                        translated = mapGeometry translate shape
                        expected = case S.centroid shape of EmptyPoint -> EmptyPoint; Point coordinate -> Point (translate coordinate)
                     in conjoin
                            [ S.area translated === S.area shape
                            , S.curveLength translated === S.curveLength shape
                            , S.perimeter translated === S.perimeter shape
                            , counterexample "centroid" (pointsNear expected (S.centroid translated))
                            ]
            , testProperty "Z and M do not affect planar results" $
                forAll (geometryGen 2) $ \shape ->
                    let xyz = mapGeometry (\(XY a b) -> XYZ a b (a * b)) shape
                        xym = mapGeometry (\(XY a b) -> XYM a b (a - b)) shape
                        xyzm = mapGeometry (\(XY a b) -> XYZM a b (a * b) (a - b)) shape
                     in conjoin [samePlanarResults shape xyz, samePlanarResults shape xym, samePlanarResults shape xyzm]
            , testProperty "envelopes and hulls are idempotent and share bounds" $
                forAll (geometryGen 2) $ \shape ->
                    let hull = S.convexHull shape
                        bounds = S.envelope shape
                     in conjoin
                            [ S.envelope bounds === bounds
                            , S.convexHull hull === hull
                            , S.envelope hull === bounds
                            , S.isEmpty bounds === S.isEmpty shape
                            , S.isEmpty hull === S.isEmpty shape
                            ]
            , testProperty "ring rotation and winding preserve polygon measurements" $
                forAll polygonGen $ \rings ->
                    let rotate ring = let open = U.init ring; turned = U.snoc (U.tail open) (U.head open) in U.snoc turned (U.head turned)
                        original = Polygon rings
                        changed = Polygon (V.map (U.reverse . rotate) rings)
                     in conjoin
                            [ S.area changed === S.area original
                            , S.perimeter changed === S.perimeter original
                            , counterexample "centroid" (pointsNear (S.centroid original) (S.centroid changed))
                            ]
            , testProperty "line selectors recover every stored coordinate" $
                forAll lineGen $ \points ->
                    let line = LineString points
                     in conjoin
                            [ S.numPoints line === Just (U.length points)
                            , conjoin [S.pointN (index + 1) line === Just coordinate | (index, coordinate) <- zip [0 ..] (U.toList points)]
                            , S.startPoint line === points U.!? 0
                            , S.endPoint line === points U.!? (U.length points - 1)
                            , S.pointN 0 line === Nothing
                            , S.pointN (U.length points + 1) line === Nothing
                            ]
            ]
        ]

-- | Generate finite integer coordinates so that translations remain exact.
coordinateGen :: Gen XY
coordinateGen = XY <$> ordinate <*> ordinate
  where
    ordinate = fromIntegral <$> chooseInt (-1000, 1000)

-- | Generate empty lines and lines with at least two coordinates.
lineGen :: Gen (U.Vector XY)
lineGen = do
    count <- oneof [pure 0, chooseInt (2, 12)]
    U.fromList <$> vectorOf count coordinateGen

-- | Generate valid rectangles with a rectangular hole and integral coordinates.
polygonGen :: Gen (V.Vector (U.Vector XY))
polygonGen = do
    XY left bottom <- coordinateGen
    width <- fromIntegral <$> chooseInt (4, 100)
    height <- fromIntegral <$> chooseInt (4, 100)
    let rectangle a b c d = U.fromList [XY a b, XY c b, XY c d, XY a d, XY a b]
        shell = rectangle left bottom (left + width) (bottom + height)
        hole = rectangle (left + 1) (bottom + 1) (left + width - 1) (bottom + height - 1)
    oneof [pure (V.singleton shell), pure (V.fromList [shell, hole])]

-- | Generate all geometry families with valid polygons and bounded collections.
geometryGen :: Int -> Gen (Geometry XY)
geometryGen depth =
    oneof $
        [ PointGeometry <$> pointGen
        , LineString <$> lineGen
        , Polygon <$> oneof [pure V.empty, polygonGen]
        , MultiPoint . U.fromList <$> (chooseInt (0, 8) >>= (`vectorOf` pointGen))
        , MultiLineString . V.fromList <$> (chooseInt (0, 4) >>= (`vectorOf` lineGen))
        , MultiPolygon <$> oneof [pure V.empty, V.singleton <$> polygonGen]
        ]
            ++ [GeometryCollection . V.fromList <$> (chooseInt (0, 4) >>= (`vectorOf` geometryGen (depth - 1))) | depth > 0]
  where
    pointGen = oneof [pure EmptyPoint, Point <$> coordinateGen]

-- | Map stored coordinates and preserve every empty value and member boundary.
mapGeometry :: (Coordinate a, Coordinate b) => (a -> b) -> Geometry a -> Geometry b
mapGeometry convert shape = case shape of
    PointGeometry point -> PointGeometry (mapPoint point)
    LineString points -> LineString (U.map convert points)
    Polygon rings -> Polygon (V.map (U.map convert) rings)
    MultiPoint points -> MultiPoint (U.map mapPoint points)
    MultiLineString lineStrings -> MultiLineString (V.map (U.map convert) lineStrings)
    MultiPolygon polygons -> MultiPolygon (V.map (V.map (U.map convert)) polygons)
    GeometryCollection children -> GeometryCollection (V.map (mapGeometry convert) children)
  where
    mapPoint EmptyPoint = EmptyPoint
    mapPoint (Point coordinate) = Point (convert coordinate)

-- | Compare all planar results after a change to the coordinate layout.
samePlanarResults :: (Coordinate c) => Geometry XY -> Geometry c -> Bool
samePlanarResults original changed =
    and
        [ S.area original == S.area changed
        , S.curveLength original == S.curveLength changed
        , S.perimeter original == S.perimeter changed
        , S.centroid original == S.centroid changed
        , S.convexHull original == S.convexHull changed
        , S.envelope original == S.envelope changed
        , S.isClosed original == S.isClosed changed
        ]

-- | Allow rounding at the scale of the bounded property fixtures.
near :: Double -> Double -> Bool
near expected actual = abs (actual - expected) <= 1e-10 * max 1 (abs expected)

-- | Compare empty or finite centroid results.
pointsNear :: Point XY -> Point XY -> Bool
pointsNear EmptyPoint EmptyPoint = True
pointsNear (Point (XY a b)) (Point (XY c d)) = near a c && near b d
pointsNear _ _ = False

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

-- | Check layouts of atomic geometries, empty members, and empty collections.
checkDimensions :: (Coordinate c) => c -> Int -> Int -> Bool -> Bool -> Assertion
checkDimensions coordinate coordinateCount spatialCount hasZ hasM = do
    let retainLayout =
            [ PointGeometry EmptyPoint
            , LineString U.empty
            , Polygon V.empty
            , MultiPoint (U.singleton EmptyPoint)
            , MultiLineString (V.singleton U.empty)
            , MultiPolygon (V.singleton V.empty)
            ] ::
                [Geometry XY]
        noMembers =
            [ MultiPoint U.empty
            , MultiLineString V.empty
            , MultiPolygon V.empty
            , GeometryCollection V.empty
            ] ::
                [Geometry XY]
        nested = GeometryCollection . V.singleton
        convert = mapGeometry (const coordinate)
    forM_ (PointGeometry (Point coordinate) : map convert (retainLayout ++ map nested retainLayout ++ map (nested . nested) retainLayout)) $ \shape -> do
        S.coordinateDimension shape @?= coordinateCount
        S.spatialDimension shape @?= spatialCount
        S.is3D shape @?= hasZ
        S.isMeasured shape @?= hasM
    forM_ (map convert (noMembers ++ map nested noMembers ++ map (nested . nested) noMembers)) $ \shape -> do
        S.coordinateDimension shape @?= 2
        S.spatialDimension shape @?= 2
        S.is3D shape @?= False
        S.isMeasured shape @?= False

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
