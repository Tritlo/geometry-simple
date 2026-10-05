{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_HADDOCK not-home #-}

{- | The geometry types, the 'Coordinate' methods, and the validation that the
codecs share.

This module is internal. It does not follow the PVP, and any release can
change it. Import "Data.Geometry" and the codec modules for a stable API.
-}
module Data.Geometry.Internal where

import Control.DeepSeq (NFData (..), rwhnf)
import Control.Monad (unless, when)
import Data.Bits ((.|.))
import qualified Data.Vector as V
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.Vector.Unboxed as U
import Data.Word (Word8)

-- | A coordinate with X and Y.
data XY = XY !Double !Double deriving (Eq, Show, Read)

-- | A coordinate with X, Y, and elevation Z.
data XYZ = XYZ !Double !Double !Double deriving (Eq, Show, Read)

-- | A coordinate with X, Y, and a measure M.
data XYM = XYM !Double !Double !Double deriving (Eq, Show, Read)

-- | A coordinate with X, Y, elevation Z, and a measure M.
data XYZM = XYZM !Double !Double !Double !Double deriving (Eq, Show, Read)

-- | The coordinate dimensions stored by a geometry.
data Dimensions = DimXY | DimXYZ | DimXYM | DimXYZM
    deriving (Eq, Ord, Show, Read, Enum, Bounded)

{- | The coordinate types t'XY', t'XYZ', t'XYM', and t'XYZM'. Other instances
are not supported.
-}
class (Eq c, Show c, Read c, NFData c, U.Unbox c) => Coordinate c where
    -- | The dimensions of the coordinate type.
    coordinateDimensions :: proxy c -> Dimensions

    -- | The X, Y, Z, and M ordinates. An ordinate that the type does not have is zero.
    coordinateComponents :: c -> (Double, Double, Double, Double)

    -- | Make a coordinate from X, Y, Z, and M. The type ignores ordinates that it does not have.
    coordinateFromComponents :: (Double, Double, Double, Double) -> c

instance Coordinate XY where
    coordinateDimensions _ = DimXY
    coordinateComponents (XY x y) = (x, y, 0, 0)
    coordinateFromComponents (x, y, _, _) = XY x y

instance Coordinate XYZ where
    coordinateDimensions _ = DimXYZ
    coordinateComponents (XYZ x y z) = (x, y, z, 0)
    coordinateFromComponents (x, y, z, _) = XYZ x y z

instance Coordinate XYM where
    coordinateDimensions _ = DimXYM
    coordinateComponents (XYM x y m) = (x, y, 0, m)
    coordinateFromComponents (x, y, _, m) = XYM x y m

instance Coordinate XYZM where
    coordinateDimensions _ = DimXYZM
    coordinateComponents (XYZM x y z m) = (x, y, z, m)
    coordinateFromComponents (x, y, z, m) = XYZM x y z m

-- | A point with its own coordinate layout. Empty points retain their layout.
data Point
    = EmptyPoint !Dimensions
    | PointXY !XY
    | PointXYZ !XYZ
    | PointXYM !XYM
    | PointXYZM !XYZM
    deriving (Eq, Show, Read)

-- | An unboxed coordinate sequence. Empty sequences retain their layout.
data Coordinates
    = CoordinatesXY !(U.Vector XY)
    | CoordinatesXYZ !(U.Vector XYZ)
    | CoordinatesXYM !(U.Vector XYM)
    | CoordinatesXYZM !(U.Vector XYZM)
    deriving (Eq, Show, Read)

-- | An exterior ring and its holes. Each ring has its own coordinate layout.
data PolygonRings = PolygonRings !Coordinates !(V.Vector Coordinates)
    deriving (Eq, Show, Read)

{- | The seven Simple Features geometry families. Each point, line, and ring
retains its coordinate layout. Collection members can have different layouts.
The constructors do not check minimum lengths, ring closure, or topology.
-}
data Geometry
    = PointGeometry !Point
    | LineString !Coordinates
    | Polygon !PolygonRings
    | MultiPoint !(U.Vector Point)
    | MultiLineString !(V.Vector Coordinates)
    | MultiPolygon !(V.Vector PolygonRings)
    | GeometryCollection !(V.Vector Geometry)
    deriving (Eq, Show, Read)

-- Coordinates have strict fields, so weak head normal form is normal form.
instance NFData XY where rnf = rwhnf
instance NFData XYZ where rnf = rwhnf
instance NFData XYM where rnf = rwhnf
instance NFData XYZM where rnf = rwhnf

instance NFData Dimensions where rnf = rwhnf
instance NFData Point where
    rnf (EmptyPoint dimensions) = rnf dimensions
    rnf (PointXY value) = rnf value
    rnf (PointXYZ value) = rnf value
    rnf (PointXYM value) = rnf value
    rnf (PointXYZM value) = rnf value

instance NFData Coordinates where
    rnf = withCoordinates rnf

instance NFData PolygonRings where
    rnf (PolygonRings shell holes) = rnf shell `seq` rnf holes

-- Boxed vectors of rings and members can contain unevaluated elements.
instance NFData Geometry where
    rnf geometry = case geometry of
        PointGeometry point -> rnf point
        LineString points -> rnf points
        Polygon rings -> rnf rings
        MultiPoint points -> rnf points
        MultiLineString lineStrings -> rnf lineStrings
        MultiPolygon polygons -> rnf polygons
        GeometryCollection children -> rnf children

-- | Apply an operation to the typed buffer of a coordinate sequence.
withCoordinates :: (forall c. (Coordinate c) => U.Vector c -> a) -> Coordinates -> a
withCoordinates f coordinates = case coordinates of
    CoordinatesXY values -> f values
    CoordinatesXYZ values -> f values
    CoordinatesXYM values -> f values
    CoordinatesXYZM values -> f values

-- | Apply an operation to a nonempty point's coordinate.
withPoint :: (forall c. (Coordinate c) => c -> a) -> Point -> Maybe a
withPoint f point = case point of
    EmptyPoint _ -> Nothing
    PointXY value -> Just (f value)
    PointXYZ value -> Just (f value)
    PointXYM value -> Just (f value)
    PointXYZM value -> Just (f value)

-- | The layout stored by a coordinate sequence.
dimensionsOf :: Coordinates -> Dimensions
dimensionsOf (CoordinatesXY _) = DimXY
dimensionsOf (CoordinatesXYZ _) = DimXYZ
dimensionsOf (CoordinatesXYM _) = DimXYM
dimensionsOf (CoordinatesXYZM _) = DimXYZM

-- | The layout stored by a point, including an empty point.
pointDimensions :: Point -> Dimensions
pointDimensions (EmptyPoint dimensions) = dimensions
pointDimensions (PointXY _) = DimXY
pointDimensions (PointXYZ _) = DimXYZ
pointDimensions (PointXYM _) = DimXYM
pointDimensions (PointXYZM _) = DimXYZM

-- | Construct a nonempty point. Missing ordinates are ignored by its layout.
{-# INLINE pointFromComponents #-}
pointFromComponents :: Dimensions -> (Double, Double, Double, Double) -> Point
pointFromComponents dimensions values = case dimensions of
    DimXY -> PointXY (coordinateFromComponents values)
    DimXYZ -> PointXYZ (coordinateFromComponents values)
    DimXYM -> PointXYM (coordinateFromComponents values)
    DimXYZM -> PointXYZM (coordinateFromComponents values)

-- | Combine Z and M flags independently.
unionDimensions :: Dimensions -> Dimensions -> Dimensions
unionDimensions a b = toEnum (fromEnum a .|. fromEnum b)

-- | The number of ordinates stored by a layout.
dimensionCount :: Dimensions -> Int
dimensionCount DimXY = 2
dimensionCount DimXYZM = 4
dimensionCount _ = 3

-- | The union of the layouts stored by all polygon rings.
polygonDimensions :: PolygonRings -> Dimensions
polygonDimensions (PolygonRings shell holes) = V.foldl' (\acc ring -> unionDimensions acc (dimensionsOf ring)) (dimensionsOf shell) holes

-- | The union of all stored Z and M flags. Empty collections report XY.
geometryDimensions :: Geometry -> Dimensions
geometryDimensions geometry = case geometry of
    PointGeometry point -> pointDimensions point
    LineString points -> dimensionsOf points
    Polygon rings -> polygonDimensions rings
    MultiPoint points -> U.foldl' (\acc point -> unionDimensions acc (pointDimensions point)) DimXY points
    MultiLineString lineStrings -> V.foldl' (\acc points -> unionDimensions acc (dimensionsOf points)) DimXY lineStrings
    MultiPolygon polygons -> V.foldl' (\acc rings -> unionDimensions acc (polygonDimensions rings)) DimXY polygons
    GeometryCollection children -> V.foldl' (\acc child -> unionDimensions acc (geometryDimensions child)) DimXY children

-- | The greatest coordinate count among members. XYZ and XYM together give 3.
geometryCoordinateDimension :: Geometry -> Int
geometryCoordinateDimension geometry = case geometry of
    PointGeometry point -> dimensionCount (pointDimensions point)
    LineString points -> dimensionCount (dimensionsOf points)
    Polygon (PolygonRings shell holes) -> V.foldl' (\acc ring -> max acc (dimensionCount (dimensionsOf ring))) (dimensionCount (dimensionsOf shell)) holes
    MultiPoint points -> U.foldl' (\acc point -> max acc (dimensionCount (pointDimensions point))) 2 points
    MultiLineString lineStrings -> V.foldl' (\acc points -> max acc (dimensionCount (dimensionsOf points))) 2 lineStrings
    MultiPolygon polygons -> V.foldl' (\acc rings -> max acc (geometryCoordinateDimension (Polygon rings))) 2 polygons
    GeometryCollection children -> V.foldl' (\acc child -> max acc (geometryCoordinateDimension child)) 2 children

-- | Construct an empty sequence with the given layout.
emptyCoordinates :: Dimensions -> Coordinates
emptyCoordinates DimXY = CoordinatesXY U.empty
emptyCoordinates DimXYZ = CoordinatesXYZ U.empty
emptyCoordinates DimXYM = CoordinatesXYM U.empty
emptyCoordinates DimXYZM = CoordinatesXYZM U.empty

-- | Whether a sequence contains no coordinates.
coordinatesEmpty :: Coordinates -> Bool
coordinatesEmpty = withCoordinates U.null

-- | Test whether an ordinate is neither NaN nor infinity.
finite :: Double -> Bool
{-# INLINE finite #-}
finite value = not (isNaN value || isInfinite value)

-- | Check the constructor rules that the GEOS readers require.
validateGeometry :: (Int -> Either String ()) -> Geometry -> Either String ()
validateGeometry checkLength geometry = case geometry of
    PointGeometry _ -> pure ()
    LineString points -> checkLineLength points >> validateLine points
    Polygon rings@(PolygonRings shell holes) -> do
        checkLength (1 + V.length holes)
        checkLineLength shell
        V.mapM_ checkLineLength holes
        validatePolygon rings
    MultiPoint points -> checkLength (U.length points)
    MultiLineString lineStrings -> do
        checkLength (V.length lineStrings)
        V.mapM_ (validateGeometry checkLength . LineString) lineStrings
    MultiPolygon polygons -> do
        checkLength (V.length polygons)
        V.mapM_ (validateGeometry checkLength . Polygon) polygons
    GeometryCollection children -> do
        checkLength (V.length children)
        V.mapM_ (validateGeometry checkLength) children
  where
    checkLineLength = checkLength . withCoordinates U.length

-- | A line has zero coordinates or at least two coordinates.
validateLine :: Coordinates -> Either String ()
validateLine points = when (withCoordinates U.length points == 1) (Left "Geometry line must have zero or at least two coordinates")

-- | Rings have zero or at least three coordinates and close in X and Y.
validatePolygon :: PolygonRings -> Either String ()
validatePolygon (PolygonRings shell holes) = do
    validateRing shell
    V.mapM_ validateRing holes
    unless (not (coordinatesEmpty shell) || V.all coordinatesEmpty holes) $
        Left "Geometry polygon has an empty shell and nonempty holes"
  where
    validateRing = withCoordinates $ \points ->
        if U.null points
            then pure ()
            else
                if U.length points < 3
                    then Left "Geometry ring must have zero or at least three coordinates"
                    else
                        let (x, y, _, _) = coordinateComponents (U.head points)
                            (x', y', _, _) = coordinateComponents (U.last points)
                         in unless (x == x' && y == y') (Left "Geometry ring is not closed")

-- | Test whether a geometry has no stored coordinates.
geometryEmpty :: Geometry -> Bool
geometryEmpty geometry = case geometry of
    PointGeometry point -> emptyPoint point
    LineString points -> coordinatesEmpty points
    Polygon (PolygonRings shell holes) -> coordinatesEmpty shell && V.all coordinatesEmpty holes
    MultiPoint points -> U.all emptyPoint points
    MultiLineString lineStrings -> V.all coordinatesEmpty lineStrings
    MultiPolygon polygons -> V.all (geometryEmpty . Polygon) polygons
    GeometryCollection children -> V.all geometryEmpty children
  where
    emptyPoint (EmptyPoint _) = True
    emptyPoint _ = False

-- Unboxed vectors store coordinates as tuples, so each ordinate has its own buffer.

instance U.IsoUnbox XY (Double, Double) where
    toURepr (XY x y) = (x, y)
    {-# INLINE toURepr #-}
    fromURepr (x, y) = XY x y
    {-# INLINE fromURepr #-}

newtype instance U.MVector s XY = MVXY (U.MVector s (Double, Double))
newtype instance U.Vector XY = VXY (U.Vector (Double, Double))
deriving via (U.As XY (Double, Double)) instance M.MVector U.MVector XY
deriving via (U.As XY (Double, Double)) instance G.Vector U.Vector XY
instance U.Unbox XY

instance U.IsoUnbox XYZ (Double, Double, Double) where
    toURepr (XYZ x y z) = (x, y, z)
    {-# INLINE toURepr #-}
    fromURepr (x, y, z) = XYZ x y z
    {-# INLINE fromURepr #-}

newtype instance U.MVector s XYZ = MVXYZ (U.MVector s (Double, Double, Double))
newtype instance U.Vector XYZ = VXYZ (U.Vector (Double, Double, Double))
deriving via (U.As XYZ (Double, Double, Double)) instance M.MVector U.MVector XYZ
deriving via (U.As XYZ (Double, Double, Double)) instance G.Vector U.Vector XYZ
instance U.Unbox XYZ

instance U.IsoUnbox XYM (Double, Double, Double) where
    toURepr (XYM x y m) = (x, y, m)
    {-# INLINE toURepr #-}
    fromURepr (x, y, m) = XYM x y m
    {-# INLINE fromURepr #-}

newtype instance U.MVector s XYM = MVXYM (U.MVector s (Double, Double, Double))
newtype instance U.Vector XYM = VXYM (U.Vector (Double, Double, Double))
deriving via (U.As XYM (Double, Double, Double)) instance M.MVector U.MVector XYM
deriving via (U.As XYM (Double, Double, Double)) instance G.Vector U.Vector XYM
instance U.Unbox XYM

instance U.IsoUnbox XYZM (Double, Double, Double, Double) where
    toURepr (XYZM x y z m) = (x, y, z, m)
    {-# INLINE toURepr #-}
    fromURepr (x, y, z, m) = XYZM x y z m
    {-# INLINE fromURepr #-}

newtype instance U.MVector s XYZM = MVXYZM (U.MVector s (Double, Double, Double, Double))
newtype instance U.Vector XYZM = VXYZM (U.Vector (Double, Double, Double, Double))
deriving via (U.As XYZM (Double, Double, Double, Double)) instance M.MVector U.MVector XYZM
deriving via (U.As XYZM (Double, Double, Double, Double)) instance G.Vector U.Vector XYZM
instance U.Unbox XYZM

-- One tag buffer stores the layout and presence. Unused ordinates are zero.
instance U.IsoUnbox Point (Word8, Double, Double, Double, Double) where
    toURepr (EmptyPoint dimensions) = (fromIntegral (fromEnum dimensions), 0, 0, 0, 0)
    toURepr (PointXY (XY x y)) = (4, x, y, 0, 0)
    toURepr (PointXYZ (XYZ x y z)) = (5, x, y, z, 0)
    toURepr (PointXYM (XYM x y m)) = (6, x, y, 0, m)
    toURepr (PointXYZM (XYZM x y z m)) = (7, x, y, z, m)
    {-# INLINE toURepr #-}
    fromURepr (tag, x, y, z, m) = case tag of
        0 -> EmptyPoint DimXY
        1 -> EmptyPoint DimXYZ
        2 -> EmptyPoint DimXYM
        3 -> EmptyPoint DimXYZM
        4 -> PointXY (XY x y)
        5 -> PointXYZ (XYZ x y z)
        6 -> PointXYM (XYM x y m)
        _ -> PointXYZM (XYZM x y z m)
    {-# INLINE fromURepr #-}

newtype instance U.MVector s Point = MVPoint (U.MVector s (Word8, Double, Double, Double, Double))
newtype instance U.Vector Point = VPoint (U.Vector (Word8, Double, Double, Double, Double))
deriving via (U.As Point (Word8, Double, Double, Double, Double)) instance M.MVector U.MVector Point
deriving via (U.As Point (Word8, Double, Double, Double, Double)) instance G.Vector U.Vector Point
instance U.Unbox Point
