{- | Simple Features geometry values with XY, XYZ, XYM, or XYZM coordinates.
Each point and coordinate sequence has its own layout. Collection members
and polygon rings can use different layouts.

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
ISO WKB and WKT. "Data.Geometry.SimpleFeatures" provides accessors,
measurements, spatial predicates, and planar geometry operations.
"Data.Geometry.Internal" exposes the 'Coordinate' methods. That module can
change between releases without following the package versioning policy.
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
    withPoint,
    withCoordinates,
) where

import Data.Geometry.Internal
