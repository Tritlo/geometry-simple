{-# LANGUAGE ScopedTypeVariables #-}

{- | Checked ISO WKB decoding and encoding.

The codecs support the seven simple geometry families and all four coordinate
types. Every child must have the same dimensions as its parent. WKB
children can use different byte orders. EWKB flags and embedded SRIDs are not
supported. Keep coordinate reference system metadata outside the geometry.

The codecs check finite coordinates, lengths, and dimensions.
They do not validate topology.
-}
module Data.Geometry.WKB (
    decodeWKB,
    decodeAnyWKB,
    encodeWKB,
) where

import Control.Monad (unless, when)
import Control.Monad.ST (runST)
import Data.Binary.Get (Get, bytesRead, getByteString, getWord32be, getWord32le, getWord64be, getWord64le, getWord8, lookAhead, runGetOrFail)
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
Reject trailing bytes, invalid counts, mixed dimensions, and non-finite
coordinates. All-NaN point ordinates decode to 'EmptyPoint'.
-}
decodeWKB :: (Coordinate c) => ByteString -> Either String (Geometry c)
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XY) #-}
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XYZ) #-}
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XYM) #-}
{-# SPECIALIZE decodeWKB :: ByteString -> Either String (Geometry XYZM) #-}
decodeWKB bytes = runDecoder (getGeometry (fromIntegral (BS.length bytes)) Nothing) bytes

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
    unless (dimensions == coordinateDimensions (Proxy :: Proxy c)) $
        fail "Geometry WKB has the wrong coordinate dimensions"
    case expectedFamily of
        Just expected | family /= expected -> fail "Geometry WKB multi child has the wrong family"
        _ -> pure ()
    let line = getLineCoordinates total little
    case family of
        1 -> PointGeometry <$> getPoint little
        2 -> LineString <$> line
        3 -> do
            count <- getCount total little 4
            Polygon <$> V.replicateM count line
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

-- | Read a coordinate tuple, allowing all-NaN ordinates for an empty point.
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
    let coordinate = coordinateFromComponents (x, y, z, m)
    if coordinateAll isNaN coordinate
        then pure EmptyPoint
        else
            if coordinateAll finite coordinate
                then pure (Point coordinate)
                else fail "Geometry WKB has a non-finite coordinate"

-- | Read a line or ring. Empty points are not coordinates in a line or ring.
getLineCoordinates :: forall c. (Coordinate c) => Int64 -> Bool -> Get (U.Vector c)
getLineCoordinates total little = do
    let stride = 8 * dimensionCount (coordinateDimensions (Proxy :: Proxy c))
    count <- getCount total little (fromIntegral stride)
    bytes <- getByteString (count * stride)
    either fail pure $ generateChecked count $ \i -> do
        let coordinate = coordinateAt little bytes (i * stride)
        validateCoordinate coordinate
        pure coordinate

-- | Read fixed-size point children directly into an unboxed vector.
getMultiPoints :: forall c. (Coordinate c) => Int64 -> Bool -> Get (U.Vector (Point c))
getMultiPoints total little = do
    let dimensions = coordinateDimensions (Proxy :: Proxy c)
        stride = 5 + 8 * dimensionCount dimensions
        expectedTag = 1 + 1000 * fromIntegral (fromEnum dimensions)
    count <- getCount total little (fromIntegral stride)
    bytes <- getByteString (count * stride)
    either fail pure $ generateChecked count $ \i -> do
        let offset = i * stride
        childLittle <- case BS.index bytes offset of
            0 -> Right False
            1 -> Right True
            _ -> Left "Geometry WKB has an invalid byte order"
        unless (word32At childLittle bytes (offset + 1) == expectedTag) $
            Left "Geometry WKB multi child has the wrong family or dimensions"
        let coordinate = coordinateAt childLittle bytes (offset + 5)
        if coordinateAll isNaN coordinate
            then Right EmptyPoint
            else validateCoordinate coordinate >> Right (Point coordinate)

{- | Fill one unboxed vector without constructing an intermediate list.
Return the shared empty vector for a zero count, so that empty rings do not
allocate buffers.
-}
generateChecked :: (U.Unbox a) => Int -> (Int -> Either String a) -> Either String (U.Vector a)
generateChecked 0 _ = Right U.empty
generateChecked count readItem = runST $ do
    target <- UM.new count
    let go i
            | i == count = Right <$> U.unsafeFreeze target
            | otherwise = case readItem i of
                Left message -> pure (Left message)
                Right value -> UM.write target i value >> go (i + 1)
    go 0

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
            Polygon rings -> putLength (V.length rings) <> V.foldMap putLine rings
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

-- | Write an empty point or its finite coordinates.
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
