# 0.1.0.0

- Release under the MIT license.
- Add pure Simple Features properties, coordinate and component accessors,
  envelopes, areas, curve lengths, perimeters, centroids, and convex hulls.
  Planar operations use Cartesian XY coordinates. Computed geometries use XY.
- Add all seven Simple Features geometry families with XY, XYZ, XYM, and XYZM
  coordinates. Empty points are explicit values. Coordinate sequences and
  multipoints use unboxed vectors.
- Add checked ISO WKB decoding and encoding. Decoding accepts either byte
  order, including different byte orders in nested geometries.
- Add WKT encoding and standalone decoding for all seven families and four
  coordinate layouts. Preserve empty dimensions and exact finite values from
  generated WKT. Reject malformed tokens, missing separators, and trailing input.
- Reject malformed payloads, inconsistent dimensions, and non-finite
  coordinates. These checks do not validate topology or limit nesting depth.
