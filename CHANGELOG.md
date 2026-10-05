# 0.1.0.0

Initial release.

- Types for the seven Simple Features geometry families with XY, XYZ, XYM, and
  XYZM coordinates. Each point, line, and polygon ring retains its own layout.
  Collections can contain mixed layouts. Empty points are explicit values.
  Coordinate sequences and multipoints use unboxed vectors. The types have
  `Eq`, `Show`, `Read`, and `NFData` instances.
- Checked ISO WKB decoding and encoding. Decoding accepts both byte orders,
  also mixed within one geometry.
- WKT encoding and decoding for all families and coordinate types, including
  empty geometries. Finite coordinates decode to the same bits. The decoder
  rejects malformed tokens, missing separators, and trailing input.
- The codecs follow GEOS construction rules for line lengths and closed rings.
  They accept non-finite ordinates and mixed-layout WKB children.
  They do not check polygon topology or limit nesting depth.
- Simple Features accessors, envelopes, areas, lengths, perimeters, centroids,
  and convex hulls in the XY plane. Selectors use zero-based indices.
  Hulls retain Z according to the first output vertex and discard M.
- Centroids retain small contributions from distant components. Zero-length
  components do not affect a nonzero-length centroid. Compensated sums retain
  local polygon offsets and point contributions when large moments cancel.
- Pure Haskell boundary, simplicity, validity, representative points, DE-9IM
  relations, spatial predicates, and distance.
  Intersection tests stop at the first contact. Point containment uses direct
  point-location tests.
- Planar intersection, union, difference, symmetric difference, and round
  buffers. Buffer quadrant resolution is configurable.
- Queries for measured locations, with linear M interpolation and OGC example tests.
- Geometry tests from OGC SFA Annex C.3.3 run through both WKT and WKB.
- Overlay construction tracks source ordinates along edges and GEOS ring-clipping
  behavior at shared vertices and collinear boundaries.
- Shapely comparisons cover paired geometries, topology, overlays,
  buffers, and explicit native discrepancies. CI runs the comparison harness.
- `Data.Geometry.Internal` exports the `Coordinate` class methods and the shared
  validation, without a stability guarantee.
