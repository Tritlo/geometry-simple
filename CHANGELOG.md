# 0.1.0.0

- Add all seven Simple Features geometry families with XY, XYZ, XYM, and XYZM
  coordinates. Empty points are explicit values. Coordinate sequences and
  multipoints use unboxed vectors.
- Add checked ISO WKB decoding and encoding, plus WKT output. Decoding accepts
  either byte order, including different byte orders in nested geometries.
- Reject malformed payloads, inconsistent dimensions, non-finite coordinates,
  and more than 128 geometry levels. These checks do not validate topology.
