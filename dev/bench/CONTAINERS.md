# Container review

Keep the public representation: unboxed vectors for coordinates and points,
and boxed vectors for rings and geometry members. Replace the nine-cell
relation accumulator with `Data.Vector.Unboxed.accum`. Keep the other
internal containers for now.

## Retained change

`relate` previously rebuilt a nine-element list for every topology sample.
It now uses `U.accum max` to update an unboxed vector. This removes the custom
update function. The public result remains a nine-character string. The
change adds no dependency and uses the existing geometry algorithms.

Measurements at 1,600 coordinates, with baseline and candidate runs in both
orders:

| Relation input | List accumulator | `U.accum` | Allocation before → after |
| --- | ---: | ---: | ---: |
| Equal multipoints | 1.68 ms | 1.39 ms | 6.56 → 4.11 MB |
| Overlapping polygons | 238 ms | 216 ms | 722 → 701 MB |

These runs reduced elapsed time by about 18% and 10%, respectively.
Allocation fell by 37% and 3%. MB means cumulative bytes allocated per call,
divided by one million. These figures do not measure retained memory.

Explicit mutable-vector and `STUArray` loops also reduced allocation. We use
`U.accum` because it provides the operation directly, requires less code, and
uses a dependency already in the library.

## Other usage patterns

| Code | Access pattern | Decision |
| --- | --- | --- |
| Geometry storage and codecs | Indexed access, bulk construction, complete folds | Keep the existing vectors. |
| Planar positions and segments | Projection, adjacent pairs, concatenation, early exit | Keep lists. |
| Convex hull and ring traversal | Push and pop at the front | Keep list stacks. |
| Buffer simplification | Indexed source coordinates; sequential passes over surviving indices | Keep the boxed source vector and index lists. |
| Measured-coordinate runs | Prepend, then reverse completed output | Keep lists. |
| Winding tables | Merge changes at exact Y coordinates; predecessor lookup | Keep `Map Rational Int`. |
| Overlay adjacency | Ordered coordinate lookup, edge deletion, degree checks | Keep `Map Position (Set Position)`. |
| Segment index construction | Sort and split at the median | Keep the current builder. This review did not test a packed tree or a new sorting algorithm. |

The experiments included construction, coordinate-to-integer conversion, and
complete result evaluation:

- Integer graph IDs with `IntMap` and `IntSet` reduced 100,000-edge split-path
  assembly from 233 ms to 134 ms. A complete 1,600-coordinate coincident-line
  intersection improved from 90.4 ms to 88.1 ms, with slightly more allocation.
  The conversion and additional degree helpers do not simplify the code.
- Replacing `Set.size` directly with `IntSet.size` made the 100,000-edge star
  case slower: 278 ms became 378 ms. Inspecting at most three neighbors brought
  it to 161 ms. Container operations are not interchangeable in cost.
- A sorted vector with binary search for winding prefixes changed complete
  polygon relation time by about 1%. It added a search function and retained
  the maps needed to merge changes.
- `Seq`, an unboxed vector of surviving indices, and unboxed source coordinates
  gave no consistent buffer improvement. The line-buffer runs were 2–5% slower;
  polygon-buffer differences were within about 2%.
- In a 100,000-coordinate projection and bounds fold, the list allocated
  54.4 MB. A vector pipeline that fused allocated the same amount. Boxed-array
  and sequence versions allocated 68.0 MB and 72.7 MB. Explicitly inlining a
  direct vector generator also preserved early exit. A generator that did not
  inline materialized the vector and lost that benefit.

The library documentation also describes why `Seq` is useful for access at
both ends and indexed edits, but can cost more for list-style stack operations.
See [Data.Sequence](https://hackage-content.haskell.org/package/containers-0.8/docs/Data-Sequence.html).

## Method and reproduction

Measured on 2026-10-05 with Nix GHC 9.14.1, `-O1`, and an AMD Ryzen 9 7950X
on Linux/WSL2. The baseline was `b8699e5`. Initial timings overlapped a Teams
meeting and were excluded from the figures above. The subsequent runs used
fresh baselines. Builds and benchmarks ran separately.

Inputs were forced before timing. Each invocation read its input from an
`IORef` and forced the complete result. Each process ran a pilot followed by
five measured batches. Batches targeted 30 ms, with at least one call. The
1,600-coordinate operation comparisons ran twice, reversing baseline and
candidate order, and report the median of ten batches. Smaller cases used
100 and 400 coordinates. Graph and projection cases also used 10,000 and
100,000. These are local timings without CPU isolation.

The existing API audit now includes `relations/relate/multipoint-equal`.
Use the same audit source with each library revision to repeat the retained
change's comparison:

```sh
nix-shell -A env
cabal build -O1 bench:geometry-simple-bench
geometry_bench=$(cabal list-bin bench:geometry-simple-bench)
"$geometry_bench" --audit relations/relate/multipoint-equal 1600 +RTS -T -RTS
"$geometry_bench" --audit relations/relate/overlap 1600 +RTS -T -RTS
```

The audit uses its usual adaptive batch lengths. Repeat each command and
alternate revision order. Experimental alternatives remain outside the
library; they are not additional supported implementations.

Validation passed: 717 Haskell tests with 1,000 trials per property, and
74,208 Shapely relation and predicate comparisons. There were no unexpected
mismatches. The 14 existing documented native differences were unchanged.

## Standard collection operations

The next review replaced custom accumulation and selection with `foldMap`,
`groupBy`, `Map.fromListWith`, `Set.intersection`, and `maximumBy`. Polygon
contact checks now use `Data.Graph` to count connected components. Line
endpoints use vector access instead of converting and traversing the sequence.

Representative points no longer require a separate centroid calculation.
Overlays join edges through degree-two vertices without reconstructing source
intersection nodes. These choices follow the point-set and representative-point
contracts described in [Simple Features and GEOS](../../docs/GEOS-DIFFERENCES.md).

Measurements against `41c44a8` used the same Nix toolchain and machine:

| Operation and input | Before | After |
| --- | ---: | ---: |
| Intersection of touching polygons, 1,600 vertices each | 209 ms | 148 ms |
| Intersection of a line and polygon, 1,600 coordinates each | 162 ms | 126 ms |
| Boundary of 50,000 two-point lines | 45.4 ms | 33.6 ms |
| Representative point for 50,000 two-point lines | 17.5 ms | 6.71 ms |

Boundary allocation in that multiline case fell from 170 MB to 69.1 MB.
Representative-point queries for a long line, a multipoint, or disjoint polygons
now stop at an early suitable component. Single-line boundary reads take constant
time. At 100,000 coordinates, these cases completed below one microsecond;
the old implementations took 0.53–39.8 ms. Timings this small approach harness
overhead, so the useful result is the change in traversal cost.

The affected audit groups ran at 100, 400, and 1,600 coordinates in both orders.
Additional interleaved checks put buffer, polygon validity, and polygon union
costs within about 3% of their baselines. Early larger timing differences did
not persist in those checks.

## Simpler codec primitives

The codec review now favors standard readers and vector builders. WKB uses
`Data.Binary.Get.getDoublele` and `getDoublebe` for ordinates, and `U.replicateM`
for coordinate buffers and multipoints. This removes 78 lines from the module:
manual byte shifts, a separate multipoint reader, and its mutable buffer loop.
Point and line decoding share one ordinate reader. Child headers use the same
validation as other geometries.

WKT uses `V.unfoldrM` to build vectors. `StateT` carries the inferred layout.
This removes 9 lines, including the custom buffer allocation, growth, writes,
and freeze. The two changes remove 87 library lines and add no dependencies.

Measurements against `9fca2d3`, on the same machine and Nix toolchain:

| Decode input | 1,000 coordinates, before → after | 100,000 coordinates, before → after | Allocation at 100,000, before → after |
| --- | ---: | ---: | ---: |
| WKB XY line | 9.4 → 19.3 µs | 1.33 → 26.7 ms | 1.60 → 36.8 MB |
| WKB XY multipoint | 23.4 → 49.4 µs | 3.03 → 35.9 ms | 8.90 → 68.1 MB |
| WKT XY line | 611 → 653 µs | 70.2 → 139 ms | 324 → 343 MB |
| WKT XY multipoint | 723 → 670 µs | 83.0 → 148 ms | 375 → 386 MB |

At 10,000 coordinates, WKB lines took 0.090 → 0.890 ms and multipoints took
0.252 → 1.98 ms. Small-input timing differences include machine noise. These
changes reduce implementation complexity but have a substantial cost for bulk
decoding. Allocation is cumulative per call, not retained memory.

The runs used 100, 1,000, 10,000, and 100,000 coordinates. Each process forced
the encoded input before timing. It read that input through an `IORef` and
forced each decoded result. A pilot preceded five measured calls. Two runs
reversed candidate order; the table reports medians of ten samples. Builds
finished before measurements started. There was no CPU isolation.

XY fixtures use `(i, sin (i / 10))`. Multipoints use the same coordinates as
lines. A mixed multipoint fixture alternates XY, XYZM, and empty XYM points.
At 100,000 mixed points, WKB decoding changed from 3.35 ms to 42.1 ms and
allocation changed from 15.6 MB to 76.4 MB. The existing API audit can repeat
the line measurements:

```sh
nix-shell -A env
cabal build -O1 bench:geometry-simple-bench
geometry_bench=$(cabal list-bin bench:geometry-simple-bench)
"$geometry_bench" --audit codecs/decodeWKB/line-XY 100000 +RTS -T -RTS
"$geometry_bench" --audit codecs/decodeWKT/line-XY 100000 +RTS -T -RTS
```

Smaller replacements were less useful. Retaining manual byte parsing and
changing only the multipoint loop to pure or mutable `replicateM` saved 6 or
2 lines. Running a standard reader separately at each byte offset saved
30 lines, but retained the custom buffer loop and allocated 169 MB for the
100,000-point fixture. The complete WKB replacement is simpler.

The exact WKT decimal conversion remains. It preserves signed zero and
subnormals and accepts WKT's decimal syntax.
