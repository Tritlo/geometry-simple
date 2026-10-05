#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely==2.1.2", "types-shapely==2.1.0.20260728"]
# ///
# pyright: strict
"""Compare the Simple Features core and both codecs with Shapely.

Run with uv and --probe pointing to geometry-simple-shapely-probe. --report
writes method counts and complete reproductions as JSON. Random inputs use
the supplied seed. Unexpected differences give a nonzero exit status.

Codecs retain strict member layouts, type tags, empty values, and coordinate
bits. WKT ignores numeric spelling and omits parent collection dimension tags.
Point observers compare stored native rows, including NaN Z/M. Constructed
planar results must be XY. Hulls compare exact XY geometry and must run
counterclockwise. Other polygon results compare geometry independently of
ring starts, winding, and equivalent collinear subdivisions.

Topology checks predicates, DE-9IM matrices, family, layout, and validity.
Constructed XY coordinates allow at most 1e-9 absolute error. Extra nearly
collinear vertices also require bounded area and length differences and a
Hausdorff check with each segment split into quarters. Inputs are never
snapped or repaired. Distance uses a relative tolerance without an absolute
allowance. Nonfinite XY inputs run codec checks only.

GeometryCollection simplicity calls GEOSisSimple_r because Shapely overrides
that result. Binary operations require valid topology; invalid binary cases
remain in the report outside pass/failure counts. Named native relation and
symmetric-difference defects require exact operands and independent expected
results. Named native empty-operation errors require an exact empty family.
--phase selects groups during development; CI and the default run all groups.
"""

from __future__ import annotations

import argparse
from collections import Counter
import ctypes
from dataclasses import asdict, dataclass
import json
import math
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
from typing import Callable, TypeAlias, cast
import warnings

import shapely as sh
from shapely.errors import GEOSException
from shapely.geometry import LinearRing
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
get_interior_ring = cast(Callable[[BaseGeometry, int], BaseGeometry | None], getattr(sh, "get_interior_ring"))
get_exterior_ring = cast(Callable[[BaseGeometry], BaseGeometry | None], getattr(sh, "get_exterior_ring"))
hausdorff_distance = cast(Callable[[BaseGeometry, BaseGeometry, float], float], getattr(sh, "hausdorff_distance"))
force_2d = cast(Callable[[BaseGeometry], BaseGeometry], getattr(sh, "force_2d"))

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
    "pointX": "stored point X or None for empty and non-point inputs",
    "pointY": "stored point Y or None for empty and non-point inputs",
    "pointZ": "stored point Z or None when absent",
    "pointM": "stored point M or None when absent",
    "numGeometries": "get_num_geometries",
    "geometryN": "get_geometry(index), reject negative indices",
    "numPoints": "get_num_points for LineString, otherwise None",
    "pointN": "stored LineString row and layout, reject negative indices",
    "startPoint": "first stored LineString row and layout",
    "endPoint": "last stored LineString row and layout",
    "isClosed": "is_closed",
    "exteriorRing": "get_exterior_ring for Polygon, otherwise None",
    "numInteriorRings": "get_num_interior_rings for Polygon, otherwise None",
    "interiorRingN": "get_interior_ring(index), reject negative indices",
    "envelope": "envelope",
    "area": "area",
    "geometryLength": "length",
    "curveLength": "sum length of linear components",
    "perimeter": "sum length of polygon components",
    "centroid": "centroid",
    "convexHull": "convex_hull XY geometry, plus counterclockwise output rings",
    "encodeWKT": "native writer tokens without collection dimension tags, and exact source ordinates",
    "encodeWKB": "native writer ISO tags, structure, and coordinate bits",
    "decodeWKT": "from_wkt versus raw Haskell structure",
    "decodeWKB": "from_wkb versus raw Haskell structure",
    "constructGeometry": "native polygon constructor versus raw Haskell structure",
}
LAYOUTS = ("XY", "XYZ", "XYM", "XYZM")
NUMBER = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
FAMILY = r"\b(?:GEOMETRYCOLLECTION|MULTILINESTRING|MULTIPOLYGON|MULTIPOINT|LINESTRING|POLYGON|POINT)\b"


@dataclass(frozen=True)
class Case:
    """A labelled input with a reproducible WKT representation."""

    name: str
    wkt: str
    codec_only: bool = False


@dataclass(frozen=True)
class Request:
    """One input and the native reader result for that exact input."""

    case: Case
    format_name: str
    payload: str
    geometry: BaseGeometry | None
    error: str | None = None


@dataclass(frozen=True)
class Shape:
    """A geometry structure with explicit layouts and exact ordinate values."""

    kind: int
    layout: str
    coordinates: tuple[tuple[str, ...], ...] = ()
    children: tuple[Shape, ...] = ()


Value: TypeAlias = str | int | float | bool | BaseGeometry | Shape | None


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
        ("empty-polygon-rings", "POLYGON (EMPTY,EMPTY)"),
        ("empty-polygon-hole", "POLYGON ((0 0,2 0,0 2,0 0),EMPTY)"),
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
    return [Case(name + "-" + layout, lift_layout(wkt, layout)) for name, wkt in fixtures for layout in LAYOUTS]


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
    if index % 5 == 0:
        other_layout = rng.choice(LAYOUTS)
        mixed = f"GEOMETRYCOLLECTION ({lift_layout(wkt, layout)},{lift_layout(point, other_layout)})"
        return Case(f"random-{index}-mixed", mixed)
    return Case(f"random-{index}-{layout}", lift_layout(wkt, layout))


def codec_cases() -> list[Case]:
    """Exercise native reader acceptance without requiring valid finite topology."""
    fixtures = [
        ("inferred-z-point", "POINT (1 2 3)", "XYZ"),
        ("inferred-zm-point", "POINT (1 2 3 4)", "XYZM"),
        ("inferred-z-line", "LINESTRING (0 0 5,1 1 9)", "XYZ"),
        ("inferred-zm-line", "LINESTRING (0 0 5 6,1 1 9 10)", "XYZM"),
        ("attached-z", "POINTZ (1 2 3)", "XYZ"),
        ("untagged-z-child", "GEOMETRYCOLLECTION Z (POINT (1 2 3))", "XYZ"),
        ("untagged-m-child", "GEOMETRYCOLLECTION M (POINT (1 2 3))", "XYM"),
        ("empty-multi-other-layout", "GEOMETRYCOLLECTION (MULTIPOINT M EMPTY,POINT (1 2))", "XY"),
        ("singleton-line", "LINESTRING (0 0)", "XY"),
        ("unclosed-ring", "POLYGON ((0 0,1 0,0 1))", "XY"),
        ("two-coordinate-ring", "POLYGON ((0 0,0 0))", "XY"),
        ("three-coordinate-ring", "POLYGON ((0 0,1 0,0 0))", "XY"),
        ("ring-closes-in-xy", "POLYGON Z ((0 0 1,1 0 2,0 0 3))", "XYZ"),
        ("empty-shell-and-hole", "POLYGON (EMPTY,EMPTY)", "XY"),
        ("empty-shell-nonempty-hole", "POLYGON (EMPTY,(0 0,1 0,0 0))", "XY"),
        ("empty-hole", "POLYGON ((0 0,2 0,0 2,0 0),EMPTY)", "XY"),
        ("mixed-multipoint-syntax", "MULTIPOINT (0 0,(1 1))", "XY"),
        ("empty-then-flat-multipoint", "MULTIPOINT (EMPTY,1 1)", "XY"),
        ("empty-then-bracketed-multipoint", "MULTIPOINT (EMPTY,(1 1))", "XY"),
        ("partial-nan-x", "POINT (NaN 1)", "XY"),
        ("partial-nan-y", "POINT (1 NaN)", "XY"),
        ("all-nan-point", "POINT (NaN NaN)", "XY"),
        ("nan-xy-finite-z", "POINT Z (NaN NaN 3)", "XYZ"),
        ("nan-xy-finite-zm", "POINT ZM (NaN NaN 3 4)", "XYZM"),
        ("infinities", "POINT (Inf -Inf)", "XY"),
        ("infinity-spelling", "POINT (Infinity 2)", "XY"),
        ("signed-nan", "POINT (+nan -nan)", "XY"),
        ("overflow", "POINT (1e309 -1e309)", "XY"),
        ("underflow", "POINT (1e-9999 -1e-9999)", "XY"),
        ("nonfinite-line", "LINESTRING (0 0,NaN Infinity)", "XY"),
        ("inconsistent-arity", "LINESTRING (0 0,1 1 2)", "XY"),
        ("trailing-wkt", "POINT (1 2) POINT (3 4)", "XY"),
        ("trailing-semicolon", "POINT (1 2);", "XY"),
        ("missing-exponent", "POINT (1e 2)", "XY"),
    ]
    return [Case("codec-" + name, text, codec_only=name not in {"empty-shell-and-hole", "empty-hole", "empty-multi-other-layout"}) for name, text, _ in fixtures] + [
        Case("mixed-nonempty-layouts", "GEOMETRYCOLLECTION (POINT Z (1 2 3),POINT (4 5))"),
        Case("empty-atomic-other-layout", "GEOMETRYCOLLECTION (POINT Z EMPTY,POINT (4 5))"),
        Case("mixed-z-m-layouts", "GEOMETRYCOLLECTION (POINT Z (1 2 3),POINT M (4 5 6))"),
        Case("mixed-nested-layouts", "GEOMETRYCOLLECTION (GEOMETRYCOLLECTION (POINT (1 2),POINT M (3 4 5)),POINT Z (6 7 8))"),
        Case("mixed-empty-layouts", "GEOMETRYCOLLECTION (POINT Z EMPTY,POINT M EMPTY)"),
        Case("hull-distinct-z", "MULTIPOINT Z ((0 0 1),(2 0 2),(0 2 3),(0 0 99))"),
        Case("hull-distinct-m", "MULTIPOINT M ((0 0 1),(2 0 2),(0 2 3),(0 0 99))"),
        Case("hull-distinct-zm", "MULTIPOINT ZM ((0 0 1 11),(2 0 2 22),(0 2 3 33),(0 0 99 99))"),
        # GEOS can select a later Z at duplicate XY when it reduces large inputs.
        Case("hull-duplicate-z-51", "MULTIPOINT Z ((10 -10 -8),(0 0 -9),(3 -3 -1),(-5 5 8),(2 -2 9),(9 -9 0),(-6 6 6),(-10 10 -6),(9 -9 7),(-5 5 -2),(2 -2 8),(-10 10 10),(8 -8 -2),(0 0 -9),(-7 7 -3),(-7 7 1),(-7 7 1),(-9 9 -9),(6 -6 -9),(1 -1 9),(0 0 -3),(9 -9 -3),(-1 1 -6),(6 -6 9),(5 -5 -4),(9 -9 -9),(-4 4 9),(0 0 -8),(-2 2 2),(-3 3 7),(9 -9 2),(9 -9 0),(1 -1 -3),(-5 5 -2),(3 -3 4),(9 -9 8),(-5 5 -7),(-3 3 -1),(-9 9 -2),(7 -7 3),(-1 1 -1),(8 -8 3),(7 -7 1),(4 -4 3),(8 -8 -7),(7 -7 -2),(-8 8 8),(8 -8 1),(1 -1 -4),(-4 4 4),(3 -3 -1))"),
        Case("inferred-multipoint-empty-layouts", "MULTIPOINT (EMPTY,(1 2 3),EMPTY)"),
        Case("inferred-multiline-empty-layouts", "MULTILINESTRING (EMPTY,(1 2 3,4 5 6),EMPTY)"),
        Case("inferred-multipolygon-empty-layouts", "MULTIPOLYGON (EMPTY,((0 0 1,2 0 2,0 2 3,0 0 1)),EMPTY)"),
        Case("mixed-ring-arity-rejected", "POLYGON ((0 0,4 0,0 0),(1 0 5,2 0 6,1 0 5))", codec_only=True),
        Case("mixed-explicit-collection-rejected", "GEOMETRYCOLLECTION ZM (POINT Z (1 2 3),POINT M (4 5 6))", codec_only=True),
    ]


def read_request(case: Case, format_name: str, payload: str) -> Request:
    """Record acceptance or rejection from the pinned native GEOS reader."""
    try:
        geometry = sh.from_wkt(payload) if format_name == "WKT" else sh.from_wkb(bytes.fromhex(payload))
        return Request(case, format_name, payload, geometry)
    except GEOSException as failure:
        return Request(case, format_name, payload, None, str(failure))


def binary_requests() -> list[Request]:
    """Include constructor failures and empty child headers not written by GEOS."""
    point = b"\x01" + struct.pack("<I2d", 1, 1, 2)
    empty_point = b"\x01" + struct.pack("<I2d", 1, math.nan, math.nan)
    xyz_point = b"\x01" + struct.pack("<I3d", 1001, 1, 2, 3)
    collection = b"\x01" + struct.pack("<II", 1007, 2)
    fixtures = [
        ("truncated-point", point[:-1], "XY"),
        ("singleton-line", b"\x01" + struct.pack("<II2d", 2, 1, 0, 0), "XY"),
        ("empty-child-other-layout", collection + empty_point + xyz_point, "XYZ"),
        ("nan-xy-finite-z", b"\x01" + struct.pack("<I3d", 1001, math.nan, math.nan, 3), "XYZ"),
        ("partial-nan-point", b"\x01" + struct.pack("<I2d", 1, math.nan, 1), "XY"),
    ]
    requests = [read_request(Case("binary-" + name, "", codec_only=name != "empty-child-other-layout"), "WKB", payload.hex()) for name, payload, _ in fixtures]
    for family, texts in [
        (4, ["POINT (1 2)", "POINT Z (3 4 5)", "POINT M EMPTY"]),
        (5, ["LINESTRING (0 0,1 2)", "LINESTRING Z (3 4 5,6 7 8)", "LINESTRING M EMPTY"]),
        (6, ["POLYGON ((0 0,2 0,0 2,0 0))", "POLYGON Z ((5 0 1,7 0 2,5 2 3,5 0 1))", "POLYGON M EMPTY"]),
        (7, ["POINT Z (1 2 3)", "LINESTRING M (0 0 5,1 2 6)", "POINT EMPTY"]),
    ]:
        members = [sh.to_wkb(sh.from_wkt(text), byte_order=1, output_dimension=4, flavor="iso") for text in texts]
        for dimensions in range(4):
            payload = b"\x01" + struct.pack("<II", 1000 * dimensions + family, len(members)) + b"".join(members)
            case = Case(f"binary-mixed-{family}-{LAYOUTS[dimensions]}", "")
            requests.append(read_request(case, "WKB", payload.hex()))
    return requests


def constructor_requests() -> list[Request]:
    """Create polygons whose individual ring layouts cannot survive a codec."""
    fixtures = [
        ("xy-z-rings", "LINEARRING (0 0,6 0,6 6,0 6,0 0)", "LINEARRING Z (1 1 3,2 1 4,2 2 5,1 1 3)"),
        ("z-m-rings", "LINEARRING Z (0 0 1,6 0 2,6 6 3,0 6 4,0 0 1)", "LINEARRING M (1 1 3,2 1 4,2 2 5,1 1 3)"),
        ("empty-z-m-rings", "LINEARRING Z EMPTY", "LINEARRING M EMPTY"),
    ]
    return [Request(Case(name, ""), "CONSTRUCT", name, sh.polygons(cast(LinearRing, sh.from_wkt(shell)), holes=[cast(LinearRing, sh.from_wkt(hole))])) for name, shell, hole in fixtures]


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


def coordinate_layout(geometry: BaseGeometry) -> str:
    """Read the stored or aggregate Z and M flags."""
    return LAYOUTS[int(bool(sh.has_z(geometry))) + 2 * int(bool(sh.has_m(geometry)))]


def rings(geometry: BaseGeometry) -> list[BaseGeometry]:
    """Retain the shell and every hole, including empty rings."""
    values = [get_exterior_ring(geometry)] + [get_interior_ring(geometry, i) for i in range(int(get_num_interior_rings(geometry)))]
    return [value for value in values if value is not None]


def coordinate_rows(geometry: BaseGeometry) -> list[tuple[float, float, float | None, float | None]]:
    """Read ordinates with each leaf's layout instead of the collection's flags."""
    kind = int(get_type_id(geometry))
    if kind >= 3:
        members = rings(geometry) if kind == 3 else children(geometry)
        return [row for child in members for row in coordinate_rows(child)]
    has_z, has_m = bool(sh.has_z(geometry)), bool(sh.has_m(geometry))
    return [(float(row[0]), float(row[1]), float(row[2]) if has_z else None, float(row[3]) if has_m else None) for row in sh.get_coordinates(geometry, include_z=True, include_m=True)]


def codec_only(request: Request) -> bool:
    """Keep nonfinite coordinates outside the measurement preconditions."""
    return request.case.codec_only or (request.geometry is not None and any(value is not None and not math.isfinite(value) for row in coordinate_rows(request.geometry) for value in row))


def expected_results(geometry: BaseGeometry) -> dict[str, Value]:
    """Use native operations and reject negative indices before Shapely wraps them."""
    kind = int(get_type_id(geometry))
    point_count = int(get_num_points(geometry)) if kind == 1 else None
    ring_count = int(get_num_interior_rings(geometry)) if kind == 3 else None
    member_count = int(get_num_geometries(geometry))
    values: dict[str, Value] = {
        "geometryType": geometry.geom_type.upper(), "dimension": int(get_dimensions(geometry)),
        "coordinateDimension": int(get_coordinate_dimension(geometry)), "spatialDimension": 3 if sh.has_z(geometry) else 2,
        "is3D": bool(sh.has_z(geometry)), "isMeasured": bool(sh.has_m(geometry)), "isEmpty": bool(sh.is_empty(geometry)),
        "numGeometries": member_count, "numPoints": point_count,
        "startPoint": stored_point(geometry, 0),
        "endPoint": stored_point(geometry, (point_count or 0) - 1),
        "isClosed": bool(sh.is_closed(geometry)), "exteriorRing": get_exterior_ring(geometry) if kind == 3 else None,
        "numInteriorRings": ring_count, "envelope": sh.envelope(geometry),
        "area": float(area(geometry)), "geometryLength": float(length(geometry)), "curveLength": component_length(geometry, False),
        "perimeter": component_length(geometry, True), "centroid": force_2d(sh.centroid(geometry)), "convexHull": force_2d(sh.convex_hull(geometry)),
    }
    for i in range(-1, member_count + 2):
        values[f"geometryN.{i}"] = get_geometry(geometry, i) if 0 <= i < member_count else None
    for i in range(-1, (point_count or 0) + 2):
        values[f"pointN.{i}"] = stored_point(geometry, i)
    for i in range(-1, (ring_count or 0) + 2):
        values[f"interiorRingN.{i}"] = get_interior_ring(geometry, i) if kind == 3 and 0 <= i < (ring_count or 0) else None
    for i, row in enumerate(coordinate_rows(geometry)):
        for method, value in zip(("x", "y", "z", "m"), row, strict=True):
            values[f"{method}.{i}"] = value
    point_rows = coordinate_rows(geometry) if kind == 0 else []
    for method, value in zip(("pointX", "pointY", "pointZ", "pointM"), point_rows[0] if point_rows else (None, None, None, None), strict=True):
        values[method] = value
    return values


def stored_point(geometry: BaseGeometry, index: int) -> Shape | None:
    """Extract the native coordinate row without GEOS's point-layout conversion."""
    if int(get_type_id(geometry)) != 1 or index < 0:
        return None
    rows = coordinate_rows(geometry)
    if index >= len(rows):
        return None
    row = tuple(value.hex() for value in rows[index] if value is not None)
    return Shape(0, coordinate_layout(geometry), coordinates=(row,))


def signature(geometry: BaseGeometry) -> Shape:
    """Retain exact coordinates, order, empty layouts, and ring structure."""
    kind = int(get_type_id(geometry))
    layout = coordinate_layout(geometry)
    if kind <= 2:
        rows = tuple(tuple(value.hex() for value in row if value is not None) for row in coordinate_rows(geometry))
        return Shape(1 if kind == 2 else kind, layout, coordinates=rows)
    members = rings(geometry) if kind == 3 else children(geometry)
    return Shape(kind, layout, children=tuple(signature(child) for child in members))


def read_structure(text: str) -> Shape:
    """Decode the probe's raw JSON without passing through either geometry codec."""
    def node(value: object) -> Shape:
        if not isinstance(value, list):
            raise ValueError("Expected a geometry array")
        fields = cast(list[object], value)
        if len(fields) != 3:
            raise ValueError("Expected kind, layout, and body")
        kind, layout, body = fields
        if not isinstance(kind, int) or not isinstance(layout, str) or layout not in LAYOUTS or not isinstance(body, list):
            raise ValueError("Invalid geometry structure")
        values = cast(list[object], body)
        if kind in (0, 1):
            rows: list[tuple[str, ...]] = []
            for row in values:
                if not isinstance(row, list):
                    raise ValueError("Expected a coordinate row")
                ordinates = cast(list[object], row)
                if len(ordinates) != len(layout) or not all(isinstance(v, str) for v in ordinates):
                    raise ValueError("Expected one decimal string per declared ordinate")
                rows.append(tuple(float(cast(str, v)).hex() for v in ordinates))
            if kind == 0 and len(rows) > 1:
                raise ValueError("A point cannot contain multiple coordinate rows")
            return Shape(kind, layout, coordinates=tuple(rows))
        return Shape(kind, layout, children=tuple(node(child) for child in values))
    return node(cast(object, json.loads(text)))


def binary_signature(data: bytes) -> Shape:
    """Check each ISO WKB tag and ordinate before a reader normalizes it."""
    offset = 0
    def geometry() -> Shape:
        nonlocal offset
        marker = data[offset]
        if marker not in (0, 1):
            raise ValueError("Invalid WKB byte order")
        endian = "<" if marker == 1 else ">"
        tag = int(struct.unpack_from(endian + "I", data, offset + 1)[0])
        family, dimensions = tag % 1000, tag // 1000
        if family not in range(1, 8) or dimensions not in range(4):
            raise ValueError("Invalid ISO WKB tag")
        layout = LAYOUTS[dimensions]
        width = (2, 3, 3, 4)[dimensions]
        offset += 5
        def count() -> int:
            nonlocal offset
            result = int(struct.unpack_from(endian + "I", data, offset)[0])
            offset += 4
            return result
        def rows(n: int) -> tuple[tuple[str, ...], ...]:
            nonlocal offset
            result: list[tuple[str, ...]] = []
            for _ in range(n):
                values = cast(tuple[float, ...], struct.unpack_from(endian + str(width) + "d", data, offset))
                result.append(tuple(value.hex() for value in values))
                offset += 8 * width
            return tuple(result)
        if family == 1:
            return Shape(0, layout, coordinates=rows(1))
        if family == 2:
            return Shape(1, layout, coordinates=rows(count()))
        if family == 3:
            return Shape(3, layout, children=tuple(Shape(1, layout, coordinates=rows(count())) for _ in range(count())))
        return Shape(family, layout, children=tuple(geometry() for _ in range(count())))
    result = geometry()
    if offset != len(data):
        raise ValueError("Trailing WKB data")
    return result


def wkt_tokens(text: str) -> tuple[list[str], list[str]]:
    """Separate WKT structure from decimal spelling without accepting extra text."""
    token = re.compile(rf"{NUMBER}|[+-]?(?:nan|inf(?:inity)?)|[A-Za-z]+|[(),]", re.IGNORECASE)
    structure: list[str] = []
    numbers: list[str] = []
    end = 0
    previous_number = False
    for match in token.finditer(text):
        gap = text[end:match.start()]
        if gap.strip():
            raise ValueError("Unexpected WKT token")
        value = match[0]
        try:
            number = float(value).hex()
        except ValueError:
            structure.append(value.upper())
            previous_number = False
        else:
            if previous_number and not gap:
                raise ValueError("Missing ordinate separator")
            structure.append("#")
            numbers.append(number)
            previous_number = True
        end = match.end()
    if text[end:].strip():
        raise ValueError("Trailing WKT data")
    return structure, numbers


def written_ordinates(geometry: BaseGeometry, output_layout: str | None = None) -> list[str]:
    """Apply native WKT layout promotion while retaining original Double bits."""
    kind = int(get_type_id(geometry))
    if kind == 7:
        return [value for child in children(geometry) for value in written_ordinates(child)]
    layout = output_layout or coordinate_layout(geometry)
    if kind >= 3:
        if kind == 3 and geometry.is_empty:
            return []
        members = rings(geometry) if kind == 3 else children(geometry)
        return [value for child in members for value in written_ordinates(child, layout)]
    columns = {"XY": (0, 1), "XYZ": (0, 1, 2), "XYM": (0, 1, 3), "XYZM": (0, 1, 2, 3)}[layout]
    return [float(row[column]).hex() for row in sh.get_coordinates(geometry, include_z=True, include_m=True) for column in columns]


def matches(method: str, actual: str, expected: Value, strict: bool) -> bool:
    """Use scalar tolerances only for measurements; retain exact output structure."""
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
        if method in ("x", "y", "z", "m", "pointX", "pointY", "pointZ", "pointM"):
            return value.hex() == expected.hex()
        return value == expected or math.isclose(value, expected, rel_tol=1e-10, abs_tol=0.0 if strict else 1e-12)
    if isinstance(expected, str):
        return actual == expected
    if isinstance(expected, Shape):
        return read_structure(actual) == expected
    if method == "encodeWKT":
        expected_text = sh.to_wkt(expected, rounding_precision=-1, output_dimension=4)
        expected_text = re.sub(r"\bGEOMETRYCOLLECTION (?:ZM|Z|M)\b", "GEOMETRYCOLLECTION", expected_text)
        tokens, numbers = wkt_tokens(actual)
        return tokens == wkt_tokens(expected_text)[0] and numbers == written_ordinates(expected)
    if method == "encodeWKB":
        native = sh.to_wkb(expected, byte_order=1, output_dimension=4, flavor="iso")
        return binary_signature(bytes.fromhex(actual)) == binary_signature(native)
    actual_shape, expected_shape = read_structure(actual), signature(expected)
    if method == "convexHull":
        if result_metadata(actual_shape) != result_metadata(expected_shape):
            return False
        actual_geometry = shape_geometry(actual_shape)
        if actual_shape.kind == 3 and not bool(sh.is_ccw(get_exterior_ring(actual_geometry))):
            return False
        return bool(sh.equals_exact(sh.normalize(actual_geometry), sh.normalize(expected), tolerance=0.0))
    if method == "centroid":
        if (actual_shape.kind, actual_shape.layout) != (expected_shape.kind, expected_shape.layout):
            return False
        if not actual_shape.coordinates or not expected_shape.coordinates:
            return actual_shape.coordinates == expected_shape.coordinates
        return all(matches("centroid_scalar", str(float.fromhex(a)), float.fromhex(b), strict) for a, b in zip(actual_shape.coordinates[0], expected_shape.coordinates[0], strict=True))
    return actual_shape == expected_shape


def codec_results(geometry: BaseGeometry) -> dict[str, Value]:
    """Keep the input geometry for independent writer checks."""
    return {"encodeWKT": geometry, "encodeWKB": geometry}




def describe(value: Value) -> str:
    """Use full WKT for geometry mismatch reports."""
    return str(sh.to_wkt(value, rounding_precision=-1, output_dimension=4)) if isinstance(value, BaseGeometry) else repr(value)



# The metadata checks are exact. Only newly computed XY coordinates use this
# absolute tolerance; codec and accessor checks never use it.
CONSTRUCTED_TOLERANCE = 1e-9
UNARY_METHODS = {
    "boundary": "boundary (None for GeometryCollection)",
    "isSimple": "is_simple; direct GEOSisSimple_r for GeometryCollection",
    "isRing": "is_ring",
    "isValid": "is_valid",
    "pointOnSurface": "point_on_surface",
}
RELATION_METHODS = {
    "relate": "relate (exact DE-9IM matrix)",
    "relatePattern": "relate_pattern with exact, boolean, and wildcard patterns",
    "equals": "equals", "disjoint": "disjoint", "intersects": "intersects",
    "touches": "touches", "crosses": "crosses", "within": "within",
    "contains": "contains", "overlaps": "overlaps", "covers": "covers",
    "coveredBy": "covered_by", "distance": "distance",
}
OVERLAY_METHODS = {
    "intersection": "intersection", "union": "union", "difference": "difference",
    "symmetricDifference": "symmetric_difference",
}
BUFFER_METHODS = {
    "buffer": "buffer (quad_segs=8, round caps and joins)",
    "bufferWithSegments": "buffer (explicit quad_segs, round caps and joins)",
}
METHODS.update(UNARY_METHODS | RELATION_METHODS | OVERLAY_METHODS | BUFFER_METHODS)
PATTERNS = ("*********", "T********", "FF*FF****", "T*F**F***", "T*****FF*", "0********", "1********", "2********", "F********", "FT*******", "F**T*****", "F***T****")


@dataclass(frozen=True)
class PairCase:
    """Two exact inputs and a name used in every mismatch report."""

    name: str
    first: str
    second: str


COINCIDENT_SHELLS = PairCase(
    "coincident-shell-ordinates",
    "POLYGON ZM ((6 2 21 7,7 2 23 8,6 4 23 1,5 4 21 0,6 2 21 7),(6 2.5 21.5 5.5,6.5 2.5 22.5 6,6 3.5 22.5 2.5,5.5 3.5 21.5 2,6 2.5 21.5 5.5))",
    "POLYGON ZM ((6 2 45 31,7 2 47 32,6 4 47 25,5 4 45 24,6 2 45 31))",
)


@dataclass(frozen=True)
class OperationError:
    """A native operation failed after both inputs decoded successfully."""

    message: str


OperationValue: TypeAlias = Value | OperationError
OrdinateRow: TypeAlias = tuple[float, float, float | None, float | None]


def topology_cases(rng: random.Random, count: int) -> list[Case]:
    """Cover valid and invalid unary topology without nonfinite coordinates."""
    fixtures = [
        ("point", "POINT (1 2)"),
        ("duplicate-points", "MULTIPOINT ((0 0),(1 1),(0 0))"),
        ("simple-line", "LINESTRING (0 0,3 4,6 0)"),
        ("closed-line", "LINESTRING (0 0,4 0,4 4,0 0)"),
        ("crossed-line", "LINESTRING (0 0,4 4,0 4,4 0)"),
        ("retraced-line", "LINESTRING (0 0,4 0,2 0)"),
        ("zero-line", "LINESTRING (2 3,2 3)"),
        ("node-lines", "MULTILINESTRING ((0 0,2 2),(2 2,4 0))"),
        ("crossed-lines", "MULTILINESTRING ((0 0,4 4),(0 4,4 0))"),
        ("overlap-lines", "MULTILINESTRING ((0 0,4 0),(2 0,6 0))"),
        ("t-junction", "MULTILINESTRING ((0 0,4 0),(2 0,2 3))"),
        ("parity-boundary", "MULTILINESTRING ((0 0,2 0),(0 0,0 2),(0 0,-2 0))"),
        ("square", "POLYGON ((0 0,6 0,6 6,0 6,0 0))"),
        ("hole", "POLYGON ((0 0,6 0,6 6,0 6,0 0),(1 1,1 5,5 5,5 1,1 1))"),
        ("concave", "POLYGON ((0 0,6 0,6 1,1 1,1 6,0 6,0 0))"),
        ("bowtie", "POLYGON ((0 0,4 4,0 4,4 0,0 0))"),
        ("outside-hole", "POLYGON ((0 0,4 0,4 4,0 4,0 0),(5 5,6 5,6 6,5 5))"),
        ("nested-holes", "POLYGON ((0 0,9 0,9 9,0 9,0 0),(1 1,8 1,8 8,1 8,1 1),(2 2,3 2,3 3,2 3,2 2))"),
        ("touching-hole", "POLYGON ((0 0,6 0,6 6,0 6,0 0),(0 3,2 2,2 4,0 3))"),
        ("overlap-polygons", "MULTIPOLYGON (((0 0,4 0,4 4,0 4,0 0)),((2 2,6 2,6 6,2 6,2 2)))"),
        ("vertex-polygons", "MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((2 2,4 2,4 4,2 4,2 2)))"),
        ("nested-collection", "GEOMETRYCOLLECTION (POINT (2 2),GEOMETRYCOLLECTION (LINESTRING (0 0,4 4),POLYGON ((0 0,4 0,4 4,0 4,0 0))))"),
        ("overlap-collection", "GEOMETRYCOLLECTION (POLYGON ((0 0,4 0,4 4,0 4,0 0)),POLYGON ((2 2,6 2,6 6,2 6,2 2)))"),
        ("empty-members", "GEOMETRYCOLLECTION (POINT EMPTY,LINESTRING EMPTY,POLYGON EMPTY)"),
    ]
    fixtures += [("empty-" + family, family + " EMPTY") for family in ("POINT", "LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION")]
    return [Case("topology-" + name + "-" + layout, lift_layout(text, layout)) for name, text in fixtures for layout in LAYOUTS] + [random_case(rng, index) for index in range(count)]


def pair_cases(rng: random.Random, count: int) -> list[PairCase]:
    """Exercise every ordered family pair, empty operands, and exact contacts."""
    families = [
        "POINT (2 2)", "LINESTRING (0 0,4 4)", "POLYGON ((0 0,4 0,4 4,0 4,0 0))",
        "MULTIPOINT ((0 0),(2 2),(8 8))", "MULTILINESTRING ((0 0,4 4),(0 4,4 0))",
        "MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((5 5,7 5,7 7,5 7,5 5)))",
        "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))",
    ]
    cases = [PairCase(f"family-{i}-{j}-{layout}", lift_layout(a, layout), lift_layout(b, layout)) for i, a in enumerate(families) for j, b in enumerate(families) for layout in LAYOUTS]
    empty = [text.split(" ", 1)[0] + " EMPTY" for text in families]
    cases += [PairCase(f"empty-{i}-{j}", a, b) for i, a in enumerate(families + empty) for j, b in enumerate(families + empty) if i >= 7 or j >= 7]
    square = families[2]
    hole = "POLYGON ((0 0,8 0,8 8,0 8,0 0),(2 2,6 2,6 6,2 6,2 2))"
    special = [
        ("hole-crossing", hole, "LINESTRING (-1 4,9 4)"),
        ("hole-boundary", hole, "LINESTRING (2 2,6 2)"),
        ("hole-interior", hole, "POINT (3 3)"),
        ("shared-edge", square, "POLYGON ((4 0,8 0,8 4,4 4,4 0))"),
        ("shared-vertex", square, "POLYGON ((4 4,8 4,8 8,4 8,4 4))"),
        ("partial-overlap", square, "POLYGON ((2 2,6 2,6 6,2 6,2 2))"),
        ("contained", square, "POLYGON ((1 1,3 1,3 3,1 3,1 1))"),
        ("collinear-overlap", "LINESTRING (0 0,6 0)", "LINESTRING (2 0,8 0)"),
        ("collinear-reversed", "LINESTRING (0 0,2 0,6 0)", "LINESTRING (6 0,0 0)"),
        ("proper-crossing", "LINESTRING (0 0,7 5)", "LINESTRING (0 4,8 0)"),
        ("endpoint-contact", "LINESTRING (0 0,2 2)", "LINESTRING (2 2,5 0)"),
        ("t-junction", "LINESTRING (0 0,4 0)", "LINESTRING (2 0,2 3)"),
        ("point-on-segment", "POINT (1 1)", "LINESTRING (0 0,3 3)"),
        ("point-near-segment", "POINT (1 1.000000000001)", "LINESTRING (0 0,3 3)"),
        ("near-parallel", "LINESTRING (0 0,10 0.000000000001)", "LINESTRING (0 0.000000000001,10 0)"),
        ("nested-overlap", "GEOMETRYCOLLECTION (GEOMETRYCOLLECTION (" + square + "),LINESTRING (-1 2,5 2))", "GEOMETRYCOLLECTION (" + square + ",POINT (2 2))"),
        ("overlap-members", "GEOMETRYCOLLECTION (" + square + ",POLYGON ((2 2,6 2,6 6,2 6,2 2)))", "LINESTRING (-1 3,7 3)"),
        ("invalid-bowtie", "POLYGON ((0 0,4 4,0 4,4 0,0 0))", square),
    ]
    for name, a, b in special:
        for layout in LAYOUTS:
            first, second = lift_layout(a, layout), lift_layout(b, layout)
            cases += [PairCase(name + "-" + layout, first, second), PairCase(name + "-reverse-" + layout, second, first)]
    cases += [
        COINCIDENT_SHELLS,
        PairCase("interpolate-z", "LINESTRING Z (0 0 0,4 4 8)", "LINESTRING Z (0 4 20,4 0 40)"),
        PairCase("interpolate-m", "LINESTRING M (0 0 0,4 4 8)", "LINESTRING M (0 4 20,4 0 40)"),
        PairCase("interpolate-zm", "LINESTRING ZM (0 0 0 10,4 4 8 20)", "LINESTRING ZM (0 4 20 100,4 0 40 200)"),
        PairCase("coincident-z", "POINT Z (1 2 3)", "POINT Z (1 2 9)"),
        PairCase("coincident-m", "POINT M (1 2 3)", "POINT M (1 2 9)"),
        PairCase("mixed-z-m", "LINESTRING Z (0 0 0,4 4 8)", "LINESTRING M (0 4 20,4 0 40)"),
        PairCase("mixed-collection", "GEOMETRYCOLLECTION (POINT Z (2 2 9),LINESTRING M (0 0 4,4 4 8))", "LINESTRING ZM (0 4 20 100,4 0 40 200)"),
    ]
    for index in range(count):
        # Nearby integer rectangles exercise positive-area overlap as well as
        # disjoint cases. Small rational shears create non-axis-aligned edges.
        x, y = rng.randint(-8, 8), rng.randint(-8, 8)
        w, h = rng.randint(1, 8), rng.randint(1, 8)
        dx, dy = rng.randint(-w, w), rng.randint(-h, h)
        slope = rng.choice([0.0, 0.25, -0.5, 1.0])
        def rectangle(a: int, b: int) -> str:
            points = [(a, b), (a + w, b), (a + w, b + h), (a, b + h), (a, b)]
            return "POLYGON ((" + ",".join(f"{px + slope * py:.17g} {py}" for px, py in points) + "))"
        first = rectangle(x, y)
        second = rectangle(x + dx, y + dy)
        if index % 5 == 0:
            second = f"LINESTRING ({x-w} {y+h/2},{x+2*w} {y+h/2})"
        elif index % 5 == 1:
            first = f"LINESTRING ({x} {y},{x+w} {y+h})"
            second = f"LINESTRING ({x} {y+h},{x+w} {y})"
        elif index % 5 == 2:
            second = f"POINT ({x+dx} {y+dy})"
        elif index % 5 == 3:
            hole = [(x + w / 4, y + h / 4), (x + 3 * w / 4, y + h / 4), (x + 3 * w / 4, y + 3 * h / 4), (x + w / 4, y + 3 * h / 4), (x + w / 4, y + h / 4)]
            hole_text = ",".join(f"{px + slope * py:.17g} {py:.17g}" for px, py in hole)
            first = first[:-1] + ",(" + hole_text + "))"
        else:
            concave = [(x, y), (x + w, y), (x + w, y + h / 2), (x + w / 2, y + h / 2), (x + w / 2, y + h), (x, y + h), (x, y)]
            first = "POLYGON ((" + ",".join(f"{px + slope * py:.17g} {py:.17g}" for px, py in concave) + "))"
        cases.append(PairCase(f"pair-random-{index}", lift_varying_ordinates(first, LAYOUTS[index % 4], 7), lift_varying_ordinates(second, LAYOUTS[(index // 4) % 4], 31)))
    cases += [
        PairCase("native-collection-contained", "GEOMETRYCOLLECTION (POINT (10 10),POLYGON ((0 0,4 0,4 4,0 4,0 0)))", "POLYGON ((1 1,2 1,2 2,1 2,1 1))"),
        PairCase("native-collection-boundary", "GEOMETRYCOLLECTION (POLYGON ((4 4,4 5,-1 5,-1 4,4 4)),POLYGON ((6 3,6 8,3 8,3 3,6 3)))", "LINESTRING (-1 3,-1 -2)"),
        PairCase("native-closed-line-boundary", "MULTILINESTRING ((0 0,1 0,0 0),(0 2,1 2))", "POINT (10 10)"),
    ]
    return cases


def lift_varying_ordinates(wkt: str, layout: str, offset: int) -> str:
    """Use different planar Z/M slopes to expose incorrect interpolation."""
    def coordinate(match: re.Match[str]) -> str:
        x, y = float(match[1]), float(match[2])
        extra = ([2 * x + y + offset] if "Z" in layout else []) + ([x - 3 * y + offset] if "M" in layout else [])
        return match[0] + "".join(f" {value:.17g}" for value in extra)
    text = re.sub(f"({NUMBER})\\s+({NUMBER})", coordinate, wkt)
    suffix = {"XY": "", "XYZ": " Z", "XYM": " M", "XYZM": " ZM"}[layout]
    return re.sub(FAMILY, lambda match: match[0] + suffix, text)


def native_operation(operation: Callable[[], Value]) -> OperationValue:
    """Keep native operation errors distinct from input parsing errors."""
    try:
        return operation()
    except GEOSException as failure:
        return OperationError(str(failure))


def native_is_simple(geometry: BaseGeometry) -> bool:
    """Bypass Shapely's always-False collection policy; call native GEOS."""
    if get_type_id(geometry) != 7:
        return bool(sh.is_simple(geometry))
    library = ctypes.CDLL(str(getattr(getattr(sh, "lib"), "__file__")))
    library.GEOS_init_r.restype = ctypes.c_void_p
    library.GEOS_finish_r.argtypes = [ctypes.c_void_p]
    library.GEOSisSimple_r.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    library.GEOSisSimple_r.restype = ctypes.c_byte
    context = library.GEOS_init_r()
    try:
        result = int(library.GEOSisSimple_r(context, int(getattr(geometry, "_geom"))))
        if result == 2:
            raise GEOSException("GEOSisSimple_r reported an exception")
        return result == 1
    finally:
        library.GEOS_finish_r(context)


def native_unary(geometry: BaseGeometry, phase: str) -> dict[str, OperationValue]:
    """Evaluate each native unary operation separately."""
    values: dict[str, OperationValue] = {}
    if phase in ("all", "unary"):
        for name, method in [("boundary", "boundary"), ("isSimple", "is_simple"), ("isRing", "is_ring"), ("isValid", "is_valid"), ("pointOnSurface", "point_on_surface")]:
            operation = cast(Callable[[BaseGeometry], Value], getattr(sh, method))
            values[name] = native_operation(lambda operation=operation, name=name: bool(operation(geometry)) if name.startswith("is") else operation(geometry))
        values["isSimple"] = native_operation(lambda: native_is_simple(geometry))
    if phase in ("all", "buffer"):
        for radius in (-1.0, 0.0, 0.5, 2.0):
            values[f"buffer.{radius}"] = native_operation(lambda radius=radius: sh.buffer(geometry, radius, quad_segs=8))
        for segments in (1, 2, 8, 16):
            for radius in (-0.5, 0.5):
                values[f"bufferWithSegments.{segments}.{radius}"] = native_operation(lambda segments=segments, radius=radius: sh.buffer(geometry, radius, quad_segs=segments))
    return values


def native_pair(first: BaseGeometry, second: BaseGeometry, phase: str) -> dict[str, OperationValue]:
    """Evaluate matrices, predicates, metrics, and overlays independently."""
    values: dict[str, OperationValue] = {}
    if phase in ("all", "relations"):
        for name in RELATION_METHODS:
            if name == "relatePattern":
                continue
            native_name = "covered_by" if name == "coveredBy" else name
            operation = cast(Callable[[BaseGeometry, BaseGeometry], Value], getattr(sh, native_name))
            values[name] = native_operation(lambda operation=operation, name=name: operation(first, second) if name in ("relate", "distance") else bool(operation(first, second)))
        for pattern in PATTERNS:
            values["relatePattern." + pattern] = native_operation(lambda pattern=pattern: bool(sh.relate_pattern(first, second, pattern)))
    if phase in ("all", "overlay"):
        for name in OVERLAY_METHODS:
            native_name = "symmetric_difference" if name == "symmetricDifference" else name
            values[name] = native_operation(lambda native_name=native_name: cast(Value, getattr(sh, native_name)(first, second)))
    return values


def shape_geometry(shape: Shape) -> BaseGeometry:
    """Read raw XY for topology. Check layouts and Z/M separately before this."""
    def encode(value: Shape) -> bytes:
        family = {0: 1, 1: 2}.get(value.kind, value.kind)
        head = b"\x01" + struct.pack("<I", family)
        def count(n: int) -> bytes:
            return struct.pack("<I", n)
        def rows(points: tuple[tuple[str, ...], ...]) -> bytes:
            return b"".join(struct.pack("<2d", *(float.fromhex(v) for v in row[:2])) for row in points)
        if value.kind == 0:
            coordinates = value.coordinates or (("nan", "nan"),)
            return head + rows(coordinates)
        if value.kind == 1:
            return head + count(len(value.coordinates)) + rows(value.coordinates)
        if value.kind == 3:
            return head + count(len(value.children)) + b"".join(count(len(ring.coordinates)) + rows(ring.coordinates) for ring in value.children)
        return head + count(len(value.children)) + b"".join(encode(child) for child in value.children)
    return sh.from_wkb(encode(shape))


def result_metadata(shape: Shape) -> tuple[object, ...]:
    """Compare family, layout, empty members, and ring counts without order."""
    if shape.kind in (0, 1):
        return shape.kind, shape.layout, bool(shape.coordinates)
    return shape.kind, shape.layout, tuple(sorted((result_metadata(child) for child in shape.children), key=repr))


def extra_ordinates_match(actual: Shape, expected: Shape) -> bool:
    """Check Z/M at vertices and interpolate only along native output edges."""
    def leaves(shape: Shape) -> list[Shape]:
        return [shape] if shape.kind in (0, 1) else [leaf for child in shape.children for leaf in leaves(child)]
    def rows(shape: Shape) -> list[OrdinateRow]:
        result: list[OrdinateRow] = []
        for encoded in shape.coordinates:
            values = [float.fromhex(value) for value in encoded]
            z = values[2] if "Z" in shape.layout else None
            m = values[-1] if "M" in shape.layout else None
            result.append((values[0], values[1], z, m))
        return result
    def close(a: float | None, b: float | None) -> bool:
        if a is None or b is None:
            return a is b
        return (math.isnan(a) and math.isnan(b)) or a == b or math.isclose(a, b, rel_tol=0.0, abs_tol=CONSTRUCTED_TOLERANCE)
    def matches_row(row: OrdinateRow, samples: list[OrdinateRow], segments: list[tuple[OrdinateRow, OrdinateRow]]) -> bool:
        if row[2:] == (None, None):
            return True
        for sample in samples:
            if math.hypot(row[0] - sample[0], row[1] - sample[1]) <= CONSTRUCTED_TOLERANCE and all(close(a, b) for a, b in zip(row[2:], sample[2:], strict=True)):
                return True
        for a, b in segments:
            dx, dy = b[0] - a[0], b[1] - a[1]
            squared = dx * dx + dy * dy
            if squared == 0:
                continue
            t = ((row[0] - a[0]) * dx + (row[1] - a[1]) * dy) / squared
            if not 0 <= t <= 1 or math.hypot(row[0] - (a[0] + t * dx), row[1] - (a[1] + t * dy)) > CONSTRUCTED_TOLERANCE:
                continue
            interpolated = tuple(None if p is None or q is None else p + t * (q - p) for p, q in zip(a[2:], b[2:], strict=True))
            if all(close(p, q) for p, q in zip(row[2:], interpolated, strict=True)):
                return True
        return False
    def covered(source: Shape, target: Shape) -> bool:
        target_leaves = leaves(target)
        target_rows = [row for leaf in target_leaves for row in rows(leaf)]
        target_segments = [pair for leaf in target_leaves if leaf.kind == 1 for pair in zip(rows(leaf), rows(leaf)[1:])]
        return all(matches_row(row, target_rows, target_segments) for leaf in leaves(source) for row in rows(leaf))
    return covered(actual, expected) and covered(expected, actual)


def geometry_result_matches(shape: Shape, expected_shape: Shape, expected: BaseGeometry) -> bool:
    """Check metadata and validity before bounded geometric comparisons."""
    def finite_xy(value: Shape) -> bool:
        return all(math.isfinite(float.fromhex(ordinate)) for row in value.coordinates for ordinate in row[:2]) and all(finite_xy(child) for child in value.children)
    if not finite_xy(shape):
        return False
    if result_metadata(shape) != result_metadata(expected_shape) or not extra_ordinates_match(shape, expected_shape):
        return False
    geometry = shape_geometry(shape)
    if geometry.is_valid != expected.is_valid:
        return False
    # Equality permits different ring starts and exact collinear subdivisions.
    if bool(sh.equals(geometry, expected)):
        return True
    if bool(sh.equals_exact(sh.normalize(geometry), sh.normalize(expected), tolerance=CONSTRUCTED_TOLERANCE)):
        return True
    # Additional nearly-collinear vertices can defeat equals_exact. Require a
    # small displacement and small measurement changes, without modifying input.
    displacement = hausdorff_distance(geometry, expected, 0.25)
    if not math.isfinite(displacement) or displacement > CONSTRUCTED_TOLERANCE:
        return False
    coordinate_count = len(coordinate_rows(geometry)) + len(coordinate_rows(expected))
    if abs(length(geometry) - length(expected)) > CONSTRUCTED_TOLERANCE * max(1, coordinate_count):
        return False
    if max(get_dimensions(geometry), get_dimensions(expected)) == 2:
        return float(area(sh.symmetric_difference(geometry, expected))) <= CONSTRUCTED_TOLERANCE * (1 + length(geometry) + length(expected))
    return True








def geometry_mismatch_reason(actual: str, expected: BaseGeometry) -> str:
    """Identify the first failed geometry contract for the report."""
    try:
        shape, native = read_structure(actual), signature(expected)
        if result_metadata(shape) != result_metadata(native):
            return "Geometry family, dimensions, empty members, or ring counts differ"
        if not extra_ordinates_match(shape, native):
            return "Z/M ordinates differ"
        if shape_geometry(shape).is_valid != expected.is_valid:
            return "Output validity differs"
        return "XY geometry differs beyond the stated tolerance"
    except (ValueError, IndexError, struct.error, GEOSException):
        return "Invalid geometry result"


def operation_matches(method: str, actual: str, expected: OperationValue) -> bool:
    """Keep metadata exact; allow 1e-9 absolute XY error in constructed results."""
    if isinstance(expected, OperationError):
        return actual.startswith("!exception:")
    if isinstance(expected, BaseGeometry):
        return not actual.startswith("!") and actual != "~" and geometry_result_matches(read_structure(actual), signature(expected), expected)
    if isinstance(expected, float) and math.isnan(expected):
        return math.isnan(float(actual))
    return matches(method, actual, expected, method == "distance")




# Only these exact fixed operands have an independently verified native defect.
NATIVE_SYMDIFF_FIXTURES: dict[str, tuple[str, str]] = {
    "family-0-6": ("POINT (2 2)", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "family-1-6": ("LINESTRING (0 0,4 4)", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "family-2-6": ("POLYGON ((0 0,4 0,4 4,0 4,0 0))", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "family-3-6": ("MULTIPOINT ((0 0),(2 2),(8 8))", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "family-4-6": ("MULTILINESTRING ((0 0,4 4),(0 4,4 0))", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "family-5-6": ("MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((5 5,7 5,7 7,5 7,5 5)))", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "family-6-1": ("GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))", "LINESTRING (0 0,4 4)"),
    "family-6-3": ("GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))", "MULTIPOINT ((0 0),(2 2),(8 8))"),
    "family-6-4": ("GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))", "MULTILINESTRING ((0 0,4 4),(0 4,4 0))"),
    "family-6-5": ("GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))", "MULTIPOLYGON (((0 0,2 0,2 2,0 2,0 0)),((5 5,7 5,7 7,5 7,5 5)))"),
    "empty-7-6": ("POINT EMPTY", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "empty-8-6": ("LINESTRING EMPTY", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "empty-9-6": ("POLYGON EMPTY", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "empty-10-6": ("MULTIPOINT EMPTY", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "empty-11-6": ("MULTILINESTRING EMPTY", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "empty-12-6": ("MULTIPOLYGON EMPTY", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "empty-13-6": ("GEOMETRYCOLLECTION EMPTY", "GEOMETRYCOLLECTION (POINT (6 6),LINESTRING (0 2,4 2),POLYGON ((0 0,2 0,2 2,0 2,0 0)))"),
    "nested-overlap": ("GEOMETRYCOLLECTION (GEOMETRYCOLLECTION (POLYGON ((0 0,4 0,4 4,0 4,0 0))),LINESTRING (-1 2,5 2))", "GEOMETRYCOLLECTION (POLYGON ((0 0,4 0,4 4,0 4,0 0)),POINT (2 2))"),
    "nested-overlap-reverse": ("GEOMETRYCOLLECTION (POLYGON ((0 0,4 0,4 4,0 4,0 0)),POINT (2 2))", "GEOMETRYCOLLECTION (GEOMETRYCOLLECTION (POLYGON ((0 0,4 0,4 4,0 4,0 0))),LINESTRING (-1 2,5 2))"),
    "overlap-members": ("GEOMETRYCOLLECTION (POLYGON ((0 0,4 0,4 4,0 4,0 0)),POLYGON ((2 2,6 2,6 6,2 6,2 2)))", "LINESTRING (-1 3,7 3)"),
    "mixed-collection": ("GEOMETRYCOLLECTION (POINT Z (2 2 9),LINESTRING M (0 0 4,4 4 8))", "LINESTRING ZM (0 4 20 100,4 0 40 200)"),
    "native-collection-boundary": ("GEOMETRYCOLLECTION (POLYGON ((4 4,4 5,-1 5,-1 4,4 4)),POLYGON ((6 3,6 8,3 8,3 3,6 3)))", "LINESTRING (-1 3,-1 -2)"),
}


def known_symdiff_reference(case: PairCase, first: BaseGeometry, second: BaseGeometry) -> BaseGeometry | None:
    """Use the set identity only for named, unchanged, verified fixture operands."""
    key, _, layout = case.name.rpartition("-")
    if layout not in LAYOUTS:
        key, layout = case.name, ""
    fixture = NATIVE_SYMDIFF_FIXTURES.get(key)
    if fixture is None:
        return None
    a, b = fixture
    if layout:
        a, b = lift_layout(a, layout), lift_layout(b, layout)
    if (case.first, case.second) != (a, b):
        return None
    def atoms(geometry: BaseGeometry) -> list[BaseGeometry]:
        if get_type_id(geometry) >= 4:
            return [atom for child in children(geometry) for atom in atoms(child)]
        return [] if geometry.is_empty else [geometry]
    def difference_parts(left: list[BaseGeometry], right: list[BaseGeometry]) -> list[BaseGeometry]:
        result: list[BaseGeometry] = []
        for part in left:
            for cutter in right:
                part = sh.difference(part, cutter)
            result.append(part)
        return result
    first_parts, second_parts = atoms(first), atoms(second)
    result = sh.union_all(difference_parts(first_parts, second_parts) + difference_parts(second_parts, first_parts))
    if layout:
        # The guarded lifted fixtures have constant Z=3 and M=4. Interpolation
        # must retain these constants, even when native intermediate steps lose M.
        text = str(sh.to_wkt(force_2d(result), rounding_precision=-1))
        return sh.from_wkt(lift_layout(text, layout))
    return result






def known_empty_reference(case: PairCase, method: str, first: BaseGeometry, second: BaseGeometry) -> BaseGeometry | None:
    """Require the declared empty family where named native cases assert."""
    collection = NATIVE_SYMDIFF_FIXTURES["empty-7-6"][1]
    families = ("POINT", "LINESTRING", "POLYGON", "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION")
    for index, family in enumerate(families, 7):
        empty = family + " EMPTY"
        forward = case.name == f"empty-6-{index}" and (case.first, case.second) == (collection, empty)
        reverse = case.name == f"empty-{index}-6" and (case.first, case.second) == (empty, collection)
        if method == "intersection" and (forward or reverse):
            dimension = min(get_dimensions(first), get_dimensions(second))
        elif method == "difference" and reverse:
            dimension = get_dimensions(first)
        else:
            continue
        expected_family = {-1: "GEOMETRYCOLLECTION", 0: "POINT", 1: "LINESTRING", 2: "POLYGON"}[dimension]
        return sh.from_wkt(expected_family + " EMPTY")
    return None


def known_collection_result(case: PairCase | None, key: str) -> str | None:
    """Require exact corrected values for documented native relation bugs."""
    if case is None:
        return None
    fixtures = {
        "native-collection-contained": ("GEOMETRYCOLLECTION (POINT (10 10),POLYGON ((0 0,4 0,4 4,0 4,0 0)))", "POLYGON ((1 1,2 1,2 2,1 2,1 1))", "212FF1FF2"),
        "native-collection-boundary": ("GEOMETRYCOLLECTION (POLYGON ((4 4,4 5,-1 5,-1 4,4 4)),POLYGON ((6 3,6 8,3 8,3 3,6 3)))", "LINESTRING (-1 3,-1 -2)", "FF2FF1102"),
        "native-closed-line-boundary": ("MULTILINESTRING ((0 0,1 0,0 0),(0 2,1 2))", "POINT (10 10)", "FF1FF00F2"),
    }
    fixture = fixtures.get(case.name)
    if fixture is None or (case.first, case.second) != fixture[:2]:
        return None
    matrix = fixture[2]
    if key == "relate":
        return matrix
    if key.startswith("relatePattern."):
        pattern = key.split(".", 1)[1]
        return str(all(p == "*" or p == c or (p == "T" and c != "F") for p, c in zip(pattern, matrix, strict=True)))
    if case.name == "native-collection-contained":
        return {"contains": "True", "covers": "True", "overlaps": "False"}.get(key)
    return None

def run_operations(probe: Path, phases: set[str], seed: int, count: int, buffer_count: int, checked: Counter[str], failures: list[dict[str, str]], known_differences: list[dict[str, str]]) -> dict[str, object]:
    """Run topology requests and retain exact operands for each disagreement."""
    inputs: list[str] = []
    expected_rows: list[tuple[str, str, str, str, dict[str, OperationValue]]] = []
    input_validity: dict[str, tuple[bool, bool | None]] = {}
    overlay_corrections: dict[tuple[str, str], BaseGeometry] = {}
    correction_reasons: dict[tuple[str, str], str] = {}
    pairs = pair_cases(random.Random(seed ^ 0x912), count)
    pair_inputs = {case.name: case for case in pairs}
    pair_phase = "all" if {"relations", "overlay"} <= phases else "relations" if "relations" in phases else "overlay"
    def payload(geometry: BaseGeometry, text: str, format_name: str) -> str:
        return text if format_name == "WKT" else sh.to_wkb(geometry, byte_order=1, output_dimension=4, flavor="iso").hex()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        for unary_phase, generated in [("unary", count), ("buffer", buffer_count)]:
            if unary_phase not in phases:
                continue
            for case in topology_cases(random.Random(seed ^ 0x541), generated):
                geometry = sh.from_wkt(case.wkt)
                if case.name.startswith("random-") and not geometry.is_valid:
                    raise RuntimeError("Random generator produced invalid topology: " + case.wkt)
                input_validity[case.name] = (geometry.is_valid, None)
                values = native_unary(geometry, unary_phase)
                for format_name in ("WKT", "WKB"):
                    first = payload(geometry, case.wkt, format_name)
                    inputs.append(f"TOPO-{format_name}\t{unary_phase}\t{first}")
                    expected_rows.append((case.name, format_name, first, "", values))
        if phases & {"relations", "overlay"}:
            for case in pairs:
                first_geometry, second_geometry = sh.from_wkt(case.first), sh.from_wkt(case.second)
                if case.name.startswith("pair-random-") and not (first_geometry.is_valid and second_geometry.is_valid):
                    raise RuntimeError("Random pair generator produced invalid topology: " + case.first + " / " + case.second)
                input_validity[case.name] = (first_geometry.is_valid, second_geometry.is_valid)
                values = native_pair(first_geometry, second_geometry, pair_phase)
                if "symmetricDifference" in values:
                    reference = known_symdiff_reference(case, first_geometry, second_geometry)
                    if reference is not None:
                        overlay_corrections[case.name, "symmetricDifference"] = reference
                        correction_reasons[case.name, "symmetricDifference"] = "Named native symmetricDifference loses components; require union of atomic differences in both directions"
                for method in ("intersection", "difference"):
                    if isinstance(values.get(method), OperationError):
                        reference = known_empty_reference(case, method, first_geometry, second_geometry)
                        if reference is not None:
                            overlay_corrections[case.name, method] = reference
                            correction_reasons[case.name, method] = "Named native operation asserts on a valid empty operand; require exact declared empty family and XY layout"
                for format_name in ("WKT", "WKB"):
                    first, second = payload(first_geometry, case.first, format_name), payload(second_geometry, case.second, format_name)
                    inputs.append(f"PAIR-{format_name}\t{pair_phase}\t{first}\t{second}")
                    expected_rows.append((case.name, format_name, first, second, values))
    if not inputs:
        return {"requests": 0, "native_operation_errors": 0, "family_pairs": [], "out_of_contract": [], "out_of_contract_count": 0}
    completed = subprocess.run([str(probe.resolve())], input="\n".join(inputs) + ("\n" if inputs else ""), text=True, capture_output=True, check=True)
    lines = completed.stdout.splitlines()
    if len(lines) != len(inputs):
        raise RuntimeError(f"Topology probe returned {len(lines)} responses for {len(inputs)} inputs: {completed.stderr}")
    native_errors = 0
    out_of_contract: list[dict[str, str]] = []
    for (name, format_name, first, second, values), line in zip(expected_rows, lines, strict=True):
        context = {"case": name, "format": format_name, "input": first, "second_input": second}
        first_valid, second_valid = input_validity[name]
        context["input_valid"] = str(first_valid)
        if second_valid is not None:
            context["second_input_valid"] = str(second_valid)
        if not line.startswith("OK\t"):
            failures.append(context | {"method": "operation-decode", "expected": "both native inputs decoded", "actual": line})
            continue
        actual_values = dict(field.split("=", 1) for field in line.split("\t")[1:])
        if actual_values.keys() != values.keys():
            failures.append(context | {"method": "operation-protocol", "expected": str(sorted(values)), "actual": str(sorted(actual_values))})
        for key, expected in values.items():
            method = key.split(".", 1)[0]
            actual = actual_values.get(key, "!missing field")
            if second_valid is not None and not (first_valid and second_valid):
                expected_text = expected.message if isinstance(expected, OperationError) else describe(expected)
                out_of_contract.append(context | {"method": key, "native": expected_text, "actual": actual, "reason": "Binary operations require valid topology"})
                continue
            checked[method] += 1
            native_errors += isinstance(expected, OperationError)
            original_expected = expected
            if (name, key) in overlay_corrections:
                expected = overlay_corrections[name, key]
            corrected = known_collection_result(pair_inputs.get(name), key)
            if corrected is not None:
                native_text = describe(expected) if not isinstance(expected, OperationError) else expected.message
                difference = context | {"method": key, "expected": corrected, "native_expected": native_text, "actual": actual}
                if actual != corrected:
                    failures.append(difference)
                elif actual != str(expected):
                    known_differences.append(difference | {"reason": "Named GEOS 3.13.1 collection relation defect; exact corrected result required"})
                continue
            if method in {"intersection", "union", "difference", "symmetricDifference", "buffer", "bufferWithSegments", "pointOnSurface"} and isinstance(expected, BaseGeometry):
                expected = force_2d(expected)
            try:
                matched = operation_matches(method, actual, expected)
            except (ValueError, IndexError, struct.error, GEOSException) as failure:
                matched = False
                actual += " [invalid result: " + str(failure) + "]"
            if (name, key) in overlay_corrections and matched:
                native_text = original_expected.message if isinstance(original_expected, OperationError) else describe(original_expected)
                expected_text = expected.message if isinstance(expected, OperationError) else describe(expected)
                known_differences.append(context | {"method": key, "native_expected": native_text, "expected": expected_text, "actual": actual, "reason": correction_reasons[name, key]})
            if not matched:
                expected_text = "operation exception: " + expected.message if isinstance(expected, OperationError) else describe(expected)
                difference = context | {"method": key, "expected": expected_text, "actual": actual}
                if isinstance(expected, BaseGeometry):
                    difference["expected_structure"] = json.dumps(asdict(signature(expected)))
                    difference["reason"] = geometry_mismatch_reason(actual, expected)
                failures.append(difference)
    family_pairs = sorted({(sh.from_wkt(case.first).geom_type, sh.from_wkt(case.second).geom_type) for case in pairs}) if phases & {"relations", "overlay"} else []
    return {"requests": len(inputs), "native_operation_errors": native_errors, "family_pairs": family_pairs, "constructed_xy_absolute_tolerance": CONSTRUCTED_TOLERANCE, "out_of_contract": out_of_contract, "out_of_contract_count": len(out_of_contract)}

def main() -> int:
    """Run a bounded deterministic comparison and report every unexpected mismatch."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True, help="compiled geometry-simple-shapely-probe")
    parser.add_argument("--seed", type=int, default=20261003)
    parser.add_argument("--cases", type=int, default=1000, help="random shapes in addition to fixed fixtures")
    parser.add_argument("--report", type=Path, help="write counts and complete mismatch repros as JSON")
    parser.add_argument("--buffer-cases", type=int, default=24, help="random buffer shapes in addition to fixed fixtures; buffering costs more than predicates")
    parser.add_argument("--phase", nargs="+", choices=["all", "existing", "unary", "relations", "overlay", "buffer"], default=["all"], help="explicit operation groups; default checks every export")
    args = parser.parse_args()
    probe = cast(Path, args.probe)
    seed = cast(int, args.seed)
    case_count = cast(int, args.cases)
    buffer_count = cast(int, args.buffer_cases)
    report = cast(Path | None, args.report)
    phases = set(cast(list[str], args.phase))
    if "all" in phases:
        phases = {"existing", "unary", "relations", "overlay", "buffer"}
    if min(case_count, buffer_count) < 0:
        parser.error("--cases and --buffer-cases must be nonnegative")
    rng = random.Random(seed)
    cases = fixed_cases() + codec_cases() + [random_case(rng, i) for i in range(case_count)] if "existing" in phases else []
    requests: list[Request] = []
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        for case in cases:
            request = read_request(case, "WKT", case.wkt)
            requests.append(request)
            geometry = request.geometry
            if geometry is None:
                continue
            if case.name.startswith("random-") and not geometry.is_valid:
                raise RuntimeError("Random generator produced invalid topology: " + case.wkt)
            text = str(sh.to_wkt(geometry, rounding_precision=-1, output_dimension=4))
            requests.append(read_request(case, "WKT", text))
            for byte_order in (0, 1):
                blob = sh.to_wkb(geometry, byte_order=byte_order, output_dimension=4, flavor="iso")
                requests.append(read_request(case, "WKB", blob.hex()))
        if "existing" in phases:
            requests.extend(binary_requests())
            requests.extend(constructor_requests())
    inputs = [("CODEC-" if codec_only(request) else "") + request.format_name + "\t" + request.payload for request in requests]
    completed = subprocess.run([str(probe.resolve())], input="\n".join(inputs) + ("\n" if inputs else ""), text=True, capture_output=True, check=True)
    lines = completed.stdout.splitlines()
    if len(lines) != len(requests):
        raise RuntimeError(f"Probe returned {len(lines)} responses for {len(requests)} requests: {completed.stderr}")
    checked: Counter[str] = Counter()
    failures: list[dict[str, str]] = []
    known_differences: list[dict[str, str]] = []
    rejected = 0
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        for request, line in zip(requests, lines, strict=True):
            case, format_name, payload, geometry = request.case, request.format_name, request.payload, request.geometry
            if geometry is None:
                checked["decode" + format_name] += 1
                rejected += 1
                if not line.startswith("ERROR\t"):
                    failures.append({"case": case.name, "method": "decode" + format_name, "format": format_name, "input": payload, "expected": request.error or "native reader rejection", "actual": line})
                continue
            input_method = "constructGeometry" if format_name == "CONSTRUCT" else "decode" + format_name
            if not line.startswith("OK\t"):
                failures.append({"case": case.name, "method": input_method, "format": format_name, "input": payload, "expected": "successful native decode", "actual": line})
                continue
            actual_fields = dict(field.split("=", 1) for field in line.split("\t")[1:])
            expected_fields = {} if codec_only(request) else expected_results(geometry)
            expected_fields.update(codec_results(geometry))
            expected_fields[input_method] = geometry
            if actual_fields.keys() != expected_fields.keys():
                failures.append({"case": case.name, "method": "protocol", "format": format_name, "input": payload, "expected": str(sorted(expected_fields)), "actual": str(sorted(actual_fields))})
            for key, expected in expected_fields.items():
                method = key.split(".", 1)[0]
                checked[method] += 1
                actual = actual_fields.get(key, "!missing field")
                try:
                    matched = matches(method, actual, expected, case.name.startswith("numeric-"))
                except (ValueError, IndexError, struct.error) as failure:
                    actual += " [invalid result: " + str(failure) + "]"
                    matched = False
                if matched:
                    continue
                difference = {"case": case.name, "method": key, "format": format_name, "input": payload, "expected": describe(expected), "actual": actual}
                failures.append(difference)
    topology_summary = run_operations(probe, phases, seed, case_count, buffer_count, checked, failures, known_differences)
    selected_methods: set[str] = set()
    groups = {"unary": UNARY_METHODS, "relations": RELATION_METHODS, "overlay": OVERLAY_METHODS, "buffer": BUFFER_METHODS}
    for phase, methods in groups.items():
        if phase in phases:
            selected_methods.update(methods)
    if "existing" in phases:
        selected_methods.update(METHODS.keys() - (UNARY_METHODS.keys() | RELATION_METHODS.keys() | OVERLAY_METHODS.keys() | BUFFER_METHODS.keys()))
    missing = selected_methods - checked.keys()
    if missing:
        raise RuntimeError("Methods were not exercised: " + ", ".join(sorted(missing)))
    mismatch_counts = Counter(failure["method"].split(".", 1)[0] for failure in failures)
    known_counts = Counter(difference["method"] for difference in known_differences)
    summary: dict[str, object] = {"shapely": sh.__version__, "geos": sh.geos_version_string, "phases": sorted(phases), "topology": topology_summary, "seed": seed, "random_cases": case_count, "buffer_random_cases": buffer_count, "shapes": len(cases), "requests": len(requests), "native_rejections": rejected, "methods": dict(sorted(checked.items())), "known_difference_counts": dict(sorted(known_counts.items())), "known_differences": known_differences, "mismatch_counts": dict(sorted(mismatch_counts.items())), "mismatches": failures}
    if report is not None:
        report.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Shapely {sh.__version__}; GEOS {sh.geos_version_string}; seed {seed}; {len(cases)} existing shapes; {len(requests)} existing requests; {topology_summary['requests']} topology requests")
    for method, count in sorted(checked.items()):
        print(f"{method}: {count} comparisons [{METHODS[method]}]")
    print(f"Known native differences: {len(known_differences)}")
    print(f"Out-of-contract binary outcomes: {topology_summary['out_of_contract_count']}")
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
