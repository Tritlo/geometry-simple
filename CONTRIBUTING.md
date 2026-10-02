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

The project uses GHC 9.14.1 by default. Use `--with-compiler=ghc-VERSION` to
select another compiler. The CI compiler matrix is in
[.github/workflows/ci.yml](https://github.com/Tritlo/geometry-simple/blob/main/.github/workflows/ci.yml).

`nix-build --no-out-link` builds the package, runs the tests, and generates
the documentation with the pinned Nix environment. Run Nix development
commands inside `nix-shell`.

## Code style

Write straightforward Haskell and keep dependencies few. Document exported
types and functions with Haddock comments in short sentences with consistent
terms. Format Haskell files with `fourmolu` and the Cabal file with
`cabal-gild`:

```sh
fourmolu --mode inplace src/Data/Geometry.hs src/Data/Geometry/*.hs test/*.hs bench/*.hs
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
2. Run `scripts/release.sh`. It uploads a package candidate and its
   documentation to Hackage.
3. Review the candidate on Hackage, then run `scripts/release.sh --publish`.

Cabal uses the Hackage credentials from its configuration, or asks for them.
