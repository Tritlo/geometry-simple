# Contributing

## Project structure

`src/Data/Geometry` contains the geometry representation and WKB/WKT codecs.
`test` contains format fixtures and property tests. `bench` contains the codec
and vector benchmarks. The package has no database or native library dependency.

## Tests and documentation

Add a regression test for each bug fix. Cover malformed input and valid edge
cases when changing a codec. Keep dimensional layouts, empty values, and
floating-point precision consistent with the contracts in [README.md](README.md).

Build all components before running the tests:

```sh
cabal build all
cabal test all --test-show-details=direct
cabal haddock all
cabal check
cabal sdist
```

The project defaults to GHC 9.14.1. Use `--with-compiler=ghc-VERSION` to select
another compiler. The CI compiler matrix is in
[.github/workflows/ci.yml](https://github.com/Tritlo/geometry-simple/blob/main/.github/workflows/ci.yml).

Run `nix-build --no-out-link` to build, test, and generate documentation with the
pinned Nix environment. Run Nix development commands inside `nix-shell`.

## Code style

Use straightforward Haskell and keep dependencies small. Document exported types
and functions with Haddock comments. Use short sentences and consistent terms.
Format Haskell files with `fourmolu`. Format the Cabal file with `cabal-gild`.

```sh
fourmolu --mode inplace src/Data/Geometry.hs src/Data/Geometry/*.hs test/*.hs bench/*.hs
cabal-gild --mode format geometry-simple.cabal
```

## Benchmarks

Use the same compiler, optimization level, input, and RTS options when comparing
changes. Keep input construction outside the measured operation. Report the
workload size and distinguish cumulative allocation from retained memory.

```sh
cabal run -O1 geometry-simple-bench -- 1000000 +RTS -T -RTS
```

## Pull requests

Explain what changes, why it changes, and which checks passed. Update the
changelog for user-visible changes. Update the README and Haddock when public
behavior changes. Keep unrelated changes in separate commits.

The [release instructions](README.md#release) describe candidate and published
uploads. Development and test commands do not publish anything.
