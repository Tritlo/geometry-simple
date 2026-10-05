{- | Simple Features geometry values. Each point and coordinate sequence has
its own layout. Collections and polygon rings can contain different layouts.

@
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

square :: Geometry
square = Polygon (PolygonRings
    (CoordinatesXY (U.fromList [XY 0 0, XY 1 0, XY 1 1, XY 0 1, XY 0 0]))
    V.empty)
@

A geometry does not store a coordinate reference system. Keep the CRS or SRID
next to the value.

"Data.Geometry.WKB" and "Data.Geometry.WKT" convert geometries to and from
ISO WKB and WKT. "Data.Geometry.SimpleFeatures" has accessors and planar
measurements. "Data.Geometry.Internal" has the 'Coordinate' methods, without a
stability guarantee.
-}
module Data.Geometry (
    XY (..),
    XYZ (..),
    XYM (..),
    XYZM (..),
    Dimensions (..),
    Coordinate,
    Point (..),
    Coordinates (..),
    PolygonRings (..),
    Geometry (..),
) where

import Data.Geometry.Internal
