# geometry-simple

OGC Simple Features geometry types for Haskell, with checked ISO WKB and WKT
codecs and pure planar operations. The package stores coordinates in unboxed
vectors and needs no database or native library.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Data.ByteString (ByteString)
import Data.Geometry
import Data.Geometry.WKB
import Data.Geometry.WKT (decodeWKT, encodeWKT)
import qualified Data.Geometry.SimpleFeatures as SF
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U

point = PointGeometry (PointXY (XY 1 2))
line = LineString (CoordinatesXY (U.fromList [XY 0 0, XY 1 2, XY 3 4]))
polygon = Polygon (PolygonRings
    (CoordinatesXY (U.fromList [XY 0 0, XY 1 0, XY 1 1, XY 0 0])) V.empty)
points = MultiPoint (U.fromList [PointXY (XY 1 2), EmptyPoint DimXYZ])

encoded = encodeWKB line
-- Each decoded point and sequence retains its coordinate layout.
decoded = encoded >>= (decodeWKB :: ByteString -> Either String Geometry)
parsed = decodeWKT "POINT Z (1 2 3)" :: Either String Geometry
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
collections. Each `Point` has an XY, XYZ, XYM, or XYZM layout. An empty point
stores its layout explicitly, such as `EmptyPoint DimXYZ`.

`Coordinates` wraps an unboxed vector of `XY`, `XYZ`, `XYM`, or `XYZM` values.
Every sequence has its own layout, including empty sequences. Collection
members can have different layouts. Decoding returns one `Geometry` type,
so callers do not need to know the coordinate layout in advance.

`PolygonRings` stores an exterior ring and a boxed vector of holes. An empty
polygon has an empty exterior ring, which retains its layout. Different rings
can use different layouts. Multipoints use four unboxed ordinate buffers and
a tag buffer for each point's layout and presence. Multilines, multipolygons,
and geometry collections store their members in boxed vectors.

`Data.Geometry.Internal` exports the `Coordinate` class methods and shared
validation. It can change in any release without following the package
versioning policy (PVP).

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
| Topology | `boundary`, `isSimple`, `isRing`, `isValid`, `pointOnSurface` |
| Spatial relations | `relate`, `relatePattern`, `equals`, `disjoint`, `intersects`, `touches`, `crosses`, `within`, `contains`, `overlaps`, `covers`, `coveredBy` |
| Distance and construction | `distance`, `intersection`, `union`, `difference`, `symmetricDifference`, `buffer`, `bufferWithSegments` |
| Measured locations | `locateAlong`, `locateBetween` |

Indices start at zero, as in GEOS. Accessors that return `Maybe` give `Nothing`
for an index out of range or a geometry family they do not apply to. `isClosed`
gives `False` for families other than lines. Member counts include empty
members. A geometry that is not a collection counts as one member.

`isEmpty` checks every child. Empty points, lines, and polygons keep their
family's dimension and coordinate layout. A geometry collection with no
members has dimension -1; collections with no members report XY layout.
`is3D` and `isMeasured` combine the Z and M flags of all members.
`coordinateDimension` reports the largest ordinate count among them. An XYZ
member and an XYM member together give coordinate dimension 3, while both
`is3D` and `isMeasured` are true.

Measurements and closure tests use only X and Y. Lengths are in coordinate
units and areas in square units. Envelopes and nonempty centroids use XY.
Hull vertices can retain Z and always discard M. For longitude and latitude
input, planar lengths are in degrees.

`area` treats the first ring of each polygon as the exterior and the other
rings as holes. Ring orientation does not matter. `geometryLength` matches
GEOS length: it includes lines and polygon boundaries. `curveLength` measures
only lines, and `perimeter` measures only polygon rings, including holes.
The planar operations assume finite X and Y values and valid polygon topology.
Area and perimeter close open rings supplied through the Haskell constructors.

Measurements use `Double` arithmetic. Polygon cross products use coordinates
relative to a ring vertex. Centroids use compensated sums and keep polygon
positions separate from local moments to retain small contributions when
large moments cancel. Multiplying coordinate differences can still overflow:
for `centroid`, this can occur when a polygon spans more than about 1e100 units
or a line more than about 1e150 units. Underflow can occur below about 1e-100
units for polygons or 1e-150 units for lines. Compensated sums cannot recover
rounding errors in products. Strong cancellation between weighted products
can reduce accuracy even when all intermediate values are finite.

The orientation tests in `convexHull` are exact. They use `Double` when its
error bound decides the sign, and `Rational` otherwise.

`centroid` weights polygons by area. If the total area is zero, it weights
segments by length. If all segments have zero length, it averages the points,
and counts each line or ring as one point at its first coordinate, as GEOS
does. Lower-dimensional parts do not affect a higher-dimensional centroid.
An empty centroid retains GEOS's coordinate-count rule: 2 gives XY, 3 gives
XYZ, and 4 gives XYZM, including when the source has M.

An empty envelope is an XY empty point. An envelope with one XY location is
a point. Other envelopes are polygons, including degenerate polygons for
horizontal or vertical bounds. Hull polygons are clockwise and start at the
lowest Y, then X. The first hull vertex determines the output layout: a
non-NaN Z gives XYZ; otherwise the hull uses XY. An empty hull is an XY
geometry collection.

The comparison tests use Shapely 2.1.2 with GEOS 3.13.1. They compare mixed
layouts, empty members, selectors, and hull vertex order directly. Measurements
can differ in their last floating-point digits. WKT numeric formatting also
differs. When duplicate XY hull candidates have different Z values, this
library keeps the first input candidate. GEOS can select a different candidate
when it reduces a large point set.

Binary spatial operations require valid topology and finite XY coordinates.
`isValid` checks topology. `isSimple` checks self-intersections under the
Simple Features rules. Line boundaries use the mod-2 endpoint rule.
`boundary` returns `Nothing` for a geometry collection, as GEOS does.
`equals` compares spatial point sets; the derived `Eq` instance compares storage.
`relate` returns the nine-character DE-9IM matrix. `relatePattern` accepts the
characters `T`, `F`, `*`, `0`, `1`, and `2`; an invalid pattern returns `False`.
`distance` returns NaN when either geometry is empty.

`intersects` and `disjoint` first check envelopes and component points. They
then scan segments in X order and stop at the first contact. Point containment
uses point-location tests. General relation matrices and constructed results
use rational segment intersections to classify points, edges, and faces.
Output coordinates round to `Double`. These operations can check segment
pairs directly and are intended for modest geometries. Use
[`geos`](https://hackage.haskell.org/package/geos) for large indexed workloads.

`buffer` uses round joins and caps, with eight segments per quadrant.
`bufferWithSegments` selects the quadrant resolution. A negative distance
erodes polygons and gives an empty polygon for points and lines. A zero
distance repairs polygon topology. Nonzero buffers discard Z and M.

`locateAlong` and `locateBetween` select positions by M, with linear
interpolation along segments. They return `Nothing` for empty input and an
empty point for no match. Polygon queries select boundary positions.
The OGC specification leaves the surface interpretation to the implementation.

The package targets the Simple Features core on the seven geometry
families. Its scope excludes Triangle, TIN, PolyhedralSurface, MultiSurface,
and spatial-reference metadata, so it does not claim full OGC SFA conformance.
GEOS is a comparison reference. Consistent geometry and codec behavior takes
priority over reproducing every GEOS output convention.

The comparison report lists known GEOS data-loss and relation differences
separately. Overlay noding uses a deterministic order. When coincident input
vertices have conflicting Z/M values, GEOS's unstable node sort can select a
different source value. A fixed test records this difference and requires
complete input Z/M tuples at those vertices. The library does not promise
exact GEOS parity.

The test suite includes the 46 applicable geometry cases from the standard's
SQL conformance examples. Each case runs through WKT and WKB. See
[test/SFA-TESTS.md](test/SFA-TESTS.md) for the scope and source corrections.

## Codecs

- `decodeWKB` decodes WKB and retains each point and sequence's layout.
- `encodeWKB` writes little-endian ISO WKB.
- `encodeWKT` writes WKT with a Z, M, or ZM suffix where needed. Each
  ordinate uses scientific notation with the shortest digits that decode to the
  same `Double`, such as `1.0e0` or `1.2345e-2`. Scientific notation is faster
  to render than fixed notation such as `1.0`.
- `decodeWKT` decodes WKT with explicit or inferred coordinate layouts.

`Data.Geometry.WKB` has the WKB functions and `Data.Geometry.WKT` has the WKT
functions. The WKT decoder accepts lowercase keywords, attached dimension
tags such as `POINTZ`, and both `MULTIPOINT (1 2, 3 4)` and
`MULTIPOINT ((1 2), (3 4))`. Numbers can have a sign, a fraction, and an
exponent. Ordinates must be separated by whitespace, which is space, tab, CR,
or LF. Trailing input is an error.

Untagged WKT infers XY, XYZ, or XYZM from two, three, or four ordinates.
XYM needs an M tag. Untagged geometry collections infer each child's layout
independently. In untagged multi-geometries, an empty member before the first
coordinate has XY layout. Later empty members use the inferred layout.
Explicitly tagged WKT collections require matching tags or inferred dimensions
on their children, including empty children.

WKB collection members retain their own dimension tags. Collection metadata
comes from the members. Writers pad missing Z and M ordinates with NaN when
the format requires one layout, such as polygon rings in WKB and multi-geometry
bodies in WKT. These conversions can change layouts when the output is read.
WKT geometry collections omit the parent dimension tag and retain each child's
own tag. This preserves mixed member layouts when the output is decoded.
GEOS can write a conflicting parent tag that causes its own reader to reject
the collection. This library writes readable collections instead.
EWKT `SRID=...;` prefixes are not supported.

All codecs return `Either String`. The WKB decoder accepts both byte orders,
also mixed within nested geometries. It rejects trailing bytes, unknown type
codes, and incorrect child families. It checks every count against
the remaining input before it allocates a vector. EWKB flags and embedded
SRIDs are not supported.

The codecs require each line to be empty or have at least two coordinates.
Each ring must be empty or have at least three coordinates and close in XY.
A polygon with an empty exterior cannot have a nonempty hole. These are
construction checks. They do not detect self-intersections or overlapping holes.
Writers normalize polygons that contain only empty rings to an empty polygon.
Readers retain empty holes, so ring counts can change after encoding.

Finite `Double` ordinates keep their exact bits through WKB. WKT numbers from
`encodeWKT` also retain their bits when decoded, including negative zero and
subnormals. This does not promise a structural round trip for layouts that a
writer must convert. The WKT decoder rounds other numbers to the nearest
`Double`. Underflow gives a signed zero and overflow gives an infinity.
The codecs accept NaN and infinite ordinates.
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
