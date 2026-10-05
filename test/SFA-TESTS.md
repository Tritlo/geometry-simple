# Simple Features standard tests

The source fixtures are from OGC 06-104r4, Copyright © 2007, 2010, 2012
Open Geospatial Consortium, Inc. They are used under the license on page ii
of the linked standard. This adaptation contains modifications that OGC has
not approved or adopted.

`SFAConformanceTests.hs` adapts geometry cases T6 through T52 from
[OGC 06-104r4, Annex C.3.3](https://docs.ogc.org/is/06-104r4/06-104r4.pdf).
It uses the published coordinates and expected answers. It runs each case
with WKT input and with input passed through WKB. It excludes T10 (SRID).
T1 through T5 test SQL metadata tables and reference systems, which this library
does not implement. This is a geometry API adaptation, not SQL conformance certification.

The [OGC test-suite page](https://cite.ogc.org/teamengine/about/sfs/1.2.1/site/)
uses these cases for the SQL types-and-functions profile.
The Haskell tests call the corresponding functions directly. They use zero-based
indices. Spatial result checks allow different ring directions and starting
vertices, as the standard permits. Scalar answers remain independent of GEOS.

The tests account for these inconsistencies in the published text:

- T7: the SQL query names `lakes`. Route 75 is in `divided_routes`.
- T24: the answer prints X=53. Goose Island spans X=59 to X=67, so its
  rectangle centroid is X=63. The test uses `(63,15.5)`.
- T40: the SQL arguments are reversed. The description and expected true result
  put the house within Ashton. The test uses that direction.
- T42 and T43: the table says road 101, but the road fixture and SQL use 102.
- T50: the SQL selects Ashton. The description and expected result use
  Goose Island. The test uses Goose Island.

`MeasureTests.hs` also checks the measured-location examples in OGC 06-103r4,
section 6.1.2.6. The Shapely comparison suite checks additional inputs against
GEOS, beyond the small set of standard fixtures.
