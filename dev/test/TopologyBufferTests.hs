{-# LANGUAGE OverloadedStrings #-}

-- | Buffer regressions derived from GEOS 3.13.1.
module TopologyBufferTests (tests) where

import Data.Geometry.Internal
import qualified Data.Geometry.SimpleFeatures as S
import qualified Data.Geometry.WKT as WKT
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | Check native buffer topology, coordinate layouts, and arc construction.
tests :: TestTree
tests =
    testGroup
        "buffers"
        [ testCase "one segment per quadrant produces a diamond" $
            sameXY (S.bufferWithSegments 1 1 (geometry "POINT (0 0)")) "POLYGON ((1 0,0 -1,-1 0,0 1,1 0))"
        , testCase "nonpositive quadrant count uses one" $
            S.bufferWithSegments 0 1 (geometry "POINT (0 0)") @?= S.bufferWithSegments 1 1 (geometry "POINT (0 0)")
        , testCase "straight line joins its caps" $
            sameXY (S.bufferWithSegments 1 1 (geometry "LINESTRING (0 0,2 0)")) "POLYGON ((0 1,2 1,3 0,2 -1,0 -1,-1 0,0 1))"
        , testCase "negative point buffer is empty" $
            S.isEmpty (S.buffer (-1) (geometry "POINT ZM (1 2 3 4)")) @?= True
        , testCase "negative line buffer is empty" $
            S.isEmpty (S.buffer (-1) (geometry "LINESTRING (0 0,2 0)")) @?= True
        , testCase "nonzero buffer drops Z and M" $ do
            let result = S.buffer 1 (geometry "POINT ZM (1 2 3 4)")
            S.coordinateDimension result @?= 2
            near (S.area result) 3.121445152258052
        , testCase "zero empty polygon drops Z and M" $
            S.buffer 0 (geometry "POLYGON ZM EMPTY") @?= geometry "POLYGON EMPTY"
        , testCase "zero buffer drops M" $
            S.coordinateDimension (S.buffer 0 (geometry "POLYGON M ((0 0 1,3 0 2,0 3 3,0 0 1))")) @?= 2
        , testCase "zero buffer projects Z and M onto XY" $
            S.coordinateDimension (S.buffer 0 (geometry "POLYGON ZM ((0 0 1 4,3 0 2 5,0 3 3 6,0 0 1 4))")) @?= 2
        , testCase "zero buffer repairs the bowtie by winding" $
            sameXY (S.buffer 0 (geometry "POLYGON ((0 0,10 10,0 10,10 0,0 0))")) "POLYGON ((0 0,5 5,10 0,0 0))"
        , testCase "coincident hole curves retain both winding contributions" $ do
            let outer = geometry "POLYGON ((-2 -2,12 -2,12 12,-2 12,-2 -2),(3 3,7 3,7 7,3 7,3 3))"
                combined = geometry "GEOMETRYCOLLECTION (POLYGON ((-2 -2,12 -2,12 12,-2 12,-2 -2),(3 3,7 3,7 7,3 7,3 3)),POLYGON ((0 0,10 0,10 10,0 10,0 0),(3 3,7 3,7 7,3 7,3 3)))"
            S.equals (S.buffer 1 combined) (S.buffer 1 outer) @?= True
        , testCase "empty polygon remains empty" $
            sameXY (S.buffer 1 (geometry "POLYGON EMPTY")) "POLYGON EMPTY"
        , testCase "square erosion keeps straight corners" $
            sameXY (S.buffer (-1) (geometry "POLYGON ((0 0,10 0,10 10,0 10,0 0))")) "POLYGON ((1 1,1 9,9 9,9 1,1 1))"
        , testCase "complete erosion is empty" $
            S.isEmpty (S.buffer (-6) (geometry "POLYGON ((0 0,10 0,10 10,0 10,0 0))")) @?= True
        , testCase "collection members erode before union" $
            sameXY
                (S.buffer (-0.75) (geometry "GEOMETRYCOLLECTION (POLYGON ((0 0,2 0,2 2,0 2,0 0)),POLYGON ((1 0,3 0,3 2,1 2,1 0)))"))
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
        let result = S.bufferWithSegments count radius (geometry input)
        assertBool "buffer is invalid" (S.isValid result)
        S.geometryType result @?= "POLYGON"
        near (S.area result) expected

-- | Parse a fixed native fixture.
geometry :: Text -> Geometry
geometry text = case WKT.decodeWKT text of
    Right value -> value
    Left message -> error message
