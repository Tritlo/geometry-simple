{-# LANGUAGE OverloadedStrings #-}

-- | Check ISO WKB against independent fixtures and bounded geometry trees.
module Main (main) where

import Control.Monad (forM_, void)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Char (digitToInt)
import Data.Either (isLeft, isRight)
import Data.Geometry
import Data.Geometry.Internal (emptyCoordinates, pointFromComponents)
import qualified Data.Geometry.SimpleFeatures as S
import Data.Geometry.WKB
import Data.Geometry.WKT (encodeWKT)
import qualified Data.Geometry.WKT as WKT
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import Data.Word (Word32, Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import qualified MeasureTests
import Numeric (showEFloat)
import qualified SFAConformanceTests
import qualified SimpleFeaturesTests
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, Property, arbitrary, chooseInt, conjoin, counterexample, elements, forAll, frequency, testProperty, vectorOf, (===))
import qualified TopologyBufferTests
import qualified TopologyOverlayTests
import qualified TopologyRelationTests
import qualified TopologyUnaryTests
import qualified WKTTests

-- | Run the pure tests without a native geometry library.
main :: IO ()
main = defaultMain tests

-- | Cover layouts, IEEE values, malformed input, and independent native fixtures.
tests :: TestTree
tests =
    testGroup
        "geometry-simple"
        [ SimpleFeaturesTests.tests
        , SFAConformanceTests.tests
        , MeasureTests.tests
        , TopologyRelationTests.tests
        , TopologyBufferTests.tests
        , TopologyOverlayTests.tests
        , TopologyUnaryTests.tests
        , WKTTests.tests
        , testGroup "fixed WKB bytes" fixedTests
        , testGroup
            "families, layouts, and byte orders"
            [ testCase label $ do
                decodeWKB bytes @?= Right expected
                validateWKB bytes @?= Right ()
                encodeWKB expected @?= Right canonical
                encodeWKT expected @?= Right text
                WKT.decodeWKT text @?= Right expected
            | (label, bytes, canonical, expected, text) <- samples
            ]
        , testGroup "malformed WKB" [testCase label (assertRejected label bytes) | (label, bytes) <- malformed]
        , testCase "all fixture prefixes and trailing bytes are rejected" $
            forM_ samples $ \(label, bytes, _, _, _) -> do
                forM_ [0 .. BS.length bytes - 1] $ \size -> assertRejected label (BS.take size bytes)
                assertRejected label (bytes <> BS.singleton 0)
        , testCase "empty atoms keep layout while empty collections discard parent tags" $
            forM_ [0, 1000, 2000, 3000] $ \offset -> forM_ [1 .. 7] $ \family ->
                (decodeWKB (emptyWKB False offset family) >>= encodeWKB)
                    @?= Right (emptyWKB True (if family < 4 then offset else 0) family)
        , testCase "empty children retain independent layouts" $
            forM_ [0, 1000, 2000, 3000] $ \parentOffset -> forM_ [0, 1000, 2000, 3000] $ \childOffset -> forM_ [1 .. 7] $ \family -> do
                let retained = if family < 4 then childOffset else 0
                    input = children False (parentOffset + 7) [emptyWKB False childOffset family]
                    canonical = children True (retained + 7) [emptyWKB True retained family]
                (decodeWKB input >>= encodeWKB) @?= Right canonical
        , testCase "mixed layouts ignore parent tags and preserve every child" $
            forM_ [0, 1000, 2000, 3000] $ \offset -> do
                let parts = [point False 0 [1, 2], point True 1000 [3, 4, 5], point False 2000 [6, 7, 8], emptyWKB True 3000 1]
                    canonical = children True 3007 [point True 0 [1, 2], point True 1000 [3, 4, 5], point True 2000 [6, 7, 8], emptyWKB True 3000 1]
                (decodeWKB (children False (offset + 7) parts) >>= encodeWKB) @?= Right canonical
        , testCase "mixed-width multipoints preserve bits and following siblings" $
            forM_ [(0, [-0.0, 5e-324]), (1000, [-0.0, 5e-324, 3]), (2000, [-0.0, 5e-324, 4]), (3000, [-0.0, 5e-324, 3, 4])] $ \(offset, values) ->
                forM_ [False, True] $ \little -> do
                    let parts = [point False 0 [0 / 0, 0 / 0], point True 1000 [0 / 0, 0 / 0, 3], point False 2000 [0 / 0, 0 / 0, 1 / 0], point True 3000 [0 / 0, 0 / 0, 3, -0.0], point little offset values]
                        multi = children little (offset + 4) parts
                        sibling = point (not little) offset values
                        bytes = children (not little) (offset + 7) [multi, sibling]
                        canonicalMulti = children True 3004 ([emptyWKB True d 1 | d <- [0, 1000, 2000, 3000]] ++ [point True offset values])
                        canonical = children True 3007 [canonicalMulti, point True offset values]
                    (decodeWKB bytes >>= encodeWKB) @?= Right canonical
                    validateWKB bytes @?= Right ()
                    forM_ [0 .. BS.length multi - 1] $ \size -> assertRejected "truncated mixed-width child" (BS.take size multi)
                    forM_ [0, 4, 6, maxBound] $ \wrongCount ->
                        assertRejected "count crosses a sibling boundary" $
                            children little (offset + 7) [wkb little (offset + 4) (count little wrongCount <> BS.concat parts), sibling]
        , testCase "multipoint mutable buffers preserve tags, slices, and bits" $ do
            let values = U.fromList [EmptyPoint DimXY, PointXY (XY (-0.0) 5e-324), EmptyPoint DimXYZ, PointXYZ (XYZ 1 2 (-0.0)), EmptyPoint DimXYM, PointXYM (XYM 1 2 5e-324), EmptyPoint DimXYZM, PointXYZM (XYZM (-0.0) 2 3 4)]
            target <- UM.new (U.length values + 2)
            U.imapM_ (\i value -> UM.write target (i + 1) value) values
            copied <- U.freeze (UM.slice 1 (U.length values) target)
            copied @?= values
            let shape = MultiPoint copied
            bytes <- rightOrFail (encodeWKB shape)
            (decodeWKB bytes >>= encodeWKB) @?= Right bytes
            read (show shape) @?= shape
            case copied U.! 1 of
                PointXY (XY x y) -> map castDoubleToWord64 [x, y] @?= [0x8000000000000000, 1]
                _ -> assertFailure "point layout changed"
        , testCase "finite coordinates preserve exact bits in every layout" $
            forM_ finiteWords $ \bits -> forM_ [0, 1000, 2000, 3000] $ \offset -> forM_ [False, True] $ \little -> do
                let value = castWord64ToDouble bits
                    values = case offset of 0 -> [value, -0.0]; 3000 -> [value, -0.0, value, value]; _ -> [value, -0.0, value]
                    canonical = point True offset values
                shape <- rightOrFail (decodeWKB (point little offset values))
                encodeWKB shape @?= Right canonical
                (encodeWKT shape >>= WKT.decodeWKT >>= encodeWKB) @?= Right canonical
        , testCase "XY NaNs denote empty WKB regardless of Z and M" $
            forM_ [(1000, [0 / 0, 0 / 0, 3]), (2000, [0 / 0, 0 / 0, 3]), (3000, [0 / 0, 0 / 0, 3, 4])] $ \(offset, values) ->
                (decodeWKB (point False offset values) >>= encodeWKB) @?= Right (emptyWKB True offset 1)
        , testCase "empty points accept distinct NaN payloads" $ do
            let values = map castWord64ToDouble [0x7ff0000000000001, 0xfff8000000000001, 0x7fffffffffffffff, 0xfff0000000000001]
            decodeWKB (point False 3000 values) @?= Right (PointGeometry (EmptyPoint DimXYZM))
        , testCase "WKT NaN points remain nonempty" $ do
            let shape = PointGeometry (PointXYZM (XYZM (0 / 0) (0 / 0) 3 4))
            (encodeWKB shape >>= decodeWKB) @?= Right (PointGeometry (EmptyPoint DimXYZM))
            decoded <- rightOrFail (encodeWKT shape >>= WKT.decodeWKT)
            case decoded of
                PointGeometry (PointXYZM (XYZM x y z m)) -> do
                    assertBool "lost NaN point" (isNaN x && isNaN y)
                    (z, m) @?= (3, 4)
                _ -> assertFailure "WKT point changed layout or emptiness"
        , testCase "non-finite ordinates remain in nonempty points and lines" $
            forM_ [0 / 0, 1 / 0, -1 / 0] $ \value ->
                forM_ [point True 3000 [value, 2, value, value], wkb True 2 (count True 2 <> coordinates True [value, 2, 3, value])] $ \bytes ->
                    (decodeWKB bytes >>= encodeWKB) @?= Right bytes
        , testCase "line and polygon constructor rules match GEOS" $ do
            let coords = CoordinatesXY . U.fromList
                polygon shell holes = Polygon (PolygonRings (coords shell) (V.fromList (map coords holes)))
                invalid = [LineString (coords [XY 1 2]), polygon [XY 0 0, XY 1 1] [], polygon [XY 0 0, XY 1 1, XY 2 2] [], polygon [] [[XY 0 0, XY 1 1, XY 0 0]]]
            forM_ invalid $ \shape -> do
                assertLeft (encodeWKB shape)
                assertLeft (encodeWKT shape)
            let degenerate = polygon [XY 0 0, XY 1 1, XY 0 0] []
            (encodeWKB degenerate >>= decodeWKB) @?= Right degenerate
        , testCase "empty polygon holes survive reading before writer normalization" $ do
            text <- rightOrFail (WKT.decodeWKT "POLYGON (EMPTY,EMPTY)")
            binary <- rightOrFail (decodeWKB (wkb True 3 (count True 2 <> count True 0 <> count True 0)))
            forM_ [text, binary] $ \shape -> do
                S.numInteriorRings shape @?= Just 1
                encodeWKT shape @?= Right "POLYGON EMPTY"
                encodeWKB shape @?= Right (emptyWKB True 0 3)
        , testCase "deep collections have no artificial nesting limit" $
            forM_ [127, 128, 1024] $ \depth -> forM_ [PointGeometry (PointXY (XY 1 2)), MultiPoint U.empty, MultiPoint (U.singleton (PointXY (XY 1 2)))] $ \leaf -> do
                let shape = foldr (\_ child -> GeometryCollection (V.singleton child)) leaf [1 .. depth :: Int]
                (encodeWKB shape >>= decodeWKB) @?= Right shape
                (encodeWKB shape >>= validateWKB) @?= Right ()
                (encodeWKT shape >>= WKT.decodeWKT) @?= Right shape
        , testCase "wide empty collections round-trip" $ do
            let shape = GeometryCollection (V.replicate 4096 (GeometryCollection V.empty))
            (encodeWKB shape >>= decodeWKB) @?= Right shape
        , testCase "deep WKB headers combine descendant layouts once" $ do
            let leaf = GeometryCollection (V.fromList [PointGeometry (EmptyPoint DimXYZ), PointGeometry (PointXYM (XYM 1 2 3))])
                shape = iterate (GeometryCollection . V.singleton) leaf !! 1024
                header = BS.pack [1, 191, 11, 0, 0, 1, 0, 0, 0]
            bytes <- rightOrFail (encodeWKB leaf)
            encodeWKB shape @?= Right (BS.concat (replicate 1024 header) <> bytes)
            (encodeWKB shape >>= decodeWKB) @?= Right shape
        , testProperty "WKB validation agrees after byte mutations" $
            forAll (geometryGen Nothing 3) $ \shape -> case encodeWKB shape of
                Left message -> counterexample message False
                Right bytes -> forAll (chooseInt (0, BS.length bytes - 1)) $ \offset -> forAll arbitrary $ \byte ->
                    let mutated = BS.take offset bytes <> BS.singleton byte <> BS.drop (offset + 1) bytes
                     in isRight (validateWKB mutated) === isRight (decodeWKB mutated)
        , testCase "ring validation uses XY closure in either byte order" $
            forM_ [False, True] $ \little -> forM_ [0, 1000, 2000, 3000] $ \offset -> do
                let dimensions = case offset of 0 -> 2; 3000 -> 4; _ -> 3
                    coord x y = [x, y] ++ replicate (dimensions - 2) (0 / 0)
                    ring values = count little (fromIntegral (length values)) <> coordinates little (concat values)
                    polygon rings = wkb little (offset + 3) (count little (fromIntegral (length rings)) <> BS.concat (map ring rings))
                    closed = [coord 0 0, coord 1 1, coord (-0.0) 0]
                forM_ [[], [[]], [closed], [closed, []], [[coord (1 / 0) 0, coord 1 1, coord (1 / 0) 0]]] $ \rings -> do
                    let bytes = polygon rings
                    validateWKB bytes @?= Right ()
                    assertBool "decoder rejected valid rings" (isRight (decodeWKB bytes))
                forM_ [[take 2 closed], [[coord 0 0, coord 1 1, coord 2 2]], [[coord (0 / 0) 0, coord 1 1, coord (0 / 0) 0]], [[], closed]] $ \rings ->
                    assertRejected "invalid polygon ring" (polygon rings)
        , testProperty "mixed-layout WKB round trips" $ roundTripProperty Nothing False
        , testProperty "XY WKT round trips" $ roundTripProperty (Just DimXY) True
        , testProperty "mixed-layout WKT stabilizes after format promotion" $
            forAll (geometryGen Nothing 3) $ \shape -> case encodeWKT shape of
                Left message -> counterexample message False
                Right encoded -> (WKT.decodeWKT encoded >>= encodeWKT) === Right encoded
        , testProperty "finite point bit patterns" $
            forAll finiteDouble $ \x -> forAll finiteDouble $ \y ->
                let bytes = point True 0 [x, y] in (decodeWKB bytes >>= encodeWKB) === Right bytes
        ]

-- | Generate finite trees. Each polygon uses one layout to avoid writer padding.
geometryGen :: Maybe Dimensions -> Int -> Gen Geometry
geometryGen fixed depth =
    frequency $
        [(2, PointGeometry <$> pointGen), (2, LineString <$> lineGen), (2, Polygon <$> polygonGen), (2, MultiPoint . U.fromList <$> shortList pointGen), (2, MultiLineString . V.fromList <$> shortList lineGen), (2, MultiPolygon . V.fromList <$> shortList polygonGen)]
            ++ [(1, GeometryCollection . V.fromList <$> shortList (geometryGen fixed (depth - 1))) | depth > 0]
  where
    layout = maybe (elements [minBound .. maxBound]) pure fixed
    pointGen = do
        dimensions <- layout
        frequency [(1, pure (EmptyPoint dimensions)), (3, pointFromComponents dimensions <$> components)]
    lineGen = do
        dimensions <- layout
        n <- elements [0, 2, 3]
        sequenceFrom dimensions <$> vectorOf n components
    polygonGen = do
        dimensions <- layout
        frequency
            [ (1, pure (PolygonRings (emptyCoordinates dimensions) V.empty))
            ,
                ( 3
                , do
                    a <- components
                    b <- components
                    holes <- shortList (frequency [(1, pure (emptyCoordinates dimensions)), (3, do p <- components; q <- components; pure (sequenceFrom dimensions [p, q, p]))])
                    pure (PolygonRings (sequenceFrom dimensions [a, b, a]) (V.fromList holes))
                )
            ]

-- | Four independently generated finite ordinates.
components :: Gen (Double, Double, Double, Double)
components = (,,,) <$> finiteDouble <*> finiteDouble <*> finiteDouble <*> finiteDouble

-- | Construct typed buffers from test tuples.
sequenceFrom :: Dimensions -> [(Double, Double, Double, Double)] -> Coordinates
sequenceFrom dimensions values = case dimensions of
    DimXY -> CoordinatesXY (U.fromList [XY x y | (x, y, _, _) <- values])
    DimXYZ -> CoordinatesXYZ (U.fromList [XYZ x y z | (x, y, z, _) <- values])
    DimXYM -> CoordinatesXYM (U.fromList [XYM x y m | (x, y, _, m) <- values])
    DimXYZM -> CoordinatesXYZM (U.fromList [XYZM x y z m | (x, y, z, m) <- values])

-- | Bound each container independently of the QuickCheck size.
shortList :: Gen a -> Gen [a]
shortList gen = chooseInt (0, 3) >>= (`vectorOf` gen)

-- | Generate finite bit patterns and IEEE boundaries.
finiteDouble :: Gen Double
finiteDouble = castWord64ToDouble <$> frequency [(1, elements finiteWords), (4, do bits <- arbitrary; pure (if bits .&. 0x7ff0000000000000 == 0x7ff0000000000000 then bits .&. 0xffefffffffffffff else bits))]

-- | Check values and canonical bytes. WKT identity applies to XY trees.
roundTripProperty :: Maybe Dimensions -> Bool -> Property
roundTripProperty layout useText = forAll (geometryGen layout 3) $ \shape ->
    case encodeWKB shape of
        Left message -> counterexample message False
        Right bytes ->
            let decoded = if useText then encodeWKT shape >>= WKT.decodeWKT else decodeWKB bytes
             in conjoin [decoded === Right shape, (decoded >>= encodeWKB) === Right bytes, validateWKB bytes === Right ()]

-- | Compare literal ISO WKB bytes with explicit geometry values.
fixedTests :: [TestTree]
fixedTests =
    [ testCase "little endian point" $
        decodeWKB (hexBytes "0101000000000000000000f03f0000000000000040") @?= Right ((PointGeometry (PointXY (XY 1 2))))
    , testCase "big endian point" $
        decodeWKB (hexBytes "00000000013ff00000000000004000000000000000") @?= Right ((PointGeometry (PointXY (XY 1 2))))
    , testCase "empty point" $
        decodeWKB (hexBytes "0101000000000000000000f87f000000000000f87f") @?= Right ((PointGeometry (EmptyPoint DimXY)))
    , testCase "two-point line" $
        decodeWKB (hexBytes "010200000002000000000000000000f03f000000000000004000000000000008400000000000001040")
            @?= Right ((LineString (CoordinatesXY (U.fromList [XY 1 2, XY 3 4]))))
    , testCase "triangle polygon" $
        decodeWKB (hexBytes "0103000000010000000400000000000000000000000000000000000000000000000000f03f0000000000000000000000000000f03f000000000000f03f00000000000000000000000000000000")
            @?= Right ((Polygon (PolygonRings (CoordinatesXY (U.fromList [XY 0 0, XY 1 0, XY 1 1, XY 0 0])) V.empty)))
    ]

-- | Fixtures use ISO type codes and explicitly selected byte orders.
samples :: [(String, ByteString, ByteString, Geometry, Text)]
samples =
    samplesFor 0 [1, 2] (XY 1 2) CoordinatesXY PointXY
        ++ samplesFor 1000 [1, 2, 3] (XYZ 1 2 3) CoordinatesXYZ PointXYZ
        ++ samplesFor 2000 [1, 2, 3] (XYM 1 2 3) CoordinatesXYM PointXYM
        ++ samplesFor 3000 [1, 2, 3, 4] (XYZM 1 2 3 4) CoordinatesXYZM PointXYZM

-- | Cover every family and its empty representation for one dimension.
samplesFor :: (Coordinate c) => Word32 -> [Double] -> c -> (U.Vector c -> Coordinates) -> (c -> Point) -> [(String, ByteString, ByteString, Geometry, Text)]
samplesFor offset values coord wrap makePoint = do
    little <- [False, True]
    empty <- [False, True]
    let dimensions = toEnum (fromIntegral (offset `div` 1000))
        suffix = case offset of 0 -> ""; 1000 -> " Z"; 2000 -> " M"; _ -> " ZM"
        coordinateText = Text.intercalate " " (map (\x -> Text.pack (showEFloat Nothing x "")) values)
        lineBody = "(" <> coordinateText <> ", " <> coordinateText <> ")"
        polygonBody = "((" <> Text.intercalate ", " (replicate 4 coordinateText) <> "))"
        fullPoint = PointGeometry (makePoint coord)
        fullLine = LineString (wrap (U.replicate 2 coord))
        fullPolygon = Polygon (PolygonRings (wrap (U.replicate 4 coord)) V.empty)
        cases =
            [ (1, "POINT", fullPoint, PointGeometry (EmptyPoint dimensions), "(" <> coordinateText <> ")")
            , (2, "LINESTRING", fullLine, LineString (wrap U.empty), lineBody)
            , (3, "POLYGON", fullPolygon, Polygon (PolygonRings (wrap U.empty) V.empty), polygonBody)
            , (4, "MULTIPOINT", MultiPoint (U.fromList [makePoint coord, EmptyPoint dimensions]), MultiPoint U.empty, "((" <> coordinateText <> "), EMPTY)")
            , (5, "MULTILINESTRING", MultiLineString (V.fromList [wrap (U.replicate 2 coord), wrap U.empty]), MultiLineString V.empty, "(" <> lineBody <> ", EMPTY)")
            , (6, "MULTIPOLYGON", MultiPolygon (V.fromList [PolygonRings (wrap (U.replicate 4 coord)) V.empty, PolygonRings (wrap U.empty) V.empty]), MultiPolygon V.empty, "(" <> polygonBody <> ", EMPTY)")
            , (7, "GEOMETRYCOLLECTION", GeometryCollection (V.fromList [fullPoint, LineString (wrap U.empty)]), GeometryCollection V.empty, "(POINT" <> suffix <> " (" <> coordinateText <> "), LINESTRING" <> suffix <> " EMPTY)")
            ]
        fullBytes order childOrder family = case family of
            1 -> point order offset values
            2 -> wkb order (offset + 2) (count order 2 <> coordinates order values <> coordinates order values)
            3 -> wkb order (offset + 3) (count order 1 <> count order 4 <> BS.concat (replicate 4 (coordinates order values)))
            4 -> children order (offset + 4) [point childOrder offset values, emptyWKB childOrder offset 1]
            5 -> children order (offset + 5) [fullBytes childOrder childOrder 2, emptyWKB childOrder offset 2]
            6 -> children order (offset + 6) [fullBytes childOrder childOrder 3, emptyWKB childOrder offset 3]
            _ -> children order (offset + 7) [point childOrder offset values, emptyWKB childOrder offset 2]
    (family, name, full, emptyShape, body) <- cases
    let bytes order childOrder = if empty then emptyWKB order offset family else fullBytes order childOrder family
        label = Text.unpack (name <> suffix) ++ " little=" ++ show little ++ " empty=" ++ show empty
    pure (label, bytes little (not little), (if empty && family >= 4 then emptyWKB True 0 family else bytes True True), (if empty then emptyShape else full), name <> (if empty && family >= 4 then "" else suffix) <> " " <> if empty then "EMPTY" else body)

-- | Reject invalid encodings before allocating from untrusted counts.
malformed :: [(String, ByteString)]
malformed =
    [("truncated point " ++ show size, BS.take size (point True 0 [1, 2])) | size <- [0 .. 20]]
        ++ [("byte order " ++ show marker, BS.singleton marker <> BS.drop 1 (point True 0 [1, 2])) | marker <- [2, 255]]
        ++ [("type " ++ show tag, wkb True tag (coordinates True [1, 2])) | tag <- [0, 8, 1000, 2000, 3000, 4001, 0x80000001, 0x40000001, 0x20000001, maxBound]]
        ++ [("hostile count " ++ show family ++ " " ++ show little, wkb little family (count little maxBound)) | little <- [False, True], family <- [2 .. 7]]
        ++ [ ("line count exceeds payload", wkb True 2 (count True 2 <> coordinates True [1, 2]))
           , ("coordinate count multiplication overflows uint32", wkb True 2 (count True 0x10000000 <> coordinates True [1, 2]))
           , ("ring count exceeds payload", wkb True 3 (count True 2 <> count True 0))
           , ("ring coordinate count exceeds payload", wkb True 3 (count True 1 <> count True maxBound))
           , ("child count exceeds payload", wkb True 7 (count True 2 <> emptyWKB True 0 7))
           , ("singleton line", wkb True 2 (count True 1 <> coordinates True [0 / 0, 0 / 0]))
           , ("singleton ring", wkb True 3 (count True 1 <> count True 1 <> coordinates True [0 / 0, 2]))
           , ("collection child byte order", children True 7 [BS.singleton 2 <> BS.drop 1 (point True 0 [1, 2])])
           , ("collection child type", children True 7 [wkb False 8 (count False 0)])
           ]
        ++ [("multi family mismatch " ++ show family, children True family [wkb False 7 (count False 0)]) | family <- [4 .. 6]]

-- | Finite IEEE 754 values with subnormal, boundary, and precision cases.
finiteWords :: [Word64]
finiteWords = [0, 0x8000000000000000, 1, 0x8000000000000001, 0x000fffffffffffff, 0x0010000000000000, 0x3fb999999999999b, 0x3ff0000000000001, 0x4340000000000001, 0x44b52d02c7e14af6, 0x7fefffffffffffff, 0xffefffffffffffff]

-- | Require a controlled parse failure.
assertRejected :: String -> ByteString -> Assertion
assertRejected label bytes = forM_ [void (decodeWKB bytes), validateWKB bytes] $ \result -> case result of
    Left message -> assertBool (label ++ ": " ++ message) ("Geometry WKB " `isPrefixOf` message)
    Right () -> assertFailure (label ++ " accepted malformed WKB")

-- | Require a validation error without relying on its wording.
assertLeft :: Either String a -> Assertion
assertLeft result = assertBool "expected validation failure" (isLeft result)

-- | Turn an unexpected codec error into a test failure.
rightOrFail :: Either String a -> IO a
rightOrFail result = case result of
    Left message -> assertFailure message
    Right value -> pure value

-- | Build an ISO WKB geometry header and payload.
wkb :: Bool -> Word32 -> ByteString -> ByteString
wkb little tag payload = BS.singleton (if little then 1 else 0) <> count little tag <> payload

-- | Encode a WKB point with explicit dimension metadata.
point :: Bool -> Word32 -> [Double] -> ByteString
point little offset values = wkb little (offset + 1) (coordinates little values)

-- | Encode an empty value with its own dimension metadata.
emptyWKB :: Bool -> Word32 -> Word32 -> ByteString
emptyWKB little offset family
    | family == 1 = point little offset (replicate dimensions (castWord64ToDouble 0x7ff8000000000000))
    | otherwise = wkb little (offset + family) (count little 0)
  where
    dimensions = case offset of 0 -> 2; 3000 -> 4; _ -> 3

-- | Encode a child sequence with its own geometry headers.
children :: Bool -> Word32 -> [ByteString] -> ByteString
children little tag parts = wkb little tag (count little (fromIntegral (length parts)) <> BS.concat parts)

-- | Encode a WKB coordinate count or type tag.
count :: Bool -> Word32 -> ByteString
count little value = wordBytes little 4 (fromIntegral value)

-- | Encode IEEE 754 coordinates in the selected byte order.
coordinates :: Bool -> [Double] -> ByteString
coordinates little = BS.concat . map (wordBytes little 8 . castDoubleToWord64)

-- | Encode an unsigned word in the selected byte order.
wordBytes :: Bool -> Int -> Word64 -> ByteString
wordBytes little size value = BS.pack [fromIntegral (shiftR value (8 * position)) | position <- if little then [0 .. size - 1] else reverse [0 .. size - 1]]

-- | Decode fixed hexadecimal fixture bytes.
hexBytes :: String -> ByteString
hexBytes = BS.pack . go
  where
    go [] = []
    go (a : b : rest) = fromIntegral (16 * digitToInt a + digitToInt b) : go rest
    go _ = error "odd hexadecimal fixture length"
