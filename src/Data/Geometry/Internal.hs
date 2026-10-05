{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_HADDOCK not-home #-}

{- | Geometry types, coordinate conversion, and shared codec validation.

This module is internal. It does not follow the PVP, and any release can
change it. Import "Data.Geometry" and the codec modules for a stable API.
-}
module Data.Geometry.Internal where

import Control.DeepSeq (NFData (..), rwhnf)
import Control.Monad (unless, when)
import qualified Data.Vector as V
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.Vector.Unboxed as U
import Data.Word (Word8)

-- | A coordinate in the XY plane.
data XY
    = -- | @XY x y@.
      XY !Double !Double
    deriving (Eq, Show, Read)

-- | A coordinate with X, Y, and elevation Z.
data XYZ
    = -- | @XYZ x y z@.
      XYZ !Double !Double !Double
    deriving (Eq, Show, Read)

-- | A coordinate with X, Y, and a measure M.
data XYM
    = -- | @XYM x y m@.
      XYM !Double !Double !Double
    deriving (Eq, Show, Read)

-- | A coordinate with X, Y, elevation Z, and a measure M.
data XYZM
    = -- | @XYZM x y z m@.
      XYZM !Double !Double !Double !Double
    deriving (Eq, Show, Read)

-- | The ordinates stored by a point or coordinate sequence.
data Dimensions
    = -- | X and Y.
      DimXY
    | -- | X, Y, and Z.
      DimXYZ
    | -- | X, Y, and M.
      DimXYM
    | -- | X, Y, Z, and M.
      DimXYZM
    deriving (Eq, Ord, Show, Read, Enum, Bounded)

-- | The dimension of a point set, ordered from empty collections to surfaces.
data TopologicalDimension
    = -- | A collection with no atomic members.
      NoDimension
    | -- | A point or multipoint, including an empty value.
      PointDimension
    | -- | A line or multiline, including an empty value.
      CurveDimension
    | -- | A polygon or multipolygon, including an empty value.
      SurfaceDimension
    deriving (Eq, Ord, Show, Read)

{- | The coordinate types t'XY', t'XYZ', t'XYM', and t'XYZM'. Other instances
are not supported.
-}
class (Eq c, Show c, Read c, NFData c, U.Unbox c) => Coordinate c where
    -- | The ordinates available in this coordinate type.
    coordinateDimensions :: proxy c -> Dimensions

    -- | The X, Y, Z, and M ordinates. An ordinate that the type does not have is zero.
    coordinateComponents :: c -> (Double, Double, Double, Double)

    -- | Construct a coordinate from X, Y, Z, and M. Ignore ordinates absent from the type.
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
    = -- | No coordinate, with an explicit layout for serialization.
      EmptyPoint !Dimensions
    | -- | A point in the XY plane.
      PointXY !XY
    | -- | A point with elevation Z.
      PointXYZ !XYZ
    | -- | A point with measure M.
      PointXYM !XYM
    | -- | A point with elevation Z and measure M.
      PointXYZM !XYZM
    deriving (Eq, Show, Read)

-- | An unboxed coordinate sequence. Empty sequences retain their layout.
data Coordinates
    = -- | An XY sequence, including an empty XY sequence.
      CoordinatesXY !(U.Vector XY)
    | -- | An XYZ sequence, including an empty XYZ sequence.
      CoordinatesXYZ !(U.Vector XYZ)
    | -- | An XYM sequence, including an empty XYM sequence.
      CoordinatesXYM !(U.Vector XYM)
    | -- | An XYZM sequence, including an empty XYZM sequence.
      CoordinatesXYZM !(U.Vector XYZM)
    deriving (Eq, Show, Read)

-- | An exterior ring and its holes. Each ring has its own coordinate layout.
data PolygonRings
    = -- | @PolygonRings shell holes@. Ring orientation does not affect area.
      PolygonRings
        -- | Exterior ring. An empty polygon has an empty exterior.
        !Coordinates
        -- | Interior rings, in stored order.
        !(V.Vector Coordinates)
    deriving (Eq, Show, Read)

{- | The seven Simple Features geometry families. Each point, line, and ring
retains its coordinate layout. Collection members can have different layouts.
The constructors do not check minimum lengths, ring closure, or topology.
-}
data Geometry
    = -- | One point, which may be empty.
      PointGeometry !Point
    | -- | A sequence joined by straight segments.
      LineString !Coordinates
    | -- | An exterior ring and any holes.
      Polygon !PolygonRings
    | -- | Points with independent layouts and empty values.
      MultiPoint !(U.Vector Point)
    | -- | Line strings with independent coordinate layouts.
      MultiLineString !(V.Vector Coordinates)
    | -- | Polygons with independent ring layouts.
      MultiPolygon !(V.Vector PolygonRings)
    | -- | Geometries of any family, including nested collections.
      GeometryCollection !(V.Vector Geometry)
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

-- | Construct a nonempty point. Ignore tuple fields absent from the chosen layout.
{-# INLINE pointFromComponents #-}
pointFromComponents :: Dimensions -> (Double, Double, Double, Double) -> Point
pointFromComponents dimensions values = case dimensions of
    DimXY -> PointXY (coordinateFromComponents values)
    DimXYZ -> PointXYZ (coordinateFromComponents values)
    DimXYM -> PointXYM (coordinateFromComponents values)
    DimXYZM -> PointXYZM (coordinateFromComponents values)

-- | Combine Z and M flags independently.
unionDimensions :: Dimensions -> Dimensions -> Dimensions
unionDimensions DimXY b = b
unionDimensions a DimXY = a
unionDimensions a b
    | a == b = a
    | otherwise = DimXYZM

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

{- | The topological dimension of the geometry family.
Empty values keep their family's dimension. Collections use the greatest
member dimension, or 'NoDimension' when they have no atomic members.
-}
topologicalDimension :: Geometry -> TopologicalDimension
topologicalDimension geometry = case geometry of
    PointGeometry _ -> PointDimension
    MultiPoint _ -> PointDimension
    LineString _ -> CurveDimension
    MultiLineString _ -> CurveDimension
    Polygon _ -> SurfaceDimension
    MultiPolygon _ -> SurfaceDimension
    GeometryCollection children -> V.foldl' (\n child -> max n (topologicalDimension child)) NoDimension children

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

{- | Check line lengths, ring closure, and polygon emptiness.
Apply the supplied count check to each sequence and collection before checking
its contents. WKB uses it to enforce its 32-bit count limit.
-}
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
    validateRing = withCoordinates $ \points -> case U.length points of
        0 -> pure ()
        count | count < 3 -> Left "Geometry ring must have zero or at least three coordinates"
        _ ->
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

-- | Mutable unboxed storage for XY values.
newtype instance U.MVector s XY
    = -- | Wrap the unboxed buffers for X and Y.
      MVXY (U.MVector s (Double, Double))

-- | Immutable unboxed storage for XY values.
newtype instance U.Vector XY
    = -- | Wrap the unboxed buffers for X and Y.
      VXY (U.Vector (Double, Double))

deriving via (U.As XY (Double, Double)) instance M.MVector U.MVector XY
deriving via (U.As XY (Double, Double)) instance G.Vector U.Vector XY
instance U.Unbox XY

instance U.IsoUnbox XYZ (Double, Double, Double) where
    toURepr (XYZ x y z) = (x, y, z)
    {-# INLINE toURepr #-}
    fromURepr (x, y, z) = XYZ x y z
    {-# INLINE fromURepr #-}

-- | Mutable unboxed storage for XYZ values.
newtype instance U.MVector s XYZ
    = -- | Wrap the unboxed buffers for X, Y, and Z.
      MVXYZ (U.MVector s (Double, Double, Double))

-- | Immutable unboxed storage for XYZ values.
newtype instance U.Vector XYZ
    = -- | Wrap the unboxed buffers for X, Y, and Z.
      VXYZ (U.Vector (Double, Double, Double))

deriving via (U.As XYZ (Double, Double, Double)) instance M.MVector U.MVector XYZ
deriving via (U.As XYZ (Double, Double, Double)) instance G.Vector U.Vector XYZ
instance U.Unbox XYZ

instance U.IsoUnbox XYM (Double, Double, Double) where
    toURepr (XYM x y m) = (x, y, m)
    {-# INLINE toURepr #-}
    fromURepr (x, y, m) = XYM x y m
    {-# INLINE fromURepr #-}

-- | Mutable unboxed storage for XYM values.
newtype instance U.MVector s XYM
    = -- | Wrap the unboxed buffers for X, Y, and M.
      MVXYM (U.MVector s (Double, Double, Double))

-- | Immutable unboxed storage for XYM values.
newtype instance U.Vector XYM
    = -- | Wrap the unboxed buffers for X, Y, and M.
      VXYM (U.Vector (Double, Double, Double))

deriving via (U.As XYM (Double, Double, Double)) instance M.MVector U.MVector XYM
deriving via (U.As XYM (Double, Double, Double)) instance G.Vector U.Vector XYM
instance U.Unbox XYM

instance U.IsoUnbox XYZM (Double, Double, Double, Double) where
    toURepr (XYZM x y z m) = (x, y, z, m)
    {-# INLINE toURepr #-}
    fromURepr (x, y, z, m) = XYZM x y z m
    {-# INLINE fromURepr #-}

-- | Mutable unboxed storage for XYZM values.
newtype instance U.MVector s XYZM
    = -- | Wrap the unboxed buffers for X, Y, Z, and M.
      MVXYZM (U.MVector s (Double, Double, Double, Double))

-- | Immutable unboxed storage for XYZM values.
newtype instance U.Vector XYZM
    = -- | Wrap the unboxed buffers for X, Y, Z, and M.
      VXYZM (U.Vector (Double, Double, Double, Double))

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

-- | Mutable unboxed storage for Point values.
newtype instance U.MVector s Point
    = -- | Wrap the unboxed buffers for point tags and X, Y, Z, and M.
      MVPoint (U.MVector s (Word8, Double, Double, Double, Double))

-- | Immutable unboxed storage for Point values.
newtype instance U.Vector Point
    = -- | Wrap the unboxed buffers for point tags and X, Y, Z, and M.
      VPoint (U.Vector (Word8, Double, Double, Double, Double))

deriving via (U.As Point (Word8, Double, Double, Double, Double)) instance M.MVector U.MVector Point
deriving via (U.As Point (Word8, Double, Double, Double, Double)) instance G.Vector U.Vector Point
instance U.Unbox Point
