# 0.1.0.0

- Add all seven Simple Features geometry families with XY, XYZ, XYM, and XYZM
  coordinates. Empty points are explicit values. Coordinate sequences and
  multipoints use unboxed vectors.
- Add checked ISO WKB decoding and encoding. Decoding accepts either byte
  order, including different byte orders in nested geometries.
- Add WKT encoding and standalone decoding for all seven families and four
  coordinate layouts. Preserve empty dimensions and exact finite values from
  generated WKT. Reject malformed tokens, missing separators, and trailing input.
- Reject malformed payloads, inconsistent dimensions, non-finite coordinates,
  and more than 128 geometry levels. These checks do not validate topology.
