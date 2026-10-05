{-# LANGUAGE ScopedTypeVariables #-}

-- | Check Simple Features accessors and planar operations against fixed results.
module SimpleFeaturesTests (tests) where

import Control.Monad (forM_)
import Data.Geometry
import Data.Geometry.Internal (Coordinate (..), emptyCoordinates, pointFromComponents, unionDimensions)
import qualified Data.Geometry.SimpleFeatures as S
import Data.List (inits, permutations, tails)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
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
                let shape = GeometryCollection (V.fromList [PointGeometry (EmptyPoint DimXY), GeometryCollection (V.singleton (polygonXY V.empty))]) :: Geometry
                S.dimension shape @?= 2
                S.isEmpty shape @?= True
                S.dimension (GeometryCollection (V.singleton (GeometryCollection V.empty)) :: Geometry) @?= -1
            , testCase "XY metadata" $ checkDimensions (XY 1 2) 2 2 False False
            , testCase "XYZ metadata" $ checkDimensions (XYZ 1 2 3) 3 3 True False
            , testCase "XYM metadata" $ checkDimensions (XYM 1 2 3) 3 2 False True
            , testCase "XYZM metadata" $ checkDimensions (XYZM 1 2 3 4) 4 3 True True
            , testCase "mixed Z and M members have three ordinates and both flags" $ do
                let shape = GeometryCollection (V.fromList [PointGeometry (PointXYZ (XYZ 1 2 3)), PointGeometry (PointXYM (XYM 4 5 6))])
                S.coordinateDimension shape @?= 3
                S.is3D shape @?= True
                S.isMeasured shape @?= True
                S.geometryN 1 shape @?= Just (PointGeometry (PointXYM (XYM 4 5 6)))
            , testCase "coordinate accessors distinguish elevation and measure" $ do
                checkCoordinate (XY 1 2) Nothing Nothing
                checkCoordinate (XYZ 1 2 3) (Just 3) Nothing
                checkCoordinate (XYM 1 2 3) Nothing (Just 3)
                checkCoordinate (XYZM 1 2 3 4) (Just 3) (Just 4)
            , testCase "empty members do not make a collection nonempty" $ do
                let emptyShapes =
                        [ MultiPoint (U.fromList [(EmptyPoint DimXY), (EmptyPoint DimXY)])
                        , multiLineStringXY (V.fromList [U.empty, U.empty])
                        , polygonXY (V.singleton U.empty)
                        , multiPolygonXY (V.fromList [V.empty, V.singleton U.empty])
                        ] ::
                            [Geometry]
                forM_ emptyShapes $ \shape -> S.isEmpty shape @?= True
                S.isEmpty (GeometryCollection (V.fromList emptyShapes)) @?= True
                S.isEmpty (GeometryCollection (V.fromList (PointGeometry (PointXY (XY 0 0)) : emptyShapes))) @?= False
            ]
        , testGroup
            "selectors"
            [ testCase "atomic geometries count as one, including empty values" $
                forM_ [PointGeometry (EmptyPoint DimXY), lineXY U.empty, polygonXY V.empty] $ \shape -> do
                    S.numGeometries (shape :: Geometry) @?= 1
                    S.geometryN 0 shape @?= Just shape
                    S.geometryN (-1) shape @?= Nothing
                    S.geometryN 1 shape @?= Nothing
            , testCase "collections use zero-based indices and retain immediate children" $ do
                let child = MultiPoint (U.fromList [(EmptyPoint DimXY), PointXY (XY 1 2)])
                    shape = GeometryCollection (V.fromList [PointGeometry (EmptyPoint DimXY), child, GeometryCollection V.empty])
                S.numGeometries shape @?= 3
                S.geometryN 0 shape @?= Just (PointGeometry (EmptyPoint DimXY))
                S.geometryN 1 shape @?= Just child
                S.geometryN 2 shape @?= Just (GeometryCollection V.empty)
                forM_ [minBound, -1, 3, maxBound] $ \index -> S.geometryN index shape @?= Nothing
                S.numGeometries (GeometryCollection V.empty :: Geometry) @?= 0
            , testCase "multi-geometries expose their stored members" $ do
                S.geometryN 0 (MultiPoint (U.fromList [(EmptyPoint DimXY), PointXY (XY 1 2)])) @?= Just (PointGeometry (EmptyPoint DimXY))
                S.geometryN 1 (MultiPoint (U.fromList [(EmptyPoint DimXY), PointXY (XY 1 2)])) @?= Just (PointGeometry (PointXY (XY 1 2)))
                S.geometryN 0 (multiLineStringXY (V.singleton U.empty) :: Geometry) @?= Just (lineXY U.empty)
                S.geometryN 0 (multiPolygonXY (V.singleton (V.singleton unitSquare))) @?= Just (polygonXY (V.singleton unitSquare))
                S.numGeometries (MultiPoint (U.fromList [(EmptyPoint DimXY), (EmptyPoint DimXY)]) :: Geometry) @?= 2
            , testCase "line accessors retain all coordinate ordinates" $ do
                let first = XYZM 1 2 3 4
                    lastPoint = XYZM 5 6 7 8
                    shape = LineString (CoordinatesXYZM (U.fromList [first, lastPoint]))
                S.numPoints shape @?= Just 2
                S.pointN 0 shape @?= Just (PointXYZM first)
                S.pointN 1 shape @?= Just (PointXYZM lastPoint)
                S.startPoint shape @?= Just (PointXYZM first)
                S.endPoint shape @?= Just (PointXYZM lastPoint)
                forM_ [minBound, -1, 2, maxBound] $ \index -> S.pointN index shape @?= Nothing
            , testCase "line accessors distinguish empty lines and other families" $ do
                let emptyLine = lineXY U.empty :: Geometry
                    point = PointGeometry (PointXY (XY 1 2))
                S.numPoints emptyLine @?= Just 0
                S.startPoint emptyLine @?= Nothing
                S.endPoint emptyLine @?= Nothing
                S.pointN 0 emptyLine @?= Nothing
                S.numPoints point @?= Nothing
                S.pointN 0 point @?= Nothing
                S.startPoint point @?= Nothing
                S.endPoint point @?= Nothing
            , testCase "extracted points retain NaN Z and M ordinates" $ do
                let nan = 0 / 0
                    shape = LineString (CoordinatesXYZM (U.fromList [XYZM 1 2 nan 7, XYZM 3 4 6 nan, XYZM 5 6 nan nan]))
                forM_ [S.pointN 0 shape, S.startPoint shape] $ \result -> case result of
                    Just (PointXYZM (XYZM a b elevation measure)) -> do
                        (a, b, measure) @?= (1, 2, 7)
                        assertBool "Z stays NaN" (isNaN elevation)
                    _ -> assertFailure "expected the stored XYZM layout"
                case S.pointN 1 shape of
                    Just (PointXYZM (XYZM a b elevation measure)) -> do
                        (a, b, elevation) @?= (3, 4, 6)
                        assertBool "M stays NaN" (isNaN measure)
                    _ -> assertFailure "expected the stored XYZM layout"
                case S.endPoint shape of
                    Just (PointXYZM (XYZM a b elevation measure)) -> do
                        (a, b) @?= (5, 6)
                        assertBool "Z and M stay NaN" (isNaN elevation && isNaN measure)
                    _ -> assertFailure "expected the stored XYZM layout"
            , testCase "point ordinates distinguish absent fields from NaN" $ do
                forM_ [EmptyPoint DimXY, EmptyPoint DimXYZ, EmptyPoint DimXYM, EmptyPoint DimXYZM] $ \point ->
                    map ($ point) [S.pointX, S.pointY, S.pointZ, S.pointM] @?= replicate 4 Nothing
                map ($ PointXY (XY 1 2)) [S.pointX, S.pointY, S.pointZ, S.pointM] @?= [Just 1, Just 2, Nothing, Nothing]
                map ($ PointXYZM (XYZM 1 2 3 4)) [S.pointX, S.pointY, S.pointZ, S.pointM] @?= map Just [1, 2, 3, 4]
                S.pointZ (PointXYM (XYM 1 2 3)) @?= Nothing
                assertBool "stored NaN is present" (maybe False isNaN (S.pointM (PointXYM (XYM 1 2 (0 / 0)))))
            , testCase "coordinate layout union is independent of constructor tags" $
                forM_ [DimXY, DimXYZ, DimXYM, DimXYZM] $ \a ->
                    forM_ [DimXY, DimXYZ, DimXYM, DimXYZM] $ \b -> do
                        let result = PointGeometry (EmptyPoint (unionDimensions a b))
                        S.is3D result @?= any (`elem` [DimXYZ, DimXYZM]) [a, b]
                        S.isMeasured result @?= any (`elem` [DimXYM, DimXYZM]) [a, b]
            , testCase "extracted NaN XY coordinates remain nonempty points" $ do
                let shape = lineXY (U.fromList [XY (0 / 0) (0 / 0), XY 1 2])
                case S.pointN 0 shape of
                    Just point@(PointXY (XY a b)) -> do
                        assertBool "both ordinates remain NaN" (isNaN a && isNaN b)
                        S.isEmpty (PointGeometry point) @?= False
                    _ -> assertFailure "expected a stored XY point"
            , testCase "closure compares XY and requires a nonempty line" $ do
                S.isClosed (LineString (CoordinatesXYZM (U.fromList [XYZM 0 0 1 2, XYZM 1 1 3 4, XYZM 0 0 5 6]))) @?= True
                S.isClosed (lineXY (U.fromList [XY 0 0, XY 1 1])) @?= False
                S.isClosed (lineXY (U.singleton (XY 1 2))) @?= True
                S.isClosed (lineXY U.empty :: Geometry) @?= False
                S.isClosed (multiLineStringXY V.empty :: Geometry) @?= False
                S.isClosed (multiLineStringXY (V.fromList [unitSquare, unitSquare])) @?= True
                S.isClosed (multiLineStringXY (V.fromList [unitSquare, U.empty])) @?= False
                S.isClosed (polygonXY (V.singleton unitSquare)) @?= False
            , testCase "polygon ring accessors use zero-based hole indices" $ do
                let hole = U.fromList [XY 1 1, XY 3 1, XY 3 3, XY 1 3, XY 1 1]
                    shell = U.fromList [XY 0 0, XY 6 0, XY 6 6, XY 0 6, XY 0 0]
                    shape = polygonXY (V.fromList [shell, hole])
                S.exteriorRing shape @?= Just (CoordinatesXY shell)
                S.numInteriorRings shape @?= Just 1
                S.interiorRingN 0 shape @?= Just (CoordinatesXY hole)
                forM_ [minBound, -1, 1, maxBound] $ \index -> S.interiorRingN index shape @?= Nothing
                S.exteriorRing (polygonXY V.empty :: Geometry) @?= Just (CoordinatesXY U.empty)
                S.numInteriorRings (polygonXY V.empty :: Geometry) @?= Just 0
                S.interiorRingN 0 (polygonXY V.empty :: Geometry) @?= Nothing
                S.exteriorRing (lineXY unitSquare) @?= Nothing
                S.numInteriorRings (lineXY unitSquare) @?= Nothing
                S.interiorRingN 0 (lineXY unitSquare) @?= Nothing
            , testCase "ring accessors retain independent layouts" $ do
                let shell = CoordinatesXYZ (U.fromList [XYZ 0 0 1, XYZ 4 0 2, XYZ 4 4 3, XYZ 0 4 4, XYZ 0 0 1])
                    hole = CoordinatesXYM (U.fromList [XYM 1 1 5, XYM 2 1 6, XYM 2 2 7, XYM 1 2 8, XYM 1 1 5])
                    shape = Polygon (PolygonRings shell (V.singleton hole))
                S.exteriorRing shape @?= Just shell
                S.interiorRingN 0 shape @?= Just hole
                S.coordinateDimension shape @?= 3
                S.is3D shape @?= True
                S.isMeasured shape @?= True
                S.exteriorRing (Polygon (PolygonRings (emptyCoordinates DimXYZM) V.empty)) @?= Just (emptyCoordinates DimXYZM)
                assertBool "mixed rings preserve planar measurements" (samePlanarResults (mapGeometry id shape) shape)
            ]
        , testGroup
            "measurements"
            [ testCase "polygon measurements ignore ring winding" $
                forM_ [False, True] $ \reverseShell -> forM_ [False, True] $ \reverseHole -> do
                    let turn reverseRing ring = if reverseRing then U.reverse ring else ring
                        shape = polygonXY (V.fromList [turn reverseShell (holedRings V.! 0), turn reverseHole (holedRings V.! 1)])
                    S.area shape @?= 32
                    S.perimeter shape @?= 32
                    S.centroid shape @?= PointXY (XY (25 / 8) (25 / 8))
            , testCase "rings close implicitly for area and perimeter" $ do
                let openSquare = polygonXY (V.singleton (U.init unitSquare))
                S.area openSquare @?= 1
                S.perimeter openSquare @?= 4
                S.centroid openSquare @?= PointXY (XY 0.5 0.5)
            , testCase "mixed collections measure only applicable components" $ do
                let shape = GeometryCollection (V.fromList [PointGeometry (PointXY (XY 100 100)), lineXY (U.fromList [XY 0 0, XY 3 4]), GeometryCollection (V.singleton (polygonXY (V.singleton unitSquare)))])
                S.area shape @?= 1
                S.curveLength shape @?= 5
                S.perimeter shape @?= 4
                S.geometryLength shape @?= 9
                S.centroid shape @?= PointXY (XY 0.5 0.5)
                S.curveLength holedPolygon @?= 0
                S.geometryLength holedPolygon @?= 32
                S.perimeter (lineXY unitSquare) @?= 0
                S.geometryLength (lineXY unitSquare) @?= 4
                S.geometryLength (PointGeometry (PointXY (XY 1 2))) @?= 0
            , testCase "measurements project Z and M coordinates to XY" $ do
                let line = LineString (CoordinatesXYZM (U.fromList [XYZM 0 0 100 200, XYZM 3 4 (-100) (-200)]))
                    polygon = Polygon (PolygonRings (CoordinatesXYZM (U.map (\(XY a b) -> XYZM a b 100 200) unitSquare)) V.empty)
                S.curveLength line @?= 5
                S.area polygon @?= 1
                S.perimeter polygon @?= 4
                S.centroid polygon @?= PointXY (XY 0.5 0.5)
            , testCase "translated polygons retain small areas and centroids" $ do
                let offset = 2 ^ (40 :: Int)
                    shape = polygonXY (V.singleton (U.map (\(XY a b) -> XY (a + offset) (b + offset)) unitSquare))
                S.area shape @?= 1
                S.centroid shape @?= PointXY (XY (offset + 0.5) (offset + 0.5))
            , testCase "length avoids intermediate overflow and underflow" $
                forM_ [1e200, 1e-200] $ \distance ->
                    assertNear distance (S.curveLength (lineXY (U.fromList [XY 0 0, XY distance 0])))
            , testProperty "rectangles match analytic area, perimeter, and centroid" $
                forAll ((,,,) <$> chooseInt (-100000, 100000) <*> chooseInt (-100000, 100000) <*> chooseInt (1, 10000) <*> chooseInt (1, 10000)) $ \(left, bottom, width, height) ->
                    let minX = fromIntegral left
                        minY = fromIntegral bottom
                        maxX = fromIntegral (left + width)
                        maxY = fromIntegral (bottom + height)
                        shape = polygonXY (V.singleton (U.fromList [XY minX minY, XY maxX minY, XY maxX maxY, XY minX maxY]))
                     in conjoin
                            [ S.area shape === fromIntegral (width * height)
                            , S.perimeter shape === fromIntegral (2 * (width + height))
                            , S.centroid shape === PointXY (XY ((minX + maxX) / 2) ((minY + maxY) / 2))
                            ]
            , testCase "empty values have zero measurements and no centroid" $
                forM_ emptyFamilies $ \(_, shape, _) -> do
                    S.area shape @?= 0
                    S.geometryLength shape @?= 0
                    S.curveLength shape @?= 0
                    S.perimeter shape @?= 0
                    S.centroid shape @?= (EmptyPoint DimXY)
            ]
        , testGroup
            "centroids"
            [ testCase "empty centroids use XY coordinates" $ do
                forM_ [(layout, DimXY) | layout <- [DimXY, DimXYZ, DimXYM, DimXYZM]] $ \(input, output) -> do
                    S.centroid (PointGeometry (EmptyPoint input)) @?= EmptyPoint output
                    S.centroid (LineString (emptyCoordinates input)) @?= EmptyPoint output
                    S.centroid (Polygon (PolygonRings (emptyCoordinates input) V.empty)) @?= EmptyPoint output
                S.centroid (GeometryCollection (V.fromList [PointGeometry (EmptyPoint DimXYZ), PointGeometry (EmptyPoint DimXYM)])) @?= EmptyPoint DimXY
            , testCase "mixed point layouts share one planar centroid" $
                S.centroid (MultiPoint (U.fromList [PointXY (XY 0 0), PointXYZ (XYZ 3 3 99), PointXYM (XYM 6 6 77), EmptyPoint DimXYZM])) @?= PointXY (XY 3 3)
            , testCase "mixed line layouts share length weights" $ do
                let shape = MultiLineString (V.fromList [CoordinatesXY (U.fromList [XY 0 0, XY 3 4]), CoordinatesXYZM (U.fromList [XYZM 10 10 99 7, XYZM 10 12 88 6])])
                S.curveLength shape @?= 7
                assertPointNear (XY (27.5 / 7) (32 / 7)) (S.centroid shape)
            , testCase "point means retain duplicates and ignore empty points" $
                S.centroid (MultiPoint (U.fromList [(EmptyPoint DimXY), PointXY (XY 0 0), PointXY (XY 0 0), PointXY (XY 6 3)])) @?= PointXY (XY 2 1)
            , testCase "large point means avoid intermediate overflow" $
                S.centroid (MultiPoint (U.fromList [PointXY (XY 1e308 0), PointXY (XY 1e308 2)])) @?= PointXY (XY 1e308 1)
            , testCase "point means retain small terms when large coordinates cancel" $
                forM_ (permutations [1e16, 1, -1e16]) $ \ordinates ->
                    S.centroid (MultiPoint (U.fromList [PointXY (XY value 0) | value <- ordinates])) @?= PointXY (XY (1 / 3) 0)
            , testCase "point moments divide after cancellation" $
                forM_ (permutations [1e16, -4999999999999999, -4999999999999999]) $ \ordinates ->
                    S.centroid (MultiPoint (U.fromList [PointXY (XY value 0) | value <- ordinates])) @?= PointXY (XY (2 / 3) 0)
            , testCase "overflow in one ordinate does not round the other ordinate early" $
                S.centroid (MultiPoint (U.fromList [PointXY (XY 1e308 value) | value <- [1e16, -4999999999999999, -4999999999999999]])) @?= PointXY (XY 1e308 (2 / 3))
            , testCase "line centroids weight segments by length" $ do
                let line = lineXY (U.fromList [XY 0 0, XY 9 0, XY 9 1])
                assertPointNear (XY 4.95 0.05) (S.centroid line)
                assertPointNear (XY 4.95 0.05) (S.centroid (GeometryCollection (V.fromList [line, PointGeometry (PointXY (XY 999 999))])))
                let tinyLine = lineXY (U.fromList [XY 0 0, XY 1e-100 0])
                assertPointNear (XY 5e-101 0) (S.centroid (GeometryCollection (V.fromList [PointGeometry (PointXY (XY 1e308 1e308)), tinyLine])))
            , testCase "multipolygon centroids weight components by area" $ do
                let largeSquare = U.fromList [XY 10 0, XY 13 0, XY 13 3, XY 10 3, XY 10 0]
                assertPointNear (XY 10.4 1.4) (S.centroid (multiPolygonXY (V.fromList [V.singleton unitSquare, V.singleton largeSquare])))
            , testCase "zero-area polygons fall back to their boundary segments" $
                S.centroid (polygonXY (V.singleton (U.fromList [XY 0 0, XY 2 0, XY 0 0]))) @?= PointXY (XY 1 0)
            , testCase "zero-length lines fall back to their first coordinates" $ do
                S.centroid (lineXY (U.replicate 3 (XY 7 8))) @?= PointXY (XY 7 8)
                S.centroid (GeometryCollection (V.fromList [lineXY (U.replicate 3 (XY 1 1)), PointGeometry (PointXY (XY 3 3))])) @?= PointXY (XY 2 2)
            , testCase "a distant zero-length member does not move a multiline centroid" $ do
                let zero = U.replicate 2 (XY 1e16 1e16)
                    line = U.fromList [XY 0 0, XY 1 0]
                forM_ [[zero, line], [line, zero]] $ \members ->
                    S.centroid (multiLineStringXY (V.fromList members)) @?= PointXY (XY 0.5 0)
            , testCase "a nested zero-length member does not move a line centroid" $ do
                let zero = GeometryCollection (V.singleton (lineXY (U.replicate 2 (XY 1e16 1e16))))
                    line = lineXY (U.fromList [XY 0 0, XY 1 0])
                forM_ [[zero, line], [line, zero]] $ \members ->
                    S.centroid (GeometryCollection (V.fromList members)) @?= PointXY (XY 0.5 0)
            , testCase "a distant short line retains its small centroid weight" $ do
                let short = U.fromList [XY 1e16 0, XY 1e16 1e-20]
                    line = U.fromList [XY 0 0, XY 1 0]
                forM_ [[short, line], [line, short]] $ \members ->
                    assertPointNear (XY 0.5001 5e-41) (S.centroid (multiLineStringXY (V.fromList members)))
            , testCase "a distant thin polygon retains its small centroid weight" $ do
                let thin = V.singleton (U.fromList [XY 1e16 0, XY (1e16 + 2) 0, XY (1e16 + 2) 1e-20, XY 1e16 1e-20, XY 1e16 0])
                    square = V.singleton unitSquare
                forM_ [[thin, square], [square, thin]] $ \members ->
                    assertPointNear (XY 0.5002 0.5) (S.centroid (multiPolygonXY (V.fromList members)))
            , testCase "segment endpoints retain offsets before weighted cancellation" $ do
                let firstLine = U.fromList [XY 1e16 0, XY 1e16 1]
                    secondLine = U.fromList [XY (-4999999999999999) 0, XY (-4999999999999999) 2]
                forM_ [[firstLine, secondLine], [secondLine, firstLine]] $ \members ->
                    assertPointNear (XY (2 / 3) (5 / 6)) (S.centroid (multiLineStringXY (V.fromList members)))
            , testCase "polygon offsets survive cancellation between distant components" $ do
                let rectangle left = V.singleton (U.fromList [XY left 0, XY (left + 2) 0, XY (left + 2) 1, XY left 1, XY left 0])
                forM_ [[rectangle 1e16, rectangle (-1e16)], [rectangle (-1e16), rectangle 1e16]] $ \members ->
                    S.centroid (multiPolygonXY (V.fromList members)) @?= PointXY (XY 1 0.5)
            , testCase "translated thin polygon frames subtract holes locally" $
                forM_ [(1e8, 1e-8), (1e9, 1e-6)] $ \(offset, inset) -> do
                    let square low high = U.fromList [XY low low, XY high low, XY high high, XY low high, XY low low]
                        shell = square offset (offset + 100)
                        hole = square (offset + inset) (offset + 100 - inset)
                    assertPointNear (XY (offset + 50) (offset + 50)) (S.centroid (polygonXY (V.fromList [shell, hole])))
            , testCase "ignored zero-length members cannot overflow the centroid" $ do
                let zero = U.replicate 2 (XY 1e308 1e308)
                    line = U.fromList [XY 0 0, XY 1 0]
                forM_ [[zero, line], [line, zero]] $ \members ->
                    S.centroid (multiLineStringXY (V.fromList members)) @?= PointXY (XY 0.5 0)
            , testCase "empty polygons do not suppress line and point centroids" $ do
                let empty = polygonXY V.empty :: Geometry
                S.centroid (GeometryCollection (V.fromList [empty, lineXY (U.fromList [XY 0 0, XY 1 0])])) @?= PointXY (XY 0.5 0)
                S.centroid (GeometryCollection (V.fromList [empty, PointGeometry (PointXY (XY 3 4))])) @?= PointXY (XY 3 4)
            ]
        , testGroup
            "envelopes and convex hulls"
            [ testCase "empty envelopes are points and empty hulls are collections" $
                forM_ emptyFamilies $ \(_, shape, _) -> do
                    S.envelope shape @?= PointGeometry (EmptyPoint DimXY)
                    S.convexHull shape @?= GeometryCollection V.empty
            , testCase "one XY location produces a point" $ do
                let shape = MultiPoint (U.fromList [PointXYZM (XYZM 1 2 3 4), (EmptyPoint DimXY), PointXYZM (XYZM 1 2 5 6)])
                S.envelope shape @?= PointGeometry (PointXY (XY 1 2))
                S.convexHull shape @?= PointGeometry (PointXY (XY 1 2))
            , testCase "vertical envelopes retain repeated polygon corners" $
                S.envelope (lineXY (U.fromList [XY 2 4, XY 2 (-1), XY 2 0]))
                    @?= polygonXY (V.singleton (U.fromList [XY 2 (-1), XY 2 (-1), XY 2 4, XY 2 4, XY 2 (-1)]))
            , testCase "horizontal envelopes retain repeated polygon corners" $
                S.envelope (lineXY (U.fromList [XY 4 2, XY (-1) 2, XY 0 2]))
                    @?= polygonXY (V.singleton (U.fromList [XY (-1) 2, XY 4 2, XY 4 2, XY (-1) 2, XY (-1) 2]))
            , testCase "envelopes discard Z and M even on empty input" $ do
                S.envelope (PointGeometry (PointXYZM (XYZM 1 2 3 4))) @?= PointGeometry (PointXY (XY 1 2))
                S.envelope (PointGeometry (EmptyPoint DimXYZM)) @?= PointGeometry (EmptyPoint DimXY)
            , testCase "collection envelopes include every component" $ do
                let shape = GeometryCollection (V.fromList [lineXY (U.fromList [XY 1 2, XY 3 4]), PointGeometry (PointXY (XY (-2) 7))])
                assertPolygonVertices [XY (-2) 2, XY 3 2, XY 3 7, XY (-2) 7] (S.envelope shape)
            , testCase "collinear hulls retain only their endpoints" $
                assertLineEndpoints (XY 0 0) (XY 4 4) (S.convexHull (MultiPoint (U.fromList (map PointXY [XY 2 2, XY 4 4, XY 0 0, XY 2 2, XY 1 1]))))
            , testCase "hulls remove interior, duplicate, and collinear edge points" $ do
                let shape = MultiPoint (U.fromList (map PointXY [XY 0 0, XY 2 0, XY 2 2, XY 0 2, XY 1 1, XY 1 0, XY 2 2]))
                assertPolygonVertices [XY 0 0, XY 2 0, XY 2 2, XY 0 2] (S.convexHull shape)
            , testCase "hulls retain nearly collinear extreme vertices" $
                assertPolygonVertices slenderTriangle (S.convexHull (MultiPoint (U.fromList (map PointXY slenderTriangle))))
            , testCase "hull rings are counterclockwise and start at the smallest XY" $
                S.convexHull (MultiPoint (U.fromList (map PointXY [XY 0 10, XY 2 0, XY 4 5])))
                    @?= polygonXY (V.singleton (U.fromList [XY 0 10, XY 2 0, XY 4 5, XY 0 10]))
            , testCase "two hull locations use XY order regardless of input order" $ do
                let first = PointXYZ (XYZ 0 4 7)
                    second = PointXY (XY 0 0)
                forM_ [[first, second], [second, first]] $ \points ->
                    S.convexHull (MultiPoint (U.fromList points)) @?= lineXY (U.fromList [XY 0 0, XY 0 4])
            , testCase "collinear hull locations use XY order" $
                S.convexHull (MultiPoint (U.fromList (map PointXY [XY 0 2, XY 1 1, XY 2 0]))) @?= lineXY (U.fromList [XY 0 2, XY 2 0])
            , testCase "hulls ignore source Z and M" $ do
                let make first = MultiPoint (U.fromList [first, PointXY (XY 4 0), PointXY (XY 0 4), PointXYZ (XYZ 1 1 9), EmptyPoint DimXYZM])
                forM_ [PointXY (XY 0 0), PointXYZ (XYZ 0 0 7)] $ \first ->
                    S.convexHull (make first) @?= polygonXY (V.singleton (U.fromList [XY 0 0, XY 4 0, XY 0 4, XY 0 0]))
                S.convexHull (PointGeometry (PointXYZM (XYZM 1 2 (0 / 0) 7))) @?= PointGeometry (PointXY (XY 1 2))
                S.convexHull (PointGeometry (EmptyPoint DimXYZM)) @?= GeometryCollection V.empty
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
                    let first = lineXY points
                        reversed = lineXY (U.reverse points)
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
                     in S.centroid (multiLineStringXY (V.fromList [zero, line])) === S.centroid (lineXY line)
            , testProperty "translation preserves measurements and translates centroids" $
                forAll (geometryGen 2) $ \shape ->
                    let translate (XY a b) = XY (a + 128) (b - 256)
                        translated = mapGeometry translate shape
                        expected = case S.centroid shape of PointXY coordinate -> PointXY (translate coordinate); point -> point
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
                        original = polygonXY rings
                        changed = polygonXY (V.map (U.reverse . rotate) rings)
                     in conjoin
                            [ S.area changed === S.area original
                            , S.perimeter changed === S.perimeter original
                            , counterexample "centroid" (pointsNear (S.centroid original) (S.centroid changed))
                            ]
            , testProperty "line selectors recover every stored coordinate" $
                forAll lineGen $ \points ->
                    let line = lineXY points
                     in conjoin
                            [ S.numPoints line === Just (U.length points)
                            , conjoin [S.pointN index line === Just (PointXY coordinate) | (index, coordinate) <- zip [0 ..] (U.toList points)]
                            , S.startPoint line === (PointXY <$> points U.!? 0)
                            , S.endPoint line === (PointXY <$> points U.!? (U.length points - 1))
                            , S.pointN (-1) line === Nothing
                            , S.pointN (U.length points) line === Nothing
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
geometryGen :: Int -> Gen Geometry
geometryGen depth =
    oneof $
        [ PointGeometry <$> pointGen
        , lineXY <$> lineGen
        , polygonXY <$> oneof [pure V.empty, polygonGen]
        , MultiPoint . U.fromList <$> (chooseInt (0, 8) >>= (`vectorOf` pointGen))
        , multiLineStringXY . V.fromList <$> (chooseInt (0, 4) >>= (`vectorOf` lineGen))
        , multiPolygonXY <$> oneof [pure V.empty, V.singleton <$> polygonGen]
        ]
            ++ [GeometryCollection . V.fromList <$> (chooseInt (0, 4) >>= (`vectorOf` geometryGen (depth - 1))) | depth > 0]
  where
    pointGen = oneof [pure (EmptyPoint DimXY), PointXY <$> coordinateGen]

-- | Map XY positions to one chosen layout. Preserve empty members and boundaries.
mapGeometry :: forall c. (Coordinate c) => (XY -> c) -> Geometry -> Geometry
mapGeometry convert shape = case shape of
    PointGeometry point -> PointGeometry (mapPoint point)
    LineString points -> LineString (mapCoordinates points)
    Polygon rings -> Polygon (mapRings rings)
    MultiPoint points -> MultiPoint (U.map mapPoint points)
    MultiLineString lineStrings -> MultiLineString (V.map mapCoordinates lineStrings)
    MultiPolygon polygons -> MultiPolygon (V.map mapRings polygons)
    GeometryCollection children -> GeometryCollection (V.map (mapGeometry convert) children)
  where
    dimensions = coordinateDimensions (Proxy :: Proxy c)
    scalar coordinate = convert (XY (S.x coordinate) (S.y coordinate))
    mapPoint point = fromMaybe (EmptyPoint dimensions) (withPoint (pointFromComponents dimensions . coordinateComponents . scalar) point)
    mapCoordinates points =
        let values = withCoordinates (U.map (coordinateComponents . scalar)) points
         in case dimensions of
                DimXY -> CoordinatesXY (U.map coordinateFromComponents values)
                DimXYZ -> CoordinatesXYZ (U.map coordinateFromComponents values)
                DimXYM -> CoordinatesXYM (U.map coordinateFromComponents values)
                DimXYZM -> CoordinatesXYZM (U.map coordinateFromComponents values)
    mapRings (PolygonRings shell holes) = PolygonRings (mapCoordinates shell) (V.map mapCoordinates holes)

-- | Compare all planar results after a change to the coordinate layout.
samePlanarResults :: Geometry -> Geometry -> Bool
samePlanarResults original changed =
    and
        [ S.area original == S.area changed
        , S.curveLength original == S.curveLength changed
        , S.perimeter original == S.perimeter changed
        , planarPoint (S.centroid original) == planarPoint (S.centroid changed)
        , S.convexHull original == mapGeometry id (S.convexHull changed)
        , S.envelope original == S.envelope changed
        , S.isClosed original == S.isClosed changed
        ]

-- | Compare centroid positions separately from empty-result layouts.
planarPoint :: Point -> Point
planarPoint point = fromMaybe (EmptyPoint DimXY) (withPoint (\coordinate -> PointXY (XY (S.x coordinate) (S.y coordinate))) point)

-- | Allow rounding at the scale of the bounded property fixtures.
near :: Double -> Double -> Bool
near expected actual = abs (actual - expected) <= 1e-10 * max 1 (abs expected)

-- | Compare empty or finite centroid results.
pointsNear :: Point -> Point -> Bool
pointsNear (EmptyPoint DimXY) (EmptyPoint DimXY) = True
pointsNear (PointXY (XY a b)) (PointXY (XY c d)) = near a c && near b d
pointsNear _ _ = False

-- | Empty fixtures retain their geometry family and inherent dimension.
emptyFamilies :: [(String, Geometry, Int)]
emptyFamilies =
    [ ("POINT", PointGeometry (EmptyPoint DimXY), 0)
    , ("LINESTRING", lineXY U.empty, 1)
    , ("POLYGON", polygonXY V.empty, 2)
    , ("MULTIPOINT", MultiPoint U.empty, 0)
    , ("MULTILINESTRING", multiLineStringXY V.empty, 1)
    , ("MULTIPOLYGON", multiPolygonXY V.empty, 2)
    , ("GEOMETRYCOLLECTION", GeometryCollection V.empty, -1)
    ]

-- | Check layouts of atomic geometries, empty members, and empty collections.
checkDimensions :: forall c. (Coordinate c) => c -> Int -> Int -> Bool -> Bool -> Assertion
checkDimensions coordinate coordinateCount spatialCount hasZ hasM = do
    let retainLayout =
            [ PointGeometry (EmptyPoint DimXY)
            , lineXY U.empty
            , polygonXY V.empty
            , MultiPoint (U.singleton (EmptyPoint DimXY))
            , multiLineStringXY (V.singleton U.empty)
            , multiPolygonXY (V.singleton V.empty)
            ] ::
                [Geometry]
        noMembers =
            [ MultiPoint U.empty
            , multiLineStringXY V.empty
            , multiPolygonXY V.empty
            , GeometryCollection V.empty
            ] ::
                [Geometry]
        nested = GeometryCollection . V.singleton
        convert = mapGeometry (const coordinate)
    forM_ (PointGeometry (pointFromComponents (coordinateDimensions (Proxy :: Proxy c)) (coordinateComponents coordinate)) : map convert (retainLayout ++ map nested retainLayout ++ map (nested . nested) retainLayout)) $ \shape -> do
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
holedPolygon :: Geometry
holedPolygon = polygonXY holedRings

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
assertPointNear :: XY -> Point -> Assertion
assertPointNear (XY expectedX expectedY) point = case point of
    PointXY (XY actualX actualY) -> assertNear expectedX actualX >> assertNear expectedY actualY
    _ -> assertFailure ("expected a nonempty XY centroid, got " ++ show point)

-- | Accept either orientation of a two-point line.
assertLineEndpoints :: XY -> XY -> Geometry -> Assertion
assertLineEndpoints first lastPoint shape = case shape of
    LineString (CoordinatesXY coordinates) -> assertBool "unexpected line endpoints" (U.toList coordinates `elem` [[first, lastPoint], [lastPoint, first]])
    _ -> assertFailure ("expected a line, got " ++ show shape)

-- | Compare a polygon boundary without fixing its start vertex.
assertPolygonVertices :: [XY] -> Geometry -> Assertion
assertPolygonVertices expected shape = case shape of
    Polygon (PolygonRings (CoordinatesXY ring) holes) | V.null holes -> do
        U.length ring @?= length expected + 1
        U.head ring @?= U.last ring
        assertBool "unexpected polygon cycle" (U.toList (U.init ring) `elem` zipWith (++) (tails expected) (inits expected))
    _ -> assertFailure ("expected a polygon with one ring, got " ++ show shape)

-- | Construct an XY line fixture.
lineXY :: U.Vector XY -> Geometry
lineXY = LineString . CoordinatesXY

-- | Construct XY polygon rings from a vector with the shell first.
ringsXY :: V.Vector (U.Vector XY) -> PolygonRings
ringsXY rings = case rings V.!? 0 of
    Nothing -> PolygonRings (CoordinatesXY U.empty) V.empty
    Just shell -> PolygonRings (CoordinatesXY shell) (V.map CoordinatesXY (V.tail rings))

-- | Construct an XY polygon fixture.
polygonXY :: V.Vector (U.Vector XY) -> Geometry
polygonXY = Polygon . ringsXY

-- | Construct an XY multiline fixture.
multiLineStringXY :: V.Vector (U.Vector XY) -> Geometry
multiLineStringXY = MultiLineString . V.map CoordinatesXY

-- | Construct an XY multipolygon fixture.
multiPolygonXY :: V.Vector (V.Vector (U.Vector XY)) -> Geometry
multiPolygonXY = MultiPolygon . V.map ringsXY
