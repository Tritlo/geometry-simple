{-# LANGUAGE OverloadedStrings #-}

-- | Buffer regressions derived from GEOS 3.13.1.
module TopologyBufferTests (tests) where

import Control.Monad (forM_, when)
import Data.Geometry.Internal
import qualified Data.Geometry.SimpleFeatures as S
import qualified Data.Geometry.WKT as WKT
import Data.Text (Text)
import qualified Data.Vector.Unboxed as U
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | Check native buffer topology, coordinate layouts, and arc construction.
tests :: TestTree
tests =
    testGroup
        "buffers"
        [ testCase "one segment per quadrant produces a diamond" $
            sameXY (successful (S.bufferWithSegments 1 1 (geometry "POINT (0 0)"))) "POLYGON ((1 0,0 -1,-1 0,0 1,1 0))"
        , testCase "nonpositive quadrant count uses one" $
            successful (S.bufferWithSegments 0 1 (geometry "POINT (0 0)")) @?= successful (S.bufferWithSegments 1 1 (geometry "POINT (0 0)"))
        , testCase "straight line joins its caps" $
            sameXY (successful (S.bufferWithSegments 1 1 (geometry "LINESTRING (0 0,2 0)"))) "POLYGON ((0 1,2 1,3 0,2 -1,0 -1,-1 0,0 1))"
        , testCase "radii below the coordinate precision keep large rings" $ do
            S.area (successful (S.buffer (-1e-12) (geometry "POLYGON ((1000001 1000000,1000002 1000000,1000002 1000001,1000003 1000001,1000003 1000002,1000002 1000002,1000002 1000003,1000001 1000003,1000001 1000002,1000000 1000002,1000000 1000001,1000001 1000001,1000001 1000000))"))) @?= 5
            S.area (successful (S.buffer 1e-12 (geometry "POLYGON ((999990 999990,1000010 999990,1000010 1000010,999990 1000010,999990 999990),(1000001 1000000,1000002 1000000,1000002 1000001,1000003 1000001,1000003 1000002,1000002 1000002,1000002 1000003,1000001 1000003,1000001 1000002,1000000 1000002,1000000 1000001,1000001 1000001,1000001 1000000))"))) @?= 395
        , testCase "negative point buffer is empty" $
            S.isEmpty (successful (S.buffer (-1) (geometry "POINT ZM (1 2 3 4)"))) @?= True
        , testCase "negative line buffer is empty" $
            S.isEmpty (successful (S.buffer (-1) (geometry "LINESTRING (0 0,2 0)"))) @?= True
        , testCase "nonzero buffer drops Z and M" $ do
            let result = successful (S.buffer 1 (geometry "POINT ZM (1 2 3 4)"))
            S.coordinateDimension result @?= 2
            near (S.area result) 3.121445152258052
        , testCase "zero empty polygon drops Z and M" $
            successful (S.buffer 0 (geometry "POLYGON ZM EMPTY")) @?= geometry "POLYGON EMPTY"
        , testCase "zero buffer drops M" $
            S.coordinateDimension (successful (S.buffer 0 (geometry "POLYGON M ((0 0 1,3 0 2,0 3 3,0 0 1))"))) @?= 2
        , testCase "zero buffer projects Z and M onto XY" $
            S.coordinateDimension (successful (S.buffer 0 (geometry "POLYGON ZM ((0 0 1 4,3 0 2 5,0 3 3 6,0 0 1 4))"))) @?= 2
        , testCase "zero buffer selects one bowtie lobe by winding" $
            sameXY (successful (S.buffer 0 (geometry "POLYGON ((0 0,10 10,0 10,10 0,0 0))"))) "POLYGON ((0 0,5 5,10 0,0 0))"
        , testCase "buffers preserve very short and very long segments" $
            forM_ [1e-200, 1e-150, 1, 1e150, 1e200] $ \size -> do
                let line = LineString (CoordinatesXY (U.fromList [XY 0 0, XY size 0]))
                    result = successful (S.buffer size line)
                    point x y = PointGeometry (PointXY (XY x y))
                assertBool "nonempty valid buffer" (not (S.isEmpty result) && S.isValid result)
                forM_ [point 0 0, point size 0, point (size / 2) (size / 2)] $ \sample ->
                    assertBool "buffer covers an interior sample" (S.covers result sample)
        , testCase "long segment buffer keeps its middle" $ do
            let source = geometry "LINESTRING (0 0,1e200 0)"
                result = successful (S.buffer 0.5 source)
            assertBool "buffer covers its source" (S.covers result source)
        , testCase "gradual underflow does not shrink a thin buffer" $ do
            let source = geometry "LINESTRING (0 0,5e-124 0)"
                result = successful (S.buffer 1e-200 source)
            assertBool "sample below the requested radius" (S.covers result (geometry "POINT (2.5e-124 9.95e-201)"))
        , testCase "gradual underflow does not enlarge buffer offsets" $ do
            let result = successful (S.buffer 1e-100 (geometry "LINESTRING (0 0,1e-160 0)"))
            case S.envelope result of
                Polygon (PolygonRings (CoordinatesXY points) _) ->
                    assertBool "buffer radius" (U.all (\(XY x y) -> abs x <= 1.00000000000001e-100 && abs y <= 1.00000000000001e-100) points)
                _ -> assertBool "nonempty polygon envelope" False
        , testCase "a subnormal segment norm does not enlarge a large buffer" $ do
            let radius = 1e300
                result = successful (S.buffer radius (geometry "LINESTRING (0 0,5e-324 5e-324)"))
                limit = toRational radius ^ (2 :: Int) * toRational (1.00000000000001 :: Double)
            case result of
                Polygon (PolygonRings (CoordinatesXY points) _) ->
                    assertBool "vertices stay within the requested radius" (U.all (\(XY x y) -> toRational x ^ (2 :: Int) + toRational y ^ (2 :: Int) <= limit) points)
                _ -> assertBool "nonempty polygon buffer" False
        , testCase "large translated polygon erosion remains nonempty" $
            sameXY
                (successful (S.buffer (-1e307) (geometry "POLYGON ((1e308 1e308,1.6e308 1e308,1.6e308 1.6e308,1e308 1.6e308,1e308 1e308))")))
                "POLYGON ((1.1e308 1.1e308,1.5e308 1.1e308,1.5e308 1.5e308,1.1e308 1.5e308,1.1e308 1.1e308))"
        , testCase "unrepresentable offsets return an explicit error" $
            S.buffer 1e308 (geometry "POINT (1e308 1e308)") @?= Left S.CoordinateOverflow
        , testCase "near-coincident polygons produce valid rounded buffers" $ do
            let source = geometry "GEOMETRYCOLLECTION (POLYGON ((-0.5 17,-18.5 1.5,40.5 35.5,-0.5 17)),POLYGON ((-0.499999999999993 17.00000000000001,-18.499999999999993 1.50000000000001,40.50000000000001 35.50000000000001,-0.499999999999993 17.00000000000001)))"
            forM_ [-1, 0, 0.5, 2] $ \radius -> do
                let result = successful (S.buffer radius source)
                assertBool "valid rounded buffer" (S.isValid result)
                when (radius == 0) (near (S.area result) 151.25)
        , testCase "coincident hole curves retain both winding contributions" $ do
            let outer = geometry "POLYGON ((-2 -2,12 -2,12 12,-2 12,-2 -2),(3 3,7 3,7 7,3 7,3 3))"
                combined = geometry "GEOMETRYCOLLECTION (POLYGON ((-2 -2,12 -2,12 12,-2 12,-2 -2),(3 3,7 3,7 7,3 7,3 3)),POLYGON ((0 0,10 0,10 10,0 10,0 0),(3 3,7 3,7 7,3 7,3 3)))"
            S.equals (successful (S.buffer 1 combined)) (successful (S.buffer 1 outer)) @?= True
        , testCase "empty polygon remains empty" $
            sameXY (successful (S.buffer 1 (geometry "POLYGON EMPTY"))) "POLYGON EMPTY"
        , testCase "square erosion keeps straight corners" $
            sameXY (successful (S.buffer (-1) (geometry "POLYGON ((0 0,10 0,10 10,0 10,0 0))"))) "POLYGON ((1 1,1 9,9 9,9 1,1 1))"
        , testCase "complete erosion is empty" $
            S.isEmpty (successful (S.buffer (-6) (geometry "POLYGON ((0 0,10 0,10 10,0 10,0 0))"))) @?= True
        , testCase "collection members erode before union" $
            sameXY
                (successful (S.buffer (-0.75) (geometry "GEOMETRYCOLLECTION (POLYGON ((0 0,2 0,2 2,0 2,0 0)),POLYGON ((1 0,3 0,3 2,1 2,1 0)))")))
                "MULTIPOLYGON (((0.75 0.75,0.75 1.25,1.25 1.25,1.25 0.75,0.75 0.75)),((1.75 0.75,1.75 1.25,2.25 1.25,2.25 0.75,1.75 0.75)))"
        , testCase "diagonal cap remains attached after floating-point offsets" $
            validArea 2 6 "LINESTRING (0 0,10 5)" 235.98745514085024
        , testCase "reversed diagonal segments have round ends" $
            validArea 2 1 "LINESTRING (0 0,5 5,0 0)" 16.970562748477146
        , testCase "shallow corners use native simplification" $
            validArea 8 1 "LINESTRING (0 0,1 0,1.001 0.001,2 0,3 0)" 9.121949269329543
        , testCase "independent side simplification joins directly after the cap" $
            validArea 2 10 "LINESTRING (0 0,1.0003 0.0042,1.0004 0.0034,1.0005 0.0035)" 306.71659023111783
        , testCase "large positive buffer removes a hole" $
            validArea 2 6 "POLYGON ((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2))" 441.8233764908628
        , testCase "native arc rounding at a bowtie intersection" $
            validArea 1 0.5 "POLYGON ((0 0,4 4,0 4,4 0,0 0))" 9.39778535552233
        , testCase "reversed ring spike follows native orientation" $
            validArea 2 0.2 "POLYGON ((9 9,0 9,7 5,9 6,9 3,9 9))" 26.629320378500218
        ]
  where
    sameXY actual expected = do
        assertBool "buffer is invalid" (S.isValid actual)
        assertBool "buffer differs from native shape" (S.equals actual (geometry expected))
    near actual expected = assertBool ("expected " ++ show expected ++ ", got " ++ show actual) (abs (actual - expected) <= 1e-10 * max 1 (abs expected))
    validArea count radius input expected = do
        let result = successful (S.bufferWithSegments count radius (geometry input))
        assertBool "buffer is invalid" (S.isValid result)
        S.geometryType result @?= "POLYGON"
        near (S.area result) expected

-- | Parse a fixed native fixture.
geometry :: Text -> Geometry
geometry text = case WKT.decodeWKT text of
    Right value -> value
    Left message -> error message

-- | Require successful construction for a fixture or generated valid input.
successful :: (Show e) => Either e a -> a
successful = either (error . show) id
