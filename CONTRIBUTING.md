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
and require counterclockwise winding. Other constructions retain family and
validity checks while permitting equivalent ring starts, directions, and
collinear subdivisions. XY coordinates have an absolute tolerance of 1e-9.
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
```

Cases include disjoint polygons with overlapping envelopes, boundary points,
and crossing lines. Report workload sizes and distinguish total allocation
from retained memory.

The README timings were measured with GHC 9.14.1, `-O1`, and a Ryzen 9 7950X.
Inputs were prepared 400-vertex unit circles centered at `(0,0)` and `(0.5,0)`.
The distance case used centers `(0,0)` and `(3,0)`. Each reported slow operation
was evaluated once with its result fully forced.

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
