{-# LANGUAGE ScopedTypeVariables #-}

{- | Checked ISO WKB decoding and encoding.

The codecs support the seven simple geometry families and all four coordinate
types. Nonempty children must have the same dimensions as their parent. WKB
children can use different byte orders. EWKB flags and embedded SRIDs are not
supported. Keep coordinate reference system metadata outside the geometry.

The codecs check line lengths, ring closure, counts, and dimensions.
They accept non-finite ordinates and do not validate polygon topology.
-}
module Data.Geometry.WKB (
    decodeWKB,
    decodeAnyWKB,
    encodeWKB,
) where

import Control.Monad (unless, when)
import Control.Monad.ST (runST)
import Data.Binary.Get (Get, bytesRead, getByteString, getWord32be, getWord32le, getWord64be, getWord64le, getWord8, lookAhead, runGetOrFail, skip)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as Builder
import Data.ByteString.Builder.Prim ((>$<), (>*<))
import qualified Data.ByteString.Builder.Prim as Prim
import qualified Data.ByteString.Lazy as BL
import Data.Geometry.Internal
import Data.Int (Int64)
import Data.Proxy (Proxy (..))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import Data.Word (Word32, Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)

{- | Decode one ISO WKB geometry into the requested coordinate type.
Reject trailing bytes, invalid counts, and mixed nonempty dimensions.
A point with NaN in both X and Y decodes to 'EmptyPoint'.
-}
decodeWKB :: forall c. (Coordinate c) => ByteString -> Either String (Geometry c)
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XY) #-}
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XYZ) #-}
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XYM) #-}
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XYZM) #-}
decodeWKB bytes = runDecoder parser bytes
  where
    parser = do
        (_, dimensions, _) <- lookAhead getHeader
        unless (dimensions == coordinateDimensions (Proxy :: Proxy c)) $
            fail "Geometry WKB has the wrong coordinate dimensions"
        getGeometry (fromIntegral (BS.length bytes)) Nothing

-- | Decode one ISO WKB geometry and keep the coordinate type from its header.
decodeAnyWKB :: ByteString -> Either String AnyGeometry
decodeAnyWKB bytes = runDecoder parser bytes
  where
    parser = do
        (_, dimensions, _) <- lookAhead getHeader
        let total = fromIntegral (BS.length bytes)
        case dimensions of
            DimXY -> GeometryXY <$> getGeometry total Nothing
            DimXYZ -> GeometryXYZ <$> getGeometry total Nothing
            DimXYM -> GeometryXYM <$> getGeometry total Nothing
            DimXYZM -> GeometryXYZM <$> getGeometry total Nothing

{- | Encode little-endian ISO WKB. Empty points use quiet NaN ordinates.
Finite coordinates retain their exact bits, including negative zero.
-}
encodeWKB :: (Coordinate c) => Geometry c -> Either String ByteString
{-# SPECIALIZE encodeWKB :: Geometry XY -> Either String ByteString #-}
{-# SPECIALIZE encodeWKB :: Geometry XYZ -> Either String ByteString #-}
{-# SPECIALIZE encodeWKB :: Geometry XYM -> Either String ByteString #-}
{-# SPECIALIZE encodeWKB :: Geometry XYZM -> Either String ByteString #-}
encodeWKB geometry = do
    validateGeometry checkedLength geometry
    pure (BL.toStrict (Builder.toLazyByteString (putGeometry geometry)))

-- | Run a decoder and require complete input consumption.
runDecoder :: Get a -> ByteString -> Either String a
runDecoder parser bytes = case runGetOrFail parser (BL.fromStrict bytes) of
    Left (_, _, message) -> Left message
    Right (remaining, _, value)
        | BL.null remaining -> Right value
        | otherwise -> Left "Geometry WKB has trailing bytes"

-- | Read each geometry's byte order, dimensions, and family independently.
getHeader :: Get (Bool, Dimensions, Word32)
getHeader = do
    marker <- getWord8
    little <- case marker of
        0 -> pure False
        1 -> pure True
        _ -> fail "Geometry WKB has an invalid byte order"
    tag <- getWord little
    let (dimensionTag, family) = tag `quotRem` 1000
    unless (dimensionTag <= 3 && family >= 1 && family <= 7) $
        fail "Geometry WKB has an unsupported type"
    pure (little, toEnum (fromIntegral dimensionTag), family)

-- | Read a word in the current geometry's byte order.
getWord :: Bool -> Get Word32
getWord little = if little then getWord32le else getWord32be

-- | Check a count against remaining input before allocating a vector.
getCount :: Int64 -> Bool -> Int64 -> Get Int
getCount total little minimumBytes = do
    count <- getWord little
    consumed <- bytesRead
    when (fromIntegral count > (total - consumed) `div` minimumBytes) $
        fail "Geometry WKB count exceeds the remaining bytes"
    pure (fromIntegral count)

-- | Read a geometry with optional family checking for multi-geometries.
getGeometry :: forall c. (Coordinate c) => Int64 -> Maybe Word32 -> Get (Geometry c)
getGeometry total expectedFamily = do
    (little, dimensions, family) <- getHeader
    case expectedFamily of
        Just expected | family /= expected -> fail "Geometry WKB multi child has the wrong family"
        _ -> pure ()
    if dimensions == coordinateDimensions (Proxy :: Proxy c)
        then getGeometryBody total little family
        else case dimensions of
            DimXY -> emptyBody little family (Proxy :: Proxy XY)
            DimXYZ -> emptyBody little family (Proxy :: Proxy XYZ)
            DimXYM -> emptyBody little family (Proxy :: Proxy XYM)
            DimXYZM -> emptyBody little family (Proxy :: Proxy XYZM)
  where
    emptyBody :: forall a. (Coordinate a) => Bool -> Word32 -> Proxy a -> Get (Geometry c)
    emptyBody little family _ = do
        shape <- getGeometryBody total little family :: Get (Geometry a)
        maybe (fail "Geometry WKB has mixed nonempty coordinate dimensions") pure (convertEmptyGeometry shape)

-- | Read a body after its byte order and family have been checked.
getGeometryBody :: forall c. (Coordinate c) => Int64 -> Bool -> Word32 -> Get (Geometry c)
getGeometryBody total little family = do
    let line = getLineCoordinates total little
    case family of
        1 -> PointGeometry <$> getPoint little
        2 -> LineString <$> line
        3 -> do
            count <- getCount total little 4
            rings <- V.replicateM count line
            either fail pure (validatePolygon rings)
            pure (Polygon rings)
        4 -> MultiPoint <$> getMultiPoints total little
        5 -> do
            count <- getCount total little 9
            MultiLineString
                <$> V.replicateM
                    count
                    ( do
                        child <- getGeometry total (Just 2)
                        case child of
                            LineString points -> pure points
                            _ -> fail "Geometry WKB multi child has the wrong family"
                    )
        6 -> do
            count <- getCount total little 9
            MultiPolygon
                <$> V.replicateM
                    count
                    ( do
                        child <- getGeometry total (Just 3)
                        case child of
                            Polygon rings -> pure rings
                            _ -> fail "Geometry WKB multi child has the wrong family"
                    )
        _ -> do
            count <- getCount total little 9
            GeometryCollection <$> V.replicateM count (getGeometry total Nothing)

-- | The number of ordinates in one coordinate.
dimensionCount :: (Num a) => Dimensions -> a
dimensionCount DimXY = 2
dimensionCount DimXYZM = 4
dimensionCount _ = 3

-- | NaN in both X and Y marks an empty WKB point, including Z and M points.
getPoint :: forall c. (Coordinate c) => Bool -> Get (Point c)
getPoint little = do
    let number = castWord64ToDouble <$> (if little then getWord64le else getWord64be)
    x <- number
    y <- number
    (z, m) <- case coordinateDimensions (Proxy :: Proxy c) of
        DimXY -> pure (0, 0)
        DimXYZ -> do z <- number; pure (z, 0)
        DimXYM -> do m <- number; pure (0, m)
        DimXYZM -> (,) <$> number <*> number
    pure (if isNaN x && isNaN y then EmptyPoint else Point (coordinateFromComponents (x, y, z, m)))

-- | Read a line or ring and retain every ordinate, including NaN and infinity.
getLineCoordinates :: forall c. (Coordinate c) => Int64 -> Bool -> Get (U.Vector c)
getLineCoordinates total little = do
    let stride = 8 * dimensionCount (coordinateDimensions (Proxy :: Proxy c))
    count <- getCount total little (fromIntegral stride)
    when (count == 1) (fail "Geometry line must have zero or at least two coordinates")
    bytes <- getByteString (count * stride)
    pure (U.generate count (\i -> coordinateAt little bytes (i * stride)))

-- | Read point children with independent headers, including untagged empty points.
getMultiPoints :: forall c. (Coordinate c) => Int64 -> Bool -> Get (U.Vector (Point c))
getMultiPoints total little = do
    count <- getCount total little 21
    if count == 0
        then pure U.empty
        else do
            consumed <- bytesRead
            bytes <- lookAhead (getByteString (fromIntegral (total - consumed)))
            (points, size) <- either fail pure (multiPointsAt count bytes)
            skip size
            pure points

-- | Read checked point children of different byte lengths into one unboxed vector.
multiPointsAt :: forall c. (Coordinate c) => Int -> ByteString -> Either String (U.Vector (Point c), Int)
multiPointsAt count bytes = runST $ do
    target <- UM.new count
    let go index offset
            | index == count = do
                points <- U.unsafeFreeze target
                pure (Right (points, offset))
            | BS.length bytes - offset < 5 = pure (Left "Geometry WKB point header exceeds the remaining bytes")
            | otherwise = case BS.index bytes offset of
                0 -> child index offset False
                1 -> child index offset True
                _ -> pure (Left "Geometry WKB has an invalid byte order")
        child index offset little
            | dimensionTag > 3 || family < 1 || family > 7 = pure (Left "Geometry WKB has an unsupported type")
            | family /= 1 = pure (Left "Geometry WKB multi child has the wrong family")
            | stride > BS.length bytes - offset = pure (Left "Geometry WKB point exceeds the remaining bytes")
            | otherwise = case point of
                Left message -> pure (Left message)
                Right value -> UM.write target index value >> go (index + 1) (offset + stride)
          where
            (dimensionTag, family) = word32At little bytes (offset + 1) `quotRem` 1000
            dimensions = toEnum (fromIntegral dimensionTag)
            stride = 5 + 8 * dimensionCount dimensions
            point
                | dimensions == coordinateDimensions (Proxy :: Proxy c) =
                    let coordinate = coordinateAt little bytes (offset + 5)
                        (x, y, _, _) = coordinateComponents coordinate
                     in Right (if isNaN x && isNaN y then EmptyPoint else Point coordinate)
                | isNaN (ordinate 5) && isNaN (ordinate 13) = Right EmptyPoint
                | otherwise = Left "Geometry WKB has mixed nonempty coordinate dimensions"
            ordinate position = castWord64ToDouble (word64At little bytes (offset + position))
    go 0 0

-- | Read a coordinate from a block whose complete byte length was checked.
coordinateAt :: forall c. (Coordinate c) => Bool -> ByteString -> Int -> c
coordinateAt little bytes offset =
    let number i = castWord64ToDouble (word64At little bytes (offset + i))
        x = number 0
        y = number 8
        (z, m) = case coordinateDimensions (Proxy :: Proxy c) of
            DimXY -> (0, 0)
            DimXYZ -> (number 16, 0)
            DimXYM -> (0, number 16)
            DimXYZM -> (number 16, number 24)
     in coordinateFromComponents (x, y, z, m)

-- | Read four checked bytes in either byte order without alignment assumptions.
word32At :: Bool -> ByteString -> Int -> Word32
word32At little bytes offset =
    let byte i = fromIntegral (BS.index bytes (offset + i))
     in if little
            then byte 0 .|. shiftL (byte 1) 8 .|. shiftL (byte 2) 16 .|. shiftL (byte 3) 24
            else shiftL (byte 0) 24 .|. shiftL (byte 1) 16 .|. shiftL (byte 2) 8 .|. byte 3

-- | Read eight checked bytes and preserve the exact IEEE-754 representation.
word64At :: Bool -> ByteString -> Int -> Word64
word64At little bytes offset =
    let byte i = fromIntegral (BS.index bytes (offset + i))
     in if little
            then
                byte 0
                    .|. shiftL (byte 1) 8
                    .|. shiftL (byte 2) 16
                    .|. shiftL (byte 3) 24
                    .|. shiftL (byte 4) 32
                    .|. shiftL (byte 5) 40
                    .|. shiftL (byte 6) 48
                    .|. shiftL (byte 7) 56
            else
                shiftL (byte 0) 56
                    .|. shiftL (byte 1) 48
                    .|. shiftL (byte 2) 40
                    .|. shiftL (byte 3) 32
                    .|. shiftL (byte 4) 24
                    .|. shiftL (byte 5) 16
                    .|. shiftL (byte 6) 8
                    .|. byte 7

-- | Check that a vector length fits the WKB unsigned 32-bit count.
checkedLength :: Int -> Either String ()
checkedLength count = when (toInteger count > toInteger (maxBound :: Word32)) (Left "Geometry count exceeds Word32")

-- | Write one validated geometry with a complete little-endian header.
putGeometry :: forall c. (Coordinate c) => Geometry c -> Builder
putGeometry geometry =
    Builder.word8 1
        <> Builder.word32LE (geometryFamily geometry + 1000 * fromIntegral (fromEnum (coordinateDimensions (Proxy :: Proxy c))))
        <> case geometry of
            PointGeometry point -> putPoint point
            LineString points -> putLine points
            Polygon rings ->
                let normalized = normalizePolygon rings
                 in putLength (V.length normalized) <> V.foldMap putLine normalized
            MultiPoint points -> putLength (U.length points) <> U.foldMap (putGeometry . PointGeometry) points
            MultiLineString lineStrings -> putLength (V.length lineStrings) <> V.foldMap (putGeometry . LineString) lineStrings
            MultiPolygon polygons -> putLength (V.length polygons) <> V.foldMap (putGeometry . Polygon) polygons
            GeometryCollection children -> putLength (V.length children) <> V.foldMap putGeometry children

-- | The ISO WKB family tag for a geometry.
geometryFamily :: Geometry c -> Word32
geometryFamily (PointGeometry _) = 1
geometryFamily (LineString _) = 2
geometryFamily (Polygon _) = 3
geometryFamily (MultiPoint _) = 4
geometryFamily (MultiLineString _) = 5
geometryFamily (MultiPolygon _) = 6
geometryFamily (GeometryCollection _) = 7

-- | Write a length already checked by 'validateGeometry'.
putLength :: Int -> Builder
putLength = Builder.word32LE . fromIntegral

-- | Write an empty point or its stored ordinates.
putPoint :: forall c. (Coordinate c) => Point c -> Builder
putPoint EmptyPoint =
    let nan = Builder.word64LE 0x7ff8000000000000
        extra = case coordinateDimensions (Proxy :: Proxy c) of
            DimXY -> mempty
            DimXYZM -> nan <> nan
            _ -> nan
     in nan <> nan <> extra
putPoint (Point coordinate) = putCoordinate coordinate

-- | Write the exact IEEE-754 bits of each ordinate.
putCoordinate :: forall c. (Coordinate c) => c -> Builder
putCoordinate coordinate =
    let (x, y, z, m) = coordinateComponents coordinate
        number = Builder.word64LE . castDoubleToWord64
        extra = case coordinateDimensions (Proxy :: Proxy c) of
            DimXY -> mempty
            DimXYZ -> number z
            DimXYM -> number m
            DimXYZM -> number z <> number m
     in number x <> number y <> extra

-- | Write a line or ring without a geometry header.
putLine :: (Coordinate c) => U.Vector c -> Builder
putLine points = putLength (U.length points) <> Prim.primUnfoldrFixed coordinatePrim next 0
  where
    next i
        | i >= U.length points = Nothing
        | otherwise = Just (points U.! i, i + 1)

-- | Write a complete coordinate with one buffer-size check.
coordinatePrim :: forall c. (Coordinate c) => Prim.FixedPrim c
coordinatePrim = case coordinateDimensions (Proxy :: Proxy c) of
    DimXY -> (\c -> let (x, y, _, _) = coordinateComponents c in (x, y)) >$< (Prim.doubleLE >*< Prim.doubleLE)
    DimXYZ -> (\c -> let (x, y, z, _) = coordinateComponents c in (x, (y, z))) >$< (Prim.doubleLE >*< Prim.doubleLE >*< Prim.doubleLE)
    DimXYM -> (\c -> let (x, y, _, m) = coordinateComponents c in (x, (y, m))) >$< (Prim.doubleLE >*< Prim.doubleLE >*< Prim.doubleLE)
    DimXYZM -> (\c -> let (x, y, z, m) = coordinateComponents c in ((x, y), (z, m))) >$< ((Prim.doubleLE >*< Prim.doubleLE) >*< (Prim.doubleLE >*< Prim.doubleLE))
