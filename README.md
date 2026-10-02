# geometry-simple

Pure geometry values with unboxed coordinate vectors and checked WKB and WKT
codecs. The package needs no database or native library.

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Data.ByteString (ByteString)
import Data.Geometry
import Data.Geometry.WKB
import Data.Geometry.WKT (decodeWKT, decodeAnyWKT)
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
```

## Use in a Cabal project

Add `geometry-simple` to your component's `build-depends`:

```cabal
build-depends: geometry-simple >=0.1 && <0.2
```

To use a local checkout beside your application, include it in the application's
`cabal.project`:

```cabal
packages: . ../geometry-simple
```

## Representation

The seven geometry families are points, linestrings, polygons, their three
multi-geometry forms, and geometry collections. `PointGeometry` contains either
`Point coordinate` or `EmptyPoint`. `MultiPoint` also supports empty members.
SQL NULL is a database concern and is not an empty geometry.

Use `XY`, `XYZ`, `XYM`, or `XYZM` for the coordinate type. Every member of a
`Geometry coord` uses the same coordinate type, including nested collections.
Empty geometries retain their dimensions through this type. `AnyGeometry`
contains one of the four layouts when the dimensions are known only at runtime.

A polygon contains an outer ring followed by its holes. An empty vector of rings
represents an empty polygon. Coordinates and multipoints use unboxed vectors.
Rings, polygons, and collection members use boxed outer vectors. Unboxed
coordinates use separate numeric buffers for each ordinate. Empty multipoint
members use a separate presence buffer.

Use the standard vector operations for slicing, mapping, folds, and mutable
construction. A slice shares its source allocation. Use `U.force` to copy a
small slice when retaining its larger source buffer is undesirable.

CRS metadata is separate from these geometry values. Changing a CRS label does
not transform coordinates. Derived `Eq` compares the stored structure and
coordinates, not spatial equivalence. Floating-point equality treats positive
and negative zero as equal.

## Codecs

- `decodeWKB` checks the requested coordinate layout, including empty values.
- `decodeAnyWKB` retains the layout found in the WKB header.
- `encodeWKB` writes little-endian ISO WKB.
- `encodeWKT` writes WKT with explicit Z, M, or ZM suffixes where needed.
  Coordinates use scientific notation, such as `1.0e0`. This reduces temporary
  allocation during conversion to text.
- `decodeWKT` reads WKT with the requested coordinate layout.
- `decodeAnyWKT` retains the layout declared in the WKT header.

Import the WKT functions from `Data.Geometry.WKT`. The WKB module also exports
`encodeWKT`. WKT decoding accepts lowercase keywords, attached dimension tags
such as `POINTZ`, and both `MULTIPOINT (1 2, 3 4)` and
`MULTIPOINT ((1 2), (3 4))`. Signed decimal numbers and exponents are supported.
Ordinates require whitespace between them. Trailing input is rejected.

Untagged WKT means XY. Use Z, M, or ZM for other layouts, even for empty shapes.
Each geometry in a collection must declare the same layout. The parser does
not infer dimensions from extra ordinates or from the requested Haskell type.
EWKT `SRID=...;` prefixes are not supported.

All codecs return `Either String`. WKB decoding accepts either byte order,
including different byte orders in nested geometries. It rejects trailing data,
invalid tags, inconsistent dimensions, and counts that exceed the input before
allocating coordinate vectors. EWKB flags and embedded SRIDs are not supported.

Finite `Double` coordinates retain their exact bits through WKB and generated
WKT, including negative zero and subnormal values. WKT numbers round to the
nearest representable `Double`; underflow can produce signed zero and overflow
is rejected. WKB uses all-NaN ordinates for empty points.
Other NaN values and infinities are rejected. Use `EmptyPoint` to construct an
empty point in Haskell.

The codecs accept at most 128 geometry levels, including the root. Polygon
rings do not add a level. Checks cover encoding structure and finite coordinates;
they do not check ring closure, self-intersection, or other topology rules.

## Development

The project uses GHC 9.14.1 by default. To build and test:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock all
```

Use `--with-compiler=ghc-VERSION` to select another compiler. CI covers
GHC 9.6.7, 9.8.4, 9.10.3, 9.12.4, and 9.14.1 on Linux, and GHC 9.14.1 on macOS.
The pinned Nix build uses GHC 9.14.1. Run `nix-build --no-out-link` to build,
test, and generate documentation with Nix.

See [CONTRIBUTIONS.md](CONTRIBUTIONS.md) for test coverage, formatting, and
pull request guidelines.

The benchmark measures codec conversion and vector operations. It takes the
number of XY coordinates as its first argument:

```sh
cabal run geometry-simple-bench -- 1000000 +RTS -T -RTS
```

## Release

Update the version in `geometry-simple.cabal` and the changelog before a release.
Run `scripts/release.sh` to upload a Hackage candidate and its documentation.
Review the candidate before running `scripts/release.sh --publish`.

## License

[MPL-2.0](LICENSE).
