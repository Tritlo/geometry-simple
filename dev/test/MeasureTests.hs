-- | Check measured-location queries against OGC SFA 1.2.1 section 6.1.2.6.
module MeasureTests (tests) where

import Control.Monad (forM_)
import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import Data.Geometry.WKT (decodeWKT)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (chooseInt, forAll, testProperty, (===))

-- | Cover the standard examples and the documented interpolation rules.
tests :: TestTree
tests =
    testGroup
        "measured locations"
        [ testGroup "OGC examples" [testCase name (S.locateBetween lower upper (geometry input) @?= Just (geometry output)) | (name, lower, upper, input, output) <- examples]
        , testCase "empty inputs return null" $
            forM_ ["POINT EMPTY", "LINESTRING M EMPTY", "POLYGON ZM EMPTY", "GEOMETRYCOLLECTION (POINT M EMPTY,LINESTRING EMPTY)"] $ \input ->
                S.locateAlong 1 (geometry input) @?= Nothing
        , testCase "unmeasured nonempty inputs return an empty XY point" $
            forM_ ["POINT (1 2)", "POINT Z (1 2 4)", "LINESTRING (0 0,2 2)"] $ \input ->
                S.locateAlong 0 (geometry input) @?= Just (geometry "POINT EMPTY")
        , testCase "descending measures preserve line direction" $
            S.locateBetween 2 8 (geometry "LINESTRING M (0 0 10,10 10 0)")
                @?= Just (geometry "MULTILINESTRING M ((2 2 8,8 8 2))")
        , testCase "reversed intervals are empty" $
            S.locateBetween 8 2 (geometry "LINESTRING M (0 0 0,10 10 10)")
                @?= Just (geometry "POINT M EMPTY")
        , testCase "Z is interpolated and XYZM is retained" $
            S.locateBetween 2 8 (geometry "LINESTRING ZM (0 0 10 0,10 20 30 10)")
                @?= Just (geometry "MULTILINESTRING ZM ((2 4 14 2,8 16 26 8))")
        , testCase "an exact matching vertex appears only once" $
            S.locateAlong 3 (geometry "LINESTRING M (0 0 0,1 1 3,2 0 0)")
                @?= Just (geometry "MULTIPOINT M ((1 1 3))")
        , testCase "a repeated matching coordinate remains a point" $
            S.locateAlong 3 (geometry "LINESTRING M (0 0 3,0 0 3,2 0 5)")
                @?= Just (geometry "MULTIPOINT M ((0 0 3))")
        , testCase "a measured ring selects its closing point once" $
            forM_ ["LINESTRING M (0 0 0,2 0 1,0 2 1,0 0 0)", "POLYGON M ((0 0 0,2 0 1,0 2 1,0 0 0))"] $ \input -> do
                S.locateAlong 0 (geometry input) @?= Just (geometry "MULTIPOINT M ((0 0 0))")
                S.locateBetween 0 0.5 (geometry input) @?= Just (geometry "MULTILINESTRING M ((0 1 0.5,0 0 0,1 0 0.5))")
        , testCase "a measure reversal can create separate runs" $
            S.locateBetween 1 2 (geometry "LINESTRING M (0 0 0,3 0 3,6 0 0)")
                @?= Just (geometry "MULTILINESTRING M ((1 0 1,2 0 2),(4 0 2,5 0 1))")
        , testCase "constant intervals and isolated matches coexist" $
            S.locateAlong 4 (geometry "LINESTRING M (0 0 4,1 0 4,2 0 0,3 0 4,4 0 0)")
                @?= Just (geometry "GEOMETRYCOLLECTION (MULTILINESTRING M ((0 0 4,1 0 4)),MULTIPOINT M ((3 0 4)))")
        , testCase "touching line members remain separate" $
            S.locateBetween 0 3 (geometry "MULTILINESTRING M ((0 0 0,1 0 1),(1 0 1,2 0 2))")
                @?= Just (geometry "MULTILINESTRING M ((0 0 0,1 0 1),(1 0 1,2 0 2))")
        , testCase "different member layouts remain different" $ do
            let input = GeometryCollection (V.fromList [geometry "LINESTRING M (0 0 0,2 0 2)", geometry "LINESTRING ZM (0 1 4 0,2 1 8 2)", geometry "POINT (1 5)"])
                expected = MultiPoint (U.fromList [PointXYM (XYM 1 0 1), PointXYZM (XYZM 1 1 6 1)])
            S.locateAlong 1 input @?= Just expected
        , testCase "polygons select their measured boundary curves" $
            S.locateAlong 2 (geometry "POLYGON M ((0 0 0,4 0 4,4 4 4,0 4 0,0 0 0))")
                @?= Just (geometry "MULTIPOINT M ((2 0 2),(2 4 2))")
        , testCase "polygon holes use their own measures and layouts" $ do
            let shell = CoordinatesXY (U.fromList [XY 0 0, XY 5 0, XY 5 5, XY 0 5, XY 0 0])
                hole = CoordinatesXYM (U.fromList [XYM 1 1 0, XYM 3 1 2, XYM 3 3 2, XYM 1 3 0, XYM 1 1 0])
            S.locateAlong 1 (Polygon (PolygonRings shell (V.singleton hole)))
                @?= Just (geometry "MULTIPOINT M ((2 1 1),(2 3 1))")
        , testCase "large opposite measures do not overflow interpolation" $
            S.locateAlong 0 (geometry "LINESTRING ZM (-1e308 0 -1e308 -1e308,1e308 2 1e308 1e308)")
                @?= Just (geometry "MULTIPOINT ZM ((0 1 0 0))")
        , testCase "NaN interval endpoints match nothing" $ do
            let input = geometry "LINESTRING M (0 0 0,1 1 1)"
            S.locateBetween (0 / 0) 1 input @?= Just (geometry "POINT M EMPTY")
            S.locateBetween 0 (0 / 0) input @?= Just (geometry "POINT M EMPTY")
        , testCase "unknown endpoint measures do not connect selected points" $ do
            let input = LineString (CoordinatesXYM (U.fromList [XYM 0 0 1, XYM 1 0 (0 / 0), XYM 2 0 1]))
            S.locateAlong 1 input @?= Just (geometry "MULTIPOINT M ((0 0 1),(2 0 1))")
        , testProperty "linear measures recover the interpolated XYZM coordinate" $
            forAll (chooseInt (-50, 50)) $ \value ->
                let input = geometry "LINESTRING ZM (-50 -100 -46 -50,50 100 54 50)"
                    measure = fromIntegral value
                    expected = MultiPoint (U.singleton (PointXYZM (XYZM measure (2 * measure) (measure + 4) measure)))
                 in S.locateAlong measure input === Just expected
        ]

-- | Parse a fixed fixture with known constructor validity.
geometry :: String -> Geometry
geometry = either (error . show) id . decodeWKT . Text.pack

-- | Examples from OGC SFA 1.2.1 sections 6.1.2.6.3 and 6.1.2.6.4.
examples :: [(String, Double, Double, String, String)]
examples =
    [ ("0D a", 4, 4, "MULTIPOINT M ((1 0 4),(1 1 1),(1 2 2),(3 1 4),(5 3 4))", "MULTIPOINT M ((1 0 4),(3 1 4),(5 3 4))")
    , ("0D b", 2, 4, "MULTIPOINT M ((1 0 4),(1 1 1),(1 2 2),(3 1 4),(5 3 5),(9 5 3),(7 6 7))", "MULTIPOINT M ((1 0 4),(1 2 2),(3 1 4),(9 5 3))")
    , ("0D c", 1, 4, "POINT M (7 6 7)", "POINT M EMPTY")
    , ("0D d", 7, 7, "POINT M (7 6 7)", "MULTIPOINT M ((7 6 7))")
    , ("1D a", 4, 4, "LINESTRING M (1 0 0,3 1 4,5 3 4,5 5 1,5 6 4,7 8 4,9 9 0)", "MULTILINESTRING M ((3 1 4,5 3 4),(5 6 4,7 8 4))")
    , ("1D b", 2, 4, "LINESTRING M (1 0 0,1 1 1,1 2 2,3 1 3,5 3 4,9 5 5,7 6 6)", "MULTILINESTRING M ((1 2 2,3 1 3,5 3 4))")
    , ("1D c", 6, 9, "LINESTRING M (1 0 0,1 1 1,1 2 2,3 1 3,5 3 4,9 5 5,7 6 6)", "MULTIPOINT M ((7 6 6))")
    , ("1D d", 2, 4, "MULTILINESTRING M ((1 0 0,1 1 1,1 2 2,3 1 3),(4 5 3,5 3 4,9 5 5,7 6 6))", "MULTILINESTRING M ((1 2 2,3 1 3),(4 5 3,5 3 4))")
    , ("1D e", 1, 3, "LINESTRING M (0 0 0,2 2 2,4 4 4)", "MULTILINESTRING M ((1 1 1,2 2 2,3 3 3))")
    , ("1D f", 7, 9, "MULTILINESTRING M ((1 0 0,1 1 1,1 2 2,3 1 3),(4 5 3,5 3 4,9 5 5,7 6 6))", "POINT M EMPTY")
    ]
