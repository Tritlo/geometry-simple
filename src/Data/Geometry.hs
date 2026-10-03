{- | Simple Features geometry values. The coordinate type sets the dimensions.

A @'Geometry' t'XY'@ has two-dimensional coordinates. A @'Geometry' t'XYZM'@ has
coordinates with elevation and a measure. Use 'AnyGeometry' when the
dimensions are known only at runtime.

@
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

square :: Geometry XY
square = Polygon (V.singleton (U.fromList [XY 0 0, XY 1 0, XY 1 1, XY 0 1, XY 0 0]))
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
    Coordinate,
    Point (..),
    Geometry (..),
    AnyGeometry (..),
) where

import Data.Geometry.Internal
