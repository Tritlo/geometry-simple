# Performance audit results

Coverage: **64 stable public functions**, **304 workloads**, at sizes 100, 400, and 1,600. The harness baseline is separate.

See [CONTRIBUTING](../../CONTRIBUTING.md#full-api-audit) for the machine, source revision, commands, workload definitions, and measurement limits.

Times below 200 ms use the median of three measured batches after a pilot call. Slower calls have one sample. Additional invocations contribute more samples when present. Allocation is cumulative per call; it is not peak memory. `>` denotes a timeout lower bound. `†` marks completed samples accompanied by a timeout. Ratios compare the same workload at 400 and 1,600.

## Slowest measured workload for each function

Selection uses time at size 1,600 in the previous audit. These are the slowest cases in that corpus, not proven worst-case bounds.

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 | Previous time at 1,600 | Speedup |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `area` | many-holes | 7.51 µs | 29.9 µs | 115 µs | 3.8× | 1.3 MiB | 116 µs | 1.01× |
| `boundary` | multiline | 9.52 µs | 44.1 µs | 220 µs | 5.0× | 1.94 MiB | 234 µs | 1.06× |
| `buffer` | line-positive | 16.6 ms | 74.9 ms | 418 ms | 5.6× | 1.28 GiB | 7.19 s | 17.2× |
| `bufferWithSegments` | line-16-quadrant | 18.6 ms | 79 ms | 411 ms | 5.2× | 1.28 GiB | 7.89 s | 19.2× |
| `centroid` | hole | 9.11 µs | 35.3 µs | 138 µs | 3.9× | 1.71 MiB | 141 µs | 1.02× |
| `contains` | line-polygon | 0.613 µs | 0.625 µs | 0.607 µs | — | 2.37 KiB | 5.36 s | 8.84e+06× |
| `convexHull` | hole | 125 µs | 512 µs | 2.44 ms | 4.8× | 14 MiB | 2.18 ms | 0.895× |
| `coordinateDimension` | nested | 0.362 µs | 1.48 µs | 11.9 µs | 8.1× | 64 KiB | 11.3 µs | 0.945× |
| `coveredBy` | inside | 10.7 ms | 51.8 ms | 230 ms | 4.4× | 663 MiB | 4.75 s | 20.7× |
| `covers` | contained | 10.8 ms | 54.5 ms | 230 ms | 4.2× | 663 MiB | 4.55 s | 19.8× |
| `crosses` | inside | 1.15 µs | 1.1 µs | 1.13 µs | 1.0× | 3.5 KiB | 5.2 s | 4.62e+06× |
| `curveLength` | multiline | 1.21 µs | 4.76 µs | 19.3 µs | 4.1× | 188 KiB | 18.9 µs | 0.978× |
| `decodeWKB` | mixed-collection | 6.29 µs | 26.7 µs | 140 µs | 5.2× | 1.8 MiB | 146 µs | 1.04× |
| `decodeWKT` | polygon-hole-truncated | 184 µs | 739 µs | 2.91 ms | 3.9× | 13.7 MiB | 3.28 ms | 1.13× |
| `difference` | contained | 12.2 ms | 52.6 ms | 242 ms | 4.6× | 774 MiB | 5.45 s | 22.5× |
| `dimension` | nested | 0.385 µs | 1.48 µs | 12 µs | 8.2× | 64 KiB | 11 µs | 0.914× |
| `disjoint` | line-polygon | 83.2 µs | 316 µs | 1.46 ms | 4.6× | 6.75 MiB | 2.26 ms | 1.55× |
| `distance` | disjoint | 587 µs | 2.88 ms | 13.7 ms | 4.8× | 53.4 MiB | 204 ms | 14.9× |
| `encodeWKB` | nested | 9.51 µs | 37.8 µs | 180 µs | 4.8× | 1.39 MiB | 7.83 ms | 43.6× |
| `encodeWKT` | polygon-hole | 81.5 µs | 324 µs | 1.41 ms | 4.4× | 10.1 MiB | 1.65 ms | 1.17× |
| `endPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 96.1 B | <0.1 µs | 0.927× |
| `envelope` | hole | 6.79 µs | 26.4 µs | 105 µs | 4.0× | 1.66 MiB | 103 µs | 0.981× |
| `equals` | equal | 5.95 ms | 26.3 ms | 130 ms | 4.9× | 399 MiB | 1.85 s | 14.3× |
| `exteriorRing` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B | <0.1 µs | 0.795× |
| `geometryLength` | hole | 1.98 µs | 7.62 µs | 30.2 µs | 4.0× | 351 KiB | 29.9 µs | 0.988× |
| `geometryN` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B | <0.1 µs | 0.899× |
| `geometryType` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.052 B | <0.1 µs | 1.03× |
| `interiorRingN` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B | <0.1 µs | 0.969× |
| `intersection` | contained | 11.6 ms | 50.6 ms | 242 ms | 4.8× | 748 MiB | 4.8 s | 19.8× |
| `intersects` | crossing-lines | 104 µs | 405 µs | 1.84 ms | 4.6× | 8.96 MiB | 2.11 ms | 1.15× |
| `is3D` | nested | 0.345 µs | 1.48 µs | 11.3 µs | 7.7× | 64 KiB | 11.9 µs | 1.05× |
| `isClosed` | closed-multiline | <0.1 µs | 0.248 µs | 0.994 µs | — | 0.311 B | 1.01 µs | 1.01× |
| `isEmpty` | nested | 0.342 µs | 1.38 µs | 11.1 µs | 8.1× | 64 KiB | 10.8 µs | 0.968× |
| `isMeasured` | nested | 0.348 µs | 1.46 µs | 11.2 µs | 7.7× | 64 KiB | 11.8 µs | 1.05× |
| `isRing` | closed-line | 885 µs | 3.95 ms | 19 ms | 4.8× | 61.9 MiB | 102 ms | 5.34× |
| `isSimple` | hole | 1.84 ms | 8.41 ms | 35.8 ms | 4.3× | 127 MiB | 206 ms | 5.77× |
| `isValid` | hole | 3.11 ms | 13.8 ms | 67.5 ms | 4.9× | 225 MiB | 980 ms | 14.5× |
| `locateAlong` | alternating-M | 68.6 µs | 281 µs | 1.12 ms | 4.0× | 3.01 MiB | 1.33 ms | 1.18× |
| `locateBetween` | alternating-M | 142 µs | 593 µs | 2.4 ms | 4.1× | 6.33 MiB | 2.93 ms | 1.22× |
| `m` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B | <0.1 µs | 0.768× |
| `numGeometries` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B | <0.1 µs | 0.992× |
| `numInteriorRings` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B | <0.1 µs | 0.777× |
| `numPoints` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56.1 B | <0.1 µs | 0.998× |
| `overlaps` | disjoint | 19.7 µs | 75 µs | 290 µs | 3.9× | 2.25 MiB | 5.06 s | 1.75e+04× |
| `perimeter` | many-holes | 1.6 µs | 6.34 µs | 24.5 µs | 3.9× | 295 KiB | 24.6 µs | 1× |
| `pointM` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B | <0.1 µs | 0.71× |
| `pointN` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 112 B | <0.1 µs | 0.775× |
| `pointOnSurface` | many-holes | 8.04 µs | 35.2 µs | 160 µs | 4.5× | 1.16 MiB | 156 µs | 0.974× |
| `pointX` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32.1 B | <0.1 µs | 1.05× |
| `pointY` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B | <0.1 µs | 0.895× |
| `pointZ` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B | <0.1 µs | 0.998× |
| `relate` | disjoint | 9.47 ms | 43.7 ms | 206 ms | 4.7× | 601 MiB | 5.04 s | 24.4× |
| `relatePattern` | disjoint | 9.67 ms | 46.8 ms | 201 ms | 4.3× | 583 MiB | 4.94 s | 24.6× |
| `spatialDimension` | nested | 0.349 µs | 1.47 µs | 11.2 µs | 7.6× | 64 KiB | 12.2 µs | 1.08× |
| `startPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56 B | <0.1 µs | 0.977× |
| `symmetricDifference` | contained | 12.3 ms | 53.2 ms | 245 ms | 4.6× | 774 MiB | 5.98 s | 24.4× |
| `touches` | touching | 6.8 ms | 35.7 ms | 147 ms | 4.1× | 371 MiB | 3.83 s | 26× |
| `union` | inside | 11.8 ms | 50.5 ms | 233 ms | 4.6× | 744 MiB | 4.76 s | 20.5× |
| `withCoordinates` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B | <0.1 µs | 1.01× |
| `withPoint` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B | <0.1 µs | 0.87× |
| `within` | inside | 10.7 ms | 51.8 ms | 223 ms | 4.3× | 663 MiB | 4.82 s | 21.6× |
| `x` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B | <0.1 µs | 0.867× |
| `y` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B | <0.1 µs | 0.75× |
| `z` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B | <0.1 µs | 0.94× |

## Every workload

### accessors

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `coordinateDimension` | collection | 0.178 µs | 0.676 µs | 2.66 µs | — | 16.8 B |
| `coordinateDimension` | empty-members | 0.201 µs | 0.762 µs | 3.02 µs | — | 16.9 B |
| `coordinateDimension` | nested | 0.362 µs | 1.48 µs | 11.9 µs | 8.1× | 64 KiB |
| `coordinateDimension` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `dimension` | collection | 0.182 µs | 0.687 µs | 2.73 µs | — | 0.796 B |
| `dimension` | empty-members | 0.181 µs | 0.689 µs | 2.76 µs | — | 0.894 B |
| `dimension` | nested | 0.385 µs | 1.48 µs | 12 µs | 8.2× | 64 KiB |
| `dimension` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.133 B |
| `endPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 96.1 B |
| `exteriorRing` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `geometryN` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `geometryType` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.052 B |
| `geometryType` | empty-members | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.044 B |
| `geometryType` | nested | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.064 B |
| `geometryType` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.1 B |
| `interiorRingN` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `is3D` | collection | 0.269 µs | 1.08 µs | 4.24 µs | 3.9× | 1.34 B |
| `is3D` | empty-members | 0.291 µs | 1.14 µs | 4.56 µs | 4.0× | 1.38 B |
| `is3D` | nested | 0.345 µs | 1.48 µs | 11.3 µs | 7.7× | 64 KiB |
| `is3D` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.061 B |
| `isClosed` | closed-multiline | <0.1 µs | 0.248 µs | 0.994 µs | — | 0.311 B |
| `isClosed` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.078 B |
| `isClosed` | multiline | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.05 B |
| `isEmpty` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.039 B |
| `isEmpty` | empty-members | 0.138 µs | 0.533 µs | 2.12 µs | — | 0.637 B |
| `isEmpty` | nested | 0.342 µs | 1.38 µs | 11.1 µs | 8.1× | 64 KiB |
| `isEmpty` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.091 B |
| `isMeasured` | collection | 0.274 µs | 1.08 µs | 4.31 µs | 4.0× | 1.36 B |
| `isMeasured` | empty-members | 0.288 µs | 1.13 µs | 4.53 µs | 4.0× | 1.39 B |
| `isMeasured` | nested | 0.348 µs | 1.46 µs | 11.2 µs | 7.7× | 64 KiB |
| `isMeasured` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.083 B |
| `m` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `numGeometries` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `numInteriorRings` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `numPoints` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56.1 B |
| `pointM` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `pointN` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 112 B |
| `pointX` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32.1 B |
| `pointY` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `pointZ` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `spatialDimension` | collection | 0.275 µs | 1.11 µs | 4.28 µs | 3.9× | 1.37 B |
| `spatialDimension` | empty-members | 0.29 µs | 1.19 µs | 4.58 µs | 3.8× | 1.36 B |
| `spatialDimension` | nested | 0.349 µs | 1.47 µs | 11.2 µs | 7.6× | 64 KiB |
| `spatialDimension` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.172 B |
| `startPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56 B |
| `withCoordinates` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `withPoint` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `x` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `y` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `z` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |

### codecs

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `decodeWKB` | line-XY | 1.11 µs | 4.2 µs | 18.5 µs | 4.4× | 27 KiB |
| `decodeWKB` | line-XY-truncated | 0.149 µs | 0.151 µs | 0.15 µs | — | 1.59 KiB |
| `decodeWKB` | line-XYZM | 2.08 µs | 7.88 µs | 37.3 µs | 4.7× | 52.1 KiB |
| `decodeWKB` | line-XYZM-truncated | 0.147 µs | 0.146 µs | 0.156 µs | — | 1.59 KiB |
| `decodeWKB` | mixed-collection | 6.29 µs | 26.7 µs | 140 µs | 5.2× | 1.8 MiB |
| `decodeWKB` | mixed-collection-truncated | 3.84 µs | 16.6 µs | 85.5 µs | 5.2× | 1.61 MiB |
| `decodeWKB` | nested | 5.6 µs | 23.2 µs | 106 µs | 4.6× | 1.52 MiB |
| `decodeWKB` | nested-truncated | 3.93 µs | 15.5 µs | 64.8 µs | 4.2× | 1.2 MiB |
| `decodeWKB` | polygon-hole | 2.18 µs | 8.15 µs | 40.3 µs | 4.9× | 53.4 KiB |
| `decodeWKB` | polygon-hole-truncated | 0.204 µs | 0.225 µs | 0.212 µs | — | 2.67 KiB |
| `decodeWKT` | line-XY | 59 µs | 239 µs | 958 µs | 4.0× | 4.83 MiB |
| `decodeWKT` | line-XY-truncated | 58.1 µs | 250 µs | 960 µs | 3.8× | 4.8 MiB |
| `decodeWKT` | line-XYZM | 88.1 µs | 360 µs | 1.45 ms | 4.0× | 7.64 MiB |
| `decodeWKT` | line-XYZM-truncated | 86.8 µs | 357 µs | 1.45 ms | 4.1× | 7.59 MiB |
| `decodeWKT` | mixed-collection | 55.1 µs | 242 µs | 1.08 ms | 4.5× | 6.41 MiB |
| `decodeWKT` | mixed-collection-truncated | 36.1 µs | 161 µs | 770 µs | 4.8× | 5.32 MiB |
| `decodeWKT` | nested | 19.9 µs | 77.8 µs | 335 µs | 4.3× | 2.26 MiB |
| `decodeWKT` | nested-truncated | 17.2 µs | 69.2 µs | 302 µs | 4.4× | 2.02 MiB |
| `decodeWKT` | polygon-hole | 183 µs | 736 µs | 2.91 ms | 4.0× | 13.7 MiB |
| `decodeWKT` | polygon-hole-truncated | 184 µs | 739 µs | 2.91 ms | 3.9× | 13.7 MiB |
| `encodeWKB` | line-XY | 1.41 µs | 4.62 µs | 12.4 µs | 2.7× | 288 KiB |
| `encodeWKB` | line-XYZM | 1.16 µs | 7.09 µs | 18.5 µs | 2.6× | 434 KiB |
| `encodeWKB` | mixed-collection | 7.18 µs | 29.3 µs | 119 µs | 4.1× | 1.07 MiB |
| `encodeWKB` | nested | 9.51 µs | 37.8 µs | 180 µs | 4.8× | 1.39 MiB |
| `encodeWKB` | polygon-hole | 1.92 µs | 7.73 µs | 25.7 µs | 3.3× | 585 KiB |
| `encodeWKT` | line-XY | 26.3 µs | 105 µs | 424 µs | 4.0× | 3.41 MiB |
| `encodeWKT` | line-XYZM | 77.5 µs | 303 µs | 1.19 ms | 3.9× | 9.44 MiB |
| `encodeWKT` | mixed-collection | 28.2 µs | 116 µs | 534 µs | 4.6× | 3.67 MiB |
| `encodeWKT` | nested | 19.6 µs | 80.3 µs | 338 µs | 4.2× | 2.4 MiB |
| `encodeWKT` | polygon-hole | 81.5 µs | 324 µs | 1.41 ms | 4.4× | 10.1 MiB |

### construction

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `buffer` | line-positive | 16.6 ms | 74.9 ms | 418 ms | 5.6× | 1.28 GiB |
| `buffer` | polygon-negative | 5.6 ms | 27.5 ms | 103 ms | 3.7× | 307 MiB |
| `buffer` | polygon-positive | 8.21 ms | 36.1 ms | 167 ms | 4.6× | 535 MiB |
| `buffer` | polygon-zero | 3.99 ms | 17.9 ms | 76.3 ms | 4.3× | 233 MiB |
| `bufferWithSegments` | line-16-quadrant | 18.6 ms | 79 ms | 411 ms | 5.2× | 1.28 GiB |
| `bufferWithSegments` | polygon-2-quadrant | 8.58 ms | 36.2 ms | 170 ms | 4.7× | 535 MiB |
| `difference` | contained | 12.2 ms | 52.6 ms | 242 ms | 4.6× | 774 MiB |
| `difference` | crossing-lines | 11.2 ms | 46.7 ms | 212 ms | 4.5× | 714 MiB |
| `difference` | disjoint | 108 µs | 296 µs | 1.21 ms | 4.1× | 4.51 MiB |
| `difference` | equal | 5.69 ms | 24.7 ms | 117 ms | 4.7× | 375 MiB |
| `difference` | inside | 9.26 ms | 39.3 ms | 180 ms | 4.6× | 567 MiB |
| `difference` | line-polygon | 11.6 ms | 34.4 ms | 158 ms | 4.6× | 514 MiB |
| `difference` | overlap | 13.4 ms | 50 ms | 226 ms | 4.5× | 719 MiB |
| `difference` | touching | 6.93 ms | 31.8 ms | 143 ms | 4.5× | 402 MiB |
| `intersection` | contained | 11.6 ms | 50.6 ms | 242 ms | 4.8× | 748 MiB |
| `intersection` | crossing-lines | 6.04 ms | 23.2 ms | 103 ms | 4.4× | 351 MiB |
| `intersection` | disjoint | 18.5 µs | 76.7 µs | 330 µs | 4.3× | 2.25 MiB |
| `intersection` | equal | 7.02 ms | 30.5 ms | 148 ms | 4.8× | 475 MiB |
| `intersection` | inside | 10.6 ms | 45.5 ms | 215 ms | 4.7× | 667 MiB |
| `intersection` | line-polygon | 8.44 ms | 34.8 ms | 153 ms | 4.4× | 511 MiB |
| `intersection` | overlap | 13 ms | 50.9 ms | 233 ms | 4.6× | 713 MiB |
| `intersection` | touching | 6.09 ms | 27.7 ms | 124 ms | 4.5× | 339 MiB |
| `symmetricDifference` | contained | 12.3 ms | 53.2 ms | 245 ms | 4.6× | 774 MiB |
| `symmetricDifference` | crossing-lines | 11.7 ms | 49.7 ms | 224 ms | 4.5× | 788 MiB |
| `symmetricDifference` | disjoint | 131 µs | 527 µs | 2.14 ms | 4.1× | 6.76 MiB |
| `symmetricDifference` | equal | 5.77 ms | 25.7 ms | 119 ms | 4.6× | 393 MiB |
| `symmetricDifference` | inside | 12.2 ms | 52.9 ms | 242 ms | 4.6× | 774 MiB |
| `symmetricDifference` | line-polygon | 14 ms | 58.8 ms | 271 ms | 4.6× | 877 MiB |
| `symmetricDifference` | overlap | 15 ms | 61.6 ms | 272 ms | 4.4× | 871 MiB |
| `symmetricDifference` | touching | 7.94 ms | 36 ms | 161 ms | 4.5× | 452 MiB |
| `union` | contained | 11.4 ms | 47 ms | 213 ms | 4.5× | 684 MiB |
| `union` | crossing-lines | 11.8 ms | 49.9 ms | 224 ms | 4.5× | 782 MiB |
| `union` | disjoint | 131 µs | 564 µs | 2.17 ms | 3.8× | 6.76 MiB |
| `union` | equal | 6.73 ms | 28.4 ms | 132 ms | 4.6× | 436 MiB |
| `union` | inside | 11.8 ms | 50.5 ms | 233 ms | 4.6× | 744 MiB |
| `union` | line-polygon | 13.9 ms | 59.4 ms | 271 ms | 4.6× | 876 MiB |
| `union` | overlap | 13.6 ms | 52.9 ms | 242 ms | 4.6× | 767 MiB |
| `union` | touching | 7.9 ms | 35.9 ms | 157 ms | 4.4× | 448 MiB |

### harness

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `baseline` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.028 B |

### measurements

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `area` | many-holes | 7.51 µs | 29.9 µs | 115 µs | 3.8× | 1.3 MiB |
| `area` | multipolygon | 6.23 µs | 24.6 µs | 97.8 µs | 4.0× | 1.1 MiB |
| `area` | polygon | 4.49 µs | 17.7 µs | 68.4 µs | 3.9× | 876 KiB |
| `centroid` | collection | 1.7 µs | 6.55 µs | 25.6 µs | 3.9× | 88.9 KiB |
| `centroid` | hole | 9.11 µs | 35.3 µs | 138 µs | 3.9× | 1.71 MiB |
| `centroid` | line | 2.15 µs | 8.7 µs | 35 µs | 4.0× | 238 KiB |
| `centroid` | many-holes | 7.46 µs | 29.4 µs | 117 µs | 4.0× | 1.3 MiB |
| `centroid` | multiline | 2.26 µs | 9.07 µs | 36 µs | 4.0× | 245 KiB |
| `centroid` | multipoint | 0.801 µs | 2.55 µs | 9.9 µs | 3.9× | 88.9 KiB |
| `centroid` | multipolygon | 6.38 µs | 25.7 µs | 102 µs | 4.0× | 1.12 MiB |
| `centroid` | polygon | 4.6 µs | 18 µs | 68.3 µs | 3.8× | 877 KiB |
| `convexHull` | collection | 67.6 µs | 269 µs | 1.08 ms | 4.0× | 6.13 MiB |
| `convexHull` | hole | 125 µs | 512 µs | 2.44 ms | 4.8× | 14 MiB |
| `convexHull` | line | 51.9 µs | 247 µs | 1.05 ms | 4.3× | 7.22 MiB |
| `convexHull` | many-holes | 62.9 µs | 257 µs | 1.05 ms | 4.1× | 6.63 MiB |
| `convexHull` | multiline | 66.5 µs | 266 µs | 1.08 ms | 4.1× | 5.91 MiB |
| `convexHull` | multipoint | 52 µs | 244 µs | 1.03 ms | 4.2× | 7.22 MiB |
| `convexHull` | multipolygon | 61.6 µs | 253 µs | 1.04 ms | 4.1× | 5.51 MiB |
| `convexHull` | polygon | 52.9 µs | 219 µs | 921 µs | 4.2× | 6.33 MiB |
| `curveLength` | collection | 0.221 µs | 0.896 µs | 3.63 µs | — | 17.4 B |
| `curveLength` | line | 1.51 µs | 3.78 µs | 15.1 µs | 4.0× | 175 KiB |
| `curveLength` | multiline | 1.21 µs | 4.76 µs | 19.3 µs | 4.1× | 188 KiB |
| `envelope` | collection | 3.45 µs | 13.6 µs | 53.9 µs | 4.0× | 1.1 MiB |
| `envelope` | hole | 6.79 µs | 26.4 µs | 105 µs | 4.0× | 1.66 MiB |
| `envelope` | line | 3.46 µs | 14.6 µs | 53.1 µs | 3.6× | 851 KiB |
| `envelope` | many-holes | 4.6 µs | 17.4 µs | 68.2 µs | 3.9× | 1.04 MiB |
| `envelope` | multiline | 3.6 µs | 14.6 µs | 56.2 µs | 3.8× | 851 KiB |
| `envelope` | multipoint | 3.2 µs | 12.1 µs | 47.1 µs | 3.9× | 851 KiB |
| `envelope` | multipolygon | 3.6 µs | 14.3 µs | 55.8 µs | 3.9× | 851 KiB |
| `envelope` | polygon | 3.45 µs | 13.4 µs | 52.3 µs | 3.9× | 852 KiB |
| `geometryLength` | collection | 0.446 µs | 1.8 µs | 7.26 µs | 4.0× | 34 B |
| `geometryLength` | hole | 1.98 µs | 7.62 µs | 30.2 µs | 4.0× | 351 KiB |
| `geometryLength` | line | 0.96 µs | 3.79 µs | 15 µs | 4.0× | 175 KiB |
| `geometryLength` | many-holes | 1.68 µs | 6.23 µs | 24.6 µs | 3.9× | 295 KiB |
| `geometryLength` | multiline | 1.22 µs | 4.71 µs | 18.8 µs | 4.0× | 188 KiB |
| `geometryLength` | multipoint | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `geometryLength` | multipolygon | 1.39 µs | 5.51 µs | 21.8 µs | 4.0× | 256 KiB |
| `geometryLength` | polygon | 1.01 µs | 3.83 µs | 20.4 µs | 5.3× | 175 KiB |
| `perimeter` | many-holes | 1.6 µs | 6.34 µs | 24.5 µs | 3.9× | 295 KiB |
| `perimeter` | multipolygon | 1.39 µs | 5.52 µs | 21.8 µs | 4.0× | 256 KiB |
| `perimeter` | polygon | 0.991 µs | 3.94 µs | 15.5 µs | 3.9× | 175 KiB |

### measures

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `locateAlong` | alternating-M | 68.6 µs | 281 µs | 1.12 ms | 4.0× | 3.01 MiB |
| `locateAlong` | constant-M | 4.78 µs | 19.3 µs | 78.8 µs | 4.1× | 868 KiB |
| `locateAlong` | multipoint | 0.668 µs | 2.03 µs | 7.6 µs | 3.7× | 88.5 KiB |
| `locateAlong` | varying-M | 2.47 µs | 9.13 µs | 36.9 µs | 4.0× | 352 KiB |
| `locateBetween` | alternating-M | 142 µs | 593 µs | 2.4 ms | 4.1× | 6.33 MiB |
| `locateBetween` | multipoint | 1.22 µs | 3.92 µs | 17.1 µs | 4.4× | 186 KiB |
| `locateBetween` | varying-M | 5.49 µs | 14.9 µs | 53.2 µs | 3.6× | 617 KiB |

### relations

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `contains` | contained | 10.9 ms | 51.8 ms | 220 ms | 4.3× | 663 MiB |
| `contains` | crossing-lines | 6.17 ms | 26.7 ms | 119 ms | 4.5× | 390 MiB |
| `contains` | disjoint | 19.9 µs | 76.7 µs | 290 µs | 3.8× | 2.25 MiB |
| `contains` | equal | 5.97 ms | 29.2 ms | 129 ms | 4.4× | 399 MiB |
| `contains` | inside | 20.6 µs | 77.6 µs | 299 µs | 3.9× | 2.27 MiB |
| `contains` | line-polygon | 0.613 µs | 0.625 µs | 0.607 µs | — | 2.37 KiB |
| `contains` | overlap | 20.3 µs | 79.6 µs | 291 µs | 3.7× | 2.27 MiB |
| `contains` | touching | 23.4 µs | 92.6 µs | 365 µs | 3.9× | 2.04 MiB |
| `coveredBy` | contained | 20.6 µs | 77.1 µs | 295 µs | 3.8× | 2.27 MiB |
| `coveredBy` | crossing-lines | 6.23 ms | 28.6 ms | 124 ms | 4.3× | 390 MiB |
| `coveredBy` | disjoint | 20.6 µs | 75.7 µs | 291 µs | 3.8× | 2.25 MiB |
| `coveredBy` | equal | 6.12 ms | 27 ms | 140 ms | 5.2× | 399 MiB |
| `coveredBy` | inside | 10.7 ms | 51.8 ms | 230 ms | 4.4× | 663 MiB |
| `coveredBy` | line-polygon | 21.6 µs | 75.5 µs | 289 µs | 3.8× | 2.39 MiB |
| `coveredBy` | overlap | 20.3 µs | 75.8 µs | 288 µs | 3.8× | 2.27 MiB |
| `coveredBy` | touching | 23.3 µs | 91.6 µs | 359 µs | 3.9× | 2.04 MiB |
| `covers` | contained | 10.8 ms | 54.5 ms | 230 ms | 4.2× | 663 MiB |
| `covers` | crossing-lines | 6.17 ms | 28.1 ms | 122 ms | 4.3× | 390 MiB |
| `covers` | disjoint | 20.5 µs | 76.7 µs | 292 µs | 3.8× | 2.25 MiB |
| `covers` | equal | 6.44 ms | 27.5 ms | 136 ms | 4.9× | 399 MiB |
| `covers` | inside | 20.4 µs | 77.7 µs | 296 µs | 3.8× | 2.27 MiB |
| `covers` | line-polygon | 0.633 µs | 0.633 µs | 0.601 µs | — | 2.37 KiB |
| `covers` | overlap | 20.1 µs | 79.6 µs | 309 µs | 3.9× | 2.27 MiB |
| `covers` | touching | 23.7 µs | 92.9 µs | 365 µs | 3.9× | 2.04 MiB |
| `crosses` | contained | 1.12 µs | 1.14 µs | 1.1 µs | 1.0× | 3.5 KiB |
| `crosses` | crossing-lines | 6.15 ms | 27 ms | 119 ms | 4.4× | 394 MiB |
| `crosses` | disjoint | 1.13 µs | 1.09 µs | 1.07 µs | 1.0× | 3.38 KiB |
| `crosses` | equal | 1.1 µs | 1.08 µs | 1.06 µs | 1.0× | 3.36 KiB |
| `crosses` | inside | 1.15 µs | 1.1 µs | 1.13 µs | 1.0× | 3.5 KiB |
| `crosses` | line-polygon | 10.2 ms | 48.3 ms | 211 ms | 4.4× | 626 MiB |
| `crosses` | overlap | 1.11 µs | 1.13 µs | 1.16 µs | 1.0× | 3.52 KiB |
| `crosses` | touching | 9.37 µs | 32.1 µs | 124 µs | 3.9× | 239 KiB |
| `disjoint` | contained | 40.3 µs | 149 µs | 630 µs | 4.2× | 3.02 MiB |
| `disjoint` | crossing-lines | 103 µs | 401 µs | 1.86 ms | 4.6× | 8.96 MiB |
| `disjoint` | disjoint | 18.7 µs | 77.3 µs | 337 µs | 4.4× | 2.25 MiB |
| `disjoint` | equal | 18.8 µs | 73.8 µs | 330 µs | 4.5× | 2.21 MiB |
| `disjoint` | inside | 29.7 µs | 116 µs | 494 µs | 4.3× | 2.67 MiB |
| `disjoint` | line-polygon | 83.2 µs | 316 µs | 1.46 ms | 4.6× | 6.75 MiB |
| `disjoint` | overlap | 28.7 µs | 112 µs | 507 µs | 4.5× | 2.63 MiB |
| `disjoint` | touching | 25.4 µs | 98.1 µs | 416 µs | 4.2× | 2.34 MiB |
| `distance` | contained | 76 µs | 338 µs | 1.58 ms | 4.7× | 7.86 MiB |
| `distance` | crossing-lines | 110 µs | 441 µs | 2.02 ms | 4.6× | 9.69 MiB |
| `distance` | disjoint | 587 µs | 2.88 ms | 13.7 ms | 4.8× | 53.4 MiB |
| `distance` | equal | 52.7 µs | 260 µs | 1.38 ms | 5.3× | 7.05 MiB |
| `distance` | inside | 66.7 µs | 302 µs | 1.51 ms | 5.0× | 7.51 MiB |
| `distance` | line-polygon | 110 µs | 433 µs | 2.01 ms | 4.6× | 9.54 MiB |
| `distance` | overlap | 64.7 µs | 301 µs | 1.56 ms | 5.2× | 7.46 MiB |
| `distance` | touching | 51.5 µs | 229 µs | 1.07 ms | 4.7× | 4.92 MiB |
| `equals` | contained | 20.5 µs | 76.3 µs | 298 µs | 3.9× | 2.27 MiB |
| `equals` | crossing-lines | 5.98 ms | 25.1 ms | 117 ms | 4.7× | 381 MiB |
| `equals` | disjoint | 19.9 µs | 74 µs | 295 µs | 4.0× | 2.25 MiB |
| `equals` | equal | 5.95 ms | 26.3 ms | 130 ms | 4.9× | 399 MiB |
| `equals` | inside | 20.6 µs | 76.3 µs | 301 µs | 3.9× | 2.27 MiB |
| `equals` | line-polygon | 0.613 µs | 0.627 µs | 0.681 µs | — | 2.37 KiB |
| `equals` | overlap | 20.2 µs | 75.4 µs | 289 µs | 3.8× | 2.27 MiB |
| `equals` | touching | 23.5 µs | 96.1 µs | 359 µs | 3.7× | 2.04 MiB |
| `intersects` | contained | 40.3 µs | 149 µs | 619 µs | 4.1× | 3.02 MiB |
| `intersects` | crossing-lines | 104 µs | 405 µs | 1.84 ms | 4.6× | 8.96 MiB |
| `intersects` | disjoint | 18.5 µs | 77 µs | 328 µs | 4.3× | 2.25 MiB |
| `intersects` | equal | 18.6 µs | 75 µs | 322 µs | 4.3× | 2.21 MiB |
| `intersects` | inside | 29.5 µs | 115 µs | 490 µs | 4.3× | 2.67 MiB |
| `intersects` | line-polygon | 86.1 µs | 322 µs | 1.43 ms | 4.4× | 6.75 MiB |
| `intersects` | overlap | 28.6 µs | 111 µs | 491 µs | 4.4× | 2.63 MiB |
| `intersects` | touching | 24.9 µs | 97.6 µs | 416 µs | 4.3× | 2.34 MiB |
| `overlaps` | contained | 10.6 ms | 50.4 ms | 218 ms | 4.3× | 659 MiB |
| `overlaps` | crossing-lines | 5.97 ms | 27.4 ms | 113 ms | 4.1× | 377 MiB |
| `overlaps` | disjoint | 19.7 µs | 75 µs | 290 µs | 3.9× | 2.25 MiB |
| `overlaps` | equal | 5.85 ms | 29.1 ms | 126 ms | 4.3× | 393 MiB |
| `overlaps` | inside | 10.5 ms | 48.4 ms | 220 ms | 4.6× | 650 MiB |
| `overlaps` | line-polygon | 0.617 µs | 0.669 µs | 0.629 µs | — | 2.37 KiB |
| `overlaps` | overlap | 12.5 ms | 53.3 ms | 231 ms | 4.3× | 690 MiB |
| `overlaps` | touching | 6.61 ms | 31.8 ms | 139 ms | 4.4× | 354 MiB |
| `relate` | contained | 11 ms | 49.7 ms | 226 ms | 4.5× | 662 MiB |
| `relate` | crossing-lines | 6.05 ms | 26.7 ms | 120 ms | 4.5× | 392 MiB |
| `relate` | disjoint | 9.47 ms | 43.7 ms | 206 ms | 4.7× | 601 MiB |
| `relate` | equal | 5.83 ms | 27 ms | 129 ms | 4.8× | 397 MiB |
| `relate` | inside | 10.7 ms | 48.1 ms | 226 ms | 4.7× | 662 MiB |
| `relate` | line-polygon | 10.3 ms | 45.1 ms | 213 ms | 4.7× | 624 MiB |
| `relate` | overlap | 13 ms | 51.2 ms | 244 ms | 4.8× | 689 MiB |
| `relate` | touching | 6.84 ms | 31.9 ms | 145 ms | 4.5× | 369 MiB |
| `relatePattern` | contained | 11.4 ms | 48.5 ms | 228 ms | 4.7× | 661 MiB |
| `relatePattern` | crossing-lines | 6.18 ms | 25.5 ms | 122 ms | 4.8× | 387 MiB |
| `relatePattern` | disjoint | 9.67 ms | 46.8 ms | 201 ms | 4.3× | 583 MiB |
| `relatePattern` | equal | 6.09 ms | 27.2 ms | 129 ms | 4.7× | 397 MiB |
| `relatePattern` | inside | 11.3 ms | 49.8 ms | 221 ms | 4.4× | 656 MiB |
| `relatePattern` | line-polygon | 10.3 ms | 45.1 ms | 209 ms | 4.6× | 619 MiB |
| `relatePattern` | overlap | 12.6 ms | 51.1 ms | 231 ms | 4.5× | 684 MiB |
| `relatePattern` | touching | 6.83 ms | 30.6 ms | 148 ms | 4.8× | 352 MiB |
| `touches` | contained | 48.9 µs | 186 µs | 751 µs | 4.0× | 3.42 MiB |
| `touches` | crossing-lines | 6.09 ms | 26 ms | 119 ms | 4.6× | 384 MiB |
| `touches` | disjoint | 18.5 µs | 82.3 µs | 332 µs | 4.0× | 2.25 MiB |
| `touches` | equal | 5.93 ms | 26.7 ms | 129 ms | 4.8× | 391 MiB |
| `touches` | inside | 48.6 µs | 186 µs | 760 µs | 4.1× | 3.42 MiB |
| `touches` | line-polygon | 10.2 ms | 46.2 ms | 205 ms | 4.4× | 614 MiB |
| `touches` | overlap | 50.8 µs | 187 µs | 769 µs | 4.1× | 3.44 MiB |
| `touches` | touching | 6.8 ms | 35.7 ms | 147 ms | 4.1× | 371 MiB |
| `within` | contained | 20.2 µs | 76.9 µs | 296 µs | 3.8× | 2.27 MiB |
| `within` | crossing-lines | 7.95 ms | 28.2 ms | 120 ms | 4.2× | 390 MiB |
| `within` | disjoint | 20.2 µs | 76.7 µs | 291 µs | 3.8× | 2.25 MiB |
| `within` | equal | 6.05 ms | 29 ms | 131 ms | 4.5× | 399 MiB |
| `within` | inside | 10.7 ms | 51.8 ms | 223 ms | 4.3× | 663 MiB |
| `within` | line-polygon | 19.3 µs | 77.2 µs | 291 µs | 3.8× | 2.39 MiB |
| `within` | overlap | 20.2 µs | 77.6 µs | 289 µs | 3.7× | 2.27 MiB |
| `within` | touching | 23.6 µs | 121 µs | 356 µs | 3.0× | 2.04 MiB |

### unary

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `boundary` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.028 B |
| `boundary` | hole | <0.1 µs | <0.1 µs | <0.1 µs | — | 160 B |
| `boundary` | line | 0.585 µs | 1.88 µs | 7.19 µs | 3.8× | 151 KiB |
| `boundary` | many-holes | <0.1 µs | 0.151 µs | 0.512 µs | — | 3.27 KiB |
| `boundary` | multiline | 9.52 µs | 44.1 µs | 220 µs | 5.0× | 1.94 MiB |
| `boundary` | multipoint | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.028 B |
| `boundary` | multipolygon | 0.374 µs | 1.32 µs | 4.7 µs | 3.6× | 67.8 KiB |
| `boundary` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 32.1 B |
| `isRing` | closed-line | 885 µs | 3.95 ms | 19 ms | 4.8× | 61.9 MiB |
| `isRing` | open-line | 0.463 µs | 1.78 µs | 7.44 µs | 4.2× | 150 KiB |
| `isSimple` | collection | 0.14 µs | 0.558 µs | 2.16 µs | — | 0.78 B |
| `isSimple` | hole | 1.84 ms | 8.41 ms | 35.8 ms | 4.3× | 127 MiB |
| `isSimple` | line | 566 µs | 2.74 ms | 14.7 ms | 5.4× | 41.7 MiB |
| `isSimple` | many-holes | 217 µs | 833 µs | 3.16 ms | 3.8× | 6.45 MiB |
| `isSimple` | multiline | 90.8 µs | 446 µs | 2.25 ms | 5.0× | 5.92 MiB |
| `isSimple` | multipoint | 3.1 µs | 12.7 µs | 51.7 µs | 4.1× | 400 KiB |
| `isSimple` | multipolygon | 135 µs | 530 µs | 2.07 ms | 3.9× | 4.46 MiB |
| `isSimple` | polygon | 915 µs | 3.86 ms | 17.9 ms | 4.6× | 61.7 MiB |
| `isValid` | collection | 1.22 µs | 4.71 µs | 19 µs | 4.0× | 5.29 B |
| `isValid` | hole | 3.11 ms | 13.8 ms | 67.5 ms | 4.9× | 225 MiB |
| `isValid` | line | 0.438 µs | 1.62 µs | 6.19 µs | 3.8× | 387 B |
| `isValid` | many-holes | 661 µs | 2.52 ms | 10.3 ms | 4.1× | 21.6 MiB |
| `isValid` | multiline | 2.16 µs | 8.46 µs | 34.2 µs | 4.0× | 300 KiB |
| `isValid` | multipoint | 0.776 µs | 2.98 µs | 12.3 µs | 4.1× | 87.5 KiB |
| `isValid` | multipolygon | 212 µs | 842 µs | 3.92 ms | 4.7× | 8.19 MiB |
| `isValid` | polygon | 934 µs | 4.03 ms | 19.6 ms | 4.9× | 64.7 MiB |
| `pointOnSurface` | collection | 4.34 µs | 17.7 µs | 89.9 µs | 5.1× | 859 KiB |
| `pointOnSurface` | hole | 8.85 µs | 34.4 µs | 147 µs | 4.3× | 1.11 MiB |
| `pointOnSurface` | line | 4.59 µs | 21.8 µs | 98.4 µs | 4.5× | 978 KiB |
| `pointOnSurface` | many-holes | 8.04 µs | 35.2 µs | 160 µs | 4.5× | 1.16 MiB |
| `pointOnSurface` | multiline | 5.31 µs | 22 µs | 106 µs | 4.8× | 1.01e+03 KiB |
| `pointOnSurface` | multipoint | 4.42 µs | 18.3 µs | 97.6 µs | 5.3× | 1.01e+03 KiB |
| `pointOnSurface` | multipolygon | 6.24 µs | 24.5 µs | 98.9 µs | 4.0× | 1.03 MiB |
| `pointOnSurface` | polygon | 5.22 µs | 19.6 µs | 81.7 µs | 4.2× | 639 KiB |

## Larger inputs

These runs cover selected accessors, measurements, measured locations, and codecs. Topology remains in the smaller sweep. The `nested` case measures collection depth; line cases measure coordinate count.

| Function | Case | Size | Time | Allocation | Completed samples | Timeouts |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `coordinateDimension` | collection | 10,000 | 16.2 µs | 20.5 B | 3 | 0 |
| `coordinateDimension` | collection | 100,000 | 176 µs | 111 B | 3 | 0 |
| `coordinateDimension` | empty-members | 10,000 | 18.8 µs | 21.3 B | 3 | 0 |
| `coordinateDimension` | empty-members | 100,000 | 188 µs | 67.2 B | 3 | 0 |
| `coordinateDimension` | nested | 10,000 | 79.2 µs | 480 KiB | 3 | 0 |
| `coordinateDimension` | nested | 100,000 | 1.28 ms | 4.75 MiB | 3 | 0 |
| `coordinateDimension` | polygon | 10,000 | <0.1 µs | 16.2 B | 3 | 0 |
| `coordinateDimension` | polygon | 100,000 | <0.1 µs | 16.3 B | 3 | 0 |
| `dimension` | collection | 10,000 | 17 µs | 4.74 B | 3 | 0 |
| `dimension` | collection | 100,000 | 169 µs | 47.9 B | 3 | 0 |
| `dimension` | empty-members | 10,000 | 16.9 µs | 4.65 B | 3 | 0 |
| `dimension` | empty-members | 100,000 | 169 µs | 46.8 B | 3 | 0 |
| `dimension` | nested | 10,000 | 81.8 µs | 480 KiB | 3 | 0 |
| `dimension` | nested | 100,000 | 1.4 ms | 4.75 MiB | 3 | 0 |
| `dimension` | polygon | 10,000 | <0.1 µs | 0.102 B | 3 | 0 |
| `dimension` | polygon | 100,000 | <0.1 µs | 0.21 B | 3 | 0 |
| `endPoint` | line | 10,000 | <0.1 µs | 96.1 B | 3 | 0 |
| `endPoint` | line | 100,000 | <0.1 µs | 96.3 B | 3 | 0 |
| `exteriorRing` | polygon | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `exteriorRing` | polygon | 100,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `geometryN` | collection | 10,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `geometryN` | collection | 100,000 | <0.1 µs | 16.3 B | 3 | 0 |
| `geometryType` | collection | 10,000 | <0.1 µs | 0.161 B | 3 | 0 |
| `geometryType` | collection | 100,000 | <0.1 µs | 0.578 B | 3 | 0 |
| `geometryType` | empty-members | 10,000 | <0.1 µs | 0.053 B | 3 | 0 |
| `geometryType` | empty-members | 100,000 | <0.1 µs | 0.495 B | 3 | 0 |
| `geometryType` | nested | 10,000 | <0.1 µs | 0.069 B | 3 | 0 |
| `geometryType` | nested | 100,000 | <0.1 µs | 0.354 B | 3 | 0 |
| `geometryType` | polygon | 10,000 | <0.1 µs | 0.136 B | 3 | 0 |
| `geometryType` | polygon | 100,000 | <0.1 µs | 0.266 B | 3 | 0 |
| `interiorRingN` | many-holes | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `interiorRingN` | many-holes | 100,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `is3D` | collection | 10,000 | 26.5 µs | 7.8 B | 3 | 0 |
| `is3D` | collection | 100,000 | 274 µs | 138 B | 3 | 0 |
| `is3D` | empty-members | 10,000 | 28.2 µs | 7.8 B | 3 | 0 |
| `is3D` | empty-members | 100,000 | 278 µs | 78.9 B | 3 | 0 |
| `is3D` | nested | 10,000 | 69.9 µs | 384 KiB | 3 | 0 |
| `is3D` | nested | 100,000 | 909 µs | 3.94 MiB | 3 | 0 |
| `is3D` | polygon | 10,000 | <0.1 µs | 0.136 B | 3 | 0 |
| `is3D` | polygon | 100,000 | <0.1 µs | 0.459 B | 3 | 0 |
| `isClosed` | closed-multiline | 10,000 | 6.17 µs | 1.69 B | 3 | 0 |
| `isClosed` | closed-multiline | 100,000 | 62.1 µs | 16.7 B | 3 | 0 |
| `isClosed` | line | 10,000 | <0.1 µs | 0.067 B | 3 | 0 |
| `isClosed` | line | 100,000 | <0.1 µs | 0.138 B | 3 | 0 |
| `isClosed` | multiline | 10,000 | <0.1 µs | 0.031 B | 3 | 0 |
| `isClosed` | multiline | 100,000 | <0.1 µs | 0.382 B | 3 | 0 |
| `isEmpty` | collection | 10,000 | <0.1 µs | 0.078 B | 3 | 0 |
| `isEmpty` | collection | 100,000 | <0.1 µs | 0.266 B | 3 | 0 |
| `isEmpty` | empty-members | 10,000 | 13.3 µs | 3.66 B | 3 | 0 |
| `isEmpty` | empty-members | 100,000 | 133 µs | 36.5 B | 3 | 0 |
| `isEmpty` | nested | 10,000 | 70.9 µs | 384 KiB | 3 | 0 |
| `isEmpty` | nested | 100,000 | 899 µs | 3.94 MiB | 3 | 0 |
| `isEmpty` | polygon | 10,000 | <0.1 µs | 0.108 B | 3 | 0 |
| `isEmpty` | polygon | 100,000 | <0.1 µs | 0.462 B | 3 | 0 |
| `isMeasured` | collection | 10,000 | 26.5 µs | 7.71 B | 3 | 0 |
| `isMeasured` | collection | 100,000 | 269 µs | 82.2 B | 3 | 0 |
| `isMeasured` | empty-members | 10,000 | 28.4 µs | 7.84 B | 3 | 0 |
| `isMeasured` | empty-members | 100,000 | 278 µs | 70.8 B | 3 | 0 |
| `isMeasured` | nested | 10,000 | 69.9 µs | 384 KiB | 3 | 0 |
| `isMeasured` | nested | 100,000 | 1.1 ms | 3.94 MiB | 3 | 0 |
| `isMeasured` | polygon | 10,000 | <0.1 µs | 0.053 B | 3 | 0 |
| `isMeasured` | polygon | 100,000 | <0.1 µs | 0.362 B | 3 | 0 |
| `m` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `m` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `numGeometries` | collection | 10,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `numGeometries` | collection | 100,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `numInteriorRings` | many-holes | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `numInteriorRings` | many-holes | 100,000 | <0.1 µs | 32.1 B | 3 | 0 |
| `numPoints` | line | 10,000 | <0.1 µs | 56.1 B | 3 | 0 |
| `numPoints` | line | 100,000 | <0.1 µs | 56.1 B | 3 | 0 |
| `pointM` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `pointM` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `pointN` | line | 10,000 | <0.1 µs | 112 B | 3 | 0 |
| `pointN` | line | 100,000 | <0.1 µs | 112 B | 3 | 0 |
| `pointX` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `pointX` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `pointY` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `pointY` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `pointZ` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `pointZ` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `spatialDimension` | collection | 10,000 | 26.3 µs | 12.7 B | 3 | 0 |
| `spatialDimension` | collection | 100,000 | 272 µs | 86.8 B | 3 | 0 |
| `spatialDimension` | empty-members | 10,000 | 28.4 µs | 7.78 B | 3 | 0 |
| `spatialDimension` | empty-members | 100,000 | 281 µs | 78.9 B | 3 | 0 |
| `spatialDimension` | nested | 10,000 | 70.5 µs | 384 KiB | 3 | 0 |
| `spatialDimension` | nested | 100,000 | 928 µs | 3.94 MiB | 3 | 0 |
| `spatialDimension` | polygon | 10,000 | <0.1 µs | 0.172 B | 3 | 0 |
| `spatialDimension` | polygon | 100,000 | <0.1 µs | 0.451 B | 3 | 0 |
| `startPoint` | line | 10,000 | <0.1 µs | 56 B | 3 | 0 |
| `startPoint` | line | 100,000 | <0.1 µs | 56.1 B | 3 | 0 |
| `withCoordinates` | line | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `withCoordinates` | line | 100,000 | <0.1 µs | 16 B | 3 | 0 |
| `withPoint` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `withPoint` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `x` | scalar | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `x` | scalar | 100,000 | <0.1 µs | 16 B | 3 | 0 |
| `y` | scalar | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `y` | scalar | 100,000 | <0.1 µs | 16 B | 3 | 0 |
| `z` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `z` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `decodeWKB` | line-XY | 10,000 | 129 µs | 158 KiB | 3 | 0 |
| `decodeWKB` | line-XY | 100,000 | 1.3 ms | 1.53 MiB | 3 | 0 |
| `decodeWKB` | line-XY-truncated | 10,000 | 0.157 µs | 1.6 KiB | 3 | 0 |
| `decodeWKB` | line-XY-truncated | 100,000 | 0.146 µs | 1.6 KiB | 3 | 0 |
| `decodeWKB` | line-XYZM | 10,000 | 231 µs | 315 KiB | 3 | 0 |
| `decodeWKB` | line-XYZM | 100,000 | 2.61 ms | 3.05 MiB | 3 | 0 |
| `decodeWKB` | line-XYZM-truncated | 10,000 | 0.148 µs | 1.59 KiB | 3 | 0 |
| `decodeWKB` | line-XYZM-truncated | 100,000 | 0.149 µs | 1.59 KiB | 3 | 0 |
| `decodeWKB` | mixed-collection | 10,000 | 2.54 ms | 11.3 MiB | 3 | 0 |
| `decodeWKB` | mixed-collection-truncated | 10,000 | 2.1 ms | 10 MiB | 3 | 0 |
| `decodeWKB` | nested | 10,000 | 1.11 ms | 9.46 MiB | 3 | 0 |
| `decodeWKB` | nested-truncated | 10,000 | 664 µs | 7.48 MiB | 3 | 0 |
| `decodeWKB` | polygon-hole | 10,000 | 230 µs | 316 KiB | 3 | 0 |
| `decodeWKB` | polygon-hole-truncated | 10,000 | 0.22 µs | 2.67 KiB | 3 | 0 |
| `decodeWKT` | line-XY | 10,000 | 6 ms | 30.6 MiB | 3 | 0 |
| `decodeWKT` | line-XY | 100,000 | 64 ms | 309 MiB | 3 | 0 |
| `decodeWKT` | line-XY-truncated | 10,000 | 6.21 ms | 30.4 MiB | 3 | 0 |
| `decodeWKT` | line-XY-truncated | 100,000 | 62.7 ms | 308 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM | 10,000 | 9.54 ms | 49 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM | 100,000 | 99.9 ms | 501 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM-truncated | 10,000 | 9.58 ms | 48.7 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM-truncated | 100,000 | 99.8 ms | 498 MiB | 3 | 0 |
| `decodeWKT` | mixed-collection | 10,000 | 12.5 ms | 40.4 MiB | 3 | 0 |
| `decodeWKT` | mixed-collection-truncated | 10,000 | 9.87 ms | 33.3 MiB | 3 | 0 |
| `decodeWKT` | nested | 10,000 | 3.35 ms | 14.2 MiB | 3 | 0 |
| `decodeWKT` | nested-truncated | 10,000 | 3.6 ms | 12.8 MiB | 3 | 0 |
| `decodeWKT` | polygon-hole | 10,000 | 18.3 ms | 86.1 MiB | 3 | 0 |
| `decodeWKT` | polygon-hole-truncated | 10,000 | 18.4 ms | 86.1 MiB | 3 | 0 |
| `encodeWKB` | line-XY | 10,000 | 75.5 µs | 1.69 MiB | 3 | 0 |
| `encodeWKB` | line-XY | 100,000 | 1.04 ms | 16.8 MiB | 3 | 0 |
| `encodeWKB` | line-XYZM | 10,000 | 120 µs | 2.46 MiB | 3 | 0 |
| `encodeWKB` | line-XYZM | 100,000 | 1.47 ms | 24.5 MiB | 3 | 0 |
| `encodeWKB` | mixed-collection | 10,000 | 1.02 ms | 6.52 MiB | 3 | 0 |
| `encodeWKB` | nested | 10,000 | 2.58 ms | 8.6 MiB | 3 | 0 |
| `encodeWKB` | nested | 100,000 | 89.5 ms | 86.1 MiB | 3 | 0 |
| `encodeWKB` | polygon-hole | 10,000 | 166 µs | 3.37 MiB | 3 | 0 |
| `encodeWKT` | line-XY | 10,000 | 2.58 ms | 21.2 MiB | 3 | 0 |
| `encodeWKT` | line-XY | 100,000 | 28.5 ms | 212 MiB | 3 | 0 |
| `encodeWKT` | line-XYZM | 10,000 | 7.26 ms | 57.4 MiB | 3 | 0 |
| `encodeWKT` | line-XYZM | 100,000 | 73.3 ms | 562 MiB | 3 | 0 |
| `encodeWKT` | mixed-collection | 10,000 | 6.5 ms | 22.8 MiB | 3 | 0 |
| `encodeWKT` | nested | 10,000 | 4.34 ms | 14.9 MiB | 3 | 0 |
| `encodeWKT` | polygon-hole | 10,000 | 9.01 ms | 62.9 MiB | 3 | 0 |
| `area` | many-holes | 10,000 | 713 µs | 8.13 MiB | 3 | 0 |
| `area` | many-holes | 100,000 | 8.12 ms | 81.3 MiB | 3 | 0 |
| `area` | multipolygon | 10,000 | 608 µs | 6.87 MiB | 3 | 0 |
| `area` | multipolygon | 100,000 | 7.35 ms | 68.7 MiB | 3 | 0 |
| `area` | polygon | 10,000 | 410 µs | 5.34 MiB | 3 | 0 |
| `area` | polygon | 100,000 | 4.55 ms | 53.4 MiB | 3 | 0 |
| `centroid` | collection | 10,000 | 163 µs | 548 KiB | 3 | 0 |
| `centroid` | collection | 100,000 | 1.94 ms | 5.34 MiB | 3 | 0 |
| `centroid` | hole | 10,000 | 816 µs | 10.7 MiB | 3 | 0 |
| `centroid` | hole | 100,000 | 8.41 ms | 107 MiB | 3 | 0 |
| `centroid` | line | 10,000 | 211 µs | 1.45 MiB | 3 | 0 |
| `centroid` | line | 100,000 | 2.33 ms | 14.5 MiB | 3 | 0 |
| `centroid` | many-holes | 10,000 | 718 µs | 8.13 MiB | 3 | 0 |
| `centroid` | many-holes | 100,000 | 8.13 ms | 81.3 MiB | 3 | 0 |
| `centroid` | multiline | 10,000 | 224 µs | 1.49 MiB | 3 | 0 |
| `centroid` | multiline | 100,000 | 2.74 ms | 14.9 MiB | 3 | 0 |
| `centroid` | multipoint | 10,000 | 62.4 µs | 548 KiB | 3 | 0 |
| `centroid` | multipoint | 100,000 | 676 µs | 5.34 MiB | 3 | 0 |
| `centroid` | multipolygon | 10,000 | 632 µs | 7.02 MiB | 3 | 0 |
| `centroid` | multipolygon | 100,000 | 6.87 ms | 70.2 MiB | 3 | 0 |
| `centroid` | polygon | 10,000 | 410 µs | 5.34 MiB | 3 | 0 |
| `centroid` | polygon | 100,000 | 4.48 ms | 53.4 MiB | 3 | 0 |
| `convexHull` | collection | 10,000 | 7.22 ms | 38.4 MiB | 3 | 0 |
| `convexHull` | collection | 100,000 | 79 ms | 384 MiB | 3 | 0 |
| `convexHull` | hole | 10,000 | 15.7 ms | 87.5 MiB | 3 | 0 |
| `convexHull` | hole | 100,000 | 221 ms | 874 MiB | 1 | 0 |
| `convexHull` | line | 10,000 | 7.04 ms | 45.5 MiB | 3 | 0 |
| `convexHull` | line | 100,000 | 76.9 ms | 456 MiB | 3 | 0 |
| `convexHull` | many-holes | 10,000 | 7.61 ms | 42.8 MiB | 3 | 0 |
| `convexHull` | many-holes | 100,000 | 97.3 ms | 435 MiB | 3 | 0 |
| `convexHull` | multiline | 10,000 | 7.5 ms | 37 MiB | 3 | 0 |
| `convexHull` | multiline | 100,000 | 81 ms | 370 MiB | 3 | 0 |
| `convexHull` | multipoint | 10,000 | 6.9 ms | 45.5 MiB | 3 | 0 |
| `convexHull` | multipoint | 100,000 | 75.9 ms | 456 MiB | 3 | 0 |
| `convexHull` | multipolygon | 10,000 | 7.92 ms | 35.4 MiB | 3 | 0 |
| `convexHull` | multipolygon | 100,000 | 95.9 ms | 362 MiB | 3 | 0 |
| `convexHull` | polygon | 10,000 | 6.52 ms | 39.7 MiB | 3 | 0 |
| `convexHull` | polygon | 100,000 | 81.4 ms | 396 MiB | 3 | 0 |
| `curveLength` | collection | 10,000 | 22.5 µs | 22.1 B | 3 | 0 |
| `curveLength` | collection | 100,000 | 225 µs | 79.1 B | 3 | 0 |
| `curveLength` | line | 10,000 | 100 µs | 1.07 MiB | 3 | 0 |
| `curveLength` | line | 100,000 | 1.11 ms | 10.7 MiB | 3 | 0 |
| `curveLength` | multiline | 10,000 | 121 µs | 1.14 MiB | 3 | 0 |
| `curveLength` | multiline | 100,000 | 1.77 ms | 11.4 MiB | 3 | 0 |
| `envelope` | collection | 10,000 | 326 µs | 6.87 MiB | 3 | 0 |
| `envelope` | collection | 100,000 | 3.74 ms | 68.7 MiB | 3 | 0 |
| `envelope` | hole | 10,000 | 593 µs | 10.4 MiB | 3 | 0 |
| `envelope` | hole | 100,000 | 5.62 ms | 104 MiB | 3 | 0 |
| `envelope` | line | 10,000 | 309 µs | 5.19 MiB | 3 | 0 |
| `envelope` | line | 100,000 | 2.86 ms | 51.9 MiB | 3 | 0 |
| `envelope` | many-holes | 10,000 | 398 µs | 6.49 MiB | 3 | 0 |
| `envelope` | many-holes | 100,000 | 4.12 ms | 64.9 MiB | 3 | 0 |
| `envelope` | multiline | 10,000 | 341 µs | 5.19 MiB | 3 | 0 |
| `envelope` | multiline | 100,000 | 4.27 ms | 51.9 MiB | 3 | 0 |
| `envelope` | multipoint | 10,000 | 285 µs | 5.19 MiB | 3 | 0 |
| `envelope` | multipoint | 100,000 | 3.06 ms | 51.9 MiB | 3 | 0 |
| `envelope` | multipolygon | 10,000 | 331 µs | 5.19 MiB | 3 | 0 |
| `envelope` | multipolygon | 100,000 | 4.08 ms | 51.9 MiB | 3 | 0 |
| `envelope` | polygon | 10,000 | 299 µs | 5.19 MiB | 3 | 0 |
| `envelope` | polygon | 100,000 | 2.84 ms | 51.9 MiB | 3 | 0 |
| `geometryLength` | collection | 10,000 | 45.1 µs | 44.5 B | 3 | 0 |
| `geometryLength` | collection | 100,000 | 448 µs | 157 B | 3 | 0 |
| `geometryLength` | hole | 10,000 | 184 µs | 2.14 MiB | 3 | 0 |
| `geometryLength` | hole | 100,000 | 2.11 ms | 21.4 MiB | 3 | 0 |
| `geometryLength` | line | 10,000 | 92.1 µs | 1.07 MiB | 3 | 0 |
| `geometryLength` | line | 100,000 | 1.04 ms | 10.7 MiB | 3 | 0 |
| `geometryLength` | many-holes | 10,000 | 159 µs | 1.79 MiB | 3 | 0 |
| `geometryLength` | many-holes | 100,000 | 2.1 ms | 17.9 MiB | 3 | 0 |
| `geometryLength` | multiline | 10,000 | 122 µs | 1.14 MiB | 3 | 0 |
| `geometryLength` | multiline | 100,000 | 1.94 ms | 11.4 MiB | 3 | 0 |
| `geometryLength` | multipoint | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `geometryLength` | multipoint | 100,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `geometryLength` | multipolygon | 10,000 | 140 µs | 1.56 MiB | 3 | 0 |
| `geometryLength` | multipolygon | 100,000 | 1.83 ms | 15.6 MiB | 3 | 0 |
| `geometryLength` | polygon | 10,000 | 92.5 µs | 1.07 MiB | 3 | 0 |
| `geometryLength` | polygon | 100,000 | 1.05 ms | 10.7 MiB | 3 | 0 |
| `perimeter` | many-holes | 10,000 | 151 µs | 1.79 MiB | 3 | 0 |
| `perimeter` | many-holes | 100,000 | 1.91 ms | 17.9 MiB | 3 | 0 |
| `perimeter` | multipolygon | 10,000 | 136 µs | 1.56 MiB | 3 | 0 |
| `perimeter` | multipolygon | 100,000 | 1.95 ms | 15.6 MiB | 3 | 0 |
| `perimeter` | polygon | 10,000 | 92.1 µs | 1.07 MiB | 3 | 0 |
| `perimeter` | polygon | 100,000 | 1.15 ms | 10.7 MiB | 3 | 0 |
| `locateAlong` | alternating-M | 10,000 | 7.74 ms | 19 MiB | 3 | 0 |
| `locateAlong` | alternating-M | 100,000 | 90.8 ms | 188 MiB | 3 | 0 |
| `locateAlong` | constant-M | 10,000 | 697 µs | 5.5 MiB | 3 | 0 |
| `locateAlong` | constant-M | 100,000 | 19.3 ms | 53 MiB | 3 | 0 |
| `locateAlong` | multipoint | 10,000 | 47.3 µs | 548 KiB | 3 | 0 |
| `locateAlong` | multipoint | 100,000 | 494 µs | 5.34 MiB | 3 | 0 |
| `locateAlong` | varying-M | 10,000 | 300 µs | 2.14 MiB | 3 | 0 |
| `locateAlong` | varying-M | 100,000 | 3.84 ms | 21.4 MiB | 3 | 0 |
| `locateBetween` | alternating-M | 10,000 | 16.7 ms | 39.7 MiB | 3 | 0 |
| `locateBetween` | alternating-M | 100,000 | 209 ms | 396 MiB | 1 | 0 |
| `locateBetween` | multipoint | 10,000 | 89.4 µs | 997 KiB | 3 | 0 |
| `locateBetween` | multipoint | 100,000 | 1.22 ms | 11.3 MiB | 3 | 0 |
| `locateBetween` | varying-M | 10,000 | 385 µs | 3.59 MiB | 3 | 0 |
| `locateBetween` | varying-M | 100,000 | 9.52 ms | 37.3 MiB | 3 | 0 |
