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
  overlays, and round buffers. Overlays use bounded snapping when output
  rounding changes topology; exhausted retries raise `OverlayPrecisionFailure`.
  The retry schedule follows GEOS 3.13.1. Its additional self-union and
  precision-grid attempts are omitted, so results and precision failures can
  differ. See the [overlay precision policy](https://github.com/Tritlo/geometry-simple/blob/main/docs/GEOS-DIFFERENCES.md#overlay-precision).
- Constructed planar results use XY. Polygon exteriors run counterclockwise
  and holes clockwise. Hull vertices use a deterministic XY order.
- Measured-location queries with linear interpolation along segments.
