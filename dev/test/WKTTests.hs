{-# LANGUAGE OverloadedStrings #-}

-- | Check WKT grammar, runtime layouts, empty members, and numeric conversion.
module WKTTests (tests) where

import Control.Monad (forM_)
import Data.Either (isLeft, isRight)
import Data.Geometry
import Data.Geometry.WKT (decodeWKT, encodeWKT)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word64)
import GHC.Float (castDoubleToWord64)
import Test.Tasty (TestTree, localOption, mkTimeout, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

-- | Cover format fixtures, native layout inference, and malformed inputs.
tests :: TestTree
tests =
    testGroup
        "WKT"
        [ testGroup
            "families and dimensions"
            [ testCase (Text.unpack input) $ do
                decodeWKT input @?= Right expected
                (encodeWKT expected >>= decodeWKT) @?= Right expected
            | (input, expected) <- fixtures
            ]
        , testGroup
            "literal syntax"
            [testCase (Text.unpack input) $ decodeWKT input @?= Right expected | (input, expected) <- literalFixtures]
        , testCase "attached dimension suffixes work for all families" $
            forM_ fixtures $ \(input, expected) ->
                decodeWKT (Text.replace " ZM" "ZM" (Text.replace " M" "M" (Text.replace " Z" "Z" input))) @?= Right expected
        , testCase "keywords ignore case and surrounding whitespace" $
            forM_ fixtures $
                \(input, expected) -> decodeWKT ("\t\n " <> Text.toLower input <> " \r\n") @?= Right expected
        , testGroup
            "numeric boundaries"
            [ testCase (Text.unpack token) $ do
                shape <- rightOrFail (decodeWKT ("POINT (" <> token <> " -0)"))
                case shape of
                    PointGeometry (PointXY (XY x y)) -> do
                        castDoubleToWord64 x @?= expected
                        castDoubleToWord64 y @?= 0x8000000000000000
                        rendered <- rightOrFail (encodeWKT shape)
                        again <- rightOrFail (decodeWKT rendered)
                        case again of
                            PointGeometry (PointXY (XY x' y')) -> map castDoubleToWord64 [x', y'] @?= [expected, 0x8000000000000000]
                            _ -> assertFailure "finite point changed family or layout"
                    _ -> assertFailure "finite point changed family or layout"
            | (token, expected) <- numericFixtures
            ]
        , localOption (mkTimeout 5000000) $ testCase "long mantissas parse in subquadratic time" $ do
            let digits = Text.replicate 1000000 "1"
            decodeWKT ("POINT (" <> digits <> "e-999999 0." <> digits <> ")")
                @?= Right (PointGeometry (PointXY (XY 1.1111111111111112 0.1111111111111111)))
        , localOption (mkTimeout 5000000) $ testCase "bare multipoints in a large collection parse in linear time" $ do
            let members = 50000
                input = "GEOMETRYCOLLECTION (" <> Text.intercalate ", " (replicate members "MULTIPOINT (1 2)") <> ")"
            fmap memberCount (decodeWKT input) @?= Right members
        , testCase "numeric components retain their order in ZM" $ do
            shape <- rightOrFail (decodeWKT "POINT ZM (-0 5e-324 -5e-324 1.7976931348623157e308)")
            case shape of
                PointGeometry (PointXYZM (XYZM x y z m)) -> map castDoubleToWord64 [x, y, z, m] @?= [0x8000000000000000, 1, 0x8000000000000001, 0x7fefffffffffffff]
                _ -> assertFailure "ZM point changed layout"
        , testCase "non-finite WKT ordinates remain stored coordinates" $ do
            forM_ ["NaN", "nan", "+NaN", "-NaN"] $ \token -> do
                shape <- rightOrFail (decodeWKT ("POINT (" <> token <> " NaN)"))
                case shape of
                    PointGeometry (PointXY (XY x y)) -> assertBool "NaN point became empty" (isNaN x && isNaN y)
                    _ -> assertFailure "WKT NaN point became empty"
                rendered <- rightOrFail (encodeWKT shape)
                assertBool "NaN output" (Text.isInfixOf "NaN" rendered)
            forM_ [("Inf", 1 / 0), ("-Infinity", -1 / 0), ("1e309", 1 / 0), ("-1e" <> Text.replicate 200 "9", -1 / 0)] $ \(token, value) ->
                decodeWKT ("POINT (" <> token <> " 2)") @?= Right (PointGeometry (PointXY (XY value 2)))
        , testCase "mixed multipoint writers pad absent Z and M ordinates" $ do
            let shape = MultiPoint (U.fromList [PointXY (XY 1 2), PointXYZ (XYZ 3 4 5), PointXYM (XYM 6 7 8)])
            encodeWKT shape @?= Right "MULTIPOINT ZM ((1.0e0 2.0e0 NaN NaN), (3.0e0 4.0e0 5.0e0 NaN), (6.0e0 7.0e0 NaN 8.0e0))"
        , testCase "mixed collection output preserves member layouts when decoded" $ do
            let shape = GeometryCollection (V.fromList [PointGeometry (PointXY (XY 1 2)), PointGeometry (PointXYZ (XYZ 3 4 5))])
            encodeWKT shape @?= Right "GEOMETRYCOLLECTION (POINT (1.0e0 2.0e0), POINT Z (3.0e0 4.0e0 5.0e0))"
            (encodeWKT shape >>= decodeWKT) @?= Right shape
        , testGroup
            "uniform collection dimension tags"
            [ testCase (Text.unpack ("layout" <> tag)) $ do
                let point = "POINT" <> tag <> " (" <> ordinates <> ")"
                    empty = "POINT" <> tag <> " EMPTY"
                    collection children = "GEOMETRYCOLLECTION" <> tag <> " (" <> Text.intercalate ", " children <> ")"
                    input = collection [point, collection [empty, point]]
                shape <- rightOrFail (decodeWKT input)
                encodeWKT shape @?= Right input
                (encodeWKT shape >>= decodeWKT) @?= Right shape
            | (tag, ordinates) <- [("", "1.0e0 2.0e0"), (" Z", "1.0e0 2.0e0 3.0e0"), (" M", "1.0e0 2.0e0 3.0e0"), (" ZM", "1.0e0 2.0e0 3.0e0 4.0e0")]
            ]
        , testCase "mixed descendants prevent a parent dimension tag" $ do
            let input = "GEOMETRYCOLLECTION (GEOMETRYCOLLECTION (POINT (1.0e0 2.0e0), POINT Z (3.0e0 4.0e0 5.0e0)), POINT Z (6.0e0 7.0e0 8.0e0))"
            shape <- rightOrFail (decodeWKT input)
            encodeWKT shape @?= Right input
            (encodeWKT shape >>= decodeWKT) @?= Right shape
        , testCase "empty collections inherit a containing layout" $ do
            let input = "GEOMETRYCOLLECTION (GEOMETRYCOLLECTION EMPTY, POINT Z EMPTY)"
            shape <- rightOrFail (decodeWKT input)
            encodeWKT shape @?= Right "GEOMETRYCOLLECTION Z (GEOMETRYCOLLECTION Z EMPTY, POINT Z EMPTY)"
            (encodeWKT shape >>= decodeWKT) @?= Right shape
        , testCase "empty containers are neutral when selecting collection tags" $
            forM_ [(" Z", "1 2 3"), (" M", "1 2 3"), (" ZM", "1 2 3 4")] $ \(tag, values) -> do
                let container family = family <> tag <> " EMPTY"
                    input = "GEOMETRYCOLLECTION" <> tag <> " (POINT" <> tag <> " (" <> values <> ")," <> Text.intercalate "," (map container ["MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON"]) <> ",GEOMETRYCOLLECTION" <> tag <> " (MULTIPOINT" <> tag <> " EMPTY))"
                shape <- rightOrFail (decodeWKT input)
                output <- rightOrFail (encodeWKT shape)
                assertBool "uniform parent tag" (Text.isPrefixOf ("GEOMETRYCOLLECTION" <> tag <> " (") output)
                forM_ ["MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON"] $ \family ->
                    assertBool "inherited empty tag" (Text.isInfixOf (container family) output)
                decodeWKT output @?= Right shape
        , testCase "collection tags use promoted multi-geometry output layouts" $ do
            let member = MultiPoint (U.fromList [PointXY (XY 1 2), PointXYZ (XYZ 3 4 5)])
            encodeWKT (GeometryCollection (V.singleton member)) @?= Right "GEOMETRYCOLLECTION Z (MULTIPOINT Z ((1.0e0 2.0e0 NaN), (3.0e0 4.0e0 5.0e0)))"
        , testCase "nested collection output preserves empty and measured layouts" $ do
            let members =
                    [PointGeometry (EmptyPoint dimensions) | dimensions <- [DimXY, DimXYZ, DimXYM, DimXYZM]]
                        ++ [PointGeometry (PointXYM (XYM 1 2 3)), PointGeometry (PointXYZM (XYZM 4 5 6 7)), LineString (CoordinatesXYZ U.empty)]
                shape = nestGeometry 3 (GeometryCollection (V.fromList members))
            (encodeWKT shape >>= decodeWKT) @?= Right shape
        , testCase "polygon writers pad each ring independently" $ do
            let shell = CoordinatesXY (U.fromList [XY 0 0, XY 4 0, XY 0 0])
                hole = CoordinatesXYZ (U.fromList [XYZ 1 1 2, XYZ 2 1 3, XYZ 1 1 2])
            encodeWKT (Polygon (PolygonRings shell (V.singleton hole))) @?= Right "POLYGON Z ((0.0e0 0.0e0 NaN, 4.0e0 0.0e0 NaN, 0.0e0 0.0e0 NaN), (1.0e0 1.0e0 2.0e0, 2.0e0 1.0e0 3.0e0, 1.0e0 1.0e0 2.0e0))"
        , testGroup "rejected syntax" [testCase (Text.unpack input) (assertRejected input) | input <- invalidInputs]
        , testCase "finite fixtures reject trailing input" $
            forM_ fixtures $
                \(input, _) -> forM_ ["x", " POINT EMPTY", ",", ";", "\0"] $ \suffix -> assertRejected (input <> suffix)
        , testCase "nested collections parse beyond 128 levels" $
            forM_ [127, 128, 1024] $ \levels ->
                decodeWKT (nestText levels "POINT (1 2)") @?= Right (nestGeometry levels (PointGeometry (PointXY (XY 1 2))))
        , testCase "nested empty point members preserve their layout" $
            decodeWKT (nestText 1024 "MULTIPOINT Z (EMPTY)") @?= Right (nestGeometry 1024 (MultiPoint (U.singleton (EmptyPoint DimXYZ))))
        , testCase "deep uniform collections retain tags and layouts when written" $ do
            let shape = nestGeometry 1024 (PointGeometry (EmptyPoint DimXYZM))
            output <- rightOrFail (encodeWKT shape)
            Text.count "GEOMETRYCOLLECTION ZM" output @?= 1024
            decodeWKT output @?= Right shape
        , testCase "wide collections parse" $ do
            let input = "GEOMETRYCOLLECTION (" <> Text.intercalate "," (replicate 1024 "POINT EMPTY") <> ")"
            decodeWKT input @?= Right (GeometryCollection (V.replicate 1024 (PointGeometry (EmptyPoint DimXY))))
        , localOption (mkTimeout 2000000) $ testCase "alternating collection tags reuse parsed child layouts" $ do
            let depth = 65536
                input = Text.concat [if even i then "GEOMETRYCOLLECTION Z (" else "GEOMETRYCOLLECTION (" | i <- [1 .. depth]] <> "POINT Z (0 0 0)" <> Text.replicate depth ")"
            assertBool "parsed alternating tags" (isRight (decodeWKT input))
        , testCase "nested mixed layouts cannot satisfy an explicit parent tag" $ do
            let mixed = "GEOMETRYCOLLECTION (POINT (1 2),POINT Z (1 2 3))"
            assertBool "untagged mixed collection" (isRight (decodeWKT mixed))
            forM_ [mixed, "GEOMETRYCOLLECTION (" <> mixed <> ")"] $ \child ->
                assertBool "tagged parent rejects mixed descendants" (isLeft (decodeWKT ("GEOMETRYCOLLECTION Z (" <> child <> ")")))
        , testCase "NaN tokens have canonical magnitude and explicit sign" $
            forM_ [("NaN", 0x7ff8000000000000), ("+NaN", 0x7ff8000000000000), ("-NaN", 0xfff8000000000000)] $ \(token, bits) -> do
                shape <- rightOrFail (decodeWKT ("POINT (" <> token <> " 0)"))
                case shape of
                    PointGeometry (PointXY (XY value _)) -> castDoubleToWord64 value @?= bits
                    _ -> assertFailure "expected an XY point"
        , testCase "construction errors retain their cause" $
            forM_ [("MULTILINESTRING ((0 0,1 1),(2 2))", "at least two coordinates"), ("POLYGON ((0 0,1 0,1 1,0 1))", "ring is not closed"), ("POINT (0 0) trailing", "trailing input")] $ \(input, message) ->
                case decodeWKT input of
                    Left failure -> assertBool failure (Text.isInfixOf message (Text.pack failure))
                    Right _ -> assertFailure "expected a parse error"
        ]

-- | Fixtures explicitly construct each coordinate layout.
fixtures :: [(Text, Geometry)]
fixtures =
    dimensionFixtures DimXY "" "1 2" "3 4" (XY 1 2) (XY 3 4) CoordinatesXY PointXY
        ++ dimensionFixtures DimXYZ " Z" "1 2 3" "4 5 6" (XYZ 1 2 3) (XYZ 4 5 6) CoordinatesXYZ PointXYZ
        ++ dimensionFixtures DimXYM " M" "1 2 3" "4 5 6" (XYM 1 2 3) (XYM 4 5 6) CoordinatesXYM PointXYM
        ++ dimensionFixtures DimXYZM " ZM" "1 2 3 4" "5 6 7 8" (XYZM 1 2 3 4) (XYZM 5 6 7 8) CoordinatesXYZM PointXYZM

-- | Pair format bodies with values independent of the decoder.
dimensionFixtures :: (Coordinate c) => Dimensions -> Text -> Text -> Text -> c -> c -> (U.Vector c -> Coordinates) -> (c -> Point) -> [(Text, Geometry)]
dimensionFixtures dimensions suffix first second a b wrap makePoint = do
    let line = wrap (U.fromList [a, b])
        ring = wrap (U.fromList [a, b, a])
        empty = wrap U.empty
        lineText = "(" <> first <> ", " <> second <> ")"
        polygonText = "((" <> first <> ", " <> second <> ", " <> first <> "))"
        rings = PolygonRings ring V.empty
    (family, body, full, emptyShape) <-
        [ ("POINT", "(" <> first <> ")", PointGeometry (makePoint a), PointGeometry (EmptyPoint dimensions))
        , ("LINESTRING", lineText, LineString line, LineString empty)
        , ("POLYGON", polygonText, Polygon rings, Polygon (PolygonRings empty V.empty))
        , ("MULTIPOINT", "((" <> first <> "), EMPTY, (" <> second <> "))", MultiPoint (U.fromList [makePoint a, EmptyPoint dimensions, makePoint b]), MultiPoint U.empty)
        , ("MULTILINESTRING", "(" <> lineText <> ", EMPTY)", MultiLineString (V.fromList [line, empty]), MultiLineString V.empty)
        , ("MULTIPOLYGON", "(" <> polygonText <> ", EMPTY)", MultiPolygon (V.fromList [rings, PolygonRings empty V.empty]), MultiPolygon V.empty)
        , ("GEOMETRYCOLLECTION", "(POINT" <> suffix <> " (" <> first <> "), LINESTRING" <> suffix <> " EMPTY)", GeometryCollection (V.fromList [PointGeometry (makePoint a), LineString empty]), GeometryCollection V.empty)
        ]
    [(family <> suffix <> " " <> body, full), (family <> suffix <> " EMPTY", emptyShape)]

-- | Cover heterogeneous members and the order of layout inference.
literalFixtures :: [(Text, Geometry)]
literalFixtures =
    [ ("POINT (1 2 3)", PointGeometry (PointXYZ (XYZ 1 2 3)))
    , ("POINT (1 2 3 4)", PointGeometry (PointXYZM (XYZM 1 2 3 4)))
    , ("POINT (.5 .25)", PointGeometry (PointXY (XY 0.5 0.25)))
    , ("POINT(+1. -2.)", PointGeometry (PointXY (XY 1 (-2))))
    , ("pOiNt\t( +.5\n-2.E+1 )", PointGeometry (PointXY (XY 0.5 (-20))))
    , ("POINT (001 002)", PointGeometry (PointXY (XY 1 2)))
    , ("MULTIPOINT (1 2,3 4)", MultiPoint (U.fromList [PointXY (XY 1 2), PointXY (XY 3 4)]))
    , ("MULTIPOINT (EMPTY,(1 2 3))", MultiPoint (U.fromList [EmptyPoint DimXY, PointXYZ (XYZ 1 2 3)]))
    , ("MULTIPOINT ((1 2 3),EMPTY)", MultiPoint (U.fromList [PointXYZ (XYZ 1 2 3), EmptyPoint DimXYZ]))
    , ("MULTILINESTRING (EMPTY,(1 2 3,4 5 6))", MultiLineString (V.fromList [CoordinatesXY U.empty, CoordinatesXYZ (U.fromList [XYZ 1 2 3, XYZ 4 5 6])]))
    , ("MULTIPOLYGON (EMPTY,((0 0 1,1 1 2,0 0 1)))", MultiPolygon (V.fromList [PolygonRings (CoordinatesXY U.empty) V.empty, PolygonRings (CoordinatesXYZ (U.fromList [XYZ 0 0 1, XYZ 1 1 2, XYZ 0 0 1])) V.empty]))
    , ("POLYGON (EMPTY,EMPTY)", Polygon (PolygonRings (CoordinatesXY U.empty) (V.singleton (CoordinatesXY U.empty))))
    , ("GEOMETRYCOLLECTION (POINT Z EMPTY,POINT (1 2))", GeometryCollection (V.fromList [PointGeometry (EmptyPoint DimXYZ), PointGeometry (PointXY (XY 1 2))]))
    , ("GEOMETRYCOLLECTION (POINT M EMPTY,POINT Z (1 2 3))", GeometryCollection (V.fromList [PointGeometry (EmptyPoint DimXYM), PointGeometry (PointXYZ (XYZ 1 2 3))]))
    , ("GEOMETRYCOLLECTION (MULTIPOINT M EMPTY,POINT (1 2))", GeometryCollection (V.fromList [MultiPoint U.empty, PointGeometry (PointXY (XY 1 2))]))
    , ("GEOMETRYCOLLECTION Z (POINT (1 2 3))", GeometryCollection (V.singleton (PointGeometry (PointXYZ (XYZ 1 2 3)))))
    , ("GEOMETRYCOLLECTION (POINT M EMPTY)", GeometryCollection (V.singleton (PointGeometry (EmptyPoint DimXYM))))
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
    , "POINT (1\x00A0\&2)"
    , "\x3000POINT (1 2)"
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
    , "GEOMETRYCOLLECTION Z (POINT EMPTY)"
    , "GEOMETRYCOLLECTION M (POINT Z EMPTY)"
    , "GEOMETRYCOLLECTION ZM (GEOMETRYCOLLECTION EMPTY)"
    , "GEOMETRYCOLLECTION (POINT EMPTY,)"
    , "CIRCULARSTRING (0 0,1 1,2 0)"
    , "POINT XY (1 2)"
    , "SRID=4326;POINT (1 2)"
    , "{\"type\":\"Point\",\"coordinates\":[1,2]}"
    ]
        ++ [ "LINESTRING (1 2)"
           , "POLYGON ((0 0,0 0))"
           , "POLYGON ((0 0,1 1,2 2))"
           , "POLYGON (EMPTY,(0 0,1 1,0 0))"
           , "POLYGON ((NaN NaN,1 1,NaN NaN))"
           , "MULTIPOINT(1 2,(3 4),EMPTY,5 6)"
           , "MULTIPOINT(EMPTY,1 2)"
           , "MULTIPOINT(1 2,EMPTY)"
           , "GEOMETRYCOLLECTION M (POINT (1 2 3))"
           , "LINESTRING (0 0,1 1 2)"
           , "LINESTRING (0 0 3,1 1)"
           , "POINT (NaNx 0)"
           , "POINT (Infinityx 0)"
           ]

-- | Require a controlled syntax or construction failure.
assertRejected :: Text -> Assertion
assertRejected input = assertBool "expected WKT rejection" (isLeft (decodeWKT input))

-- | Turn a parser error into a test failure.
rightOrFail :: Either String a -> IO a
rightOrFail result = case result of
    Left message -> assertFailure message
    Right value -> pure value

-- | Add untagged collection wrappers without using the writer.
nestText :: Int -> Text -> Text
nestText count input = Text.replicate count "GEOMETRYCOLLECTION (" <> input <> Text.replicate count ")"

-- | Build nested geometry values independently of the parser.
nestGeometry :: Int -> Geometry -> Geometry
nestGeometry 0 geometry = geometry
nestGeometry count geometry = GeometryCollection (V.singleton (nestGeometry (count - 1) geometry))

-- | Count the direct members of a geometry collection.
memberCount :: Geometry -> Int
memberCount (GeometryCollection members) = V.length members
memberCount _ = -1
