# Contributing

## Project structure

`src/Data/Geometry` has the geometry types, the WKB and WKT codecs, and the
Simple Features operations. `test` has format fixtures and property tests.
`bench` has the codec and vector benchmarks. The package has no database or
native library dependency.

## Tests and documentation

Add a regression test for each bug fix. When you change a codec, cover
malformed input and valid edge cases. Keep coordinate dimensions, empty values,
and floating-point precision consistent with [README.md](README.md).

Run these checks before you open a pull request:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock all
cabal check
cabal sdist
```

Cabal uses the `ghc` on your `PATH`. Use `--with-compiler=ghc-VERSION` to
select another compiler. The CI compiler matrix is in
[.github/workflows/ci.yml](https://github.com/Tritlo/geometry-simple/blob/main/.github/workflows/ci.yml).

`nix-build --no-out-link` builds the package, runs the tests, and generates
the documentation with the pinned Nix environment.

### Shapely comparison

The Haskell suite includes the applicable geometry tests from OGC SFA
Annex C.3.3. [test/SFA-TESTS.md](test/SFA-TESTS.md) lists their scope and the
corrections to inconsistent source examples. These tests use the standard's
expected results independently of Shapely.

The comparison tests check GEOS-compatible operations and both codec formats
against Shapely. Python and GEOS are test dependencies only. Queries for
measured locations use the OGC examples because Shapely does not expose them.
Use `nix-shell -A env` for the pinned Haskell environment, then run:

```sh
cabal build -fshapely-tests exe:geometry-simple-shapely-probe
uv run --script test/shapely_compare.py --probe "$(cabal list-bin -fshapely-tests exe:geometry-simple-shapely-probe)" --report /tmp/geometry-shapely-report.json
```

The script pins its Python dependencies. It uses fixed edge cases and generated
geometries with a repeatable seed. It reports each method's comparison count
and fails on unexpected differences. It checks selectors,
hull layouts and vertex order, envelopes, empty metadata, and total geometry
length directly. Curve lengths and polygon perimeters have separate checks.
Raw geometry results include every point and ring layout. This prevents writer
normalization from hiding decoder differences. WKT comparisons check structural
tokens and exact source ordinates separately from numeric formatting. Codec
fixtures check accepted and rejected inputs without running planar operations
on non-finite coordinates. Numeric measurements use a tolerance; finite
coordinate round trips retain exact bits.

One named hull case records GEOS's choice of Z among duplicate XY positions
separately. It still checks XY coordinates and vertex order. Other hull
comparisons require matching layouts and ordinates.

One fixed overlay case accepts a choice between conflicting input Z/M tuples
at coincident vertices. GEOS uses an unstable sort to choose these tuples.
The test still requires matching metadata and XY geometry, and rejects
invented ordinate values. The report retains both results.
`test/test_shapely_compare.py` checks these restrictions.
Use `--cases` and `--seed` to change the generated inputs.

Paired cases cover every ordered pair of geometry families. They check
DE-9IM matrices, predicates, distance, and overlays. Buffer cases have a
separate `--buffer-cases` count because their segment arrangements are larger.
`--phase` selects `existing`, `unary`, `relations`, `overlay`, or `buffer`
during development. The default and CI run every phase.

Constructed results must match the expected family and layout. XY comparisons
allow an absolute error of `1e-9`; scalar measurements use a separate
tolerance. The report lists known native differences separately. Binary
operations require valid topology. Cases with invalid binary inputs remain
in the report but do not count as passed comparisons.

Type-check the Python script in strict mode with:

```sh
uv run --no-project --with shapely==2.1.2 --with types-shapely==2.1.0.20260728 --with pyright==1.1.414 pyright test/shapely_compare.py test/test_shapely_compare.py
uv run --script test/test_shapely_compare.py
```

## Code style

Write straightforward Haskell and keep the dependency list short. Document
exported types and functions with Haddock comments in short sentences with
consistent terms. Format Haskell files with `fourmolu` and the Cabal file with
`cabal-gild`:

```sh
fourmolu --mode inplace src/Data/Geometry.hs src/Data/Geometry/*.hs src/Data/Geometry/Topology/*.hs test/*.hs bench/*.hs
cabal-gild --mode format geometry-simple.cabal
```

## Benchmarks

Use the same compiler, optimization level, input, and RTS options when you
compare changes. Keep input construction outside the measured operation.
Report the workload size, and keep cumulative allocation separate from
retained memory.

```sh
cabal run -O1 geometry-simple-bench -- 1000000 +RTS -T -RTS
```

The first argument is the number of XY coordinates.

## Pull requests

Explain what changes, why, and which checks passed. Update the changelog for
user-visible changes. Update the README and the Haddock comments when public
behavior changes. Keep unrelated changes in separate commits.

## Releases

1. Update the version in `geometry-simple.cabal` and add a changelog entry.
2. Push `main`. The README on Hackage links to files on `main`.
3. Run `scripts/release.sh`. It uploads a package candidate and its
   documentation to Hackage.
4. Review the candidate on Hackage, then run `scripts/release.sh --publish`.
5. Tag the release commit as `vVERSION` and push the tag.

Cabal uses the Hackage credentials from its configuration, or asks for them.
