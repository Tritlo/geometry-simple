# geometry-simple

OGC Simple Features geometry types for Haskell, with checked ISO WKB and WKT
codecs and planar measurements. Coordinates are stored in unboxed vectors. The
package needs no database or native library.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Data.ByteString (ByteString)
import Data.Geometry
import Data.Geometry.WKB
import Data.Geometry.WKT (decodeAnyWKT, decodeWKT, encodeWKT)
import qualified Data.Geometry.SimpleFeatures as SF
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

point = PointGeometry (Point (XY 1 2))
line = LineString (U.fromList [XY 0 0, XY 1 2, XY 3 4])
polygon = Polygon (V.singleton (U.fromList [XY 0 0, XY 1 0, XY 1 1, XY 0 0]))
points = MultiPoint (U.fromList [Point (XY 1 2), EmptyPoint])

encoded = encodeWKB line
-- Decode with known dimensions, or use decodeAnyWKB for runtime dimensions.
decoded = encoded >>= (decodeWKB :: ByteString -> Either String (Geometry XY))
parsed = decodeWKT "POINT Z (1 2 3)" :: Either String (Geometry XYZ)
-- Right "POLYGON ((0.0e0 0.0e0, 1.0e0 0.0e0, 1.0e0 1.0e0, 0.0e0 0.0e0))"
text = encodeWKT polygon
polygonArea = SF.area polygon
lineLength = SF.curveLength line
lineBounds = SF.envelope line
```

## Installation

Add `geometry-simple` to your component's `build-depends`. Geometries contain
vectors, so you also need `vector`:

```cabal
build-depends:
  geometry-simple >=0.1 && <0.2,
  vector >=0.13 && <0.14,
```

The WKB functions use `ByteString` from `bytestring`, and the WKT functions
use `Text` from `text`.

## Representation

`Geometry` has a constructor for each of the seven families: points,
linestrings, polygons, their three multi-geometry forms, and geometry
collections. A point is `Point coordinate` or `EmptyPoint`, and a multipoint
can contain empty members.

The coordinate type is `XY`, `XYZ`, `XYM`, or `XYZM`. All parts of a
`Geometry c`, including nested collections, use the same type `c`, so an empty
geometry still has known dimensions. Use `AnyGeometry` when the dimensions are
known only at runtime.

A polygon is a vector of rings: the exterior ring first, then the holes. An
empty vector is an empty polygon. Coordinate sequences and multipoints are
unboxed vectors, with one numeric buffer per ordinate and a separate presence
buffer for empty multipoint members. Rings, polygons, and collection members
are boxed vectors.

`Data.Geometry.Internal` exports the `Coordinate` class methods and the shared
validation. It does not follow the PVP and can change in any release.

Work with these values through the `vector` API. A slice shares memory with
its source. To release the larger buffer, copy the slice with `U.force`.

Geometries do not store a CRS or SRID. Keep that metadata next to the value.
The derived `Eq` instance compares the stored structure and coordinates. Two
polygons that cover the same area but start at different vertices are not
equal. As for `Double`, `0` and `-0` compare equal.

## Simple Features operations

`Data.Geometry.SimpleFeatures` implements a subset of the
[OGC Simple Feature Access](https://www.ogc.org/standards/sfa/) operations.

| Operations | Functions |
| --- | --- |
| Geometry properties | `geometryType`, `dimension`, `coordinateDimension`, `spatialDimension`, `is3D`, `isMeasured`, `isEmpty` |
| Coordinate ordinates | `x`, `y`, `z`, `m` |
| Collection members | `numGeometries`, `geometryN` |
| Line coordinates | `numPoints`, `pointN`, `startPoint`, `endPoint`, `isClosed` |
| Polygon rings | `exteriorRing`, `numInteriorRings`, `interiorRingN` |
| Planar operations | `envelope`, `area`, `geometryLength`, `curveLength`, `perimeter`, `centroid`, `convexHull` |

Indices start at one. Accessors that return `Maybe` give `Nothing` for an
index out of range or for a geometry family they do not apply to. `isClosed`
gives `False` for families other than lines. Member counts include empty
members, and a geometry that is not a collection counts as one member.
`isEmpty` checks every child. An empty point, line, or polygon keeps its
family's dimension, and a geometry collection with no members has dimension -1.
Coordinate layout queries follow GEOS: atomic empty geometries retain their
layout, but multi-geometries with no members report XY. Collections report the
layout of their atomic members, or XY when they have none. The Haskell
coordinate type remains unchanged.

Measurements and closure tests use only X and Y. Lengths are in coordinate
units and areas in square units. `envelope`, `centroid`, and `convexHull`
return `XY` geometries. The operations are planar, so for longitude and
latitude input, lengths are in degrees.

`area` treats the first ring of each polygon as the exterior and the other
rings as holes. Ring orientation does not matter. `geometryLength` matches
GEOS length: it includes lines and polygon boundaries. `curveLength` measures
only lines, and `perimeter` measures only polygon rings, including holes.
The planar operations assume finite X and Y values and valid polygon topology.
Area and perimeter close open rings supplied through the Haskell constructors.

The measurements use `Double` arithmetic. Polygon cross products use coordinates
relative to a ring vertex. Centroids use compensated sums and keep polygon positions
separate from local moments. This retains small contributions when large moments
cancel. `centroid` multiplies coordinate
differences, so it can overflow when a polygon spans more than about 1e100 units
or a line more than about 1e150 units. It can underflow when a polygon spans
less than about 1e-100 units or a line less than about 1e-150 units. The orientation tests in `convexHull` are exact: they use
`Double` when its error bound decides the sign, and `Rational` otherwise.
Compensated sums do not recover rounding errors in products. Strong
cancellation between weighted products can reduce centroid accuracy even
when all intermediate values are finite.

`centroid` weights polygons by area. If the total area is zero, it weights
segments by length. If all segments have zero length, it averages the points,
and counts each line or ring as one point at its first coordinate, as GEOS
does. Lower-dimensional parts do not affect a higher-dimensional centroid.
Empty input gives `EmptyPoint`. An empty envelope is an empty point. An envelope
with one XY location is a point. Other envelopes are polygons, including
degenerate polygons for horizontal or vertical bounds. Hull polygons are
counterclockwise.

The comparison tests use Shapely 2.1.2 with GEOS 3.13.1. Measurements can differ
in their last floating-point digits. WKT formatting also differs. The current
API uses one-based selectors and returns XY hulls; GEOS uses zero-based
selectors and retains Z in nonempty hulls. Hull vertex order also differs.
Mixed nonempty coordinate layouts cannot be represented by `Geometry c`.

The package does not claim full Simple Features conformance. For validity
checks, spatial predicates such as `intersects` and `contains`, distance,
buffers, and overlay operations, use
[`geos`](https://hackage.haskell.org/package/geos), which binds the native
GEOS library.

## Codecs

- `decodeWKB` decodes WKB into the requested coordinate type, including empty
  values.
- `decodeAnyWKB` keeps the coordinate type from the WKB header.
- `encodeWKB` writes little-endian ISO WKB.
- `encodeWKT` writes WKT with a Z, M, or ZM suffix where needed. Each
  ordinate uses scientific notation with the shortest digits that decode to the
  same `Double`, such as `1.0e0` or `1.2345e-2`. Scientific notation is faster
  to render than fixed notation such as `1.0`.
- `decodeWKT` decodes WKT into the requested coordinate type.
- `decodeAnyWKT` keeps the explicit or inferred coordinate type.

`Data.Geometry.WKB` has the WKB functions and `Data.Geometry.WKT` has the WKT
functions. The WKT decoder accepts lowercase keywords, attached dimension
tags such as `POINTZ`, and both `MULTIPOINT (1 2, 3 4)` and
`MULTIPOINT ((1 2), (3 4))`. Numbers can have a sign, a fraction, and an
exponent. Ordinates must be separated by whitespace, which is space, tab, CR,
or LF. Trailing input is an error.

Untagged WKT infers XY, XYZ, or XYZM from two, three, or four ordinates.
XYM needs an M tag. Nonempty collection members must use the same coordinate
type. Explicitly tagged WKT collections require matching tags or inferred
dimensions on their children, including empty children. GEOS 3.13 can drop tags
from empty collection members when it writes WKT; its reader and this decoder
reject those mixed dimensions. Untagged collections can promote empty children
to the common coordinate type. The WKB decoder accepts empty children with
different dimension tags and retains the parent's coordinate type.
EWKT `SRID=...;` prefixes are not supported.

All codecs return `Either String`. The WKB decoder accepts both byte orders,
also mixed within nested geometries. It rejects trailing bytes, unknown type
codes, and inconsistent nonempty dimensions. It checks every count against
the remaining input before it allocates a vector. EWKB flags and embedded
SRIDs are not supported.

The codecs require each line to be empty or have at least two coordinates.
Each ring must be empty or have at least three coordinates and close in XY.
A polygon with an empty exterior cannot have a nonempty hole. These are
construction checks. They do not detect self-intersections or overlapping holes.
Writers normalize polygons that contain only empty rings to an empty polygon.
Readers retain empty holes, so ring counts can change after encoding.

Finite `Double` values keep their exact bits through WKB and through WKT from
`encodeWKT`, including negative zero and subnormals. The WKT decoder rounds
other numbers to the nearest `Double`. Underflow gives a signed zero and
overflow gives an infinity. The codecs accept NaN and infinite ordinates.
The planar operations require finite X and Y values.
In WKB, NaN in both X and Y denotes an empty point, regardless of Z and M.
Non-finite coordinates do not have the finite-coordinate round-trip guarantee.
Use `EmptyPoint` for an empty point in Haskell.

The codecs have no nesting limit. WKB counts must fit in 32 bits; WKT has no
count limit.

## Development

```sh
cabal build all
cabal test all --test-show-details=direct
```

CI covers GHC 9.6.7, 9.8.4, 9.10.3, 9.12.4, and 9.14.1 on Linux, and GHC 9.14.1
on macOS. See
[CONTRIBUTING.md](https://github.com/Tritlo/geometry-simple/blob/main/CONTRIBUTING.md)
for formatting, Nix, benchmarks, and releases.

## License

MIT. See
[LICENSE](https://github.com/Tritlo/geometry-simple/blob/main/LICENSE).
