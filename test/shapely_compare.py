#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely==2.1.2", "types-shapely==2.1.0.20260728"]
# ///
# pyright: strict
"""Compare every Simple Features export and both codecs with Shapely.

Run with uv and --probe pointing to geometry-simple-shapely-probe. The optional
--report writes method counts and complete repros as JSON. All random inputs
use the supplied seed. Unexpected mismatches give a nonzero exit status.

Contract adapters are explicit in expected_results: indices start at one,
point accessors apply to lines, ring accessors return coordinate sequences,
curve length and polygon perimeter are separate, and degenerate envelopes use
points or lines. GEOS can discard Z/M metadata from empty values; only that
exact discrepancy is counted separately.
Shapely WKT input is compared after its writer has applied its own rounding.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import json
import math
from pathlib import Path
import random
import re
import subprocess
import sys
from typing import Callable, TypeAlias, cast
import warnings

import shapely as sh
from shapely.errors import GEOSException
from shapely.geometry.base import BaseGeometry

# The stubs leave NumPy ufunc **kwargs untyped. Narrow only these scalar calls.
get_type_id = cast(Callable[[BaseGeometry], int], getattr(sh, "get_type_id"))
get_num_geometries = cast(Callable[[BaseGeometry], int], getattr(sh, "get_num_geometries"))
get_num_points = cast(Callable[[BaseGeometry], int], getattr(sh, "get_num_points"))
get_num_interior_rings = cast(Callable[[BaseGeometry], int], getattr(sh, "get_num_interior_rings"))
get_dimensions = cast(Callable[[BaseGeometry], int], getattr(sh, "get_dimensions"))
get_coordinate_dimension = cast(Callable[[BaseGeometry], int], getattr(sh, "get_coordinate_dimension"))
length = cast(Callable[[BaseGeometry], float], getattr(sh, "length"))
area = cast(Callable[[BaseGeometry], float], getattr(sh, "area"))
get_x = cast(Callable[[BaseGeometry], float], getattr(sh, "get_x"))
get_y = cast(Callable[[BaseGeometry], float], getattr(sh, "get_y"))
get_geometry = cast(Callable[[BaseGeometry, int], BaseGeometry | None], getattr(sh, "get_geometry"))
get_point = cast(Callable[[BaseGeometry, int], BaseGeometry | None], getattr(sh, "get_point"))
get_interior_ring = cast(Callable[[BaseGeometry, int], BaseGeometry | None], getattr(sh, "get_interior_ring"))
get_exterior_ring = cast(Callable[[BaseGeometry], BaseGeometry | None], getattr(sh, "get_exterior_ring"))
force_2d = cast(Callable[[BaseGeometry], BaseGeometry], getattr(sh, "force_2d"))

Value: TypeAlias = str | int | float | bool | BaseGeometry | None

# Each entry names the independent Shapely operation or the explicit adapter.
METHODS: dict[str, str] = {
    "geometryType": "geom_type.upper",
    "dimension": "get_dimensions",
    "coordinateDimension": "get_coordinate_dimension",
    "spatialDimension": "2 + has_z",
    "is3D": "has_z",
    "isMeasured": "has_m",
    "isEmpty": "is_empty",
    "x": "get_coordinates(include_z=True, include_m=True): X",
    "y": "get_coordinates(include_z=True, include_m=True): Y",
    "z": "get_coordinates(include_z=True, include_m=True): Z or None",
    "m": "get_coordinates(include_z=True, include_m=True): M or None",
    "numGeometries": "get_num_geometries",
    "geometryN": "get_geometry(index - 1), reject nonpositive indices",
    "numPoints": "get_num_points for LineString, otherwise None",
    "pointN": "get_point(index - 1) for LineString",
    "startPoint": "get_point(0) for nonempty LineString",
    "endPoint": "get_point(-1) for nonempty LineString",
    "isClosed": "is_closed for lines; all nonempty closed members for MultiLineString",
    "exteriorRing": "get_exterior_ring for nonempty Polygon, otherwise None",
    "numInteriorRings": "get_num_interior_rings for Polygon, otherwise None",
    "interiorRingN": "get_interior_ring(index - 1), reject nonpositive indices",
    "envelope": "bounds as XY point/line/polygon; empty input -> empty GeometryCollection",
    "area": "area",
    "curveLength": "sum length of linear components",
    "perimeter": "sum length of polygon components",
    "centroid": "centroid(force_2d)",
    "convexHull": "convex_hull(force_2d)",
    "encodeWKT": "from_wkt of Haskell output, structural coordinate comparison",
    "encodeWKB": "from_wkb of Haskell output, structural coordinate comparison",
    "decodeWKT": "from_wkt of source text versus typed Haskell decoding",
    "decodeAnyWKT": "from_wkt of source text versus dynamic Haskell decoding",
    "decodeWKB": "from_wkb of source bytes versus typed Haskell decoding",
    "decodeAnyWKB": "from_wkb of source bytes versus dynamic Haskell decoding",
}
LAYOUTS = ("XY", "XYZ", "XYM", "XYZM")
NUMBER = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
FAMILY = r"\b(?:GEOMETRYCOLLECTION|MULTILINESTRING|MULTIPOLYGON|MULTIPOINT|LINESTRING|POLYGON|POINT)\b"


@dataclass(frozen=True)
class Case:
    """A labelled input with a reproducible WKT representation."""

    name: str
    wkt: str
    layout: str


def lift_layout(wkt: str, layout: str) -> str:
    """Add explicit dimension tags to every member and distinct Z/M ordinates."""
    suffix = {"XY": "", "XYZ": " Z", "XYM": " M", "XYZM": " ZM"}[layout]
    extra = {"XY": "", "XYZ": " 3", "XYM": " 4", "XYZM": " 3 4"}[layout]
    coordinates = re.sub(f"({NUMBER})\\s+({NUMBER})", lambda m: m[0] + extra, wkt)
    return re.sub(FAMILY, lambda m: m[0] + suffix, coordinates)


def fixed_cases() -> list[Case]:
    """Include all families, empty members, holes, and established regressions."""
    fixtures = [
        ("point", "POINT (1 2)"),
        ("line", "LINESTRING (0 0,3 4,9 4)"),
        ("closed-line", "LINESTRING (0 0,3 4,0 0)"),
        ("hole", "POLYGON ((0 0,6 0,6 6,0 6,0 0),(1 1,3 1,3 3,1 3,1 1))"),
        ("reversed-hole", "POLYGON ((0 0,0 6,6 6,6 0,0 0),(1 1,1 3,3 3,3 1,1 1))"),
        ("concave", "POLYGON ((0 0,5 0,5 1,2 1,2 4,0 4,0 0))"),
        ("skew-hole", "POLYGON ((0 0,6 0,12 6,6 6,0 0),(2 1,4 1,6 3,4 3,2 1))"),
        ("empty-point-members", "MULTIPOINT (EMPTY,(1 2),EMPTY)"),
        ("empty-line-member", "MULTILINESTRING (EMPTY,(0 0,3 4))"),
        ("empty-polygon-member", "MULTIPOLYGON (EMPTY,((0 0,2 0,0 2,0 0)))"),
        ("nested", "GEOMETRYCOLLECTION (POINT EMPTY,GEOMETRYCOLLECTION (LINESTRING (0 0,3 4),POLYGON ((0 0,2 0,0 2,0 0))))"),
        ("empty-nested", "GEOMETRYCOLLECTION (POINT EMPTY,GEOMETRYCOLLECTION (LINESTRING EMPTY))"),
        ("empty-multi-members", "GEOMETRYCOLLECTION (MULTIPOINT EMPTY,MULTILINESTRING EMPTY,MULTIPOLYGON EMPTY,POINT (1 2))"),
        ("collinear", "MULTIPOINT ((0 0),(2 2),(1 1),(2 2))"),
        ("zero-line", "LINESTRING (7 8,7 8,7 8)"),
        ("zero-area", "POLYGON ((0 0,2 0,1 0,0 0))"),
        ("numeric-zero-line-first", "MULTILINESTRING ((1e16 1e16,1e16 1e16),(0 0,1 0))"),
        ("numeric-zero-line-last", "MULTILINESTRING ((0 0,1 0),(1e16 1e16,1e16 1e16))"),
        ("numeric-zero-collection-first", "GEOMETRYCOLLECTION (LINESTRING (1e16 1e16,1e16 1e16),LINESTRING (0 0,1 0))"),
        ("numeric-small-line-first", "MULTILINESTRING ((1e16 0,1e16 1e-20),(0 0,1 0))"),
        ("numeric-small-line-last", "MULTILINESTRING ((0 0,1 0),(1e16 0,1e16 1e-20))"),
        ("numeric-small-polygon-first", "MULTIPOLYGON (((1e16 0,10000000000000002 0,10000000000000002 1e-20,1e16 1e-20,1e16 0)),((0 0,1 0,1 1,0 1,0 0)))"),
        ("numeric-small-polygon-last", "MULTIPOLYGON (((0 0,1 0,1 1,0 1,0 0)),((1e16 0,10000000000000002 0,10000000000000002 1e-20,1e16 1e-20,1e16 0)))"),
        ("numeric-translated", "POLYGON ((1e12 1e12,1000000000001 1e12,1000000000001 1000000000001,1e12 1000000000001,1e12 1e12))"),
        ("numeric-slender", "MULTIPOINT ((0 0),(134217728 134217727),(134217729 134217728))"),
        ("numeric-small-length", "LINESTRING (0 0,1e-140 0)"),
        ("numeric-large-length", "LINESTRING (0 0,1e140 0)"),
        ("numeric-signed-zero", "POINT (-0 5e-324)"),
    ]
    fixtures.extend(("empty-" + family.lower(), family + " EMPTY") for family in ["POINT", "LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION"])
    return [Case(name + "-" + layout, lift_layout(wkt, layout), layout) for name, wkt in fixtures for layout in LAYOUTS]


def random_case(rng: random.Random, index: int) -> Case:
    """Generate bounded coordinates and valid polygon topology without GEOS construction."""
    x, y = rng.randint(-100, 100), rng.randint(-100, 100)
    width, height = rng.randint(4, 30), rng.randint(4, 30)
    ring = [(x, y), (x + width, y), (x + width, y + height), (x, y + height), (x, y)]
    if rng.choice([False, True]):
        ring.reverse()
    body = ",".join(f"{a} {b}" for a, b in ring)
    hole = f"{x+1} {y+1},{x+2} {y+1},{x+2} {y+2},{x+1} {y+2},{x+1} {y+1}"
    polygon = f"POLYGON (({body}),({hole}))"
    line = f"LINESTRING ({x} {y},{x+width} {y+height},{x-width} {y+height})"
    point = f"POINT ({x} {y})"
    second = ",".join(f"{a+200} {b}" for a, b in ring)
    families = [point, line, polygon, f"MULTIPOINT (({x} {y}),({x+1} {y+2}),({x} {y}))", f"MULTILINESTRING (({x} {y},{x+1} {y+2}),({x+3} {y},{x+3} {y+4}))", f"MULTIPOLYGON ((({body})),(({second})))", f"GEOMETRYCOLLECTION ({point},GEOMETRYCOLLECTION ({line},{polygon}))"]
    # Invertible integer maps preserve topology and add rotations and skew.
    a, b, c, d = rng.choice([(1, 1, 0, 1), (2, -1, 1, 1), (-1, 2, 2, 1), (1, 0, 0, 1), (0, -1, 1, 0)])
    wkt = re.sub(r"(-?\d+) (-?\d+)", lambda m: f"{a * int(m[1]) + b * int(m[2])} {c * int(m[1]) + d * int(m[2])}", rng.choice(families))
    layout = LAYOUTS[index % len(LAYOUTS)]
    return Case(f"random-{index}-{layout}", lift_layout(wkt, layout), layout)


def children(geometry: BaseGeometry) -> list[BaseGeometry]:
    """Return direct members only for collection families."""
    if int(get_type_id(geometry)) < 4:
        return []
    return [child for i in range(int(get_num_geometries(geometry))) if (child := get_geometry(geometry, i)) is not None]


def component_length(geometry: BaseGeometry, polygons: bool) -> float:
    """Adapt GEOS length to the package's separate curve and perimeter methods."""
    kind = int(get_type_id(geometry))
    if kind == (3 if polygons else 1):
        return float(length(geometry))
    return sum((component_length(child, polygons) for child in children(geometry)), 0.0)


def expected_envelope(geometry: BaseGeometry) -> BaseGeometry:
    """Use the package's point and line forms for degenerate XY bounds."""
    if geometry.is_empty:
        return sh.GeometryCollection()
    min_x, min_y, max_x, max_y = geometry.bounds
    if min_x == max_x and min_y == max_y:
        return sh.Point(min_x, min_y)
    if min_x == max_x or min_y == max_y:
        return sh.LineString([(min_x, min_y), (max_x, max_y)])
    return sh.envelope(force_2d(geometry))


def expected_results(geometry: BaseGeometry) -> dict[str, Value]:
    """Map every public method to Shapely, with documented family/index adapters."""
    kind = int(get_type_id(geometry))
    empty = bool(sh.is_empty(geometry))
    point_count = int(get_num_points(geometry)) if kind == 1 else None
    ring_count = int(get_num_interior_rings(geometry)) if kind == 3 else None
    member_count = int(get_num_geometries(geometry))
    planar = force_2d(geometry)
    closed = bool(sh.is_closed(geometry)) if kind == 1 else kind == 5 and bool(children(geometry)) and all(not child.is_empty and bool(sh.is_closed(child)) for child in children(geometry))
    values: dict[str, Value] = {
        "geometryType": geometry.geom_type.upper(), "dimension": int(get_dimensions(geometry)),
        "coordinateDimension": int(get_coordinate_dimension(geometry)), "spatialDimension": 3 if sh.has_z(geometry) else 2,
        "is3D": bool(sh.has_z(geometry)), "isMeasured": bool(sh.has_m(geometry)), "isEmpty": empty,
        "numGeometries": member_count, "numPoints": point_count,
        "startPoint": get_point(geometry, 0) if kind == 1 else None,
        "endPoint": get_point(geometry, -1) if kind == 1 else None,
        "isClosed": closed, "exteriorRing": get_exterior_ring(geometry) if kind == 3 and not empty else None,
        "numInteriorRings": ring_count, "envelope": expected_envelope(geometry),
        "area": float(area(geometry)), "curveLength": component_length(geometry, False),
        "perimeter": component_length(geometry, True), "centroid": sh.centroid(planar), "convexHull": sh.convex_hull(planar),
        "encodeWKT": geometry, "encodeWKB": geometry,
    }
    for i in range(member_count + 2):
        values[f"geometryN.{i}"] = get_geometry(geometry, i - 1) if i > 0 else None
    for i in range((point_count or 0) + 2):
        values[f"pointN.{i}"] = get_point(geometry, i - 1) if i > 0 and kind == 1 else None
    for i in range((ring_count or 0) + 2):
        values[f"interiorRingN.{i}"] = get_interior_ring(geometry, i - 1) if i > 0 and kind == 3 else None
    for i, row in enumerate(sh.get_coordinates(geometry, include_z=True, include_m=True)):
        for column, method in enumerate(("x", "y", "z", "m")):
            value = float(row[column])
            values[f"{method}.{i}"] = None if math.isnan(value) else value
    return values


def signature(geometry: BaseGeometry) -> tuple[object, ...]:
    """Preserve family, member order, duplicates, Z/M, and signed coordinate bits."""
    kind = int(get_type_id(geometry))
    if kind == 2:  # Ring accessors return plain coordinate vectors in Haskell.
        kind = 1
    dimensions = None if geometry.is_empty else (bool(sh.has_z(geometry)), bool(sh.has_m(geometry)))
    if kind in (0, 1):
        coords = tuple(tuple(float(value).hex() for value in row) for row in sh.get_coordinates(geometry, include_z=True, include_m=True))
        return kind, dimensions, coords
    if kind == 3:
        rings = [get_exterior_ring(geometry)] + [get_interior_ring(geometry, i) for i in range(int(get_num_interior_rings(geometry)))]
        return kind, dimensions, tuple(signature(ring) for ring in rings if ring is not None and not ring.is_empty)
    return kind, dimensions, tuple(signature(child) for child in children(geometry))


def matches(method: str, actual: str, expected: Value, strict: bool) -> bool:
    """Use output-relative tolerances for measurements and structural codec checks."""
    if actual.startswith("!"):
        return False
    if expected is None:
        return actual == "~"
    if isinstance(expected, bool):
        return actual == str(expected)
    if isinstance(expected, int):
        return actual == str(expected)
    if isinstance(expected, float):
        value = float(actual)
        if method in ("x", "y", "z", "m"):
            return value.hex() == expected.hex()
        return value == expected or math.isclose(value, expected, rel_tol=1e-10, abs_tol=0.0 if strict else 1e-12)
    if isinstance(expected, str):
        return actual == expected
    if method in ("centroid", "convexHull", "envelope") and declared_layout("WKT", actual) != "XY":
        return False
    geometry = sh.from_wkb(bytes.fromhex(actual)) if method == "encodeWKB" else sh.from_wkt(actual)
    if method == "centroid":
        if geometry.is_empty or expected.is_empty:
            return geometry.is_empty == expected.is_empty
        return matches("centroid_scalar", str(float(get_x(geometry))), float(get_x(expected)), strict) and matches("centroid_scalar", str(float(get_y(geometry))), float(get_y(expected)), strict)
    if method in ("convexHull", "envelope"):
        return bool(sh.equals_exact(sh.normalize(geometry), sh.normalize(expected), tolerance=0.0))
    return signature(geometry) == signature(expected)


def declared_layout(format_name: str, payload: str) -> str:
    """Read a root dimension tag independently from Shapely's empty metadata."""
    if format_name == "WKB":
        raw = bytes.fromhex(payload)
        tag = int.from_bytes(raw[1:5], "little" if raw[0] == 1 else "big")
        return LAYOUTS[tag // 1000]
    tag = re.match(FAMILY + r"(?:\s+(ZM|Z|M))?", payload)
    return {None: "XY", "Z": "XYZ", "M": "XYM", "ZM": "XYZM"}[tag.group(1) if tag else None]


def dropped_empty_member_tags(case: Case, format_name: str, payload: str) -> bool:
    """Recognize only the verified GEOS tag loss in the fixed empty-multi fixture."""
    if case.name != "empty-multi-members-" + case.layout or case.layout == "XY" or payload == case.wkt:
        return False
    if declared_layout(format_name, payload) != case.layout:
        return False
    if format_name == "WKT":
        return all(family + " EMPTY" in payload for family in ("MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON"))
    # This fixture has a 9-byte collection header and three 9-byte empty members.
    raw = bytes.fromhex(payload)
    return all(declared_layout("WKB", raw[offset:].hex()) == "XY" for offset in (9, 18, 27))


def describe(value: Value) -> str:
    """Use full WKT for geometry mismatch reports."""
    return str(sh.to_wkt(value, rounding_precision=-1, output_dimension=4)) if isinstance(value, BaseGeometry) else repr(value)


def main() -> int:
    """Run a bounded deterministic comparison and report every unexpected mismatch."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True, help="compiled geometry-simple-shapely-probe")
    parser.add_argument("--seed", type=int, default=20261003)
    parser.add_argument("--cases", type=int, default=1000, help="random shapes in addition to fixed fixtures")
    parser.add_argument("--report", type=Path, help="write counts and complete mismatch repros as JSON")
    args = parser.parse_args()
    probe = cast(Path, args.probe)
    seed = cast(int, args.seed)
    case_count = cast(int, args.cases)
    report = cast(Path | None, args.report)
    if case_count < 0:
        parser.error("--cases must be nonnegative")
    rng = random.Random(seed)
    cases = fixed_cases() + [random_case(rng, i) for i in range(case_count)]
    requests: list[tuple[Case, str, str, BaseGeometry]] = []
    known: Counter[str] = Counter()
    for case in cases:
        geometry = sh.from_wkt(case.wkt)
        if case.name.startswith("random-") and not geometry.is_valid:
            raise RuntimeError("Random generator produced invalid topology: " + case.wkt)
        requests.append((case, "WKT", case.wkt, geometry))
        text = str(sh.to_wkt(geometry, rounding_precision=-1, output_dimension=4))
        try:
            written_geometry = sh.from_wkt(text)
        except GEOSException:
            if not dropped_empty_member_tags(case, "WKT", text):
                raise
            known["Shapely WKT reader rejects its nested empty Z/M tags"] += 1
            written_geometry = geometry
        requests.append((case, "WKT", text, written_geometry))
        for byte_order in (0, 1):
            blob = sh.to_wkb(geometry, byte_order=byte_order, output_dimension=4, flavor="iso")
            requests.append((case, "WKB", blob.hex(), sh.from_wkb(blob)))
    completed = subprocess.run([str(probe.resolve())], input="\n".join(format_name + "\t" + payload for _, format_name, payload, _ in requests) + "\n", text=True, capture_output=True, check=True)
    lines = completed.stdout.splitlines()
    if len(lines) != len(requests):
        raise RuntimeError(f"Probe returned {len(lines)} responses for {len(requests)} requests: {completed.stderr}")
    checked: Counter[str] = Counter()
    failures: list[dict[str, str]] = []
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        for (case, format_name, payload, geometry), line in zip(requests, lines, strict=True):
            if dropped_empty_member_tags(case, format_name, payload):
                expected_error = "ERROR\tGeometry " + format_name + " has the wrong coordinate dimensions"
                if line == expected_error:
                    known["decode" + format_name + ": GEOS discarded nested empty Z/M tags"] += 1
                else:
                    failures.append({"case": case.name, "method": "decode" + format_name, "format": format_name, "input": payload, "expected": expected_error, "actual": line})
                continue
            if not line.startswith("OK\t"):
                failures.append({"case": case.name, "method": "decode" + format_name, "format": format_name, "input": payload, "expected": "successful decode", "actual": line})
                continue
            actual_fields = dict(field.split("=", 1) for field in line.split("\t")[1:])
            expected_fields = expected_results(geometry)
            expected_fields["decode" + format_name] = geometry
            expected_fields["decodeAny" + format_name] = geometry
            if actual_fields.keys() != expected_fields.keys():
                failures.append({"case": case.name, "method": "protocol", "format": format_name, "input": payload, "expected": str(sorted(expected_fields)), "actual": str(sorted(actual_fields))})
            for key, expected in expected_fields.items():
                method = key.split(".", 1)[0]
                checked[method] += 1
                actual = actual_fields.get(key, "!missing field")
                layout = declared_layout(format_name, payload)
                codec = method.startswith(("encode", "decode"))
                output_format = "WKB" if method == "encodeWKB" else "WKT"
                tags_match = not codec or (not actual.startswith("!") and declared_layout(output_format, actual) == layout)
                if tags_match and matches(method, actual, expected, case.name.startswith("numeric-")):
                    continue
                declared: dict[str, Value] = {"coordinateDimension": {"XY": 2, "XYZ": 3, "XYM": 3, "XYZM": 4}[layout], "spatialDimension": 3 if "Z" in layout else 2, "is3D": "Z" in layout, "isMeasured": "M" in layout}
                if geometry.is_empty and method in declared and matches(method, actual, declared[method], False):
                    known[method + ": GEOS discarded empty Z/M tags"] += 1
                    continue
                failures.append({"case": case.name, "method": key, "format": format_name, "input": payload, "expected": describe(expected), "actual": actual})
    missing = METHODS.keys() - checked.keys()
    if missing:
        raise RuntimeError("Methods were not exercised: " + ", ".join(sorted(missing)))
    mismatch_counts = Counter(failure["method"].split(".", 1)[0] for failure in failures)
    summary: dict[str, object] = {"shapely": sh.__version__, "geos": sh.geos_version_string, "seed": seed, "shapes": len(cases), "requests": len(requests), "methods": dict(sorted(checked.items())), "known_empty_tag_differences": dict(sorted(known.items())), "mismatch_counts": dict(sorted(mismatch_counts.items())), "mismatches": failures}
    if report is not None:
        report.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Shapely {sh.__version__}; GEOS {sh.geos_version_string}; seed {seed}; {len(cases)} shapes; {len(requests)} requests")
    for method, count in sorted(checked.items()):
        print(f"{method}: {count} comparisons [{METHODS[method]}]")
    for reason, count in sorted(known.items()):
        print(f"Expected difference: {reason}: {count}")
    print(f"Unexpected mismatches: {len(failures)}")
    for method, count in sorted(mismatch_counts.items()):
        print(f"{method}: {count} mismatches")
    for failure in failures[:20]:
        print(json.dumps(failure))
    if report is not None:
        print(f"Full report: {report}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
