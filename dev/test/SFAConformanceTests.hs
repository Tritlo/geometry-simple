{- | Geometry tests from OGC 06-104r4, Annex C.3.3, with its original test IDs.
See test/SFA-TESTS.md for the API adaptation and corrections to source errata.
-}
module SFAConformanceTests (tests) where

import Data.Geometry
import qualified Data.Geometry.SimpleFeatures as S
import Data.Geometry.WKB (decodeWKB, encodeWKB)
import Data.Geometry.WKT (decodeWKT, encodeWKT)
import qualified Data.Text as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))

-- | Run the standard's geometry cases through both supported interchange formats.
tests :: TestTree
tests = testGroup "OGC SFA Annex C" [suite "WKT" id, suite "WKB" binary]
  where
    binary value = either error id (encodeWKB value >>= decodeWKB)

-- | Apply the geometry API equivalents of T6 through T52, excluding SRID T10.
suite :: String -> (Geometry -> Geometry) -> TestTree
suite format transform =
    testGroup
        format
        [ testCase "T6 Dimension" $ S.dimension lake @?= 2
        , testCase "T7 GeometryType" $ S.geometryType route @?= "MULTILINESTRING"
        , testCase "T8 AsText" $ (encodeWKT island >>= decodeWKT) @?= Right island
        , testCase "T9 AsBinary" $ (encodeWKB island >>= decodeWKB) @?= Right island
        , testCase "T11 IsEmpty" $ S.isEmpty mainStreet @?= False
        , testCase "T12 IsSimple" $ S.isSimple lake @?= True
        , testCase "T13 Boundary" $ maybe (fail "missing boundary") (same islandRing) (S.boundary island)
        , testCase "T14 Envelope" $ same (geometry "POLYGON ((59 13,59 18,67 18,67 13,59 13))") (S.envelope island)
        , testCase "T15 X" $ pointX bridge @?= Just 44
        , testCase "T16 Y" $ pointY bridge @?= Just 31
        , testCase "T17 StartPoint" $ S.startPoint road @?= Just (PointXY (XY 0 18))
        , testCase "T18 EndPoint" $ S.endPoint road @?= Just (PointXY (XY 44 31))
        , testCase "T19 IsClosed" $ S.isClosed islandRing @?= True
        , testCase "T20 IsRing" $ S.isRing islandRing @?= True
        , testCase "T21 Length" $ S.curveLength dirtRoad @?= 26
        , testCase "T22 NumPoints" $ S.numPoints road @?= Just 5
        , testCase "T23 PointN" $ S.pointN 0 road @?= Just (PointXY (XY 0 18))
        , testCase "T24 Centroid" $ S.centroid island @?= PointXY (XY 63 15.5)
        , testCase "T25 PointOnSurface" $ S.contains island (PointGeometry (S.pointOnSurface island)) @?= True
        , testCase "T26 Area" $ S.area island @?= 40
        , testCase "T27 ExteriorRing" $ maybe (fail "missing shell") (same lakeRing . LineString) (S.exteriorRing lake)
        , testCase "T28 NumInteriorRings" $ S.numInteriorRings lake @?= Just 1
        , testCase "T29 InteriorRingN" $ maybe (fail "missing hole") (same islandRing . LineString) (S.interiorRingN 0 lake)
        , testCase "T30 NumGeometries" $ S.numGeometries route @?= 2
        , testCase "T31 GeometryN" $ S.geometryN 1 route @?= Just (geometry "LINESTRING (16 0,16 23,16 48)")
        , testCase "T32 IsClosed" $ S.isClosed route @?= False
        , testCase "T33 Length" $ S.curveLength route @?= 96
        , testCase "T34 Centroid" $ S.centroid ponds @?= PointXY (XY 25 42)
        , testCase "T35 PointOnSurface" $ S.contains ponds (PointGeometry (S.pointOnSurface ponds)) @?= True
        , testCase "T36 Area" $ S.area ponds @?= 8
        , testCase "T37 Equals" $ S.equals island (geometry "POLYGON ((67 13,67 18,59 18,59 13,67 13))") @?= True
        , testCase "T38 Disjoint" $ S.disjoint route ashton @?= True
        , testCase "T39 Touches" $ S.touches stream lake @?= True
        , testCase "T40 Within" $ S.within house215 ashton @?= True
        , testCase "T41 Overlaps" $ S.overlaps forest ashton @?= True
        , testCase "T42 Crosses" $ S.crosses road route @?= True
        , testCase "T43 Intersects" $ S.intersects road route @?= True
        , testCase "T44 Contains" $ S.contains forest ashton @?= False
        , testCase "T45 Relate" $ S.relatePattern "TTTTTTTTT" forest ashton @?= True
        , testCase "T46 Distance" $ S.distance bridge ashton @?= 12
        , testCase "T47 Intersection" $ same (geometry "POINT (52 18)") (successful (S.intersection stream lake))
        , testCase "T48 Difference" $ same (geometry "POLYGON ((56 34,62 48,84 48,84 42,56 34))") (successful (S.difference ashton forest))
        , testCase "T49 Union" $ same lakeShell (successful (S.union lake island))
        , testCase "T50 SymDifference" $ same lakeShell (successful (S.symmetricDifference lake island))
        , testCase "T51 Buffer" $ length (filter (S.contains (successful (S.buffer 15 bridge))) [house123, house215]) @?= 1
        , testCase "T52 ConvexHull" $ same lakeShell (S.convexHull lake)
        ]
  where
    fixture = transform . geometry
    lake = fixture "POLYGON ((52 18,66 23,73 9,48 6,52 18),(59 18,67 18,67 13,59 13,59 18))"
    island = fixture "POLYGON ((67 13,67 18,59 18,59 13,67 13))"
    road = fixture "LINESTRING (0 18,10 21,16 23,28 26,44 31)"
    mainStreet = fixture "LINESTRING (44 31,56 34,70 38)"
    dirtRoad = fixture "LINESTRING (28 26,28 0)"
    route = fixture "MULTILINESTRING ((10 48,10 21,10 0),(16 0,16 23,16 48))"
    forest = fixture "MULTIPOLYGON (((28 26,28 0,84 0,84 42,28 26),(52 18,66 23,73 9,48 6,52 18)),((59 18,67 18,67 13,59 13,59 18)))"
    bridge = fixture "POINT (44 31)"
    stream = fixture "LINESTRING (38 48,44 41,41 36,44 31,52 18)"
    house123 = fixture "POLYGON ((50 31,54 31,54 29,50 29,50 31))"
    house215 = fixture "POLYGON ((66 34,62 34,62 32,66 32,66 34))"
    ponds = fixture "MULTIPOLYGON (((24 44,22 42,24 40,24 44)),((26 44,26 40,28 42,26 44)))"
    ashton = fixture "POLYGON ((62 48,84 48,84 30,56 30,56 34,62 48))"
    islandRing = fixture "LINESTRING (67 13,67 18,59 18,59 13,67 13)"
    lakeRing = fixture "LINESTRING (52 18,66 23,73 9,48 6,52 18)"
    lakeShell = fixture "POLYGON ((52 18,66 23,73 9,48 6,52 18))"

-- | Compare spatial results without requiring a particular ring start or direction.
same :: Geometry -> Geometry -> Assertion
same expected actual = assertBool ("expected " ++ show expected ++ ", got " ++ show actual) (S.equals expected actual)

-- | Decode an independent expected geometry or a standard fixture.
geometry :: String -> Geometry
geometry = either error id . decodeWKT . Text.pack

-- | Read the X value from the standard's point fixture.
pointX :: Geometry -> Maybe Double
pointX (PointGeometry (PointXY coordinate)) = Just (S.x coordinate)
pointX _ = Nothing

-- | Read the Y value from the standard's point fixture.
pointY :: Geometry -> Maybe Double
pointY (PointGeometry (PointXY coordinate)) = Just (S.y coordinate)
pointY _ = Nothing

-- | Require successful construction for a fixture or generated valid input.
successful :: (Show e) => Either e a -> a
successful = either (error . show) id
