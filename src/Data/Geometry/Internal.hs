{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Geometry types and the coordinate class. The public modules re-export them.
module Data.Geometry.Internal where

import Control.Monad (unless)
import Data.Proxy (Proxy (..))
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

{- | The coordinate types t'XY', t'XYZ', t'XYM', and t'XYZM'. The methods are
internal, so other instances are not supported.
-}
class (Eq c, Show c, Read c, U.Unbox c) => Coordinate c where
    coordinateDimensions :: proxy c -> Dimensions
    coordinateComponents :: c -> (Double, Double, Double, Double)
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
the coordinate type @c@. An empty vector is an empty geometry, such as
@LINESTRING EMPTY@. The constructors do not check ring closure, minimum
lengths, or other topology rules.
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

-- | Check each ordinate present in the coordinate type.
coordinateAll :: forall c. (Coordinate c) => (Double -> Bool) -> c -> Bool
{-# INLINE coordinateAll #-}
coordinateAll predicate coordinate =
    let (x, y, z, m) = coordinateComponents coordinate
        extra = case coordinateDimensions (Proxy :: Proxy c) of
            DimXY -> True
            DimXYZ -> predicate z
            DimXYM -> predicate m
            DimXYZM -> predicate z && predicate m
     in predicate x && predicate y && extra

-- | Reject NaN and infinity outside the empty-point representation.
finite :: Double -> Bool
{-# INLINE finite #-}
finite value = not (isNaN value || isInfinite value)

-- | Check finite coordinates and the output format's vector length bounds.
validateGeometry :: (Coordinate c) => (Int -> Either String ()) -> Geometry c -> Either String ()
validateGeometry checkLength geometry = case geometry of
    PointGeometry EmptyPoint -> pure ()
    PointGeometry (Point coordinate) -> validateCoordinate coordinate
    LineString points -> validateLine points
    Polygon rings -> checkLength (V.length rings) >> V.mapM_ validateLine rings
    MultiPoint points -> do
        checkLength (U.length points)
        U.mapM_ (validateGeometry checkLength . PointGeometry) points
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
    -- Check a line or ring without topology restrictions.
    validateLine points = checkLength (U.length points) >> U.mapM_ validateCoordinate points

-- | Check that one coordinate contains only finite ordinates.
validateCoordinate :: (Coordinate c) => c -> Either String ()
{-# INLINE validateCoordinate #-}
validateCoordinate coordinate = unless (coordinateAll finite coordinate) (Left "Geometry has a non-finite coordinate")

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
