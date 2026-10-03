# 0.1.0.0

Initial release.

- Types for the seven Simple Features geometry families with XY, XYZ, XYM, and
  XYZM coordinates. Empty points are explicit values. Coordinate sequences and
  multipoints use unboxed vectors. The types have `Eq`, `Show`, `Read`, and
  `NFData` instances.
- Checked ISO WKB decoding and encoding. Decoding accepts both byte orders,
  also mixed within one geometry.
- WKT encoding and decoding for all families and coordinate types, including
  empty geometries. Encoded values decode to the same bits. The decoder rejects
  malformed tokens, missing separators, and trailing input.
- The codecs reject malformed payloads, inconsistent dimensions, and non-finite
  coordinates. They do not check topology or limit nesting depth.
- Simple Features accessors, envelopes, areas, lengths, perimeters, centroids,
  and convex hulls in the XY plane. Computed geometries use XY coordinates.
- `Data.Geometry.Internal` exports the `Coordinate` class methods and the shared
  validation, without a stability guarantee.
