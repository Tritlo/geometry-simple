# Performance audit results

Coverage: **64 stable public functions**, **304 workloads**, at sizes 100, 400, and 1,600. The harness baseline is separate.

See [CONTRIBUTING](../../CONTRIBUTING.md#full-api-audit) for the machine, source revision, commands, workload definitions, and measurement limits.

Times below 200 ms use the median of three measured batches after a pilot call. Slower calls have one sample. Additional invocations contribute more samples when present. Allocation is cumulative per call; it is not peak memory. `>` denotes a timeout lower bound. `†` marks completed samples accompanied by a timeout. Ratios compare the same workload at 400 and 1,600.

## Slowest measured workload for each function

Selection uses time at size 1,600. These are the slowest cases in this corpus, not proven worst-case bounds.

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `area` | many-holes | 7.48 µs | 28.9 µs | 116 µs | 4.0× | 1.3 MiB |
| `boundary` | multiline | 12 µs | 44.8 µs | 234 µs | 5.2× | 1.94 MiB |
| `buffer` | line-positive | 43.7 ms | 473 ms | 7.19 s | 15.2× | 31.9 GiB |
| `bufferWithSegments` | line-16-quadrant | 53.6 ms | 493 ms | 7.89 s | 16.0× | 32.3 GiB |
| `centroid` | hole | 9.68 µs | 36.7 µs | 141 µs | 3.8× | 1.71 MiB |
| `contains` | line-polygon | 20.3 ms | 203 ms | 5.36 s | 26.5× | 14.1 GiB |
| `convexHull` | hole | 124 µs | 509 µs | 2.18 ms | 4.3× | 14 MiB |
| `coordinateDimension` | nested | 0.367 µs | 1.54 µs | 11.3 µs | 7.3× | 64 KiB |
| `coveredBy` | inside | 27.4 ms | 312 ms | 4.75 s | 15.2× | 23.1 GiB |
| `covers` | contained | 27.9 ms | 317 ms | 4.55 s | 14.3× | 23.1 GiB |
| `crosses` | inside | 27.5 ms | 352 ms | 5.2 s | 14.7× | 23.1 GiB |
| `curveLength` | multiline | 1.18 µs | 4.73 µs | 18.9 µs | 4.0× | 188 KiB |
| `decodeWKB` | mixed-collection | 6.49 µs | 26.6 µs | 146 µs | 5.5× | 1.8 MiB |
| `decodeWKT` | polygon-hole-truncated | 212 µs | 744 µs | 3.28 ms | 4.4× | 13.7 MiB |
| `difference` | contained | 32.5 ms | 376 ms | 5.45 s | 14.5× | 29.3 GiB |
| `dimension` | nested | 0.358 µs | 1.5 µs | 11 µs | 7.3× | 64 KiB |
| `disjoint` | line-polygon | 118 µs | 444 µs | 2.26 ms | 5.1× | 9.46 MiB |
| `distance` | disjoint | 3.48 ms | 26.9 ms | 204 ms | 7.6× | 473 MiB |
| `encodeWKB` | nested | 25.2 µs | 308 µs | 7.83 ms | 25.4× | 26.5 MiB |
| `encodeWKT` | polygon-hole | 88.5 µs | 333 µs | 1.65 ms | 4.9× | 10.1 MiB |
| `endPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 96.1 B |
| `envelope` | hole | 6.62 µs | 26.1 µs | 103 µs | 3.9× | 1.66 MiB |
| `equals` | equal | 12.1 ms | 121 ms | 1.85 s | 15.4× | 9.27 GiB |
| `exteriorRing` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `geometryLength` | hole | 2 µs | 7.78 µs | 29.9 µs | 3.8× | 351 KiB |
| `geometryN` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `geometryType` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.044 B |
| `interiorRingN` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `intersection` | contained | 28.1 ms | 296 ms | 4.8 s | 16.2× | 23.7 GiB |
| `intersects` | crossing-lines | 114 µs | 444 µs | 2.11 ms | 4.8× | 9.45 MiB |
| `is3D` | nested | 0.346 µs | 1.46 µs | 11.9 µs | 8.1× | 64 KiB |
| `isClosed` | closed-multiline | <0.1 µs | 0.252 µs | 1.01 µs | — | 0.342 B |
| `isEmpty` | nested | 0.322 µs | 1.42 µs | 10.8 µs | 7.6× | 64 KiB |
| `isMeasured` | nested | 0.34 µs | 1.48 µs | 11.8 µs | 8.0× | 64 KiB |
| `isRing` | closed-line | 789 µs | 7.48 ms | 102 ms | 13.6× | 518 MiB |
| `isSimple` | hole | 1.76 ms | 15.2 ms | 206 ms | 13.6× | 1.01 GiB |
| `isValid` | hole | 8.58 ms | 64.5 ms | 980 ms | 15.2× | 4.94 GiB |
| `locateAlong` | alternating-M | 72.2 µs | 283 µs | 1.33 ms | 4.7× | 3.01 MiB |
| `locateBetween` | alternating-M | 146 µs | 588 µs | 2.93 ms | 5.0× | 6.33 MiB |
| `m` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `numGeometries` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `numInteriorRings` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `numPoints` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56.1 B |
| `overlaps` | disjoint | 30 ms | 336 ms | 5.06 s | 15.1× | 25.8 GiB |
| `perimeter` | many-holes | 1.64 µs | 6.42 µs | 24.6 µs | 3.8× | 295 KiB |
| `pointM` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `pointN` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 112 B |
| `pointOnSurface` | many-holes | 8.33 µs | 34.8 µs | 156 µs | 4.5× | 1.16 MiB |
| `pointX` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32.1 B |
| `pointY` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `pointZ` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `relate` | disjoint | 30.6 ms | 351 ms | 5.04 s | 14.3× | 25.8 GiB |
| `relatePattern` | disjoint | 29.9 ms | 347 ms | 4.94 s | 14.2× | 25.7 GiB |
| `spatialDimension` | nested | 0.348 µs | 1.46 µs | 12.2 µs | 8.3× | 64 KiB |
| `startPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56.1 B |
| `symmetricDifference` | contained | 33.9 ms | 383 ms | 5.98 s | 15.6× | 30.6 GiB |
| `touches` | touching | 19.7 ms | 261 ms | 3.83 s | 14.7× | 13 GiB |
| `union` | inside | 27.4 ms | 395 ms | 4.76 s | 12.0× | 23.7 GiB |
| `withCoordinates` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `withPoint` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `within` | inside | 29.8 ms | 355 ms | 4.82 s | 13.6× | 23.1 GiB |
| `x` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `y` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `z` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |

## Every workload

### accessors

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `coordinateDimension` | collection | 0.168 µs | 0.668 µs | 2.64 µs | — | 16.9 B |
| `coordinateDimension` | empty-members | 0.201 µs | 0.772 µs | 3.07 µs | — | 16.9 B |
| `coordinateDimension` | nested | 0.367 µs | 1.54 µs | 11.3 µs | 7.3× | 64 KiB |
| `coordinateDimension` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `dimension` | collection | 0.183 µs | 0.695 µs | 2.75 µs | — | 0.801 B |
| `dimension` | empty-members | 0.181 µs | 0.694 µs | 2.74 µs | — | 0.916 B |
| `dimension` | nested | 0.358 µs | 1.5 µs | 11 µs | 7.3× | 64 KiB |
| `dimension` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.134 B |
| `endPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 96.1 B |
| `exteriorRing` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `geometryN` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `geometryType` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.044 B |
| `geometryType` | empty-members | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.064 B |
| `geometryType` | nested | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.061 B |
| `geometryType` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.064 B |
| `interiorRingN` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `is3D` | collection | 0.315 µs | 1.23 µs | 4.92 µs | 4.0× | 1.72 B |
| `is3D` | empty-members | 0.333 µs | 1.32 µs | 5.19 µs | 3.9× | 1.57 B |
| `is3D` | nested | 0.346 µs | 1.46 µs | 11.9 µs | 8.1× | 64 KiB |
| `is3D` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.141 B |
| `isClosed` | closed-multiline | <0.1 µs | 0.252 µs | 1.01 µs | — | 0.342 B |
| `isClosed` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.056 B |
| `isClosed` | multiline | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.028 B |
| `isEmpty` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.039 B |
| `isEmpty` | empty-members | 0.15 µs | 0.555 µs | 2.14 µs | — | 0.664 B |
| `isEmpty` | nested | 0.322 µs | 1.42 µs | 10.8 µs | 7.6× | 64 KiB |
| `isEmpty` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.084 B |
| `isMeasured` | collection | 0.319 µs | 1.24 µs | 4.9 µs | 3.9× | 1.71 B |
| `isMeasured` | empty-members | 0.332 µs | 1.3 µs | 5.19 µs | 4.0× | 1.52 B |
| `isMeasured` | nested | 0.34 µs | 1.48 µs | 11.8 µs | 8.0× | 64 KiB |
| `isMeasured` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.128 B |
| `m` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `numGeometries` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `numInteriorRings` | many-holes | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `numPoints` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56.1 B |
| `pointM` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `pointN` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 112 B |
| `pointX` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32.1 B |
| `pointY` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `pointZ` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `spatialDimension` | collection | 0.326 µs | 1.22 µs | 4.85 µs | 4.0× | 1.73 B |
| `spatialDimension` | empty-members | 0.332 µs | 1.3 µs | 5.13 µs | 3.9× | 1.55 B |
| `spatialDimension` | nested | 0.348 µs | 1.46 µs | 12.2 µs | 8.3× | 64 KiB |
| `spatialDimension` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.202 B |
| `startPoint` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 56.1 B |
| `withCoordinates` | line | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `withPoint` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |
| `x` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16.1 B |
| `y` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `z` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 32 B |

### codecs

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `decodeWKB` | line-XY | 1.08 µs | 3.8 µs | 20.4 µs | 5.4× | 27 KiB |
| `decodeWKB` | line-XY-truncated | 0.163 µs | 0.158 µs | 0.154 µs | — | 1.59 KiB |
| `decodeWKB` | line-XYZM | 1.92 µs | 7.81 µs | 41.8 µs | 5.4× | 52.1 KiB |
| `decodeWKB` | line-XYZM-truncated | 0.177 µs | 0.176 µs | 0.185 µs | — | 1.6 KiB |
| `decodeWKB` | mixed-collection | 6.49 µs | 26.6 µs | 146 µs | 5.5× | 1.8 MiB |
| `decodeWKB` | mixed-collection-truncated | 3.92 µs | 16.2 µs | 90.4 µs | 5.6× | 1.61 MiB |
| `decodeWKB` | nested | 5.67 µs | 22.2 µs | 113 µs | 5.1× | 1.52 MiB |
| `decodeWKB` | nested-truncated | 4.01 µs | 15.2 µs | 69.6 µs | 4.6× | 1.2 MiB |
| `decodeWKB` | polygon-hole | 2.34 µs | 7.76 µs | 35.1 µs | 4.5× | 53.4 KiB |
| `decodeWKB` | polygon-hole-truncated | 0.239 µs | 0.21 µs | 0.223 µs | — | 2.67 KiB |
| `decodeWKT` | line-XY | 60.1 µs | 246 µs | 990 µs | 4.0× | 4.83 MiB |
| `decodeWKT` | line-XY-truncated | 61.2 µs | 240 µs | 983 µs | 4.1× | 4.8 MiB |
| `decodeWKT` | line-XYZM | 90 µs | 366 µs | 1.51 ms | 4.1× | 7.64 MiB |
| `decodeWKT` | line-XYZM-truncated | 87.7 µs | 356 µs | 1.47 ms | 4.1× | 7.59 MiB |
| `decodeWKT` | mixed-collection | 56 µs | 237 µs | 1.12 ms | 4.7× | 6.41 MiB |
| `decodeWKT` | mixed-collection-truncated | 35.8 µs | 155 µs | 777 µs | 5.0× | 5.32 MiB |
| `decodeWKT` | nested | 18.9 µs | 74.6 µs | 361 µs | 4.8× | 2.26 MiB |
| `decodeWKT` | nested-truncated | 17.4 µs | 66.8 µs | 327 µs | 4.9× | 2.02 MiB |
| `decodeWKT` | polygon-hole | 199 µs | 747 µs | 3.09 ms | 4.1× | 13.7 MiB |
| `decodeWKT` | polygon-hole-truncated | 212 µs | 744 µs | 3.28 ms | 4.4× | 13.7 MiB |
| `encodeWKB` | line-XY | 2.87 µs | 4.05 µs | 17.1 µs | 4.2× | 288 KiB |
| `encodeWKB` | line-XYZM | 1.27 µs | 5.3 µs | 19.9 µs | 3.8× | 434 KiB |
| `encodeWKB` | mixed-collection | 6.02 µs | 25.1 µs | 102 µs | 4.0× | 1.01e+03 KiB |
| `encodeWKB` | nested | 25.2 µs | 308 µs | 7.83 ms | 25.4× | 26.5 MiB |
| `encodeWKB` | polygon-hole | 2.05 µs | 6.95 µs | 26.1 µs | 3.8× | 585 KiB |
| `encodeWKT` | line-XY | 26.8 µs | 105 µs | 444 µs | 4.2× | 3.41 MiB |
| `encodeWKT` | line-XYZM | 78.7 µs | 311 µs | 1.27 ms | 4.1× | 9.44 MiB |
| `encodeWKT` | mixed-collection | 28.8 µs | 118 µs | 589 µs | 5.0× | 3.67 MiB |
| `encodeWKT` | nested | 19.9 µs | 78.3 µs | 386 µs | 4.9× | 2.4 MiB |
| `encodeWKT` | polygon-hole | 88.5 µs | 333 µs | 1.65 ms | 4.9× | 10.1 MiB |

### construction

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `buffer` | line-positive | 43.7 ms | 473 ms | 7.19 s | 15.2× | 31.9 GiB |
| `buffer` | polygon-negative | 7.79 ms | 46.5 ms | 476 ms | 10.2× | 2.21 GiB |
| `buffer` | polygon-positive | 13.8 ms | 142 ms | 1.66 s | 11.7× | 8.25 GiB |
| `buffer` | polygon-zero | 16.4 ms | 207 ms | 3.15 s | 15.2× | 8.4 GiB |
| `bufferWithSegments` | line-16-quadrant | 53.6 ms | 493 ms | 7.89 s | 16.0× | 32.3 GiB |
| `bufferWithSegments` | polygon-2-quadrant | 14 ms | 122 ms | 1.69 s | 13.9× | 8.25 GiB |
| `difference` | contained | 32.5 ms | 376 ms | 5.45 s | 14.5× | 29.3 GiB |
| `difference` | crossing-lines | 15.9 ms | 121 ms | 1.47 s | 12.2× | 6.33 GiB |
| `difference` | disjoint | 116 µs | 511 µs | 2.15 ms | 4.2× | 8.27 MiB |
| `difference` | equal | 11.2 ms | 114 ms | 1.44 s | 12.6× | 7.9 GiB |
| `difference` | inside | 23.6 ms | 283 ms | 3.23 s | 11.4× | 17.2 GiB |
| `difference` | line-polygon | 13.7 ms | 117 ms | 1.55 s | 13.2× | 7.4 GiB |
| `difference` | overlap | 28.7 ms | 271 ms | 4.15 s | 15.3× | 20.7 GiB |
| `difference` | touching | 19.1 ms | 209 ms | 3.13 s | 14.9× | 11.3 GiB |
| `intersection` | contained | 28.1 ms | 296 ms | 4.8 s | 16.2× | 23.7 GiB |
| `intersection` | crossing-lines | 8.11 ms | 69.4 ms | 902 ms | 13.0× | 3.77 GiB |
| `intersection` | disjoint | 50.4 µs | 235 µs | 1.2 ms | 5.1× | 6.01 MiB |
| `intersection` | equal | 12.8 ms | 126 ms | 1.8 s | 14.3× | 9.88 GiB |
| `intersection` | inside | 23.3 ms | 265 ms | 4.02 s | 15.1× | 19.2 GiB |
| `intersection` | line-polygon | 13.3 ms | 128 ms | 1.55 s | 12.1× | 7.4 GiB |
| `intersection` | overlap | 29.3 ms | 277 ms | 4.08 s | 14.7× | 20.9 GiB |
| `intersection` | touching | 15.9 ms | 205 ms | 2.96 s | 14.4× | 10.1 GiB |
| `symmetricDifference` | contained | 33.9 ms | 383 ms | 5.98 s | 15.6× | 30.6 GiB |
| `symmetricDifference` | crossing-lines | 16 ms | 132 ms | 1.7 s | 12.9× | 6.82 GiB |
| `symmetricDifference` | disjoint | 168 µs | 706 µs | 3.26 ms | 4.6× | 10.5 MiB |
| `symmetricDifference` | equal | 13.3 ms | 119 ms | 1.65 s | 13.9× | 9.26 GiB |
| `symmetricDifference` | inside | 37.3 ms | 431 ms | 5.71 s | 13.3× | 30.6 GiB |
| `symmetricDifference` | line-polygon | 28.1 ms | 280 ms | 4.11 s | 14.7× | 20.3 GiB |
| `symmetricDifference` | overlap | 38.6 ms | 401 ms | 5.96 s | 14.8× | 31.4 GiB |
| `symmetricDifference` | touching | 21.7 ms | 285 ms | 4.3 s | 15.1× | 16.4 GiB |
| `union` | contained | 22.2 ms | 236 ms | 3.32 s | 14.0× | 16.5 GiB |
| `union` | crossing-lines | 14.5 ms | 113 ms | 1.36 s | 12.0× | 5.29 GiB |
| `union` | disjoint | 172 µs | 1.16 ms | 3.33 ms | 2.9× | 10.5 MiB |
| `union` | equal | 11.2 ms | 114 ms | 1.54 s | 13.6× | 8.08 GiB |
| `union` | inside | 27.4 ms | 395 ms | 4.76 s | 12.0× | 23.7 GiB |
| `union` | line-polygon | 25.2 ms | 244 ms | 3.6 s | 14.8× | 16.8 GiB |
| `union` | overlap | 29 ms | 292 ms | 4.31 s | 14.7× | 21.7 GiB |
| `union` | touching | 19.1 ms | 251 ms | 3.88 s | 15.5× | 13.8 GiB |

### harness

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `baseline` | scalar | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.028 B |

### measurements

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `area` | many-holes | 7.48 µs | 28.9 µs | 116 µs | 4.0× | 1.3 MiB |
| `area` | multipolygon | 8.18 µs | 24.5 µs | 97.7 µs | 4.0× | 1.1 MiB |
| `area` | polygon | 4.55 µs | 18 µs | 70.5 µs | 3.9× | 876 KiB |
| `centroid` | collection | 1.8 µs | 6.99 µs | 28 µs | 4.0× | 88.9 KiB |
| `centroid` | hole | 9.68 µs | 36.7 µs | 141 µs | 3.8× | 1.71 MiB |
| `centroid` | line | 2.23 µs | 9.02 µs | 35.4 µs | 3.9× | 238 KiB |
| `centroid` | many-holes | 7.75 µs | 29.4 µs | 115 µs | 3.9× | 1.3 MiB |
| `centroid` | multiline | 3.65 µs | 9.61 µs | 38.4 µs | 4.0× | 245 KiB |
| `centroid` | multipoint | 0.682 µs | 2.59 µs | 10 µs | 3.9× | 88.9 KiB |
| `centroid` | multipolygon | 6.51 µs | 26.3 µs | 103 µs | 3.9× | 1.12 MiB |
| `centroid` | polygon | 4.71 µs | 18.7 µs | 69.4 µs | 3.7× | 877 KiB |
| `convexHull` | collection | 68.5 µs | 267 µs | 1.12 ms | 4.2× | 6.13 MiB |
| `convexHull` | hole | 124 µs | 509 µs | 2.18 ms | 4.3× | 14 MiB |
| `convexHull` | line | 51.1 µs | 246 µs | 1.29 ms | 5.2× | 7.22 MiB |
| `convexHull` | many-holes | 62.4 µs | 260 µs | 1.06 ms | 4.1× | 6.63 MiB |
| `convexHull` | multiline | 97.7 µs | 266 µs | 1.09 ms | 4.1× | 5.91 MiB |
| `convexHull` | multipoint | 52.2 µs | 248 µs | 1.03 ms | 4.2× | 7.22 MiB |
| `convexHull` | multipolygon | 63.7 µs | 256 µs | 1.06 ms | 4.1× | 5.51 MiB |
| `convexHull` | polygon | 53.5 µs | 221 µs | 908 µs | 4.1× | 6.33 MiB |
| `curveLength` | collection | 0.224 µs | 0.909 µs | 3.64 µs | — | 17.1 B |
| `curveLength` | line | 0.978 µs | 3.91 µs | 15.2 µs | 3.9× | 175 KiB |
| `curveLength` | multiline | 1.18 µs | 4.73 µs | 18.9 µs | 4.0× | 188 KiB |
| `envelope` | collection | 3.45 µs | 13.5 µs | 53.5 µs | 4.0× | 1.1 MiB |
| `envelope` | hole | 6.62 µs | 26.1 µs | 103 µs | 3.9× | 1.66 MiB |
| `envelope` | line | 3.38 µs | 13.9 µs | 51 µs | 3.7× | 851 KiB |
| `envelope` | many-holes | 4.38 µs | 17.7 µs | 66.8 µs | 3.8× | 1.04 MiB |
| `envelope` | multiline | 3.7 µs | 14.1 µs | 55.2 µs | 3.9× | 851 KiB |
| `envelope` | multipoint | 3.1 µs | 11.7 µs | 45.8 µs | 3.9× | 851 KiB |
| `envelope` | multipolygon | 3.74 µs | 14.6 µs | 53.8 µs | 3.7× | 851 KiB |
| `envelope` | polygon | 3.3 µs | 13.2 µs | 50.5 µs | 3.8× | 852 KiB |
| `geometryLength` | collection | 0.489 µs | 1.82 µs | 7.21 µs | 4.0× | 34.1 B |
| `geometryLength` | hole | 2 µs | 7.78 µs | 29.9 µs | 3.8× | 351 KiB |
| `geometryLength` | line | 1.46 µs | 3.92 µs | 15.4 µs | 3.9× | 175 KiB |
| `geometryLength` | many-holes | 1.61 µs | 6.39 µs | 24.3 µs | 3.8× | 295 KiB |
| `geometryLength` | multiline | 1.26 µs | 4.75 µs | 18.6 µs | 3.9× | 188 KiB |
| `geometryLength` | multipoint | <0.1 µs | <0.1 µs | <0.1 µs | — | 16 B |
| `geometryLength` | multipolygon | 1.45 µs | 5.72 µs | 22.3 µs | 3.9× | 256 KiB |
| `geometryLength` | polygon | 1 µs | 3.85 µs | 14.9 µs | 3.9× | 175 KiB |
| `perimeter` | many-holes | 1.64 µs | 6.42 µs | 24.6 µs | 3.8× | 295 KiB |
| `perimeter` | multipolygon | 1.48 µs | 5.87 µs | 22.8 µs | 3.9× | 256 KiB |
| `perimeter` | polygon | 1.03 µs | 3.96 µs | 15.3 µs | 3.9× | 175 KiB |

### measures

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `locateAlong` | alternating-M | 72.2 µs | 283 µs | 1.33 ms | 4.7× | 3.01 MiB |
| `locateAlong` | constant-M | 6.01 µs | 19.2 µs | 86.6 µs | 4.5× | 868 KiB |
| `locateAlong` | multipoint | 0.65 µs | 1.98 µs | 8.31 µs | 4.2× | 88.6 KiB |
| `locateAlong` | varying-M | 2.47 µs | 9.31 µs | 42.4 µs | 4.6× | 352 KiB |
| `locateBetween` | alternating-M | 146 µs | 588 µs | 2.93 ms | 5.0× | 6.33 MiB |
| `locateBetween` | multipoint | 1.18 µs | 3.92 µs | 19.5 µs | 5.0× | 186 KiB |
| `locateBetween` | varying-M | 5.85 µs | 15.1 µs | 60 µs | 4.0× | 617 KiB |

### relations

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `contains` | contained | 27.7 ms | 315 ms | 4.42 s | 14.0× | 23.1 GiB |
| `contains` | crossing-lines | 9.03 ms | 77.5 ms | 2.21 s | 28.5× | 4.23 GiB |
| `contains` | disjoint | 49.5 µs | 225 µs | 3.11 ms | 13.9× | 6.01 MiB |
| `contains` | equal | 11.9 ms | 121 ms | 3.06 s | 25.2× | 9.27 GiB |
| `contains` | inside | 62.1 µs | 258 µs | 1.25 ms | 4.8× | 7.18 MiB |
| `contains` | line-polygon | 20.3 ms | 203 ms | 5.36 s | 26.5× | 14.1 GiB |
| `contains` | overlap | 55.5 µs | 269 µs | 1.47 ms | 5.5× | 7.15 MiB |
| `contains` | touching | 39.9 µs | 189 µs | 969 µs | 5.1× | 4.38 MiB |
| `coveredBy` | contained | 55.5 µs | 259 µs | 1.26 ms | 4.9× | 7.18 MiB |
| `coveredBy` | crossing-lines | 9 ms | 78.6 ms | 1.14 s | 14.5× | 4.23 GiB |
| `coveredBy` | disjoint | 49.6 µs | 224 µs | 1.07 ms | 4.8× | 6.01 MiB |
| `coveredBy` | equal | 12 ms | 123 ms | 1.79 s | 14.6× | 9.27 GiB |
| `coveredBy` | inside | 27.4 ms | 312 ms | 4.75 s | 15.2× | 23.1 GiB |
| `coveredBy` | line-polygon | 39.9 µs | 180 µs | 840 µs | 4.7× | 5.09 MiB |
| `coveredBy` | overlap | 55 µs | 258 µs | 1.25 ms | 4.8× | 7.15 MiB |
| `coveredBy` | touching | 41.5 µs | 226 µs | 1.15 ms | 5.1× | 4.38 MiB |
| `covers` | contained | 27.9 ms | 317 ms | 4.55 s | 14.3× | 23.1 GiB |
| `covers` | crossing-lines | 8.91 ms | 80.1 ms | 1.13 s | 14.2× | 4.23 GiB |
| `covers` | disjoint | 49.4 µs | 232 µs | 1.06 ms | 4.6× | 6.01 MiB |
| `covers` | equal | 11.8 ms | 123 ms | 1.77 s | 14.4× | 9.27 GiB |
| `covers` | inside | 61.6 µs | 296 µs | 1.25 ms | 4.2× | 7.18 MiB |
| `covers` | line-polygon | 20.7 ms | 206 ms | 2.85 s | 13.8× | 14.1 GiB |
| `covers` | overlap | 54.6 µs | 260 µs | 1.31 ms | 5.0× | 7.15 MiB |
| `covers` | touching | 51.1 µs | 189 µs | 1.01 ms | 5.3× | 4.38 MiB |
| `crosses` | contained | 27.8 ms | 312 ms | 4.54 s | 14.5× | 23.1 GiB |
| `crosses` | crossing-lines | 8.92 ms | 87.3 ms | 1.87 s | 21.4× | 4.23 GiB |
| `crosses` | disjoint | 29.1 ms | 351 ms | 4.87 s | 13.9× | 25.8 GiB |
| `crosses` | equal | 11.7 ms | 130 ms | 3.17 s | 24.3× | 9.26 GiB |
| `crosses` | inside | 27.5 ms | 352 ms | 5.2 s | 14.7× | 23.1 GiB |
| `crosses` | line-polygon | 20.5 ms | 207 ms | 5.12 s | 24.7× | 14.1 GiB |
| `crosses` | overlap | 31 ms | 332 ms | 4.81 s | 14.5× | 23.6 GiB |
| `crosses` | touching | 19.5 ms | 231 ms | 3.88 s | 16.8× | 13 GiB |
| `disjoint` | contained | 79.8 µs | 429 µs | 1.64 ms | 3.8× | 7.93 MiB |
| `disjoint` | crossing-lines | 116 µs | 450 µs | 1.98 ms | 4.4× | 9.45 MiB |
| `disjoint` | disjoint | 51.4 µs | 237 µs | 1.23 ms | 5.2× | 6.01 MiB |
| `disjoint` | equal | 57.9 µs | 275 µs | 1.48 ms | 5.4× | 7.13 MiB |
| `disjoint` | inside | 71.1 µs | 374 µs | 1.61 ms | 4.3× | 7.58 MiB |
| `disjoint` | line-polygon | 118 µs | 444 µs | 2.26 ms | 5.1× | 9.46 MiB |
| `disjoint` | overlap | 69.3 µs | 322 µs | 1.55 ms | 4.8× | 7.51 MiB |
| `disjoint` | touching | 51.6 µs | 279 µs | 1.25 ms | 4.5× | 4.74 MiB |
| `distance` | contained | 116 µs | 548 µs | 2.79 ms | 5.1× | 12.8 MiB |
| `distance` | crossing-lines | 123 µs | 516 µs | 2.37 ms | 4.6× | 10.2 MiB |
| `distance` | disjoint | 3.48 ms | 26.9 ms | 204 ms | 7.6× | 473 MiB |
| `distance` | equal | 93.9 µs | 532 µs | 2.52 ms | 4.7× | 12 MiB |
| `distance` | inside | 115 µs | 597 µs | 2.75 ms | 4.6× | 12.4 MiB |
| `distance` | line-polygon | 136 µs | 578 µs | 2.89 ms | 5.0× | 12.2 MiB |
| `distance` | overlap | 104 µs | 501 µs | 2.59 ms | 5.2× | 12.3 MiB |
| `distance` | touching | 75.7 µs | 415 µs | 1.69 ms | 4.1× | 7.33 MiB |
| `equals` | contained | 56.6 µs | 266 µs | 1.33 ms | 5.0× | 7.18 MiB |
| `equals` | crossing-lines | 9.05 ms | 79.2 ms | 1.1 s | 13.8× | 4.22 GiB |
| `equals` | disjoint | 51.3 µs | 224 µs | 1.12 ms | 5.0× | 6.01 MiB |
| `equals` | equal | 12.1 ms | 121 ms | 1.85 s | 15.4× | 9.27 GiB |
| `equals` | inside | 55.4 µs | 267 µs | 1.34 ms | 5.0× | 7.18 MiB |
| `equals` | line-polygon | 40.8 µs | 191 µs | 906 µs | 4.7× | 5.09 MiB |
| `equals` | overlap | 55.1 µs | 267 µs | 1.33 ms | 5.0× | 7.15 MiB |
| `equals` | touching | 39.8 µs | 192 µs | 1.22 ms | 6.3× | 4.38 MiB |
| `intersects` | contained | 91.4 µs | 355 µs | 1.62 ms | 4.6× | 7.93 MiB |
| `intersects` | crossing-lines | 114 µs | 444 µs | 2.11 ms | 4.8× | 9.45 MiB |
| `intersects` | disjoint | 52.6 µs | 239 µs | 1.24 ms | 5.2× | 6.01 MiB |
| `intersects` | equal | 57.8 µs | 274 µs | 1.38 ms | 5.0× | 7.13 MiB |
| `intersects` | inside | 85.5 µs | 322 µs | 1.42 ms | 4.4× | 7.58 MiB |
| `intersects` | line-polygon | 111 µs | 449 µs | 2.11 ms | 4.7× | 9.46 MiB |
| `intersects` | overlap | 70.8 µs | 310 µs | 1.58 ms | 5.1× | 7.51 MiB |
| `intersects` | touching | 51.7 µs | 284 µs | 1.34 ms | 4.7× | 4.74 MiB |
| `overlaps` | contained | 27.9 ms | 294 ms | 4.47 s | 15.2× | 23.1 GiB |
| `overlaps` | crossing-lines | 9 ms | 77 ms | 1.11 s | 14.4× | 4.23 GiB |
| `overlaps` | disjoint | 30 ms | 336 ms | 5.06 s | 15.1× | 25.8 GiB |
| `overlaps` | equal | 12 ms | 120 ms | 1.74 s | 14.5× | 9.26 GiB |
| `overlaps` | inside | 34.2 ms | 296 ms | 4.71 s | 15.9× | 23.1 GiB |
| `overlaps` | line-polygon | 20.8 ms | 204 ms | 2.89 s | 14.2× | 14.1 GiB |
| `overlaps` | overlap | 30.6 ms | 320 ms | 4.54 s | 14.2× | 23.6 GiB |
| `overlaps` | touching | 21.2 ms | 231 ms | 3.68 s | 15.9× | 13 GiB |
| `relate` | contained | 28.6 ms | 314 ms | 4.87 s | 15.5× | 23.1 GiB |
| `relate` | crossing-lines | 9.51 ms | 79.8 ms | 1.06 s | 13.3× | 4.23 GiB |
| `relate` | disjoint | 30.6 ms | 351 ms | 5.04 s | 14.3× | 25.8 GiB |
| `relate` | equal | 12.4 ms | 121 ms | 1.8 s | 14.9× | 9.26 GiB |
| `relate` | inside | 27.7 ms | 352 ms | 4.76 s | 13.5× | 23.1 GiB |
| `relate` | line-polygon | 20.9 ms | 210 ms | 2.88 s | 13.7× | 14.1 GiB |
| `relate` | overlap | 31.9 ms | 328 ms | 4.64 s | 14.2× | 23.6 GiB |
| `relate` | touching | 21.9 ms | 274 ms | 3.76 s | 13.7× | 13 GiB |
| `relatePattern` | contained | 28.6 ms | 297 ms | 4.6 s | 15.5× | 23.1 GiB |
| `relatePattern` | crossing-lines | 9.28 ms | 78.8 ms | 1.12 s | 14.3× | 4.23 GiB |
| `relatePattern` | disjoint | 29.9 ms | 347 ms | 4.94 s | 14.2× | 25.7 GiB |
| `relatePattern` | equal | 12.1 ms | 122 ms | 1.77 s | 14.5× | 9.26 GiB |
| `relatePattern` | inside | 30 ms | 312 ms | 4.58 s | 14.7× | 23.1 GiB |
| `relatePattern` | line-polygon | 20.5 ms | 210 ms | 2.86 s | 13.6× | 14.1 GiB |
| `relatePattern` | overlap | 32.4 ms | 328 ms | 4.58 s | 14.0× | 23.6 GiB |
| `relatePattern` | touching | 19.4 ms | 232 ms | 3.72 s | 16.0× | 13 GiB |
| `touches` | contained | 90 µs | 384 µs | 1.91 ms | 5.0× | 8.33 MiB |
| `touches` | crossing-lines | 9.55 ms | 78.8 ms | 1.08 s | 13.7× | 4.22 GiB |
| `touches` | disjoint | 50.9 µs | 238 µs | 1.19 ms | 5.0× | 6.01 MiB |
| `touches` | equal | 14.5 ms | 130 ms | 1.75 s | 13.4× | 9.26 GiB |
| `touches` | inside | 90.7 µs | 460 µs | 2.23 ms | 4.8× | 8.33 MiB |
| `touches` | line-polygon | 20.8 ms | 206 ms | 2.96 s | 14.3× | 14.1 GiB |
| `touches` | overlap | 91.1 µs | 393 µs | 1.98 ms | 5.1× | 8.32 MiB |
| `touches` | touching | 19.7 ms | 261 ms | 3.83 s | 14.7× | 13 GiB |
| `within` | contained | 54.9 µs | 263 µs | 1.81 ms | 6.9× | 7.18 MiB |
| `within` | crossing-lines | 9.06 ms | 80.3 ms | 1.93 s | 24.0× | 4.23 GiB |
| `within` | disjoint | 49 µs | 227 µs | 2.62 ms | 11.5× | 6.01 MiB |
| `within` | equal | 11.9 ms | 125 ms | 3.06 s | 24.5× | 9.27 GiB |
| `within` | inside | 29.8 ms | 355 ms | 4.82 s | 13.6× | 23.1 GiB |
| `within` | line-polygon | 39.8 µs | 185 µs | 1.14 ms | 6.1× | 5.09 MiB |
| `within` | overlap | 55.9 µs | 265 µs | 1.97 ms | 7.4× | 7.15 MiB |
| `within` | touching | 54.7 µs | 189 µs | 1.13 ms | 6.0× | 4.38 MiB |

### unary

| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `boundary` | collection | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.041 B |
| `boundary` | hole | <0.1 µs | <0.1 µs | <0.1 µs | — | 160 B |
| `boundary` | line | 0.614 µs | 1.9 µs | 7.51 µs | 4.0× | 151 KiB |
| `boundary` | many-holes | <0.1 µs | 0.149 µs | 0.606 µs | — | 3.27 KiB |
| `boundary` | multiline | 12 µs | 44.8 µs | 234 µs | 5.2× | 1.94 MiB |
| `boundary` | multipoint | <0.1 µs | <0.1 µs | <0.1 µs | — | 0.066 B |
| `boundary` | multipolygon | 0.545 µs | 1.3 µs | 4.76 µs | 3.6× | 67.8 KiB |
| `boundary` | polygon | <0.1 µs | <0.1 µs | <0.1 µs | — | 32.1 B |
| `isRing` | closed-line | 789 µs | 7.48 ms | 102 ms | 13.6× | 518 MiB |
| `isRing` | open-line | 0.556 µs | 1.81 µs | 7.2 µs | 4.0× | 150 KiB |
| `isSimple` | collection | 0.149 µs | 0.554 µs | 2.15 µs | — | 0.808 B |
| `isSimple` | hole | 1.76 ms | 15.2 ms | 206 ms | 13.6× | 1.01 GiB |
| `isSimple` | line | 396 µs | 3.99 ms | 59 ms | 14.8× | 104 MiB |
| `isSimple` | many-holes | 96.5 µs | 297 µs | 1.14 ms | 3.8× | 2.37 MiB |
| `isSimple` | multiline | 78.9 µs | 891 µs | 13.7 ms | 15.3× | 25.5 MiB |
| `isSimple` | multipoint | 3.82 µs | 13.6 µs | 52.8 µs | 3.9× | 400 KiB |
| `isSimple` | multipolygon | 65 µs | 194 µs | 754 µs | 3.9× | 1.76 MiB |
| `isSimple` | polygon | 976 µs | 7.57 ms | 104 ms | 13.8× | 517 MiB |
| `isValid` | collection | 1.57 µs | 5.73 µs | 23 µs | 4.0× | 7.43 B |
| `isValid` | hole | 8.58 ms | 64.5 ms | 980 ms | 15.2× | 4.94 GiB |
| `isValid` | line | 0.567 µs | 1.77 µs | 6.77 µs | 3.8× | 386 B |
| `isValid` | many-holes | 5.41 ms | 43.7 ms | 698 ms | 16.0× | 1.63 GiB |
| `isValid` | multiline | 4.14 µs | 8.74 µs | 34.8 µs | 4.0× | 300 KiB |
| `isValid` | multipoint | 1.84 µs | 3.25 µs | 13.1 µs | 4.0× | 87.5 KiB |
| `isValid` | multipolygon | 3.15 ms | 29.4 ms | 467 ms | 15.9× | 1.07 GiB |
| `isValid` | polygon | 775 µs | 7.53 ms | 106 ms | 14.1× | 520 MiB |
| `pointOnSurface` | collection | 4.36 µs | 18 µs | 91.1 µs | 5.0× | 859 KiB |
| `pointOnSurface` | hole | 9.69 µs | 34 µs | 144 µs | 4.2× | 1.11 MiB |
| `pointOnSurface` | line | 4.66 µs | 18.6 µs | 96.4 µs | 5.2× | 978 KiB |
| `pointOnSurface` | many-holes | 8.33 µs | 34.8 µs | 156 µs | 4.5× | 1.16 MiB |
| `pointOnSurface` | multiline | 5.28 µs | 21.8 µs | 106 µs | 4.9× | 1.01e+03 KiB |
| `pointOnSurface` | multipoint | 4.63 µs | 18.6 µs | 95.3 µs | 5.1× | 1.01e+03 KiB |
| `pointOnSurface` | multipolygon | 6.6 µs | 24.4 µs | 98.1 µs | 4.0× | 1.03 MiB |
| `pointOnSurface` | polygon | 5.75 µs | 19.1 µs | 77.9 µs | 4.1× | 639 KiB |

## Larger inputs

These runs cover accessors, measurements, measured locations, and codecs. Topology remains in the smaller sweep. Depth-100,000 collection codecs were not run; size 100,000 codec rows cover line vectors.

| Function | Case | Size | Time | Allocation | Completed samples | Timeouts |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `coordinateDimension` | collection | 10,000 | 17.2 µs | 21.3 B | 3 | 0 |
| `coordinateDimension` | collection | 100,000 | 234 µs | 74.7 B | 3 | 0 |
| `coordinateDimension` | empty-members | 10,000 | 21.2 µs | 22.4 B | 3 | 0 |
| `coordinateDimension` | empty-members | 100,000 | 237 µs | 77.3 B | 3 | 0 |
| `coordinateDimension` | nested | 10,000 | 76.3 µs | 480 KiB | 3 | 0 |
| `coordinateDimension` | nested | 100,000 | 1.79 ms | 4.75 MiB | 3 | 0 |
| `coordinateDimension` | polygon | 10,000 | <0.1 µs | 16.3 B | 3 | 0 |
| `coordinateDimension` | polygon | 100,000 | <0.1 µs | 16.4 B | 3 | 0 |
| `dimension` | collection | 10,000 | 17 µs | 4.74 B | 3 | 0 |
| `dimension` | collection | 100,000 | 214 µs | 92 B | 3 | 0 |
| `dimension` | empty-members | 10,000 | 17 µs | 4.8 B | 3 | 0 |
| `dimension` | empty-members | 100,000 | 210 µs | 52.1 B | 3 | 0 |
| `dimension` | nested | 10,000 | 78.1 µs | 480 KiB | 3 | 0 |
| `dimension` | nested | 100,000 | 1.92 ms | 4.75 MiB | 3 | 0 |
| `dimension` | polygon | 10,000 | <0.1 µs | 0.08 B | 3 | 0 |
| `dimension` | polygon | 100,000 | <0.1 µs | 0.23 B | 3 | 0 |
| `endPoint` | line | 10,000 | <0.1 µs | 96.2 B | 3 | 0 |
| `endPoint` | line | 100,000 | <0.1 µs | 96.2 B | 3 | 0 |
| `exteriorRing` | polygon | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `exteriorRing` | polygon | 100,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `geometryN` | collection | 10,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `geometryN` | collection | 100,000 | <0.1 µs | 16.3 B | 3 | 0 |
| `geometryType` | collection | 10,000 | <0.1 µs | 0.205 B | 3 | 0 |
| `geometryType` | collection | 100,000 | <0.1 µs | 0.288 B | 3 | 0 |
| `geometryType` | empty-members | 10,000 | <0.1 µs | 0.058 B | 3 | 0 |
| `geometryType` | empty-members | 100,000 | <0.1 µs | 0.263 B | 3 | 0 |
| `geometryType` | nested | 10,000 | <0.1 µs | 0.099 B | 3 | 0 |
| `geometryType` | nested | 100,000 | <0.1 µs | 0.528 B | 3 | 0 |
| `geometryType` | polygon | 10,000 | <0.1 µs | 0.21 B | 3 | 0 |
| `geometryType` | polygon | 100,000 | <0.1 µs | 0.371 B | 3 | 0 |
| `interiorRingN` | many-holes | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `interiorRingN` | many-holes | 100,000 | <0.1 µs | 16.2 B | 3 | 0 |
| `is3D` | collection | 10,000 | 37.3 µs | 8.47 B | 3 | 0 |
| `is3D` | collection | 100,000 | 367 µs | 89 B | 3 | 0 |
| `is3D` | empty-members | 10,000 | 38.4 µs | 8.49 B | 3 | 0 |
| `is3D` | empty-members | 100,000 | 348 µs | 145 B | 3 | 0 |
| `is3D` | nested | 10,000 | 86 µs | 384 KiB | 3 | 0 |
| `is3D` | nested | 100,000 | 925 µs | 3.94 MiB | 3 | 0 |
| `is3D` | polygon | 10,000 | <0.1 µs | 0.111 B | 3 | 0 |
| `is3D` | polygon | 100,000 | <0.1 µs | 0.448 B | 3 | 0 |
| `isClosed` | closed-multiline | 10,000 | 6.3 µs | 1.71 B | 3 | 0 |
| `isClosed` | closed-multiline | 100,000 | 62.5 µs | 16.4 B | 3 | 0 |
| `isClosed` | line | 10,000 | <0.1 µs | 0.075 B | 3 | 0 |
| `isClosed` | line | 100,000 | <0.1 µs | 0.063 B | 3 | 0 |
| `isClosed` | multiline | 10,000 | <0.1 µs | 0.055 B | 3 | 0 |
| `isClosed` | multiline | 100,000 | <0.1 µs | 0.316 B | 3 | 0 |
| `isEmpty` | collection | 10,000 | <0.1 µs | 0.105 B | 3 | 0 |
| `isEmpty` | collection | 100,000 | <0.1 µs | 0.404 B | 3 | 0 |
| `isEmpty` | empty-members | 10,000 | 16.4 µs | 3.71 B | 3 | 0 |
| `isEmpty` | empty-members | 100,000 | 168 µs | 36.9 B | 3 | 0 |
| `isEmpty` | nested | 10,000 | 86.1 µs | 384 KiB | 3 | 0 |
| `isEmpty` | nested | 100,000 | 1.31 ms | 3.94 MiB | 3 | 0 |
| `isEmpty` | polygon | 10,000 | <0.1 µs | 0.21 B | 3 | 0 |
| `isEmpty` | polygon | 100,000 | <0.1 µs | 0.34 B | 3 | 0 |
| `isMeasured` | collection | 10,000 | 30.2 µs | 8.26 B | 3 | 0 |
| `isMeasured` | collection | 100,000 | 364 µs | 86.2 B | 3 | 0 |
| `isMeasured` | empty-members | 10,000 | 38.4 µs | 8.39 B | 3 | 0 |
| `isMeasured` | empty-members | 100,000 | 341 µs | 83.6 B | 3 | 0 |
| `isMeasured` | nested | 10,000 | 91.6 µs | 384 KiB | 3 | 0 |
| `isMeasured` | nested | 100,000 | 1.23 ms | 3.94 MiB | 3 | 0 |
| `isMeasured` | polygon | 10,000 | <0.1 µs | 0.147 B | 3 | 0 |
| `isMeasured` | polygon | 100,000 | <0.1 µs | 0.451 B | 3 | 0 |
| `m` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `m` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `numGeometries` | collection | 10,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `numGeometries` | collection | 100,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `numInteriorRings` | many-holes | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `numInteriorRings` | many-holes | 100,000 | <0.1 µs | 32.3 B | 3 | 0 |
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
| `spatialDimension` | collection | 10,000 | 36.6 µs | 8.52 B | 3 | 0 |
| `spatialDimension` | collection | 100,000 | 359 µs | 92 B | 3 | 0 |
| `spatialDimension` | empty-members | 10,000 | 34.2 µs | 8.34 B | 3 | 0 |
| `spatialDimension` | empty-members | 100,000 | 338 µs | 117 B | 3 | 0 |
| `spatialDimension` | nested | 10,000 | 96.9 µs | 384 KiB | 3 | 0 |
| `spatialDimension` | nested | 100,000 | 1.26 ms | 3.94 MiB | 3 | 0 |
| `spatialDimension` | polygon | 10,000 | <0.1 µs | 0.315 B | 3 | 0 |
| `spatialDimension` | polygon | 100,000 | <0.1 µs | 0.399 B | 3 | 0 |
| `startPoint` | line | 10,000 | <0.1 µs | 56 B | 3 | 0 |
| `startPoint` | line | 100,000 | <0.1 µs | 56.1 B | 3 | 0 |
| `withCoordinates` | line | 10,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `withCoordinates` | line | 100,000 | <0.1 µs | 16 B | 3 | 0 |
| `withPoint` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `withPoint` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `x` | scalar | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `x` | scalar | 100,000 | <0.1 µs | 16 B | 3 | 0 |
| `y` | scalar | 10,000 | <0.1 µs | 16 B | 3 | 0 |
| `y` | scalar | 100,000 | <0.1 µs | 16 B | 3 | 0 |
| `z` | scalar | 10,000 | <0.1 µs | 32 B | 3 | 0 |
| `z` | scalar | 100,000 | <0.1 µs | 32 B | 3 | 0 |
| `decodeWKB` | line-XY | 10,000 | 123 µs | 158 KiB | 3 | 0 |
| `decodeWKB` | line-XY | 100,000 | 1.84 ms | 1.53 MiB | 3 | 0 |
| `decodeWKB` | line-XY-truncated | 10,000 | 0.169 µs | 1.6 KiB | 3 | 0 |
| `decodeWKB` | line-XY-truncated | 100,000 | 0.21 µs | 1.64 KiB | 3 | 0 |
| `decodeWKB` | line-XYZM | 10,000 | 354 µs | 315 KiB | 3 | 0 |
| `decodeWKB` | line-XYZM | 100,000 | 3.6 ms | 3.05 MiB | 3 | 0 |
| `decodeWKB` | line-XYZM-truncated | 10,000 | 0.165 µs | 1.59 KiB | 3 | 0 |
| `decodeWKB` | line-XYZM-truncated | 100,000 | 0.19 µs | 1.59 KiB | 3 | 0 |
| `decodeWKB` | mixed-collection | 10,000 | 4.31 ms | 11.3 MiB | 3 | 0 |
| `decodeWKB` | mixed-collection-truncated | 10,000 | 2.82 ms | 10 MiB | 3 | 0 |
| `decodeWKB` | nested | 10,000 | 1.21 ms | 9.46 MiB | 3 | 0 |
| `decodeWKB` | nested-truncated | 10,000 | 571 µs | 7.48 MiB | 3 | 0 |
| `decodeWKB` | polygon-hole | 10,000 | 281 µs | 316 KiB | 3 | 0 |
| `decodeWKB` | polygon-hole-truncated | 10,000 | 0.313 µs | 2.67 KiB | 3 | 0 |
| `decodeWKT` | line-XY | 10,000 | 7.66 ms | 30.6 MiB | 3 | 0 |
| `decodeWKT` | line-XY | 100,000 | 71.3 ms | 309 MiB | 3 | 0 |
| `decodeWKT` | line-XY-truncated | 10,000 | 7.36 ms | 30.4 MiB | 3 | 0 |
| `decodeWKT` | line-XY-truncated | 100,000 | 77.9 ms | 308 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM | 10,000 | 12.1 ms | 49 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM | 100,000 | 126 ms | 501 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM-truncated | 10,000 | 11.7 ms | 48.7 MiB | 3 | 0 |
| `decodeWKT` | line-XYZM-truncated | 100,000 | 100 ms | 498 MiB | 3 | 0 |
| `decodeWKT` | mixed-collection | 10,000 | 14.9 ms | 40.4 MiB | 3 | 0 |
| `decodeWKT` | mixed-collection-truncated | 10,000 | 14 ms | 33.3 MiB | 3 | 0 |
| `decodeWKT` | nested | 10,000 | 4.44 ms | 14.2 MiB | 3 | 0 |
| `decodeWKT` | nested-truncated | 10,000 | 4.28 ms | 12.8 MiB | 3 | 0 |
| `decodeWKT` | polygon-hole | 10,000 | 23.3 ms | 86.1 MiB | 3 | 0 |
| `decodeWKT` | polygon-hole-truncated | 10,000 | 23.2 ms | 86.1 MiB | 3 | 0 |
| `encodeWKB` | line-XY | 10,000 | 75 µs | 1.69 MiB | 3 | 0 |
| `encodeWKB` | line-XY | 100,000 | 1.33 ms | 16.8 MiB | 3 | 0 |
| `encodeWKB` | line-XYZM | 10,000 | 186 µs | 2.46 MiB | 3 | 0 |
| `encodeWKB` | line-XYZM | 100,000 | 1.95 ms | 24.5 MiB | 3 | 0 |
| `encodeWKB` | mixed-collection | 10,000 | 774 µs | 5.98 MiB | 3 | 0 |
| `encodeWKB` | nested | 10,000 | 439 ms | 1.79 GiB | 1 | 0 |
| `encodeWKB` | polygon-hole | 10,000 | 203 µs | 3.37 MiB | 3 | 0 |
| `encodeWKT` | line-XY | 10,000 | 2.65 ms | 21.2 MiB | 3 | 0 |
| `encodeWKT` | line-XY | 100,000 | 30.7 ms | 212 MiB | 3 | 0 |
| `encodeWKT` | line-XYZM | 10,000 | 9.52 ms | 57.4 MiB | 3 | 0 |
| `encodeWKT` | line-XYZM | 100,000 | 101 ms | 562 MiB | 3 | 0 |
| `encodeWKT` | mixed-collection | 10,000 | 8.69 ms | 22.8 MiB | 3 | 0 |
| `encodeWKT` | nested | 10,000 | 5.16 ms | 14.9 MiB | 3 | 0 |
| `encodeWKT` | polygon-hole | 10,000 | 11.3 ms | 62.9 MiB | 3 | 0 |
| `area` | many-holes | 10,000 | 727 µs | 8.13 MiB | 3 | 0 |
| `area` | many-holes | 100,000 | 9.43 ms | 81.3 MiB | 3 | 0 |
| `area` | multipolygon | 10,000 | 628 µs | 6.87 MiB | 3 | 0 |
| `area` | multipolygon | 100,000 | 8.21 ms | 68.7 MiB | 3 | 0 |
| `area` | polygon | 10,000 | 432 µs | 5.34 MiB | 3 | 0 |
| `area` | polygon | 100,000 | 5.99 ms | 53.4 MiB | 3 | 0 |
| `centroid` | collection | 10,000 | 199 µs | 548 KiB | 3 | 0 |
| `centroid` | collection | 100,000 | 2.71 ms | 5.34 MiB | 3 | 0 |
| `centroid` | hole | 10,000 | 784 µs | 10.7 MiB | 3 | 0 |
| `centroid` | hole | 100,000 | 8.39 ms | 107 MiB | 3 | 0 |
| `centroid` | line | 10,000 | 209 µs | 1.45 MiB | 3 | 0 |
| `centroid` | line | 100,000 | 2.87 ms | 14.5 MiB | 3 | 0 |
| `centroid` | many-holes | 10,000 | 669 µs | 8.13 MiB | 3 | 0 |
| `centroid` | many-holes | 100,000 | 7.73 ms | 81.3 MiB | 3 | 0 |
| `centroid` | multiline | 10,000 | 221 µs | 1.49 MiB | 3 | 0 |
| `centroid` | multiline | 100,000 | 3.92 ms | 14.9 MiB | 3 | 0 |
| `centroid` | multipoint | 10,000 | 60.3 µs | 548 KiB | 3 | 0 |
| `centroid` | multipoint | 100,000 | 741 µs | 5.34 MiB | 3 | 0 |
| `centroid` | multipolygon | 10,000 | 729 µs | 7.02 MiB | 3 | 0 |
| `centroid` | multipolygon | 100,000 | 9.27 ms | 70.2 MiB | 3 | 0 |
| `centroid` | polygon | 10,000 | 509 µs | 5.34 MiB | 3 | 0 |
| `centroid` | polygon | 100,000 | 6.19 ms | 53.4 MiB | 3 | 0 |
| `convexHull` | collection | 10,000 | 7.15 ms | 38.4 MiB | 3 | 0 |
| `convexHull` | collection | 100,000 | 85.6 ms | 384 MiB | 3 | 0 |
| `convexHull` | hole | 10,000 | 18.8 ms | 87.5 MiB | 3 | 0 |
| `convexHull` | hole | 100,000 | 246 ms | 874 MiB | 1 | 0 |
| `convexHull` | line | 10,000 | 8.65 ms | 45.5 MiB | 3 | 0 |
| `convexHull` | line | 100,000 | 97.6 ms | 456 MiB | 3 | 0 |
| `convexHull` | many-holes | 10,000 | 9.4 ms | 42.8 MiB | 3 | 0 |
| `convexHull` | many-holes | 100,000 | 102 ms | 435 MiB | 3 | 0 |
| `convexHull` | multiline | 10,000 | 8.33 ms | 37 MiB | 3 | 0 |
| `convexHull` | multiline | 100,000 | 82 ms | 370 MiB | 3 | 0 |
| `convexHull` | multipoint | 10,000 | 7.04 ms | 45.5 MiB | 3 | 0 |
| `convexHull` | multipoint | 100,000 | 86.9 ms | 456 MiB | 3 | 0 |
| `convexHull` | multipolygon | 10,000 | 8.39 ms | 35.4 MiB | 3 | 0 |
| `convexHull` | multipolygon | 100,000 | 105 ms | 362 MiB | 3 | 0 |
| `convexHull` | polygon | 10,000 | 7.93 ms | 39.7 MiB | 3 | 0 |
| `convexHull` | polygon | 100,000 | 90.3 ms | 396 MiB | 3 | 0 |
| `curveLength` | collection | 10,000 | 22.4 µs | 22.3 B | 3 | 0 |
| `curveLength` | collection | 100,000 | 235 µs | 85.4 B | 3 | 0 |
| `curveLength` | line | 10,000 | 90.7 µs | 1.07 MiB | 3 | 0 |
| `curveLength` | line | 100,000 | 1.15 ms | 10.7 MiB | 3 | 0 |
| `curveLength` | multiline | 10,000 | 118 µs | 1.14 MiB | 3 | 0 |
| `curveLength` | multiline | 100,000 | 2 ms | 11.4 MiB | 3 | 0 |
| `envelope` | collection | 10,000 | 340 µs | 6.87 MiB | 3 | 0 |
| `envelope` | collection | 100,000 | 5.09 ms | 68.7 MiB | 3 | 0 |
| `envelope` | hole | 10,000 | 634 µs | 10.4 MiB | 3 | 0 |
| `envelope` | hole | 100,000 | 5.42 ms | 104 MiB | 3 | 0 |
| `envelope` | line | 10,000 | 291 µs | 5.19 MiB | 3 | 0 |
| `envelope` | line | 100,000 | 2.83 ms | 51.9 MiB | 3 | 0 |
| `envelope` | many-holes | 10,000 | 424 µs | 6.49 MiB | 3 | 0 |
| `envelope` | many-holes | 100,000 | 4.14 ms | 64.9 MiB | 3 | 0 |
| `envelope` | multiline | 10,000 | 413 µs | 5.19 MiB | 3 | 0 |
| `envelope` | multiline | 100,000 | 5.52 ms | 51.9 MiB | 3 | 0 |
| `envelope` | multipoint | 10,000 | 290 µs | 5.19 MiB | 3 | 0 |
| `envelope` | multipoint | 100,000 | 3.64 ms | 51.9 MiB | 3 | 0 |
| `envelope` | multipolygon | 10,000 | 361 µs | 5.19 MiB | 3 | 0 |
| `envelope` | multipolygon | 100,000 | 5.04 ms | 51.9 MiB | 3 | 0 |
| `envelope` | polygon | 10,000 | 310 µs | 5.19 MiB | 3 | 0 |
| `envelope` | polygon | 100,000 | 2.82 ms | 51.9 MiB | 3 | 0 |
| `geometryLength` | collection | 10,000 | 45.8 µs | 44.4 B | 3 | 0 |
| `geometryLength` | collection | 100,000 | 561 µs | 155 B | 3 | 0 |
| `geometryLength` | hole | 10,000 | 208 µs | 2.14 MiB | 3 | 0 |
| `geometryLength` | hole | 100,000 | 2.51 ms | 21.4 MiB | 3 | 0 |
| `geometryLength` | line | 10,000 | 105 µs | 1.07 MiB | 3 | 0 |
| `geometryLength` | line | 100,000 | 1.29 ms | 10.7 MiB | 3 | 0 |
| `geometryLength` | many-holes | 10,000 | 177 µs | 1.79 MiB | 3 | 0 |
| `geometryLength` | many-holes | 100,000 | 2.63 ms | 17.9 MiB | 3 | 0 |
| `geometryLength` | multiline | 10,000 | 132 µs | 1.14 MiB | 3 | 0 |
| `geometryLength` | multiline | 100,000 | 2.77 ms | 11.4 MiB | 3 | 0 |
| `geometryLength` | multipoint | 10,000 | <0.1 µs | 16.1 B | 3 | 0 |
| `geometryLength` | multipoint | 100,000 | <0.1 µs | 16.2 B | 3 | 0 |
| `geometryLength` | multipolygon | 10,000 | 155 µs | 1.56 MiB | 3 | 0 |
| `geometryLength` | multipolygon | 100,000 | 2.29 ms | 15.6 MiB | 3 | 0 |
| `geometryLength` | polygon | 10,000 | 105 µs | 1.07 MiB | 3 | 0 |
| `geometryLength` | polygon | 100,000 | 1.39 ms | 10.7 MiB | 3 | 0 |
| `perimeter` | many-holes | 10,000 | 152 µs | 1.79 MiB | 3 | 0 |
| `perimeter` | many-holes | 100,000 | 2.67 ms | 17.9 MiB | 3 | 0 |
| `perimeter` | multipolygon | 10,000 | 136 µs | 1.56 MiB | 3 | 0 |
| `perimeter` | multipolygon | 100,000 | 2.17 ms | 15.6 MiB | 3 | 0 |
| `perimeter` | polygon | 10,000 | 91.5 µs | 1.07 MiB | 3 | 0 |
| `perimeter` | polygon | 100,000 | 1.49 ms | 10.7 MiB | 3 | 0 |
| `locateAlong` | alternating-M | 10,000 | 9.45 ms | 19 MiB | 3 | 0 |
| `locateAlong` | alternating-M | 100,000 | 114 ms | 188 MiB | 3 | 0 |
| `locateAlong` | constant-M | 10,000 | 803 µs | 5.5 MiB | 3 | 0 |
| `locateAlong` | constant-M | 100,000 | 24.2 ms | 53 MiB | 3 | 0 |
| `locateAlong` | multipoint | 10,000 | 58.8 µs | 548 KiB | 3 | 0 |
| `locateAlong` | multipoint | 100,000 | 573 µs | 5.34 MiB | 3 | 0 |
| `locateAlong` | varying-M | 10,000 | 323 µs | 2.14 MiB | 3 | 0 |
| `locateAlong` | varying-M | 100,000 | 5.27 ms | 21.4 MiB | 3 | 0 |
| `locateBetween` | alternating-M | 10,000 | 16.4 ms | 39.7 MiB | 3 | 0 |
| `locateBetween` | alternating-M | 100,000 | 210 ms | 396 MiB | 1 | 0 |
| `locateBetween` | multipoint | 10,000 | 89 µs | 997 KiB | 3 | 0 |
| `locateBetween` | multipoint | 100,000 | 1.29 ms | 11.3 MiB | 3 | 0 |
| `locateBetween` | varying-M | 10,000 | 433 µs | 3.59 MiB | 3 | 0 |
| `locateBetween` | varying-M | 100,000 | 11.6 ms | 37.3 MiB | 3 | 0 |
