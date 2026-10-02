{-# LANGUAGE OverloadedStrings #-}

-- | Check WKT syntax, coordinate dimensions, and numeric conversion.
module WKTTests (tests) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.Geometry
import Data.Geometry.WKT (decodeAnyWKT, decodeWKT, encodeWKT)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

-- | Cover independent fixtures, rejected syntax, and parser boundaries.
tests :: TestTree
tests =
    testGroup
        "WKT"
        [ testGroup "families and dimensions" $
            [ testCase (Text.unpack input) $ do
                decodeAnyWKT input @?= Right expected
                assertTypedDecode input expected
                (renderAny expected >>= decodeAnyWKT) @?= Right expected
            | (input, expected) <- fixtures
            ]
        , testGroup "literal syntax" $
            [ testCase (Text.unpack input) $ decodeAnyWKT input @?= Right expected
            | (input, expected) <- literalFixtures
            ]
        , testCase "attached dimension suffixes work for all families" $
            forM_ fixtures $ \(input, expected) -> do
                let attached = Text.replace " ZM" "ZM" (Text.replace " M" "M" (Text.replace " Z" "Z" input))
                decodeAnyWKT attached @?= Right expected
        , testCase "keywords ignore case and surrounding whitespace" $
            forM_ fixtures $ \(input, expected) ->
                decodeAnyWKT ("\t\n " <> Text.toLower input <> " \r\n") @?= Right expected
        , testCase "untagged empty values remain XY for typed decoding" $
            forM_ families $ \family -> do
                let input = family <> " EMPTY"
                assertLeft (decodeWKT input :: Either String (Geometry XYZ))
                assertLeft (decodeWKT input :: Either String (Geometry XYM))
                assertLeft (decodeWKT input :: Either String (Geometry XYZM))
        , testCase "typed decoders reject other explicit dimensions, including empty values" $
            forM_ fixtures $ \(input, expected) -> case expected of
                GeometryXY _ -> do
                    assertLeft (decodeWKT input :: Either String (Geometry XYZ))
                    assertLeft (decodeWKT input :: Either String (Geometry XYM))
                    assertLeft (decodeWKT input :: Either String (Geometry XYZM))
                GeometryXYZ _ -> do
                    assertLeft (decodeWKT input :: Either String (Geometry XY))
                    assertLeft (decodeWKT input :: Either String (Geometry XYM))
                    assertLeft (decodeWKT input :: Either String (Geometry XYZM))
                GeometryXYM _ -> do
                    assertLeft (decodeWKT input :: Either String (Geometry XY))
                    assertLeft (decodeWKT input :: Either String (Geometry XYZ))
                    assertLeft (decodeWKT input :: Either String (Geometry XYZM))
                GeometryXYZM _ -> do
                    assertLeft (decodeWKT input :: Either String (Geometry XY))
                    assertLeft (decodeWKT input :: Either String (Geometry XYZ))
                    assertLeft (decodeWKT input :: Either String (Geometry XYM))
        , testGroup "numeric boundaries" $
            [ testCase (Text.unpack token) $ do
                shape <- rightOrFail (decodeWKT ("POINT (" <> token <> " -0)") :: Either String (Geometry XY))
                case shape of
                    PointGeometry (Point (XY x y)) -> do
                        castDoubleToWord64 x @?= expectedBits
                        castDoubleToWord64 y @?= 0x8000000000000000
                        rendered <- rightOrFail (encodeWKT shape)
                        again <- rightOrFail (decodeWKT rendered :: Either String (Geometry XY))
                        case again of
                            PointGeometry (Point (XY x' y')) -> do
                                castDoubleToWord64 x' @?= expectedBits
                                castDoubleToWord64 y' @?= 0x8000000000000000
                            _ -> assertFailure "a rendered point changed family"
                    _ -> assertFailure "a finite point changed family"
            | (token, expectedBits) <- numericFixtures
            ]
        , testCase "numeric components retain their order in ZM" $ do
            shape <- rightOrFail (decodeWKT "POINT ZM (-0 5e-324 -5e-324 1.7976931348623157e308)" :: Either String (Geometry XYZM))
            case shape of
                PointGeometry (Point (XYZM x y z m)) ->
                    map castDoubleToWord64 [x, y, z, m] @?= [0x8000000000000000, 1, 0x8000000000000001, 0x7fefffffffffffff]
                _ -> assertFailure "a ZM point changed family"
        , testGroup "rejected syntax" [testCase (Text.unpack input) (assertRejected input) | input <- invalidInputs]
        , testCase "all finite fixtures reject trailing input" $
            forM_ fixtures $ \(input, _) ->
                forM_ ["x", " POINT EMPTY", ",", ";", "\0"] $ \suffix ->
                    assertRejected (input <> suffix)
        , testCase "128 geometry levels are accepted" $ do
            let shape = nestGeometry 127 (PointGeometry (Point (XY 1 2)))
            decodeWKT (nestText 127 "POINT (1 2)") @?= Right shape
        , testCase "129 geometry levels are rejected" $
            assertRejected (nestText 128 "POINT (1 2)")
        , testGroup "multi-geometry children count toward depth" $
            [ testCase (Text.unpack family) $ do
                decodeWKT (nestText 126 input) @?= Right (nestGeometry 126 shape)
                assertRejected (nestText 127 input)
                decodeWKT (nestText 127 (family <> " EMPTY")) @?= Right (nestGeometry 127 emptyShape)
            | (family, input, shape, emptyShape) <-
                [ ("MULTIPOINT", "MULTIPOINT ((1 2))", MultiPoint (U.singleton (Point (XY 1 2))), MultiPoint U.empty)
                , ("MULTILINESTRING", "MULTILINESTRING ((1 2))", MultiLineString (V.singleton (U.singleton (XY 1 2))), MultiLineString V.empty)
                , ("MULTIPOLYGON", "MULTIPOLYGON (((1 2)))", MultiPolygon (V.singleton (V.singleton (U.singleton (XY 1 2)))), MultiPolygon V.empty)
                ]
            ]
        , testCase "empty point children still count toward depth" $
            assertRejected (nestText 127 "MULTIPOINT (EMPTY)")
        , testCase "wide collections use siblings, not nested depth" $ do
            let input = "GEOMETRYCOLLECTION (" <> Text.intercalate "," (replicate 1024 "POINT EMPTY") <> ")"
            decodeWKT input @?= Right (GeometryCollection (V.replicate 1024 (PointGeometry EmptyPoint)) :: Geometry XY)
        ]

-- | The seven standard geometry family names.
families :: [Text]
families = ["POINT", "LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION"]

-- | Explicit coordinates and dimension tags for each supported family.
fixtures :: [(Text, AnyGeometry)]
fixtures =
    dimensionFixtures "" "1 2" "3 4" (XY 1 2) (XY 3 4) GeometryXY
        ++ dimensionFixtures " Z" "1 2 3" "4 5 6" (XYZ 1 2 3) (XYZ 4 5 6) GeometryXYZ
        ++ dimensionFixtures " M" "1 2 3" "4 5 6" (XYM 1 2 3) (XYM 4 5 6) GeometryXYM
        ++ dimensionFixtures " ZM" "1 2 3 4" "5 6 7 8" (XYZM 1 2 3 4) (XYZM 5 6 7 8) GeometryXYZM

-- | Pair each literal geometry body with an independently constructed value.
dimensionFixtures :: (Coordinate c) => Text -> Text -> Text -> c -> c -> (Geometry c -> AnyGeometry) -> [(Text, AnyGeometry)]
dimensionFixtures suffix first second a b wrap = do
    let line = U.fromList [a, b]
        ring = U.fromList [a, b, a]
        lineText = "(" <> first <> ", " <> second <> ")"
        polygonText = "((" <> first <> ", " <> second <> ", " <> first <> "))"
    (family, body, full, emptyShape) <-
        [ ("POINT", "(" <> first <> ")", PointGeometry (Point a), PointGeometry EmptyPoint)
        , ("LINESTRING", lineText, LineString line, LineString U.empty)
        , ("POLYGON", polygonText, Polygon (V.singleton ring), Polygon V.empty)
        , ("MULTIPOINT", "((" <> first <> "), EMPTY, " <> second <> ")", MultiPoint (U.fromList [Point a, EmptyPoint, Point b]), MultiPoint U.empty)
        , ("MULTILINESTRING", "(" <> lineText <> ", EMPTY)", MultiLineString (V.fromList [line, U.empty]), MultiLineString V.empty)
        , ("MULTIPOLYGON", "(" <> polygonText <> ", EMPTY)", MultiPolygon (V.fromList [V.singleton ring, V.empty]), MultiPolygon V.empty)
        , ("GEOMETRYCOLLECTION", "(POINT" <> suffix <> " (" <> first <> "), LINESTRING" <> suffix <> " EMPTY)", GeometryCollection (V.fromList [PointGeometry (Point a), LineString U.empty]), GeometryCollection V.empty)
        ]
    [(family <> suffix <> " " <> body, wrap full), (family <> suffix <> " EMPTY", wrap emptyShape)]

-- | Cover holes, empty children, optional numeric components, and delimiters.
literalFixtures :: [(Text, AnyGeometry)]
literalFixtures =
    [ ("pOiNt\t( +.5\n-2.E+1 )", GeometryXY (PointGeometry (Point (XY 0.5 (-20)))))
    , ("POINT(+1. -2.)", GeometryXY (PointGeometry (Point (XY 1 (-2)))))
    , ("POINT (.5 .25)", GeometryXY (PointGeometry (Point (XY 0.5 0.25))))
    , ("POINT (001 002)", GeometryXY (PointGeometry (Point (XY 1 2))))
    , ("POINT (1e+2 2E-1)", GeometryXY (PointGeometry (Point (XY 100 0.2))))
    , ("MULTIPOINT(1 2, 3 4)", GeometryXY (MultiPoint (U.fromList [Point (XY 1 2), Point (XY 3 4)])))
    , ("MULTIPOINT((1 2),(3 4))", GeometryXY (MultiPoint (U.fromList [Point (XY 1 2), Point (XY 3 4)])))
    , ("MULTIPOINT(1 2,(3 4),EMPTY,5 6)", GeometryXY (MultiPoint (U.fromList [Point (XY 1 2), Point (XY 3 4), EmptyPoint, Point (XY 5 6)])))
    , ("LINESTRING (1 2)", GeometryXY (LineString (U.singleton (XY 1 2))))
    , ("POLYGON (EMPTY, (1 2))", GeometryXY (Polygon (V.fromList [U.empty, U.singleton (XY 1 2)])))
    ,
        ( "POLYGON ((0 0,4 0,4 4,0 0),(1 1,2 1,1 2,1 1))"
        , GeometryXY (Polygon (V.fromList [U.fromList [XY 0 0, XY 4 0, XY 4 4, XY 0 0], U.fromList [XY 1 1, XY 2 1, XY 1 2, XY 1 1]]))
        )
    , ("MULTIPOLYGON ((EMPTY), EMPTY)", GeometryXY (MultiPolygon (V.fromList [V.singleton U.empty, V.empty])))
    ,
        ( "GEOMETRYCOLLECTION Z (POINTZ(1 2 3),GEOMETRYCOLLECTIONZ(LINESTRING Z EMPTY))"
        , GeometryXYZ (GeometryCollection (V.fromList [PointGeometry (Point (XYZ 1 2 3)), GeometryCollection (V.singleton (LineString U.empty))]))
        )
    ]

-- | Literal decimal inputs and their correctly rounded IEEE 754 results.
numericFixtures :: [(Text, Word64)]
numericFixtures =
    [ ("0", 0)
    , ("+0", 0)
    , ("-0", 0x8000000000000000)
    , ("-0.000e300", 0x8000000000000000)
    , ("0.10000000000000002", 0x3fb999999999999b)
    , ("1.0000000000000002", 0x3ff0000000000001)
    , ("9007199254740994", 0x4340000000000001)
    , ("5e-324", 1)
    , ("-5e-324", 0x8000000000000001)
    , ("2.225073858507201e-308", 0x000fffffffffffff)
    , ("2.2250738585072014e-308", 0x0010000000000000)
    , ("1.7976931348623157e308", 0x7fefffffffffffff)
    , ("-1.7976931348623157e308", 0xffefffffffffffff)
    , ("1e-400", 0)
    , ("-1e-400", 0x8000000000000000)
    , ("1e-" <> Text.replicate 200 "9", 0)
    , ("-1e-" <> Text.replicate 200 "9", 0x8000000000000000)
    , ("0e" <> Text.replicate 200 "9", 0)
    , ("-0e" <> Text.replicate 200 "9", 0x8000000000000000)
    , ("0." <> Text.replicate 500 "0" <> "1e501", 0x3ff0000000000000)
    , ("1" <> Text.replicate 500 "0" <> "e-500", 0x3ff0000000000000)
    , ("1e" <> Text.replicate 200 "0" <> "1", 0x4024000000000000)
    ]

-- | Inputs that must fail without relying on the parser's error wording.
invalidInputs :: [Text]
invalidInputs =
    [ ""
    , " "
    , "POINT"
    , "POINT EMPTYx"
    , "POINTEMPTY"
    , "POINT ZMEMPTY"
    , "POINT Z M (1 2 3 4)"
    , "POINT ()"
    , "POINT (EMPTY)"
    , "LINESTRING ()"
    , "POLYGON ()"
    , "POLYGON (())"
    , "MULTIPOINT ()"
    , "MULTIPOINT ((EMPTY))"
    , "MULTILINESTRING (())"
    , "MULTIPOLYGON (())"
    , "GEOMETRYCOLLECTION ()"
    , "POINT (1)"
    , "POINT (1 2 3)"
    , "POINT Z (1 2)"
    , "POINT M (1 2 3 4)"
    , "POINT ZM (1 2 3)"
    , "POINT (1,2)"
    , "POINT (1+2)"
    , "POINT (1-2)"
    , "POINT (.5.6)"
    , "POINT (1e2-3)"
    , "POINT (1.2.3)"
    , "POINT (+ 1 2)"
    , "POINT (--1 2)"
    , "POINT (1e 2)"
    , "POINT (1e+ 2)"
    , "POINT (. 2)"
    , "POINT (0x1 2)"
    , "POINT (1/2 3)"
    , "POINT (1_000 2)"
    , "POINT (−1 2)"
    , "POINT (１ 2)"
    , "POINT (1 2"
    , "POINT 1 2)"
    , "POINT ((1 2))"
    , "POINT (1 2))"
    , "LINESTRING (1 2,)"
    , "LINESTRING (,1 2)"
    , "LINESTRING (1 2,,3 4)"
    , "LINESTRING (EMPTY)"
    , "MULTIPOINT (POINT (1 2))"
    , "MULTIPOINT ((1 2),)"
    , "MULTILINESTRING (POINT EMPTY)"
    , "POLYGON (1 2,3 4)"
    , "MULTIPOLYGON ((1 2,3 4))"
    , "GEOMETRYCOLLECTION (1 2)"
    , "GEOMETRYCOLLECTION Z (POINT (1 2 3))"
    , "GEOMETRYCOLLECTION Z (POINT EMPTY)"
    , "GEOMETRYCOLLECTION M (POINT Z EMPTY)"
    , "GEOMETRYCOLLECTION ZM (GEOMETRYCOLLECTION EMPTY)"
    , "GEOMETRYCOLLECTION (POINT Z EMPTY)"
    , "GEOMETRYCOLLECTION (POINT EMPTY,)"
    , "CIRCULARSTRING (0 0,1 1,2 0)"
    , "POINT XY (1 2)"
    , "SRID=4326;POINT (1 2)"
    , "{\"type\":\"Point\",\"coordinates\":[1,2]}"
    ]
        ++ ["POINT (" <> token <> " 0)" | token <- ["NaN", "nan", "+NaN", "Inf", "-inf", "Infinity", "-Infinity", "1e309", "-1e309", "1.7976931348623159e308", "1e" <> Text.replicate 200 "9"]]

-- | Decode a fixture with its declared static coordinate type.
assertTypedDecode :: Text -> AnyGeometry -> Assertion
assertTypedDecode input expected = case expected of
    GeometryXY shape -> decodeWKT input @?= Right shape
    GeometryXYZ shape -> decodeWKT input @?= Right shape
    GeometryXYM shape -> decodeWKT input @?= Right shape
    GeometryXYZM shape -> decodeWKT input @?= Right shape

-- | Render a fixture whose dimensions are known at runtime.
renderAny :: AnyGeometry -> Either String Text
renderAny geometry = case geometry of
    GeometryXY shape -> encodeWKT shape
    GeometryXYZ shape -> encodeWKT shape
    GeometryXYM shape -> encodeWKT shape
    GeometryXYZM shape -> encodeWKT shape

-- | Require a controlled syntax or value error.
assertRejected :: Text -> Assertion
assertRejected = assertLeft . decodeAnyWKT

-- | Require a validation error without matching its text.
assertLeft :: Either String a -> Assertion
assertLeft result = assertBool "expected a WKT validation error" (isLeft result)

-- | Turn a parser error into a test failure.
rightOrFail :: Either String a -> IO a
rightOrFail result = case result of
    Left message -> assertFailure message
    Right value -> pure value

-- | Add collection wrappers without using the WKT encoder.
nestText :: Int -> Text -> Text
nestText count input = Text.replicate count "GEOMETRYCOLLECTION (" <> input <> Text.replicate count ")"

-- | Construct the expected value independently of the parser.
nestGeometry :: Int -> Geometry XY -> Geometry XY
nestGeometry 0 geometry = geometry
nestGeometry count geometry = GeometryCollection (V.singleton (nestGeometry (count - 1) geometry))
