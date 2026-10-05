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

The codec builders stayed unchanged. At 100,000 elements, replacing their loops
with pure `unfoldrM` or `replicateM` roughly doubled WKT time and increased WKB
multipoint time about fivefold. A mutable `replicateM` variant still added
40–60% to WKB time and several times the allocation. Those replacements removed
loop code but had a substantial cost. The original decimal rounding and exact
geometric predicates also remain.
