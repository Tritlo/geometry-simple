{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
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
import qualified Data.Vector as V
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.Vector.Unboxed as U

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

-- | A point at a coordinate, or the empty point (WKT @POINT EMPTY@).
data Point c = EmptyPoint | Point !c deriving (Eq, Show, Read)

{- | A geometry in one of the seven Simple Features families. All parts use
the coordinate type @c@. Coordinate sequences and multipoints are unboxed
vectors from "Data.Vector.Unboxed". Rings, polygons, and collection members
are boxed vectors from "Data.Vector". An empty vector is an empty geometry,
such as @LINESTRING EMPTY@. The constructors do not check ring closure,
minimum lengths, or other topology rules.
-}
data Geometry c
    = -- | A point, which can be empty.
      PointGeometry !(Point c)
    | -- | A sequence of coordinates.
      LineString !(U.Vector c)
    | -- | Rings: the exterior ring first, then the holes.
      Polygon !(V.Vector (U.Vector c))
    | -- | Points. A member can be 'EmptyPoint'.
      MultiPoint !(U.Vector (Point c))
    | -- | Lines, each a sequence of coordinates.
      MultiLineString !(V.Vector (U.Vector c))
    | -- | Polygons, each a vector of rings.
      MultiPolygon !(V.Vector (V.Vector (U.Vector c)))
    | -- | Geometries of any family, including other collections.
      GeometryCollection !(V.Vector (Geometry c))

deriving instance (Coordinate c) => Eq (Geometry c)
deriving instance (Coordinate c) => Show (Geometry c)
deriving instance (Coordinate c) => Read (Geometry c)

-- | A geometry whose coordinate type is known only at runtime.
data AnyGeometry
    = GeometryXY !(Geometry XY)
    | GeometryXYZ !(Geometry XYZ)
    | GeometryXYM !(Geometry XYM)
    | GeometryXYZM !(Geometry XYZM)
    deriving (Eq, Show, Read)

-- Coordinates have strict fields, so weak head normal form is normal form.
instance NFData XY where rnf = rwhnf
instance NFData XYZ where rnf = rwhnf
instance NFData XYM where rnf = rwhnf
instance NFData XYZM where rnf = rwhnf

instance (NFData c) => NFData (Point c) where
    rnf EmptyPoint = ()
    rnf (Point coordinate) = rnf coordinate

-- Boxed vectors of rings and members can contain unevaluated elements.
instance (Coordinate c) => NFData (Geometry c) where
    rnf geometry = case geometry of
        PointGeometry point -> rnf point
        LineString points -> rnf points
        Polygon rings -> rnf rings
        MultiPoint points -> rnf points
        MultiLineString lineStrings -> rnf lineStrings
        MultiPolygon polygons -> rnf polygons
        GeometryCollection children -> rnf children

instance NFData AnyGeometry where
    rnf geometry = case geometry of
        GeometryXY value -> rnf value
        GeometryXYZ value -> rnf value
        GeometryXYM value -> rnf value
        GeometryXYZM value -> rnf value

-- | Test whether an ordinate is neither NaN nor infinity.
finite :: Double -> Bool
{-# INLINE finite #-}
finite value = not (isNaN value || isInfinite value)

-- | Check the constructor rules that the GEOS readers require.
validateGeometry :: (Coordinate c) => (Int -> Either String ()) -> Geometry c -> Either String ()
validateGeometry checkLength geometry = case geometry of
    PointGeometry _ -> pure ()
    LineString points -> checkLength (U.length points) >> validateLine points
    Polygon rings -> do
        checkLength (V.length rings)
        V.mapM_ (checkLength . U.length) rings
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

-- | A line has zero coordinates or at least two coordinates.
validateLine :: (U.Unbox c) => U.Vector c -> Either String ()
validateLine points = when (U.length points == 1) (Left "Geometry line must have zero or at least two coordinates")

-- | Rings have zero or at least three coordinates and close in X and Y.
validatePolygon :: (Coordinate c) => V.Vector (U.Vector c) -> Either String ()
validatePolygon rings = do
    V.mapM_ validateRing rings
    unless (V.null rings || not (U.null (V.head rings)) || V.all U.null rings) $
        Left "Geometry polygon has an empty shell and nonempty holes"
  where
    validateRing points
        | U.null points = pure ()
        | U.length points < 3 = Left "Geometry ring must have zero or at least three coordinates"
        | otherwise =
            let (x, y, _, _) = coordinateComponents (U.head points)
                (x', y', _, _) = coordinateComponents (U.last points)
             in unless (x == x' && y == y') (Left "Geometry ring is not closed")

-- | GEOS writes polygons with only empty rings as an empty polygon.
normalizePolygon :: (U.Unbox c) => V.Vector (U.Vector c) -> V.Vector (U.Vector c)
normalizePolygon rings = if V.all U.null rings then V.empty else rings

-- | Test whether a geometry has no stored coordinates.
geometryEmpty :: (Coordinate c) => Geometry c -> Bool
geometryEmpty geometry = case geometry of
    PointGeometry EmptyPoint -> True
    PointGeometry (Point _) -> False
    LineString points -> U.null points
    Polygon rings -> V.all U.null rings
    MultiPoint points -> U.all emptyPoint points
    MultiLineString lineStrings -> V.all U.null lineStrings
    MultiPolygon polygons -> V.all (V.all U.null) polygons
    GeometryCollection children -> V.all geometryEmpty children
  where
    emptyPoint EmptyPoint = True
    emptyPoint (Point _) = False

-- | Convert an empty geometry to another coordinate type without losing members.
convertEmptyGeometry :: (Coordinate a, Coordinate b) => Geometry a -> Maybe (Geometry b)
convertEmptyGeometry geometry = case geometry of
    PointGeometry EmptyPoint -> Just (PointGeometry EmptyPoint)
    PointGeometry (Point _) -> Nothing
    LineString points -> if U.null points then Just (LineString U.empty) else Nothing
    Polygon rings -> Polygon <$> traverse emptyLine rings
    MultiPoint points -> MultiPoint . U.fromList <$> traverse emptyPoint (U.toList points)
    MultiLineString lineStrings -> MultiLineString <$> traverse emptyLine lineStrings
    MultiPolygon polygons -> MultiPolygon <$> traverse (traverse emptyLine) polygons
    GeometryCollection children -> GeometryCollection <$> traverse convertEmptyGeometry children
  where
    emptyLine points = if U.null points then Just U.empty else Nothing
    emptyPoint EmptyPoint = Just EmptyPoint
    emptyPoint (Point _) = Nothing

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

-- A flag buffer marks the empty points. Empty points store zero ordinates.
instance (Coordinate c) => U.IsoUnbox (Point c) (Bool, c) where
    toURepr EmptyPoint = (False, coordinateFromComponents (0, 0, 0, 0))
    toURepr (Point coordinate) = (True, coordinate)
    {-# INLINE toURepr #-}
    fromURepr (present, coordinate) = if present then Point coordinate else EmptyPoint
    {-# INLINE fromURepr #-}

newtype instance U.MVector s (Point c) = MVPoint (U.MVector s (Bool, c))
newtype instance U.Vector (Point c) = VPoint (U.Vector (Bool, c))
deriving via (U.As (Point c) (Bool, c)) instance (Coordinate c) => M.MVector U.MVector (Point c)
deriving via (U.As (Point c) (Bool, c)) instance (Coordinate c) => G.Vector U.Vector (Point c)
instance (Coordinate c) => U.Unbox (Point c)
