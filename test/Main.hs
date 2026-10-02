{-# LANGUAGE OverloadedStrings #-}

-- | Check ISO WKB against independent fixtures and bounded geometry trees.
module Main (main) where

import Control.Monad (forM_)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Char (digitToInt)
import Data.Either (isLeft)
import Data.Geometry
import Data.Geometry.WKB
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32, Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Numeric (showEFloat)
import Test.Tasty (TestTree, defaultMain, localOption, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen, Property, QuickCheckTests (..), arbitrary, chooseInt, conjoin, counterexample, elements, forAll, frequency, testProperty, vectorOf, (===))

-- | Run the pure codec tests without a native geometry library.
main :: IO ()
main = defaultMain tests

-- | Cover valid ISO encodings, malformed input, and checked construction.
tests :: TestTree
tests =
    testGroup
        "geometry-simple"
        [ testGroup "fixed WKB bytes" fixedTests
        , testGroup "families, dimensions, and byte orders" $
            [ testCase label $ do
                decodeAnyWKB bytes @?= Right expected
                assertTypedDecode bytes expected
                encodeAnyWKB expected @?= Right canonical
                encodeAnyWKT expected @?= Right wkt
            | (label, bytes, canonical, expected, wkt) <- samples
            ]
        , testCase "nested collections accept mixed byte orders" $ do
            let bytes = children False 7 [point True 0 [1, 2], children True 7 [wkb False 2 (count False 0)]]
                expected = GeometryXY $ GeometryCollection $ V.fromList [PointGeometry (Point (XY 1 2)), GeometryCollection (V.singleton (LineString U.empty))]
            decodeAnyWKB bytes @?= Right expected
            encodeAnyWKT expected @?= Right "GEOMETRYCOLLECTION (POINT (1.0e0 2.0e0), GEOMETRYCOLLECTION (LINESTRING EMPTY))"
        , testCase "all typed empty geometries reject other dimensions" $
            forM_ [0, 1000, 2000, 3000] $ \offset ->
                forM_ [1 .. 7] $ \family -> do
                    let bytes = emptyWKB False offset family
                    if offset == 0 then pure () else assertLeft (decodeWKB bytes :: Either String (Geometry XY))
                    if offset == 1000 then pure () else assertLeft (decodeWKB bytes :: Either String (Geometry XYZ))
                    if offset == 2000 then pure () else assertLeft (decodeWKB bytes :: Either String (Geometry XYM))
                    if offset == 3000 then pure () else assertLeft (decodeWKB bytes :: Either String (Geometry XYZM))
        , testCase "empty point children preserve their position" $ do
            let points = U.fromList [EmptyPoint, Point (XYZM 1 2 3 4), EmptyPoint, Point (XYZM (-0.0) 6 7 8)]
                shape = MultiPoint points
            decoded <- rightOrFail (encodeWKB shape >>= decodeWKB)
            case decoded of
                MultiPoint actual -> do
                    U.length actual @?= 4
                    actual U.! 0 @?= EmptyPoint
                    actual U.! 1 @?= Point (XYZM 1 2 3 4)
                    actual U.! 2 @?= EmptyPoint
                    case actual U.! 3 of
                        Point (XYZM x y z m) -> do
                            castDoubleToWord64 x @?= 0x8000000000000000
                            (y, z, m) @?= (6, 7, 8)
                        EmptyPoint -> assertFailure "a nonempty point became empty"
                _ -> assertFailure "a multipoint changed geometry family"
        , testCase "all-NaN points accept different NaN payloads" $ do
            let values = map castWord64ToDouble [0x7ff0000000000001, 0xfff8000000000001, 0x7fffffffffffffff, 0xfff0000000000001]
            decodeAnyWKB (point False 3000 values) @?= Right (GeometryXYZM (PointGeometry EmptyPoint))
        , testCase "finite Double values retain exact bits and negative zero" $
            forM_ finiteWords $ \word ->
                forM_ [False, True] $ \little -> do
                    let value = castWord64ToDouble word
                    decoded <- rightOrFail (decodeWKB (point little 0 [value, -0.0]) :: Either String (Geometry XY))
                    case decoded of
                        PointGeometry (Point (XY x y)) -> do
                            castDoubleToWord64 x @?= word
                            castDoubleToWord64 y @?= 0x8000000000000000
                        _ -> assertFailure "a finite point changed geometry family"
                    encodeWKB decoded @?= Right (point True 0 [value, -0.0])
                    rendered <- rightOrFail (encodeWKT decoded)
                    case Text.words (Text.dropEnd 1 (Text.drop 7 rendered)) of
                        [x, y] -> do
                            castDoubleToWord64 (read (Text.unpack x) :: Double) @?= word
                            castDoubleToWord64 (read (Text.unpack y) :: Double) @?= 0x8000000000000000
                        _ -> assertFailure ("unexpected WKT: " ++ Text.unpack rendered)
        , testCase "every dimension preserves finite coordinate bits" $
            forM_ finiteWords $ \word ->
                forM_ [0, 1000, 2000, 3000] $ \offset -> do
                    let value = castWord64ToDouble word
                        values = case offset of
                            0 -> [value, -0.0]
                            3000 -> [value, -0.0, value, value]
                            _ -> [value, -0.0, value]
                    forM_ [False, True] $ \little ->
                        (decodeAnyWKB (point little offset values) >>= encodeAnyWKB)
                            @?= Right (point True offset values)
        , testCase "coordinate and point vector slices retain their offsets" $ do
            let line = LineString (U.slice 1 2 (U.fromList [XY 9 9, XY 1 2, XY 3 4, XY 8 8]))
                points = MultiPoint (U.slice 1 2 (U.fromList [Point (XY 9 9), EmptyPoint, Point (XY 1 2), Point (XY 8 8)]))
            encodeWKB line @?= Right (wkb True 2 (count True 2 <> coordinates True [1, 2, 3, 4]))
            encodeWKB points @?= Right (children True 4 [emptyWKB True 0 1, point True 0 [1, 2]])
        , testCase "structural validation does not impose topology" $ do
            let openRing = U.fromList [XY 0 0, XY 1 1]
                polygon = Polygon (V.fromList [U.empty, openRing])
            (encodeWKB polygon >>= decodeWKB) @?= Right polygon
            encodeWKT polygon @?= Right "POLYGON (EMPTY, (0.0e0 0.0e0, 1.0e0 1.0e0))"
            let singletonLine = LineString (U.singleton (XY 1 2))
            (encodeWKB singletonLine >>= decodeWKB) @?= Right singletonLine
        , testCase "every proper fixture prefix is truncated" $
            forM_ samples $ \(label, bytes, _, _, _) ->
                forM_ [0 .. BS.length bytes - 1] $ \size ->
                    assertRejected (label ++ " prefix " ++ show size) (BS.take size bytes)
        , testCase "trailing bytes are rejected" $
            forM_ samples $ \(label, bytes, _, _, _) ->
                assertRejected label (bytes <> BS.singleton 0)
        , testGroup "malformed WKB" [testCase label (assertRejected label bytes) | (label, bytes) <- malformed]
        , testGroup "invalid constructed coordinates" invalidConstructedTests
        , testCase "128 geometry levels are accepted" $ do
            let shape = nestedGeometry 127
            decodeWKB (nestedWKB 127) @?= Right shape
            encodeWKB shape @?= Right (nestedWKB 127)
            encodeWKT shape @?= Right (nestedWKT 127)
        , testCase "129 geometry levels are rejected" $ do
            assertRejected "depth limit" (nestedWKB 128)
            assertLeft (encodeWKB (nestedGeometry 128))
            assertLeft (encodeWKT (nestedGeometry 128))
        , testGroup
            "multipoint depth"
            [ testCase label $ do
                let leaf = MultiPoint (if nonempty then U.singleton (Point (XY 1 2)) else U.empty)
                    shape = foldr (\_ child -> GeometryCollection (V.singleton child)) leaf [1 .. levels :: Int]
                    leafBytes = children True 4 [point True 0 [1, 2] | nonempty]
                    bytes = foldr (\_ child -> children True 7 [child]) leafBytes [1 .. levels :: Int]
                if accepted
                    then do
                        decodeWKB bytes @?= Right shape
                        encodeWKB shape @?= Right bytes
                        assertBool "WKT rejected an allowed depth" (not (isLeft (encodeWKT shape)))
                    else do
                        assertRejected label bytes
                        assertLeft (encodeWKB shape)
                        assertLeft (encodeWKT shape)
            | (label, levels, nonempty, accepted) <-
                [ ("point child at level 128 is accepted", 126, True, True)
                , ("point child at level 129 is rejected", 127, True, False)
                , ("empty multipoint at level 128 is accepted", 127, False, True)
                ]
            ]
        , testCase "wide collections do not consume the depth budget" $ do
            let shape = GeometryCollection (V.replicate 4096 (GeometryCollection V.empty)) :: Geometry XY
                bytes = children True 7 (replicate 4096 (wkb True 7 (count True 0)))
            decodeWKB bytes @?= Right shape
            encodeWKB shape @?= Right bytes
        , localOption (QuickCheckTests 250) $
            testGroup
                "bounded geometry properties"
                [ testProperty "XY" $ roundTripProperty (XY <$> finiteDouble <*> finiteDouble)
                , testProperty "XYZ" $ roundTripProperty (XYZ <$> finiteDouble <*> finiteDouble <*> finiteDouble)
                , testProperty "XYM" $ roundTripProperty (XYM <$> finiteDouble <*> finiteDouble <*> finiteDouble)
                , testProperty "XYZM" $ roundTripProperty (XYZM <$> finiteDouble <*> finiteDouble <*> finiteDouble <*> finiteDouble)
                , testProperty "XY point bit patterns" $
                    forAll finiteDouble $ \x -> forAll finiteDouble $ \y ->
                        let bytes = point True 0 [x, y]
                         in ((decodeWKB bytes :: Either String (Geometry XY)) >>= encodeWKB) === Right bytes
                ]
        ]

-- | Compare literal ISO WKB bytes with explicit geometry values.
fixedTests :: [TestTree]
fixedTests =
    [ testCase "little endian point" $
        decodeAnyWKB (hexBytes "0101000000000000000000f03f0000000000000040") @?= Right (GeometryXY (PointGeometry (Point (XY 1 2))))
    , testCase "big endian point" $
        decodeAnyWKB (hexBytes "00000000013ff00000000000004000000000000000") @?= Right (GeometryXY (PointGeometry (Point (XY 1 2))))
    , testCase "empty point" $
        decodeAnyWKB (hexBytes "0101000000000000000000f87f000000000000f87f") @?= Right (GeometryXY (PointGeometry EmptyPoint))
    , testCase "two-point line" $
        decodeAnyWKB (hexBytes "010200000002000000000000000000f03f000000000000004000000000000008400000000000001040")
            @?= Right (GeometryXY (LineString (U.fromList [XY 1 2, XY 3 4])))
    , testCase "triangle polygon" $
        decodeAnyWKB (hexBytes "0103000000010000000400000000000000000000000000000000000000000000000000f03f0000000000000000000000000000f03f000000000000f03f00000000000000000000000000000000")
            @?= Right (GeometryXY (Polygon (V.singleton (U.fromList [XY 0 0, XY 1 0, XY 1 1, XY 0 0]))))
    ]

-- | Fixtures use ISO type codes and explicitly selected byte orders.
samples :: [(String, ByteString, ByteString, AnyGeometry, Text)]
samples =
    samplesFor 0 [1, 2] (XY 1 2) GeometryXY
        ++ samplesFor 1000 [1, 2, 3] (XYZ 1 2 3) GeometryXYZ
        ++ samplesFor 2000 [1, 2, 3] (XYM 1 2 3) GeometryXYM
        ++ samplesFor 3000 [1, 2, 3, 4] (XYZM 1 2 3 4) GeometryXYZM

-- | Cover every family and its empty representation for one dimension.
samplesFor :: (Coordinate c) => Word32 -> [Double] -> c -> (Geometry c -> AnyGeometry) -> [(String, ByteString, ByteString, AnyGeometry, Text)]
samplesFor offset values coord wrap = do
    little <- [False, True]
    empty <- [False, True]
    let suffix = case offset of 0 -> ""; 1000 -> " Z"; 2000 -> " M"; _ -> " ZM"
        coordinateText = Text.intercalate " " (map (\x -> Text.pack (showEFloat Nothing x "")) values)
        lineBody = "(" <> coordinateText <> ", " <> coordinateText <> ")"
        polygonBody = "((" <> Text.intercalate ", " (replicate 4 coordinateText) <> "))"
        fullPoint = PointGeometry (Point coord)
        fullLine = LineString (U.replicate 2 coord)
        fullPolygon = Polygon (V.singleton (U.replicate 4 coord))
        cases =
            [ (1, "POINT", fullPoint, PointGeometry EmptyPoint, "(" <> coordinateText <> ")")
            , (2, "LINESTRING", fullLine, LineString U.empty, lineBody)
            , (3, "POLYGON", fullPolygon, Polygon V.empty, polygonBody)
            , (4, "MULTIPOINT", MultiPoint (U.fromList [Point coord, EmptyPoint]), MultiPoint U.empty, "((" <> coordinateText <> "), EMPTY)")
            , (5, "MULTILINESTRING", MultiLineString (V.fromList [U.replicate 2 coord, U.empty]), MultiLineString V.empty, "(" <> lineBody <> ", EMPTY)")
            , (6, "MULTIPOLYGON", MultiPolygon (V.fromList [V.singleton (U.replicate 4 coord), V.empty]), MultiPolygon V.empty, "(" <> polygonBody <> ", EMPTY)")
            , (7, "GEOMETRYCOLLECTION", GeometryCollection (V.fromList [fullPoint, LineString U.empty]), GeometryCollection V.empty, "(POINT" <> suffix <> " (" <> coordinateText <> "), LINESTRING" <> suffix <> " EMPTY)")
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
    pure (label, bytes little (not little), bytes True True, wrap (if empty then emptyShape else full), name <> suffix <> " " <> if empty then "EMPTY" else body)

-- | Decode a runtime dimension with its corresponding static coordinate type.
assertTypedDecode :: ByteString -> AnyGeometry -> Assertion
assertTypedDecode bytes expected = case expected of
    GeometryXY shape -> decodeWKB bytes @?= Right shape
    GeometryXYZ shape -> decodeWKB bytes @?= Right shape
    GeometryXYM shape -> decodeWKB bytes @?= Right shape
    GeometryXYZM shape -> decodeWKB bytes @?= Right shape

-- | Encode a geometry with a runtime dimension.
encodeAnyWKB :: AnyGeometry -> Either String ByteString
encodeAnyWKB geometry = case geometry of
    GeometryXY shape -> encodeWKB shape
    GeometryXYZ shape -> encodeWKB shape
    GeometryXYM shape -> encodeWKB shape
    GeometryXYZM shape -> encodeWKB shape

-- | Render a geometry with a runtime dimension.
encodeAnyWKT :: AnyGeometry -> Either String Text
encodeAnyWKT geometry = case geometry of
    GeometryXY shape -> encodeWKT shape
    GeometryXYZ shape -> encodeWKT shape
    GeometryXYM shape -> encodeWKT shape
    GeometryXYZM shape -> encodeWKT shape

-- | Reject invalid encodings before allocating from untrusted counts.
malformed :: [(String, ByteString)]
malformed =
    [("byte order " ++ show marker, BS.singleton marker <> BS.drop 1 (point True 0 [1, 2])) | marker <- [2, 255]]
        ++ [("type " ++ show tag, wkb True tag (coordinates True [1, 2])) | tag <- [0, 8, 1000, 2000, 3000, 4001, 0x80000001, 0x40000001, 0x20000001, maxBound]]
        ++ [("hostile count " ++ show family ++ " " ++ show little, wkb little family (count little maxBound)) | little <- [False, True], family <- [2 .. 7]]
        ++ [ ("line count exceeds payload", wkb True 2 (count True 2 <> coordinates True [1, 2]))
           , ("coordinate count multiplication overflows uint32", wkb True 2 (count True 0x10000000 <> coordinates True [1, 2]))
           , ("ring count exceeds payload", wkb True 3 (count True 2 <> count True 0))
           , ("ring coordinate count exceeds payload", wkb True 3 (count True 1 <> count True maxBound))
           , ("child count exceeds payload", wkb True 7 (count True 2 <> emptyWKB True 0 7))
           , ("point partially NaN", point True 0 [0 / 0, 2])
           , ("point positive infinity", point True 0 [1 / 0, 2])
           , ("point negative infinity", point False 0 [1, -1 / 0])
           , ("line all-NaN coordinate", wkb True 2 (count True 1 <> coordinates True [0 / 0, 0 / 0]))
           , ("polygon NaN coordinate", wkb True 3 (count True 1 <> count True 1 <> coordinates True [0 / 0, 2]))
           , ("point Z partial NaN", point True 1000 [0 / 0, 0 / 0, 3])
           , ("point ZM infinite measure", point False 3000 [1, 2, 3, 1 / 0])
           , ("collection child byte order", children True 7 [BS.singleton 2 <> BS.drop 1 (point True 0 [1, 2])])
           , ("collection child type", children True 7 [wkb False 8 (count False 0)])
           ]
        ++ [("multi family mismatch " ++ show family, children True family [wkb False 7 (count False 0)]) | family <- [4 .. 6]]
        ++ [("multi dimensions mismatch " ++ show family, children True family [emptyWKB False 1000 (family - 3)]) | family <- [4 .. 6]]
        ++ [ ("multi M is not Z", children True 2004 [point False 1000 [1, 2, 3]])
           , ("empty collection dimensions differ", children False 1007 [emptyWKB True 2000 7])
           , ("nested point dimensions differ", children False 7 [point True 1000 [1, 2, 3]])
           , ("nested empty point dimensions differ", children True 3007 [emptyWKB False 0 1])
           ]

-- | Non-finite coordinates must fail through both output formats.
invalidConstructedTests :: [TestTree]
invalidConstructedTests =
    testCase
        "all-NaN coordinates require EmptyPoint"
        ( do
            let shape = PointGeometry (Point (XY (0 / 0) (0 / 0)))
            assertLeft (encodeWKB shape)
            assertLeft (encodeWKT shape)
        )
        : [ testCase label $ do
                assertLeft (encodeAnyWKB shape)
                assertLeft (encodeAnyWKT shape)
          | value <- [0 / 0, 1 / 0, -1 / 0]
          , (label, shape) <-
                [ ("point " ++ show value, GeometryXY (PointGeometry (Point (XY value 2))))
                , ("line " ++ show value, GeometryXY (LineString (U.singleton (XY 1 value))))
                , ("ring " ++ show value, GeometryXY (Polygon (V.singleton (U.singleton (XY value 2)))))
                , ("multipoint " ++ show value, GeometryXY (MultiPoint (U.fromList [EmptyPoint, Point (XY 1 value)])))
                , ("nested collection " ++ show value, GeometryXY (GeometryCollection (V.singleton (PointGeometry (Point (XY value 2))))))
                , ("Z " ++ show value, GeometryXYZ (PointGeometry (Point (XYZ 1 2 value))))
                , ("M " ++ show value, GeometryXYM (PointGeometry (Point (XYM 1 2 value))))
                , ("ZM " ++ show value, GeometryXYZM (PointGeometry (Point (XYZM 1 2 3 value))))
                ]
          ]

-- | Generate small trees independently of the codec representation.
geometryGen :: (Coordinate c) => Gen c -> Int -> Gen (Geometry c)
geometryGen coordinate depth =
    frequency $
        [ (2, PointGeometry <$> pointGen)
        , (2, LineString <$> lineGen)
        , (2, Polygon <$> polygonGen)
        , (2, MultiPoint . U.fromList <$> shortList pointGen)
        , (2, MultiLineString . V.fromList <$> shortList lineGen)
        , (2, MultiPolygon . V.fromList <$> shortList polygonGen)
        ]
            ++ [(1, GeometryCollection . V.fromList <$> shortList (geometryGen coordinate (depth - 1))) | depth > 0]
  where
    pointGen = frequency [(1, pure EmptyPoint), (3, Point <$> coordinate)]
    lineGen = U.fromList <$> shortList coordinate
    polygonGen = V.fromList <$> shortList lineGen

-- | Limit the size of each container independently of QuickCheck's size.
shortList :: Gen a -> Gen [a]
shortList gen = chooseInt (0, 3) >>= (`vectorOf` gen)

-- | Include arbitrary finite bit patterns and selected IEEE boundaries.
finiteDouble :: Gen Double
finiteDouble = castWord64ToDouble <$> frequency [(1, elements finiteWords), (4, finiteBits)]
  where
    finiteBits = do
        bits <- arbitrary
        pure $ if bits .&. 0x7ff0000000000000 == 0x7ff0000000000000 then bits .&. 0xffefffffffffffff else bits

-- | Check semantic and canonical binary round trips for bounded trees.
roundTripProperty :: (Coordinate c) => Gen c -> Property
roundTripProperty coordinate =
    forAll (geometryGen coordinate 3) $ \shape ->
        case encodeWKB shape of
            Left message -> counterexample message False
            Right bytes ->
                let decoded = decodeWKB bytes
                 in conjoin
                        [ decoded === Right shape
                        , (decoded >>= encodeWKB) === Right bytes
                        , counterexample "WKT rejected finite geometry" (not (isLeft (encodeWKT shape)))
                        ]

-- | Finite IEEE 754 values with subnormal, boundary, and precision cases.
finiteWords :: [Word64]
finiteWords = [0, 0x8000000000000000, 1, 0x8000000000000001, 0x000fffffffffffff, 0x0010000000000000, 0x3fb999999999999b, 0x3ff0000000000001, 0x4340000000000001, 0x44b52d02c7e14af6, 0x7fefffffffffffff, 0xffefffffffffffff]

-- | Require a controlled parse failure.
assertRejected :: String -> ByteString -> Assertion
assertRejected label bytes = case decodeAnyWKB bytes of
    Left _ -> pure ()
    Right shape -> assertFailure (label ++ " accepted: " ++ show shape)

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

-- | Build a point within the selected number of nested collections.
nestedWKB :: Int -> ByteString
nestedWKB 0 = point True 0 [1, 2]
nestedWKB depth = children True 7 [nestedWKB (depth - 1)]

-- | Construct the expected value independently of the WKB decoder.
nestedGeometry :: Int -> Geometry XY
nestedGeometry 0 = PointGeometry (Point (XY 1 2))
nestedGeometry depth = GeometryCollection (V.singleton (nestedGeometry (depth - 1)))

-- | Render the expected text independently of the WKT encoder.
nestedWKT :: Int -> Text
nestedWKT 0 = "POINT (1.0e0 2.0e0)"
nestedWKT depth = "GEOMETRYCOLLECTION (" <> nestedWKT (depth - 1) <> ")"
