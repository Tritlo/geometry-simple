{- | Pure geometry values with explicit coordinate dimensions.

A geometry does not contain coordinate reference system metadata. Keep that
metadata beside the value when a transport or database provides it.
Use "Data.Geometry.WKB" to read ISO WKB or to write ISO WKB and WKT.
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
