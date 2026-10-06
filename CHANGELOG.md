# 0.1.1.0

- Accept bare MULTIPOINT coordinates mixed with `EMPTY`, including DuckDB's
  `ST_AsText` output. Previously this syntax failed to parse. Nonempty members
  must still use one spelling throughout. The writer keeps its parenthesized
  form, and layout inference is unchanged.
- Add `validateWKB` to check complete ISO WKB without constructing geometry
  values or coordinate buffers. It checks the same counts, types, line lengths,
  and polygon rules as `decodeWKB`. Previously callers had to decode and discard
  geometry values to perform these checks.
- Correct the DuckDB interoperability notes. DuckDB can store mixed-layout WKB
  with `ST_GeomFromWKB` and return it with `ST_AsWKB`; its WKT reader and writer
  require a common layout.

# 0.1.0.0

Initial release.

- Seven Simple Features geometry families with XY, XYZ, XYM, and XYZM layouts.
  Points, coordinate sequences, and polygon rings retain their own layouts.
  Coordinates and multipoints use unboxed storage.
- ISO WKB and WKT codecs with construction checks and exact finite-coordinate
  round trips.
- Coordinate and point accessors, measurements, envelopes, and convex hulls.
  Indices start at zero. Point observers preserve stored ordinates and layouts.
- Pure Haskell topology checks, spatial predicates, DE-9IM relations, distance,
  overlays, and round buffers. Overlays and buffers return
  `Either TopologyException Geometry`. They use bounded snapping when output
  rounding changes topology; exhausted retries return `Left PrecisionFailure`.
  Unrepresentable buffer offsets return `Left CoordinateOverflow`.
  The retry schedule follows GEOS 3.13.1, without its self-union and
  precision-grid attempts, so results and precision failures can differ. See the [overlay precision policy](https://github.com/Tritlo/geometry-simple/blob/main/docs/GEOS-DIFFERENCES.md#overlay-precision).
- Constructed planar results use XY. Polygon exteriors run counterclockwise
  and holes clockwise. Hull vertices use a deterministic XY order.
- Measured-location queries with linear interpolation along segments.
