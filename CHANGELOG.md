# 0.1.0.0

Initial release.

- Seven Simple Features geometry families with XY, XYZ, XYM, and XYZM layouts.
  Points, coordinate sequences, and polygon rings retain their own layouts.
  Coordinates and multipoints use unboxed storage.
- ISO WKB and WKT codecs with construction checks and exact finite-coordinate
  round trips. Mixed WKT collections retain child tags and omit parent tags.
- Coordinate and point accessors, measurements, envelopes, and convex hulls.
  Indices start at zero. Point observers preserve stored ordinates and layouts.
- Pure Haskell topology checks, spatial predicates, DE-9IM relations, distance,
  overlays, and round buffers. Intersection queries stop at the first contact;
  point containment uses direct point-location tests.
- Constructed planar results use XY. Polygon exteriors run counterclockwise
  and holes clockwise. Hull vertices use a deterministic XY order.
- Measured-location queries with linear interpolation along segments.
- Compensated centroid sums retain small contributions during cancellation.
- The published MIT package contains the library and user documentation.
  Development tests, standard fixtures, benchmarks, and comparison tools are
  separate from the release archive.
