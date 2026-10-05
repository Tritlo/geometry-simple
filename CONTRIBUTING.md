# Contributing

## Packages

The root package contains the library and user documentation. The private
`geometry-simple-dev` package in `dev/` contains tests, benchmarks, and the
Shapely comparison driver. Both belong to `cabal.project`; only the root
package is published.

The library is MIT licensed. Standard-derived fixtures in the development
package retain the OGC document license and modification notice. See
[dev/test/SFA-TESTS.md](dev/test/SFA-TESTS.md) and
[dev/LICENSE-OGC](dev/LICENSE-OGC). Do not include these fixtures in the release
archive or describe them as MIT-licensed data.

## Checks

Use `nix-shell -A env` for the pinned Haskell environment. Add a regression
for each bug fix. Codec changes need malformed-input and valid-edge cases.
Run:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock geometry-simple
cabal check
cabal sdist .
python3 dev/check_sdist.py dist-newstyle/sdist/geometry-simple-*.tar.gz
```

The archive check rejects development files and components. Also build an
extracted archive when package metadata or source-file lists change.

`nix-build -A checks --no-out-link` builds the library and runs the development
tests. `nix-build --no-out-link` builds only the published library. Cabal uses
the GHC on `PATH`; `--with-compiler=ghc-VERSION` selects another compiler.
The CI compiler matrix is in [.github/workflows/ci.yml](.github/workflows/ci.yml).

## Standard and Shapely comparisons

The Haskell suite adapts the applicable OGC SFA Annex C geometry cases and
measured-location examples. These use the standard's expected results
independently of Shapely. The test notice records exclusions and source errata.

Run the differential comparison with:

```sh
cabal build exe:geometry-simple-shapely-probe
uv run --script dev/test/shapely_compare.py --probe "$(cabal list-bin exe:geometry-simple-shapely-probe)" --report /tmp/geometry-shapely-report.json
```

CI uses Shapely 2.1.2 with GEOS 3.13.1. Python and GEOS are development
dependencies only. The script pins Shapely and
uses fixed cases plus generated inputs with a repeatable seed. Unexpected
differences fail the command. The report includes each method's comparison
count and complete reproductions.

Codec checks retain member layouts, empty metadata, and exact coordinate bits.
WKT comparisons ignore decimal spelling, require uniform collection tags, and
omit parent tags for mixed collections. Point selectors compare stored source rows,
including NaN Z/M, without native point-layout conversion.

Constructed planar results must be XY. Hull checks compare exact XY geometry
and require counterclockwise winding. Overlay comparisons permit different
grouping of nonempty line components. They still check the point set, validity,
empty-result families, and non-line structure. Polygon results permit equivalent
ring starts, directions, and collinear subdivisions. XY coordinates have an
absolute tolerance of 1e-9. Representative points must lie on a nonempty input
component of the highest dimension. Their coordinates need not match GEOS.
Measurements use separate tolerances. The harness does not repair or snap inputs.

Pairs cover all seven geometry families in both argument orders. Binary
operations require valid topology; invalid binary cases remain diagnostic
records outside pass/failure counts. Known native collection defects have
specific fixtures and independent expected answers. There are no Z/M copying
exceptions for constructed results.
The tests do not establish full SFA conformance or exact agreement with every
GEOS output convention.

Use `--cases`, `--buffer-cases`, and `--seed` to control generated inputs.
`--phase` selects `existing`, `unary`, `relations`, `overlay`, or `buffer` during
development. CI and the default run every phase.

Check the adapters and Python types with:

```sh
uv run --script dev/test/test_shapely_compare.py
uv run --no-project --with shapely==2.1.2 --with types-shapely==2.1.0.20260728 --with pyright==1.1.414 --with duckdb==1.5.5 pyright dev/test/shapely_compare.py dev/test/test_shapely_compare.py dev/test/test_duckdb_wkt.py dev/check_sdist.py
```

DuckDB 1.5.5 also reads the probe's WKT and WKB output in CI. This checks
uniform collection tags, nested collections, and typed empty members against
its stricter reader. The script loads or installs the spatial extension:

```sh
uv run --script dev/test/test_duckdb_wkt.py --probe "$(cabal list-bin exe:geometry-simple-shapely-probe)"
```

## Haskell style

Use straightforward code and a short dependency list. Give internal dispatch
choices sum types; retain numeric types for counts and binary-format tags.
Document exported types and functions with Haddock. State units, empty behavior,
and preconditions when they affect callers. Avoid comments that repeat an
implementation without explaining its contract.

```sh
fourmolu --mode inplace src/Data/Geometry.hs src/Data/Geometry/*.hs src/Data/Geometry/Topology/*.hs dev/test/*.hs dev/bench/*.hs
cabal-gild --mode format geometry-simple.cabal
cabal-gild --mode format dev/geometry-simple-dev.cabal
```

## Benchmarks

Keep input construction outside the measured operation. Compare the same
compiler, optimization level, input, and RTS settings. The first command takes
a coordinate count; the second measures polygons with 100, 200, 400, and 1,000
vertices. Add a vertex count after `--topology` to select one size.

```sh
cabal run -O1 geometry-simple-bench -- 1000000 +RTS -T -RTS
cabal run -O1 geometry-simple-bench -- --topology +RTS -T -RTS
cabal run -O1 geometry-simple-bench -- --arrangements +RTS -T -RTS
```

Cases include disjoint polygons with overlapping envelopes, boundary points,
and crossing lines. Report workload sizes and distinguish total allocation
from retained memory.

`--arrangements` measures full relations, polygon predicates, distance,
intersection, and buffering at 100, 400, and 1,600 vertices. Add a vertex count
to select one size. It uses three measured trials after a warmup. Results are
fully evaluated, and input construction stays outside the timed action.

Sample audit timings on GHC 9.14.1, `-O1`, and a Ryzen 9 7950X:

| Operation and input | 400 vertices | 1,600 vertices |
| --- | ---: | ---: |
| `contains`, overlapping polygons | 0.080 ms | 0.29 ms |
| `contains`, nested polygons | 52 ms | 220 ms |
| `touches`, overlapping polygons | 0.19 ms | 0.77 ms |
| `equals`, overlapping polygons | 0.075 ms | 0.29 ms |
| `relate`, overlapping polygons | 51 ms | 244 ms |
| `intersection`, overlapping polygons | 51 ms | 233 ms |
| `distance`, disjoint polygons | 2.9 ms | 14 ms |
| `buffer`, distance 0.1 | 36 ms | 167 ms |

Inputs approximate unit circles centered at `(0,0)` and `(0.5,0)`. The nested
circle has radius 0.5 and center `(0,0)`. The disjoint circle is centered at
`(3,0)` and rotated by half a turn. Compare identical inputs and compiler
settings before attributing a timing change to an implementation change.

### Full API audit

The audit covers all 64 functions exported by the four stable public modules.
It excludes derived instances and the unstable `Internal` module. The
[earlier complete results](dev/bench/RESULTS.md) include 304 workloads at sizes 100,
400, and 1,600. Selected groups also run at 10,000 and 100,000.

The [container review](dev/bench/CONTAINERS.md) compares lists, vectors, arrays,
sequences, and integer graph keys. The audit now also includes an equal-multipoint
relation case, for a total of 305 workloads.

Build once, then run the executable so build output does not enter the CSV:

```sh
cabal build -O1 bench:geometry-simple-bench
geometry_bench=$(cabal list-bin bench:geometry-simple-bench)
"$geometry_bench" --audit +RTS -T -RTS > /tmp/geometry-audit.csv
"$geometry_bench" --audit measurements 100000 +RTS -T -RTS > /tmp/geometry-audit-large.csv
python3 dev/bench/report.py /tmp/geometry-audit.csv /tmp/geometry-audit-large.csv > /tmp/geometry-performance.md
```

Add `--before PREVIOUS.csv` to the report command to compare the same workloads
with a previous audit. The summary then selects each function's slowest case
from that previous run. It reports current time, previous time, and speedup.

Selectors match a `group/operation/case` prefix. For example,
`--audit codecs/encodeWKB/nested 10000` selects one workload. Groups are
`accessors`, `measurements`, `unary`, `relations`, `construction`, `measures`,
and `codecs`; `harness` measures loop overhead. An optional final integer
sets the time limit in seconds for each measured batch. The default is 10.
Timeouts appear in the CSV and report. Fixture preparation and GC between
batches are outside this limit and outside the measured time.

Inputs are prepared once. Each call reads an input from an `IORef` and fully
evaluates the output. This prevents reuse of a previous call's result. Calls
below 200 ms use three batches after a pilot call. Each batch targets 10 ms
and contains between 1 and 100,000 calls. Slower calls retain the pilot as one
sample. The report combines repeated
invocations and checks that every public function and workload has all three
main sizes. Fast accessors approach the loop overhead; compare their scaling,
not individual nanosecond differences. Allocation includes the harness and
is cumulative per call. It does not measure retained or peak memory.

The current run used library revision `21ae8ff`, the pinned Nix environment,
GHC 9.14.1, `-O1`, and an AMD Ryzen 9 7950X on Linux/WSL2, on 2026-10-05.
The comparison uses the earlier `5e95432` audit on the same machine and
toolchain. Six slow workloads in that baseline were repeated twice.
These are local measurements without CPU isolation, not latency guarantees.

Workload sizes have these meanings:

- Lines contain `n` coordinates. Circles have `n` vertices plus closure.
- The holed circle has `n` vertices in each of two rings. The many-hole
  polygon has `n / 4` square holes and a four-corner shell.
- Multi-lines contain `n / 2` two-point lines. Multi-polygons contain `n / 4`
  disjoint triangles. Flat and empty-member collections contain `n` points.
  The closed-multiline accessor case has `n / 4` closed square rings.
- Nested collections have depth `n`. Scalar accessors always receive one value.
- Binary cases include overlap, containment in both orders, disjointness,
  equality, touching boxes, crossing lines, and a line crossing a polygon.
  Touching boxes have `n` boundary vertices each, including subdivisions.
- Measured lines have increasing, constant, or alternating M values. Codecs
  include XY and XYZM lines, holes, mixed collections, nesting, and truncated
  input. WKB encoding also runs at depth 100,000. Other codec cases at size
  100,000 use line vectors.

The topology indexes remove repeated full scans from these workloads. For
example, a fourfold input increase from 400 to 1,600 now increases full relation,
containment, validity, and buffer costs by about four to five times. Dense
intersections can still produce quadratic work and output. Exact rational
arithmetic also remains more expensive than native floating-point geometry.
Reuse the exact geometry tests and Shapely comparisons when changing these
algorithms.

## Pull requests and releases

Explain the behavior change, its reason, and the checks that passed. Keep the
README, Haddocks, changelog, and GEOS differences document consistent with the
implementation.

1. Update the package version and changelog.
2. Push `main`, which the Hackage README links to.
3. Run `scripts/release.sh` to upload a candidate and its documentation.
4. Review the candidate, then run `scripts/release.sh --publish`.
5. Tag the release commit as `vVERSION` and push the tag.

The release script checks archive contents before upload. Cabal uses the Hackage
credentials in its configuration, or asks for them.
