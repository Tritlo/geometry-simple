{-# LANGUAGE ScopedTypeVariables #-}

{- | Checked ISO WKB decoding and encoding.

Each point, line, ring, and collection member retains its own coordinate
layout. Children can use different byte orders and layouts. The codecs check
line lengths, ring closure, counts, and type codes. They accept non-finite
ordinates and do not validate polygon topology. EWKB and SRIDs are not supported.
-}
module Data.Geometry.WKB (decodeWKB, encodeWKB) where

import Control.Monad (unless, when)
import Data.Binary.Get (Get, bytesRead, getDoublebe, getDoublele, getWord32be, getWord32le, getWord8, runGetOrFail)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as Builder
import Data.ByteString.Builder.Prim ((>$<), (>*<))
import qualified Data.ByteString.Builder.Prim as Prim
import qualified Data.ByteString.Lazy as BL
import Data.Geometry.Internal
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import Data.Word (Word32)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)

{- | Decode one complete ISO WKB geometry. Each child uses its own header.
A point with NaN in both X and Y becomes an empty point with the same layout.
Return 'Left' for malformed WKB, invalid construction, or trailing bytes.
-}
decodeWKB :: ByteString -> Either String Geometry
decodeWKB bytes = runDecoder (getGeometry (fromIntegral (BS.length bytes)) Nothing) bytes

{- | Encode little-endian ISO WKB. Child headers retain their layouts.
Polygon rings use their combined layout, with NaN for absent Z or M ordinates.
Finite ordinates retain their exact bits, including negative zero.
Return 'Left' for invalid construction or a count that exceeds 32 bits.
-}
encodeWKB :: Geometry -> Either String ByteString
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

-- | Read one geometry's byte order, dimensions, and family.
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

-- | Read a geometry and check the child family required by a multi-geometry.
getGeometry :: Int64 -> Maybe Word32 -> Get Geometry
getGeometry total expectedFamily = do
    (little, dimensions, family) <- getHeader
    case expectedFamily of
        Just expected | family /= expected -> fail "Geometry WKB multi child has the wrong family"
        _ -> pure ()
    case family of
        1 -> PointGeometry <$> getPoint little dimensions
        2 -> LineString <$> getCoordinates total little dimensions
        3 -> do
            count <- getCount total little 4
            rings <-
                if count == 0
                    then pure (PolygonRings (emptyCoordinates dimensions) V.empty)
                    else PolygonRings <$> getCoordinates total little dimensions <*> V.replicateM (count - 1) (getCoordinates total little dimensions)
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

-- | Read the ordinates present in a coordinate layout.
getComponents :: Bool -> Dimensions -> Get (Double, Double, Double, Double)
getComponents little dimensions = do
    let number = if little then getDoublele else getDoublebe
    x <- number
    y <- number
    (z, m) <- case dimensions of
        DimXY -> pure (0, 0)
        DimXYZ -> do z <- number; pure (z, 0)
        DimXYM -> do m <- number; pure (0, m)
        DimXYZM -> (,) <$> number <*> number
    pure (x, y, z, m)

-- | Read point ordinates before applying WKB's XY-NaN empty convention.
getPoint :: Bool -> Dimensions -> Get Point
getPoint little dimensions = do
    components@(x, y, _, _) <- getComponents little dimensions
    pure (if isNaN x && isNaN y then EmptyPoint dimensions else pointFromComponents dimensions components)

-- | Select the typed unboxed buffer for one line or ring.
getCoordinates :: Int64 -> Bool -> Dimensions -> Get Coordinates
getCoordinates total little dimensions = case dimensions of
    DimXY -> CoordinatesXY <$> getLineCoordinates total little
    DimXYZ -> CoordinatesXYZ <$> getLineCoordinates total little
    DimXYM -> CoordinatesXYM <$> getLineCoordinates total little
    DimXYZM -> CoordinatesXYZM <$> getLineCoordinates total little

-- | Read a complete coordinate buffer after checking its byte length.
getLineCoordinates :: forall c. (Coordinate c) => Int64 -> Bool -> Get (U.Vector c)
getLineCoordinates total little = do
    let dimensions = coordinateDimensions (Proxy :: Proxy c)
    count <- getCount total little (fromIntegral (8 * dimensionCount dimensions))
    when (count == 1) (fail "Geometry line must have zero or at least two coordinates")
    U.replicateM count (coordinateFromComponents <$> getComponents little dimensions)

-- | Read each point with its own byte order and coordinate layout.
getMultiPoints :: Int64 -> Bool -> Get (U.Vector Point)
getMultiPoints total little = do
    count <- getCount total little 21
    U.replicateM count $ do
        (childLittle, dimensions, family) <- getHeader
        unless (family == 1) (fail "Geometry WKB multi child has the wrong family")
        getPoint childLittle dimensions

-- | Check that a vector length fits the WKB unsigned 32-bit count.
checkedLength :: Int -> Either String ()
checkedLength count = when (toInteger count > toInteger (maxBound :: Word32)) (Left "Geometry count exceeds Word32")

-- | Write a geometry with its own aggregate header and each child's own layout.
putGeometry :: Geometry -> Builder
putGeometry = snd . geometryBuilder

-- | Return the layout with the bytes so parents do not scan descendants again.
geometryBuilder :: Geometry -> (Dimensions, Builder)
geometryBuilder geometry = case geometry of
    PointGeometry point -> tagged (pointDimensions point) (putPoint point)
    LineString points -> tagged (dimensionsOf points) (withCoordinates (putLine (dimensionsOf points)) points)
    Polygon rings@(PolygonRings shell holes) ->
        let dimensions = polygonDimensions rings
         in tagged dimensions $
                if coordinatesEmpty shell
                    then putLength 0
                    else putLength (1 + V.length holes) <> withCoordinates (putLine dimensions) shell <> V.foldMap (withCoordinates (putLine dimensions)) holes
    MultiPoint points -> tagged (geometryDimensions geometry) (putLength (U.length points) <> U.foldMap (putGeometry . PointGeometry) points)
    MultiLineString lines' -> tagged (geometryDimensions geometry) (putLength (V.length lines') <> V.foldMap (putGeometry . LineString) lines')
    MultiPolygon polygons -> tagged (geometryDimensions geometry) (putLength (V.length polygons) <> V.foldMap (putGeometry . Polygon) polygons)
    GeometryCollection children ->
        let parts = V.map geometryBuilder children
            dimensions = V.foldl' (\acc (layout, _) -> unionDimensions acc layout) DimXY parts
         in tagged dimensions (putLength (V.length children) <> V.foldMap snd parts)
  where
    tagged dimensions body = (dimensions, Builder.word8 1 <> Builder.word32LE (geometryFamily geometry + 1000 * fromIntegral (fromEnum dimensions)) <> body)

-- | The ISO WKB family tag for a geometry.
geometryFamily :: Geometry -> Word32
geometryFamily (PointGeometry _) = 1
geometryFamily (LineString _) = 2
geometryFamily (Polygon _) = 3
geometryFamily (MultiPoint _) = 4
geometryFamily (MultiLineString _) = 5
geometryFamily (MultiPolygon _) = 6
geometryFamily (GeometryCollection _) = 7

-- | Write a vector length that validation has checked.
putLength :: Int -> Builder
putLength = Builder.word32LE . fromIntegral

-- | Empty points use canonical quiet NaNs in every declared ordinate.
putPoint :: Point -> Builder
putPoint point = case point of
    EmptyPoint dimensions -> mconcat (replicate (dimensionCount dimensions) (Builder.word64LE 0x7ff8000000000000))
    _ -> fromMaybe mempty (withPoint (putCoordinate (pointDimensions point)) point)

-- | Write exact ordinate bits, padding absent Z or M ordinates with NaN.
putCoordinate :: forall c. (Coordinate c) => Dimensions -> c -> Builder
putCoordinate target coordinate =
    let (x, y, z, m) = coordinateComponents coordinate
        source = coordinateDimensions (Proxy :: Proxy c)
        number = Builder.word64LE . castDoubleToWord64
        nan = castWord64ToDouble 0x7ff8000000000000
        zValue = if source == DimXYZ || source == DimXYZM then z else nan
        mValue = if source == DimXYM || source == DimXYZM then m else nan
        extra = case target of
            DimXY -> mempty
            DimXYZ -> number zValue
            DimXYM -> number mValue
            DimXYZM -> number zValue <> number mValue
     in number x <> number y <> extra

-- | Write a line or ring. Homogeneous buffers use the fixed-width builder.
putLine :: forall c. (Coordinate c) => Dimensions -> U.Vector c -> Builder
putLine dimensions points =
    putLength (U.length points)
        <> if dimensions == coordinateDimensions (Proxy :: Proxy c)
            then Prim.primUnfoldrFixed coordinatePrim next 0
            else U.foldMap (putCoordinate dimensions) points
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
