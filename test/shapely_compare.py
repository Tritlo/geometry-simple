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

Raw structure comparisons retain every member and ring layout, including
empty values. Selectors use zero-based indices. Hull coordinates and order
are compared directly. WKT checks use native writer structure and original
coordinate bits, with NaN padding where GEOS requires it. WKB checks include
every type tag. Codec-only requests omit measurements on nonfinite inputs.

Only hull-duplicate-z-51 permits a different input Z at duplicate XY. GEOS
can select another duplicate when sorting. Both hulls must remain XYZ lines
with two vertices and identical XY coordinates and order. The report retains
both results under known_differences. Every other hull comparison is strict.
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
get_point = cast(Callable[[BaseGeometry, int], BaseGeometry | None], getattr(sh, "get_point"))
get_interior_ring = cast(Callable[[BaseGeometry, int], BaseGeometry | None], getattr(sh, "get_interior_ring"))
get_exterior_ring = cast(Callable[[BaseGeometry], BaseGeometry | None], getattr(sh, "get_exterior_ring"))

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
    "geometryN": "get_geometry(index), reject negative indices",
    "numPoints": "get_num_points for LineString, otherwise None",
    "pointN": "get_point(index) for LineString, reject negative indices",
    "startPoint": "get_point(0) for nonempty LineString",
    "endPoint": "get_point(-1) for nonempty LineString",
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
    "convexHull": "convex_hull, including layout and vertex order",
    "encodeWKT": "native writer tokens and exact source ordinates with NaN padding",
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
        "startPoint": get_point(geometry, 0) if kind == 1 else None,
        "endPoint": get_point(geometry, -1) if kind == 1 else None,
        "isClosed": bool(sh.is_closed(geometry)), "exteriorRing": get_exterior_ring(geometry) if kind == 3 else None,
        "numInteriorRings": ring_count, "envelope": sh.envelope(geometry),
        "area": float(area(geometry)), "geometryLength": float(length(geometry)), "curveLength": component_length(geometry, False),
        "perimeter": component_length(geometry, True), "centroid": sh.centroid(geometry), "convexHull": sh.convex_hull(geometry),
    }
    for i in range(-1, member_count + 2):
        values[f"geometryN.{i}"] = get_geometry(geometry, i) if 0 <= i < member_count else None
    for i in range(-1, (point_count or 0) + 2):
        values[f"pointN.{i}"] = get_point(geometry, i) if kind == 1 and 0 <= i < (point_count or 0) else None
    for i in range(-1, (ring_count or 0) + 2):
        values[f"interiorRingN.{i}"] = get_interior_ring(geometry, i) if kind == 3 and 0 <= i < (ring_count or 0) else None
    for i, row in enumerate(coordinate_rows(geometry)):
        for method, value in zip(("x", "y", "z", "m"), row, strict=True):
            values[f"{method}.{i}"] = value
    return values


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
                if not all(isinstance(v, str) for v in ordinates):
                    raise ValueError("Expected decimal ordinate strings")
                rows.append(tuple(float(cast(str, v)).hex() for v in ordinates))
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
        if method in ("x", "y", "z", "m"):
            return value.hex() == expected.hex()
        return value == expected or math.isclose(value, expected, rel_tol=1e-10, abs_tol=0.0 if strict else 1e-12)
    if isinstance(expected, str):
        return actual == expected
    if method == "encodeWKT":
        expected_text = sh.to_wkt(expected, rounding_precision=-1, output_dimension=4)
        tokens, numbers = wkt_tokens(actual)
        return tokens == wkt_tokens(expected_text)[0] and numbers == written_ordinates(expected)
    if method == "encodeWKB":
        native = sh.to_wkb(expected, byte_order=1, output_dimension=4, flavor="iso")
        return binary_signature(bytes.fromhex(actual)) == binary_signature(native)
    actual_shape, expected_shape = read_structure(actual), signature(expected)
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


def duplicate_z_difference(request: Request, method: str, actual: str, expected: Value) -> bool:
    """Recognize only the named duplicate selection diagnostic; keep XY strict."""
    if request.case.name != "hull-duplicate-z-51" or method != "convexHull" or request.geometry is None or not isinstance(expected, BaseGeometry):
        return False
    try:
        actual_shape = read_structure(actual)
    except ValueError:
        return False
    expected_shape = signature(expected)
    for shape in (actual_shape, expected_shape):
        if shape.kind != 1 or shape.layout != "XYZ" or len(shape.coordinates) != 2 or shape.children:
            return False
    if tuple(row[:2] for row in actual_shape.coordinates) != tuple(row[:2] for row in expected_shape.coordinates):
        return False
    input_coordinates = {tuple(value.hex() for value in row if value is not None) for row in coordinate_rows(request.geometry)}
    return all(row in input_coordinates for row in actual_shape.coordinates + expected_shape.coordinates)


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
    cases = fixed_cases() + codec_cases() + [random_case(rng, i) for i in range(case_count)]
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
        requests.extend(binary_requests())
        requests.extend(constructor_requests())
    inputs = [("CODEC-" if codec_only(request) else "") + request.format_name + "\t" + request.payload for request in requests]
    completed = subprocess.run([str(probe.resolve())], input="\n".join(inputs) + "\n", text=True, capture_output=True, check=True)
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
                if duplicate_z_difference(request, method, actual, expected):
                    difference["reason"] = "GEOS selected another input Z at duplicate XY; XYZ line type, vertex count, XY coordinates, and order match"
                    known_differences.append(difference)
                else:
                    failures.append(difference)
    missing = METHODS.keys() - checked.keys()
    if missing:
        raise RuntimeError("Methods were not exercised: " + ", ".join(sorted(missing)))
    mismatch_counts = Counter(failure["method"].split(".", 1)[0] for failure in failures)
    known_counts = Counter(difference["method"] for difference in known_differences)
    summary: dict[str, object] = {"shapely": sh.__version__, "geos": sh.geos_version_string, "seed": seed, "shapes": len(cases), "requests": len(requests), "native_rejections": rejected, "methods": dict(sorted(checked.items())), "known_difference_counts": dict(sorted(known_counts.items())), "known_differences": known_differences, "mismatch_counts": dict(sorted(mismatch_counts.items())), "mismatches": failures}
    if report is not None:
        report.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Shapely {sh.__version__}; GEOS {sh.geos_version_string}; seed {seed}; {len(cases)} shapes; {len(requests)} requests")
    for method, count in sorted(checked.items()):
        print(f"{method}: {count} comparisons [{METHODS[method]}]")
    print(f"Known duplicate-Z differences: {len(known_differences)}")
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
