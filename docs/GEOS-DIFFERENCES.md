# Simple Features and GEOS

The target is the planar Simple Features core for seven geometry families.
GEOS is an independent comparison reference. It does not define every Haskell
API or output convention in this package.

## Deliberate differences

| Behavior | geometry-simple | GEOS 3.13.1 |
| --- | --- | --- |
| Constructed planar coordinates | Hulls, centroids, representative points, overlays, and buffers use XY, including empty results. | Some operations retain, interpolate, or discard Z/M according to operation-specific rules. |
| Polygon construction | Exterior rings run counterclockwise; holes run clockwise. | Hulls and many constructed polygon exteriors run clockwise. |
| Hull ordering | The first vertex and line endpoints follow lexicographic XY order. | Polygon starts use Y then X; two-point hulls can retain input order. |
| Point observers | Preserve the stored layout and every ordinate, including NaN Z/M. | Extracted points can lose dimensions whose ordinate is NaN. |
| Mixed WKT collections | Each child carries its own dimension tag; the parent has none. | A parent tag can conflict with a child and make the writer's output unreadable. |
| WKT numbers | Shortest scientific notation that decodes to the same `Double`. | Decimal formatting differs. |
| Numerical reductions | Compensated centroid sums retain small contributions during cancellation. | Evaluation order and final floating-point digits can differ. |

OGC 06-103r4 section 6.1.2.5 distinguishes observers, which retain stored Z/M,
from map operations, which ignore them when computing new geometry.
Section 6.1.11.1 describes exterior rings as counterclockwise when viewed from
the top, with opposite winding for holes. We use that convention in the XY
plane. Lexicographic start vertices are our deterministic convention; the
standard does not prescribe them.

The SQL test annex also permits either polygon winding when checking its
expected answers. A different winding alone does not establish a topology bug.

Sources: [OGC common architecture](https://docs.ogc.org/is/06-103r4/06-103r4.pdf),
[OGC SQL test examples](https://docs.ogc.org/is/06-104r4/06-104r4.pdf).

## Geometry contracts

- Point, line, and polygon empties retain their family's topological dimension.
  A collection with no atomic members has dimension -1.
- Coordinate dimensions combine stored member metadata. XYZ and XYM members
  together have coordinate dimension 3, while both Z and M flags are present.
- Polygon area subtracts holes regardless of input winding. Area and perimeter
  close rings supplied directly through Haskell constructors.
- `geometryLength` includes lines and polygon boundaries. `curveLength` counts
  only lines; `perimeter` counts only polygon rings.
- A centroid weights polygons by area, then falls back to segment lengths, then
  points. Each collapsed line or ring contributes its first coordinate once.
  Lower-dimensional components do not affect a higher-dimensional centroid.
- Envelopes use the bounding rectangle specified in section 6.1.2.2. Empty
  input gives an empty point; one XY location gives a point. Flat bounds retain
  repeated rectangle corners and can form a topologically invalid polygon.
- Line boundaries use the mod-2 endpoint rule. `boundary` returns `Nothing` for
  a geometry collection. Stored polygon rings retain their coordinate layouts.
- `relate` returns a nine-character DE-9IM matrix. `relatePattern` accepts
  `T`, `F`, `*`, `0`, `1`, and `2`; invalid patterns return `False`.
  Distance to an empty geometry is NaN.
- Buffers have round caps and joins, with eight segments per quadrant by
  default. Negative distances erode polygons and empty points and lines.
  Zero distance repairs polygon topology. Circular arcs are approximations.
- Measured queries select points and curve portions using M. Polygon queries
  select their boundary positions, as permitted by the implementation-defined
  surface rule. Empty input gives `Nothing`; no match gives an empty point.

## Numerical limits

Planar operations require finite XY coordinates. Measurements use `Double`.
Polygon cross products use coordinates relative to a ring vertex. Centroid
sums keep polygon positions separate from local moments and compensate for
rounding during addition. Products can still overflow or lose precision.

Centroids can overflow for polygon spans above about 1e100 units or line spans
above about 1e150 units. Underflow can occur below about 1e-100 and 1e-150,
respectively. Compensation cannot recover rounding already lost in products.

Hull orientation tests use a bounded `Double` calculation with an exact
`Rational` fallback. Topology uses exact rational intersections and rounds
constructed output coordinates to `Double`. Exact bounding-box indexes prune
segment pairs, validity checks, point locations, and distance candidates.
Repeated winding queries use aggregated crossing counts. Dense arrangements
can still take quadratic time. Predicates can reject incompatible dimensions
or bounds before constructing a full relation matrix.

## Format rules

Untagged WKT infers XY, XYZ, or XYZM from two, three, or four ordinates. XYM
requires M. Untagged collection children infer their layouts independently.
In multi-geometries, empties before the first coordinate remain XY; later
empties use the inferred layout. Explicit parent tags require matching child
layouts. Writers tag collections when all members share one output layout,
including nested collections. Containers with no members have implicit XY.

Mixed-layout collection WKT omits the parent tag and retains each child's tag.
This extends the OGC grammar in section 7. GEOS accepts this form, but DuckDB
requires one layout across all members for both WKT and WKB. Use a common
layout for DuckDB interchange.

The WKT decoder accepts attached tags such as `POINTZ`, both multipoint
syntaxes, signed numbers, fractions, and exponents. Whitespace between ordinates
is required: space, tab, CR, or LF. Other decimal inputs round to the nearest
`Double`. Underflow produces signed zero; overflow produces infinity.

Both codecs accept nonfinite ordinates for storage. NaN in both WKB point XY
ordinates denotes an empty point. Nonfinite values do not have the finite-bit
round-trip guarantee. Use `EmptyPoint` for an empty point in Haskell.

Lines must have zero or at least two coordinates. Rings must have zero or at
least three coordinates and close in XY. An empty exterior cannot contain a
nonempty hole. Writers normalize polygons with only empty rings to an empty
polygon, so empty-hole counts can change after writing. These construction
checks do not establish valid topology.

WKB rejects unknown type tags, incorrect child families, and counts exceeding
the remaining input before allocation. Counts must fit in 32 bits. The codecs
have no nesting limit, and WKT has no count limit. EWKB, EWKT, and embedded SRIDs
are outside the package's scope.
