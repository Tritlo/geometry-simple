-- | Check spatial relations against independent GEOS results and set identities.
module TopologyRelationTests (tests) where

import Control.Monad (forM_)
import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import Data.Geometry.WKT (decodeWKT)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))
import Test.Tasty.QuickCheck (chooseInt, conjoin, forAll, testProperty, (===))

-- | Cover all predicates, boundary rules, holes, collections, and empty values.
tests :: TestTree
tests =
    testGroup
        "spatial relations"
        [ testGroup "native intersection matrices" [checkFixture name a b matrix predicates | (name, a, b, matrix, predicates) <- fixtures]
        , testGroup
            "collection union semantics"
            [ testCase "an outside point cannot remove coverage by a polygon" $ do
                let a = geometry "GEOMETRYCOLLECTION (POINT (10 10),POLYGON ((0 0,4 0,4 4,0 4,0 0)))"
                    b = geometry "POLYGON ((1 1,2 1,2 2,1 2,1 1))"
                -- GEOS 3.13.1 returns 212FF1212 and reverses these three predicates.
                S.relate a b @?= "212FF1FF2"
                S.contains a b @?= True
                S.covers a b @?= True
                S.overlaps a b @?= False
            , testCase "a polygon union retains its boundary outside a disjoint line" $ do
                let a = geometry "GEOMETRYCOLLECTION (POLYGON ((4 4,4 5,-1 5,-1 4,4 4)),POLYGON ((6 3,6 8,3 8,3 3,6 3)))"
                    b = geometry "LINESTRING (-1 3,-1 -2)"
                -- GEOS 3.13.1 returns FF2FFF102 and omits the polygon boundary.
                S.relate a b @?= "FF2FF1102"
                S.disjoint a b @?= True
            , testCase "a closed first line does not remove later line boundaries" $ do
                let a = geometry "MULTILINESTRING ((0 0,1 0,0 0),(0 2,1 2))"
                    reordered = geometry "MULTILINESTRING ((0 2,1 2),(0 0,1 0,0 0))"
                    b = point 10 10
                -- GEOS 3.13.1 returns FF1FFF0F2 only when the closed line is first.
                S.relate a b @?= "FF1FF00F2"
                S.relate a b @?= S.relate reordered b
            ]
        , testCase "boundary points are covered but not contained" $ do
            let polygon = geometry "POLYGON ((0 0,3 0,3 3,0 3,0 0))"
                boundaryPoint = geometry "POINT (0 1)"
            S.contains polygon boundaryPoint @?= False
            S.covers polygon boundaryPoint @?= True
            S.within boundaryPoint polygon @?= False
            S.coveredBy boundaryPoint polygon @?= True
        , testCase "a line with endpoints inside can pass outside a concave polygon" $ do
            let polygon = geometry "POLYGON ((0 0,4 0,4 1,1 1,1 4,0 4,0 0))"
                line = geometry "LINESTRING (0.5 3,3 0.5)"
            S.contains polygon line @?= False
            S.covers polygon line @?= False
            S.crosses polygon line @?= True
        , testCase "a polygon does not cover a polygon that fills its hole" $ do
            let polygon = geometry "POLYGON ((0 0,4 0,4 4,0 4,0 0),(1 1,3 1,3 3,1 3,1 1))"
                filled = geometry "POLYGON ((0 0,4 0,4 4,0 4,0 0))"
            S.covers polygon filled @?= False
            S.covers filled polygon @?= True
            S.equals polygon filled @?= False
        , testCase "spatial equality ignores vertex density and direction" $ do
            S.equals (geometry "LINESTRING (0 0,4 0)") (geometry "LINESTRING (4 0,3 0,1 0,0 0)") @?= True
        , testCase "Z and M do not change a spatial relation" $ do
            S.equals (geometry "POINT Z (1 2 9)") (geometry "POINT M (1 2 44)") @?= True
            S.distance (geometry "POINT ZM (1 2 9 8)") (geometry "POINT Z (1 2 -100)") @?= 0
        , testCase "patterns support dimensions, booleans, and wildcards" $ do
            let a = geometry "POINT (1 0)"
                b = geometry "LINESTRING (0 0,2 0)"
            forM_ ["0FFFFF102", "T*F**F***", "*********"] $ \pattern -> S.relatePattern pattern a b @?= True
            forM_ ["", "********", "**********", "X********", "t********", "1********", "FF*FF****"] $ \pattern -> S.relatePattern pattern a b @?= False
        , testGroup
            "distance"
            [ testCase "point distance" $ S.distance (point 0 0) (point 3 4) @?= 5
            , testCase "nearest point is in a segment interior" $
                S.distance (point 2 3) (geometry "LINESTRING (0 0,4 0)") @?= 3
            , testCase "nearest point is an endpoint" $
                S.distance (point 7 4) (geometry "LINESTRING (0 0,4 0)") @?= 5
            , testCase "crossing segments have zero distance" $
                S.distance (geometry "LINESTRING (0 0,2 2)") (geometry "LINESTRING (0 2,2 0)") @?= 0
            , testCase "point in a hole has positive distance" $
                S.distance (point 2 2) (geometry "POLYGON ((0 0,4 0,4 4,0 4,0 0),(1 1,3 1,3 3,1 3,1 1))") @?= 1
            , testCase "point inside a surface has zero distance" $
                S.distance (point 2 2) (geometry "POLYGON ((0 0,4 0,4 4,0 4,0 0))") @?= 0
            , testCase "collections use the closest component" $
                S.distance (point 0 0) (GeometryCollection (V.fromList [point 30 40, point 3 4])) @?= 5
            , testCase "empty input returns NaN" $
                forM_ ["POINT EMPTY", "LINESTRING EMPTY", "POLYGON EMPTY", "GEOMETRYCOLLECTION EMPTY"] $ \empty -> do
                    assertBool "empty first" (isNaN (S.distance (geometry empty) (point 0 0)))
                    assertBool "empty second" (isNaN (S.distance (point 0 0) (geometry empty)))
            , testCase "large finite distances do not overflow during squaring" $ do
                let actual = S.distance (point 0 0) (point 3e200 4e200)
                assertBool "finite scaled length" (abs (actual / 5e200 - 1) < 1e-15)
            , testCase "small finite distances do not underflow during squaring" $
                S.distance (point 0 0) (point 3e-200 4e-200) @?= 5e-200
            , testCase "projection survives a segment whose length overflows Double" $
                S.distance (point 0 0) (geometry "LINESTRING (-1e308 1,1e308 1)") @?= 1
            ]
        , testProperty "transposing the inputs transposes the matrix" $
            forAll generatedLine $ \a -> forAll generatedLine $ \b ->
                S.relate b a === [S.relate a b !! index | index <- [0, 3, 6, 1, 4, 7, 2, 5, 8]]
        , testProperty "binary predicates obey their set identities" $
            forAll generatedLine $ \a -> forAll generatedLine $ \b ->
                conjoin
                    [ S.contains a b === S.within b a
                    , S.covers a b === S.coveredBy b a
                    , S.intersects a b === not (S.disjoint a b)
                    , S.touches a b === S.touches b a
                    , S.crosses a b === S.crosses b a
                    , S.overlaps a b === S.overlaps b a
                    , S.distance a b === S.distance b a
                    ]
        ]
  where
    generatedLine = do
        x <- chooseInt (-8, 8)
        y <- chooseInt (-8, 8)
        u <- chooseInt (-8, 8)
        v <- chooseInt (-8, 8)
        pure (LineString (CoordinatesXY (U.fromList [XY (fromIntegral x) (fromIntegral y), XY (fromIntegral u) (fromIntegral v)])))

-- | Read a fixed, valid test fixture.
geometry :: String -> Geometry
geometry = either (error . show) id . decodeWKT . Text.pack

-- | Construct a two-dimensional point.
point :: Double -> Double -> Geometry
point x y = PointGeometry (PointXY (XY x y))

-- | Check a native matrix and all ten predicates for one pair of fixtures.
checkFixture :: String -> String -> String -> String -> [String] -> TestTree
checkFixture name first second expected truePredicates = testCase name $ do
    let a = geometry first
        b = geometry second
    S.relate a b @?= expected
    forM_ predicateFunctions $ \(label, predicate) -> assertEqual label (label `elem` truePredicates) (predicate a b)
  where
    predicateFunctions =
        [ ("equals", S.equals)
        , ("disjoint", S.disjoint)
        , ("intersects", S.intersects)
        , ("touches", S.touches)
        , ("crosses", S.crosses)
        , ("within", S.within)
        , ("contains", S.contains)
        , ("overlaps", S.overlaps)
        , ("covers", S.covers)
        , ("coveredBy", S.coveredBy)
        ]

-- | Expected results from Shapely 2.1.2 with GEOS 3.13.1.
fixtures :: [(String, String, String, String, [String])]
fixtures =
    [ ("equal points", "POINT (0 0)", "POINT (0 0)", "0FFFFFFF2", ["equals", "intersects", "within", "contains", "covers", "coveredBy"])
    , ("separate points", "POINT (0 0)", "POINT (3 4)", "FF0FFF0F2", ["disjoint"])
    , ("point in line", "POINT (1 0)", "LINESTRING (0 0,2 0)", "0FFFFF102", ["intersects", "within", "coveredBy"])
    , ("point at endpoint", "POINT (0 0)", "LINESTRING (0 0,2 0)", "F0FFFF102", ["intersects", "touches", "coveredBy"])
    , ("lines cross", "LINESTRING (0 0,2 2)", "LINESTRING (0 2,2 0)", "0F1FF0102", ["intersects", "crosses"])
    , ("lines overlap", "LINESTRING (0 0,2 0)", "LINESTRING (1 0,3 0)", "1010F0102", ["intersects", "overlaps"])
    , ("lines meet", "LINESTRING (0 0,1 0)", "LINESTRING (1 0,1 1)", "FF1F00102", ["intersects", "touches"])
    , ("point in surface", "POINT (1 1)", "POLYGON ((0 0,3 0,3 3,0 3,0 0))", "0FFFFF212", ["intersects", "within", "coveredBy"])
    , ("line in boundary", "LINESTRING (0 0,3 0)", "POLYGON ((0 0,3 0,3 3,0 3,0 0))", "F1FF0F212", ["intersects", "touches", "coveredBy"])
    , ("surface overlap", "POLYGON ((0 0,3 0,3 3,0 3,0 0))", "POLYGON ((2 1,4 1,4 4,2 4,2 1))", "212101212", ["intersects", "overlaps"])
    , ("line passes hole", "LINESTRING (0 2,4 2)", "POLYGON ((0 0,4 0,4 4,0 4,0 0),(1 1,3 1,3 3,1 3,1 1))", "101F0F212", ["intersects", "crosses"])
    , ("boundary cancels", "MULTILINESTRING ((0 0,1 0),(0 0,0 1))", "POINT (0 0)", "0F1FF0FF2", ["intersects", "contains", "covers"])
    , ("duplicate lines cancel", "MULTILINESTRING ((0 0,1 0),(0 0,1 0))", "POINT (0 0)", "0F1FFFFF2", ["intersects", "contains", "covers"])
    , ("collapsed line", "LINESTRING (0 0,0 0)", "POINT (0 0)", "0FFFFFFF2", ["equals", "intersects", "within", "contains", "covers", "coveredBy"])
    , ("empty types", "POINT EMPTY", "POLYGON EMPTY", "FFFFFFFF2", ["equals", "disjoint"])
    , ("empty and line", "POINT EMPTY", "LINESTRING (0 0,2 0)", "FFFFFF102", ["disjoint"])
    , ("surfaces meet edge", "POLYGON ((0 0,1 0,1 1,0 1,0 0))", "POLYGON ((1 0,2 0,2 1,1 1,1 0))", "FF2F11212", ["intersects", "touches"])
    , ("surfaces meet corner", "POLYGON ((0 0,1 0,1 1,0 1,0 0))", "POLYGON ((1 1,2 1,2 2,1 2,1 1))", "FF2F01212", ["intersects", "touches"])
    , ("point on collection polygon seam", "GEOMETRYCOLLECTION (POLYGON ((0 0,1 0,1 1,0 1,0 0)),POLYGON ((1 0,2 0,2 1,1 1,1 0)))", "POINT (1 0.5)", "0F2FF1FF2", ["intersects", "contains", "covers"])
    , ("line within collection union", "GEOMETRYCOLLECTION (LINESTRING (0 0,2 0),LINESTRING (2 0,4 0))", "LINESTRING (1 0,3 0)", "101FF0FF2", ["intersects", "contains", "covers"])
    , ("empty polygon does not change line predicates", "GEOMETRYCOLLECTION (POLYGON EMPTY,LINESTRING (0 0,2 2))", "LINESTRING (0 2,2 0)", "0F1FF0102", ["intersects", "crosses"])
    , ("multipoint crosses surface", "GEOMETRYCOLLECTION (LINESTRING EMPTY,POINT (0 0),POINT (4 4))", "POLYGON ((-1 -1,1 -1,1 1,-1 1,-1 -1))", "0F0FFF212", ["intersects", "crosses"])
    ]
