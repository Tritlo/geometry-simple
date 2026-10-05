# Release review decisions

## Changes made

- Keep tests, benchmarks, the Shapely driver, and OGC-derived fixtures in the
  private development package. Publish only the MIT library and user docs.
  Check the actual source archive in CI and before upload.
- Use sum types for WKT family dispatch and internal topological dimensions.
  Remove the dimension constructor-order dependency and the `recurse = go` alias.
- Add direct `Point` ordinate accessors and expose `withPoint` and
  `withCoordinates` through the stable geometry module.
- Preserve stored layouts and NaN Z/M in point observers.
- Construct planar results in XY. Remove the GEOS-specific ordinate model and
  zero-buffer copying rules. Use counterclockwise polygon shells and clockwise
  holes, with lexicographic XY hull starts and endpoints.
- Keep `intersects` and point queries on direct paths. Index graph adjacency
  during ring and path walks instead of rescanning the full edge set each step.
- Shorten the README and changelog. Keep numerical and compatibility details in
  the user-facing GEOS differences document.

## Findings that do not justify the proposed change

The per-member layout representation and topology scope were requested. They
support mixed WKB values and the intended seven-family Simple Features core.
Returning to a single type parameter would change that scope.

Public dimensions and indices are numeric values. WKB family tags are encoded
integers. These uses differ from internal mode switches and do not need new
public wrapper types. Zero-based indices fit the Haskell vector API. The SQL
test adaptation documents its index conversion.

WKT multi-geometries have one coordinate layout. Mixed members must therefore
be promoted to their combined layout, with NaN for missing Z/M. This conversion
is documented; preserving separate layouts would require another format or
geometry family. WKB preserves member layouts, but polygon rings also share
one layout. The unreadable mixed-collection WKT was a separate writer defect
and is fixed.

The two orientation routines have different domains. The hull uses a fast
`Double` test with an exact fallback. Topology already has rational positions
and calculates the determinant directly. Combining them would add abstraction
without removing the numerical distinction.

Compensated sums fix demonstrated centroid cancellation errors. Keep their
regressions and numerical limits. Source imports should expose what each module
uses; importing `Geometry` from the public module is not itself a defect.

The standard defines an envelope by its bounding rectangle corners. Flat
bounds can therefore give a degenerate polygon. Keep that behavior documented.
Nonfinite coordinates are accepted by the codecs for storage; topology has a
finite-XY precondition. Adding repeated validation to every operation would
change the chosen API contract.

The removed zero-buffer implementation contained one `error`. The two remaining
overlay errors assert graph invariants: closed selected boundaries and holes
inside exterior rings. No public-input reproducer was established. Returning
an empty result on those paths would hide a graph-construction bug.

A different polygon winding is not by itself a topology defect. OGC common
architecture describes counterclockwise exteriors viewed from the top; the SQL
test annex permits either winding. The library now states its XY convention
explicitly. Ring starts and two-point ordering are deterministic API choices.

## Licensing

The published package is MIT licensed. OGC fixtures retain their own license
and notices in `dev/`; the root package does not relicense them. The release
archive excludes both those fixtures and the development package. A repository
may contain separately licensed development material, but its terms must remain
clear. See `LICENSE-OGC` and `test/SFA-TESTS.md` for the source notices.
