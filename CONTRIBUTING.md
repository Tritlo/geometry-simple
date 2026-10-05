# Contributing

## Packages and checks

The root package contains the MIT-licensed library and user documentation.
The unpublished `geometry-simple-dev` package contains tests, benchmarks, and
comparison tools. Standard-derived fixtures retain the notices in
[dev/test/SFA-TESTS.md](dev/test/SFA-TESTS.md) and
[dev/LICENSE-OGC](dev/LICENSE-OGC). They must stay outside the release archive.

Use `nix-shell -A env` for the pinned Haskell environment. Add a regression
for each bug fix. Codec changes need malformed-input and valid-edge cases.

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock geometry-simple
cabal check
cabal sdist .
python3 dev/check_sdist.py dist-newstyle/sdist/geometry-simple-*.tar.gz
```

Also build an extracted archive when package metadata or source lists change.
`nix-build -A checks --no-out-link` builds and tests both packages;
`nix-build --no-out-link` builds only the library. See the compiler matrix in
[CI](.github/workflows/ci.yml).

Use straightforward Haskell and a short dependency list. Document exported
types and functions with Haddock. State units, empty behavior, and preconditions.

```sh
fourmolu --mode inplace src/Data/Geometry.hs src/Data/Geometry/*.hs src/Data/Geometry/Topology/*.hs dev/test/*.hs dev/bench/*.hs
cabal-gild --mode format geometry-simple.cabal
cabal-gild --mode format dev/geometry-simple-dev.cabal
```

## Standard and native comparisons

The Haskell suite includes independent properties and adapted OGC SFA examples.
The fixture notice records excluded cases and source errata. The Python tools
pin Shapely 2.1.2, GEOS 3.13.1, and DuckDB 1.5.5 as development dependencies.

```sh
cabal build exe:geometry-simple-shapely-probe
geometry_probe=$(cabal list-bin exe:geometry-simple-shapely-probe)
uv run --script dev/test/shapely_compare.py --probe "$geometry_probe" --report /tmp/geometry-shapely-report.json
uv run --script dev/test/test_shapely_compare.py
uv run --script dev/test/test_duckdb_wkt.py --probe "$geometry_probe"
uv run --script dev/test/test_overlay_precision.py --probe "$geometry_probe"
uv run --no-project python dev/test/test_dev_tools.py
```

Comparisons cover all seven families in both operand orders with repeatable
seeds. Unexpected differences fail the command. Invalid binary inputs remain
diagnostic records outside pass/failure counts. Use `--phase`, `--cases`,
`--buffer-cases`, and `--seed` for focused runs. CI runs all phases.

Codec checks retain exact coordinate bits and stored member layouts. Empty
containers inherit their parent's output tag. WKT checks ignore decimal spelling
and omit parent tags for mixed collections. Point selectors retain source rows,
including NaN Z/M. DuckDB tests check uniform layouts with its stricter reader.

Constructed results must use XY. Hulls require exact vertices and counterclockwise
winding. Overlays permit equivalent line grouping, ring starts, winding, and
collinear subdivisions. They still check validity, point sets, empty families,
and non-line structure. Computed XY coordinates use an absolute tolerance of
1e-9; measurements use separate tolerances. Representative points must belong
to a nonempty component of the input's highest dimension. The harness does not
repair or snap inputs. These checks do not establish full SFA conformance.

The separate precision test perturbs polygon vertices by 1 to 16 ULPs at
several binary scales. It checks output validity and bounds area differences
from GEOS by 1e-9 times the squared coordinate magnitude. Differences must
also lie within 1e-8 times that magnitude of the input boundaries. A fixed
subnormal case uses rational orientation because native calculations underflow.
These checks permit small differences from GEOS's precision choices.

Run strict Python checks with the versions used in CI:

```sh
uv run --no-project --with shapely==2.1.2 --with types-shapely==2.1.0.20260728 --with pyright==1.1.414 --with duckdb==1.5.5 pyright dev/test/shapely_compare.py dev/test/test_shapely_compare.py dev/test/test_duckdb_wkt.py dev/test/test_dev_tools.py dev/test/test_overlay_precision.py dev/bench/report.py dev/check_sdist.py
```

## Benchmarks

Compare the same inputs, compiler, optimization, and RTS settings. Record the
source revisions and hardware with results. Keep working reports outside the
repository. Allocation is cumulative per call, not retained or peak memory.

```sh
cabal build -O1 bench:geometry-simple-bench
geometry_bench=$(cabal list-bin bench:geometry-simple-bench)
"$geometry_bench" --audit +RTS -T -RTS > /tmp/geometry-audit.csv
python3 dev/bench/report.py /tmp/geometry-audit.csv --before /tmp/geometry-before.csv > /tmp/geometry-performance.md
```

Omit `--before` without a baseline. The report checks all public functions at
sizes 100, 400, and 1,600. Missing baseline workloads have no speedup comparison.
A selector and size, such as `--audit codecs/decodeWKB 1000000`, restrict the run.
An optional final integer sets each batch's time limit in seconds (default 10).
The benchmark fully evaluates results and excludes input preparation and GC.
Use multiple shapes: dense intersections, many holes, and point-heavy inputs
can cost much more than simple overlapping polygons.

## Releases

Keep the README, Haddocks, changelog, and GEOS differences document consistent.

1. Update the version and changelog. Run the checks above.
2. Push the release commit to `main`.
3. Run `scripts/release.sh` to upload a candidate and its documentation.
4. Review the candidate, then run `scripts/release.sh --publish`.
5. Tag the release commit as `vVERSION` and push the tag.

The script requires a clean tree and HEAD equal to the remote `main` commit.
It checks archive contents before upload. Cabal uses its configured Hackage
credentials or asks for them.
