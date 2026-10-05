{-# LANGUAGE OverloadedStrings #-}

-- | Fixed GEOS results for unary topology and representative points.
module TopologyUnaryTests (tests) where

import Data.Geometry.Internal
import qualified Data.Geometry.SimpleFeatures as S
import qualified Data.Geometry.WKT as WKT
import Data.Text (Text)
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (chooseInt, forAll, testProperty, (===))

-- | Run regressions for endpoint rules, ring contacts, and native point choices.
tests :: TestTree
tests =
    testGroup
        "unary topology"
        [ testGroup "predicates" [testCase name $ (S.isSimple shape, S.isRing shape, S.isValid shape) @?= expected | (name, text, expected) <- predicateCases, let shape = geometry text]
        , testGroup "boundary" [testCase name $ S.boundary (geometry input) @?= fmap geometry expected | (name, input, expected) <- boundaryCases]
        , testGroup "point on surface" [testCase name $ PointGeometry (S.pointOnSurface (geometry input)) @?= geometry expected | (name, input, expected) <- surfaceCases]
        , testCase "invalid nonfinite XY" $ do
            S.isValid (PointGeometry (PointXY (XY (0 / 0) 2))) @?= False
            S.isValid (LineString (CoordinatesXY (U.fromList [XY 0 0, XY (1 / 0) 2]))) @?= False
        , testCase "nonfinite Z and M do not change validity" $
            S.isValid (PointGeometry (PointXYZM (XYZM 1 2 (0 / 0) (1 / 0)))) @?= True
        , testCase "point selection stays on the input when squared distances overflow" $
            S.pointOnSurface (MultiPoint (U.fromList [PointXY (XY 1e200 0), PointXY (XY (-1e200) 0)])) @?= PointXY (XY 1e200 0)
        , testCase "open constructor ring is invalid" $
            S.isValid (Polygon (PolygonRings (CoordinatesXY (U.fromList [XY 0 0, XY 2 0, XY 0 2])) V.empty)) @?= False
        , testCase "nonempty hole with empty shell is invalid" $
            S.isValid (Polygon (PolygonRings (CoordinatesXY U.empty) (V.singleton (CoordinatesXY (U.fromList [XY 0 0, XY 2 0, XY 0 2, XY 0 0]))))) @?= False
        , testProperty "translated and skewed annuli remain valid" $
            forAll ((,,) <$> chooseInt (-100, 100) <*> chooseInt (-100, 100) <*> chooseInt (-10, 10)) $ \(dx, dy, skew) ->
                let ring points = CoordinatesXY (U.fromList [XY (fromIntegral (x + skew * y + dx)) (fromIntegral (y + dy)) | (x, y) <- points])
                    shell = ring [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
                    hole = ring [(2, 2), (8, 2), (8, 8), (2, 8), (2, 2)]
                 in S.isValid (Polygon (PolygonRings shell (V.singleton hole))) === True
        ]

-- | Parse a fixed test geometry.
geometry :: Text -> Geometry
geometry text = case WKT.decodeWKT text of
    Right value -> value
    Left message -> error message

-- | Expected simplicity, ring status, and validity from GEOS 3.13.1.
predicateCases :: [(String, Text, (Bool, Bool, Bool))]
predicateCases =
    [ ("empty collection", "GEOMETRYCOLLECTION EMPTY", (True, False, True))
    , ("collection members are independent", "GEOMETRYCOLLECTION (LINESTRING (0 0,2 2),LINESTRING (0 2,2 0))", (True, False, True))
    , ("duplicate multipoint XY", "MULTIPOINT Z ((1 2 3),(1 2 4))", (False, False, True))
    , ("empty multipoint members", "MULTIPOINT (EMPTY,EMPTY,(1 2))", (True, False, True))
    , ("self crossing line", "LINESTRING (0 0,2 2,0 2,2 0)", (False, False, True))
    , ("repeated adjacent vertices", "LINESTRING (0 0,0 0,1 1,1 1,2 0)", (True, False, True))
    , ("collapsed closed line", "LINESTRING (0 0,0 0)", (True, True, False))
    , ("empty line is not a ring", "LINESTRING EMPTY", (True, False, True))
    , ("simple closed line", "LINESTRING (0 0,2 0,0 2,0 0)", (True, True, True))
    , ("backtracking line", "LINESTRING (0 0,2 0,1 0)", (False, False, True))
    , ("endpoint joins", "MULTILINESTRING ((0 0,1 1),(1 1,2 0))", (True, False, True))
    , ("equal segment bounds retain both lines", "MULTILINESTRING ((0 0,2 2),(0 0,2 2))", (False, False, True))
    , ("opposite diagonals have equal bounds", "MULTILINESTRING ((0 0,2 2),(0 2,2 0))", (False, False, True))
    , ("vertical segments have disjoint Y bounds", "MULTILINESTRING ((0 0,0 1),(0 2,0 3),(0 4,0 5))", (True, False, True))
    , ("interior vertex joins", "MULTILINESTRING ((0 0,1 1,2 0),(1 1,3 1))", (False, False, True))
    , ("closed line endpoint is interior", "MULTILINESTRING ((0 0,2 0,0 2,0 0),(0 0,-1 -1))", (False, False, True))
    , ("polygon crossings", "POLYGON ((0 0,2 2,0 2,2 0,0 0))", (False, False, False))
    , ("collapsed polygon", "POLYGON ((0 0,0 0,0 0))", (True, False, False))
    , ("hole outside shell", "POLYGON ((0 0,2 0,2 2,0 2,0 0),(3 3,4 3,4 4,3 3))", (True, False, False))
    , ("nested holes", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2),(3 3,4 3,4 4,3 3))", (True, False, False))
    , ("one shell contact", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(0 5,5 2,5 8,0 5))", (True, False, True))
    , ("two shell contacts disconnect interior", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(0 5,5 2,10 5,5 8,0 5))", (True, False, False))
    , ("hole chain disconnects interior", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(0 5,3 2,5 5,0 5),(5 5,7 2,10 5,5 5))", (True, False, False))
    , ("three holes can share one contact", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(5 5,2 2,4 2,5 5),(5 5,8 2,8 4,5 5),(5 5,8 8,6 8,5 5))", (True, False, True))
    , ("shared shell edge", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(0 2,2 2,2 4,0 4,0 2))", (True, False, False))
    , ("multipolygon point contact", "MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((2 2,4 2,4 4,2 4,2 2)))", (True, False, True))
    , ("multipolygon edge contact", "MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((2 0,4 0,4 2,2 2,2 0)))", (True, False, False))
    , ("multipolygon overlap", "MULTIPOLYGON (((0 0,3 0,3 3,0 3,0 0)),((2 2,4 2,4 4,2 4,2 2)))", (True, False, False))
    , ("equal polygon bounds retain both members", "MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((0 0,2 0,2 2,0 2,0 0)))", (True, False, False))
    , ("polygon inside another component hole", "MULTIPOLYGON (((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2)),((3 3,7 3,7 7,3 7,3 3)))", (True, False, True))
    ]

-- | Expected boundary structure and coordinate order from GEOS 3.13.1.
boundaryCases :: [(String, Text, Maybe Text)]
boundaryCases =
    [ ("point boundary", "POINT Z (1 2 3)", Just "GEOMETRYCOLLECTION EMPTY")
    , ("empty line boundary", "LINESTRING M EMPTY", Just "MULTIPOINT EMPTY")
    , ("line endpoint order and M", "LINESTRING M (4 4 8,0 0 9)", Just "MULTIPOINT M ((4 4 8),(0 0 9))")
    , ("closed line boundary", "LINESTRING (0 0,2 0,0 2,0 0)", Just "MULTIPOINT EMPTY")
    , ("multiline endpoint parity", "MULTILINESTRING ((3 0,4 0),(0 0,1 0),(1 0,2 0))", Just "MULTIPOINT ((0 0),(2 0),(3 0),(4 0))")
    , ("multiline discards M", "MULTILINESTRING M ((0 0 1,1 1 2))", Just "MULTIPOINT ((0 0),(1 1))")
    , ("multiline keeps first repeated endpoint Z", "MULTILINESTRING Z ((0 0 1,1 1 2),(0 0 3,2 2 4),(0 0 5,3 3 6))", Just "MULTIPOINT Z ((0 0 1),(1 1 2),(2 2 4),(3 3 6))")
    , ("polygon without holes", "POLYGON ((0 0,2 0,0 2,0 0))", Just "LINESTRING (0 0,2 0,0 2,0 0)")
    , ("polygon retains empty holes", "POLYGON ((0 0,2 0,0 2,0 0),EMPTY)", Just "MULTILINESTRING ((0 0,2 0,0 2,0 0),EMPTY)")
    , ("empty polygon", "POLYGON Z EMPTY", Just "MULTILINESTRING EMPTY")
    , ("multipolygon omits empty members", "MULTIPOLYGON (EMPTY,((0 0,2 0,0 2,0 0)))", Just "MULTILINESTRING ((0 0,2 0,0 2,0 0))")
    , ("collection unsupported", "GEOMETRYCOLLECTION (POINT (0 0))", Nothing)
    ]

-- | Expected representative point selection and layouts from GEOS 3.13.1.
surfaceCases :: [(String, Text, Text)]
surfaceCases =
    [ ("points discard Z and M", "POINT ZM (1 2 3 4)", "POINT (1 2)")
    , ("empty M projects to XY", "POINT M EMPTY", "POINT EMPTY")
    , ("empty ZM projects to XY", "LINESTRING ZM EMPTY", "POINT EMPTY")
    , ("line selects interior XY vertex", "LINESTRING Z (0 0 1,1 1 2,10 0 3)", "POINT (1 1)")
    , ("line discards M", "LINESTRING M (0 0 1,1 1 2,10 0 3)", "POINT (1 1)")
    , ("native rounding chooses first endpoint", "LINESTRING (1 4,3 1)", "POINT (1 4)")
    , ("native rounding chooses second endpoint", "LINESTRING (5 0,2 6)", "POINT (2 6)")
    , ("polygon point uses XY", "POLYGON Z ((0 0 1,4 0 2,4 4 3,0 4 4,0 0 1))", "POINT (2 2)")
    , ("polygon hole splits scanline", "POLYGON ((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2))", "POINT (1 5)")
    , ("polygon collapsed to a line", "POLYGON ((0 0,2 0,0 0))", "POINT (0 0)")
    , ("empty highest dimension controls selection", "GEOMETRYCOLLECTION (POINT (1 2),LINESTRING EMPTY)", "POINT EMPTY")
    , ("widest polygon interval wins", "MULTIPOLYGON (((0 0,2 0,2 8,0 8,0 0)),((5 0,10 0,10 2,5 2,5 0)))", "POINT (7.5 1)")
    ]
