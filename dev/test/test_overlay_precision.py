# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely==2.1.2", "types-shapely==2.1.0.20260728"]
# ///
# pyright: strict
"""Compare near-coincident polygon overlays with GEOS at a stated precision."""

import argparse
from fractions import Fraction
import math
from pathlib import Path
import random
import subprocess
from typing import Callable

import shapely as sh
from shapely.geometry.base import BaseGeometry
from shapely_compare import read_structure, shape_geometry

TRIANGLE_A = "POLYGON ((-0.5 17,-18.5 1.5,40.5 35.5,-0.5 17))"
TRIANGLE_B = "POLYGON ((-0.499999999999993 17.00000000000001,-18.499999999999993 1.50000000000001,40.50000000000001 35.50000000000001,-0.499999999999993 17.00000000000001))"
OPERATIONS: dict[str, Callable[[BaseGeometry, BaseGeometry], BaseGeometry]] = {
    "intersection": sh.intersection, "union": sh.union,
    "difference": sh.difference, "symmetricDifference": sh.symmetric_difference,
}


def cases(count: int, seed: int) -> list[tuple[str, str]]:
    """Perturb convex vertices by 1 to 16 ULPs at several binary scales."""
    rng = random.Random(seed)
    result = [(TRIANGLE_A, TRIANGLE_B)]
    for index in range(count):
        hull = sh.convex_hull(sh.MultiPoint([(rng.randint(-80, 80) / 2, rng.randint(-80, 80) / 2) for _ in range(rng.randint(3, 8))]))
        if not isinstance(hull, sh.Polygon):
            continue
        scale = 2.0 ** rng.choice([-40, -10, 0, 10, 40])
        coordinates = [(x * scale, y * scale) for x, y in hull.exterior.coords[:-1]]

        def shift(value: float) -> float:
            # Keep zero fixed here. The separate exact check covers subnormals.
            if value == 0:
                return value
            for _ in range(rng.randint(1, 16)):
                value = math.nextafter(value, math.inf if index % 2 else -math.inf)
            return value

        first = sh.Polygon(coordinates)
        if index % 3 == 0:
            target = coordinates[:2] + [(rng.randint(-80, 80) * scale, rng.randint(-80, 80) * scale)]
        elif index % 3 == 1:
            dx, dy = rng.randint(-8, 8) * scale, rng.randint(-8, 8) * scale
            target = [(x + dx, y + dy) for x, y in coordinates]
        else:
            target = coordinates
        second = sh.Polygon([(shift(x), shift(y)) for x, y in target])
        if first.is_valid and second.is_valid:
            result.append((str(sh.to_wkt(first, rounding_precision=-1)), str(sh.to_wkt(second, rounding_precision=-1))))
    return result + [(b, a) for a, b in result]


def responses(probe: Path, pairs: list[tuple[str, str]]) -> list[dict[str, str]]:
    """Evaluate the four operations independently through the Haskell probe."""
    request = "".join(f"PAIR-WKT\toverlay\t{a}\t{b}\n" for a, b in pairs)
    result = subprocess.run([str(probe)], input=request, capture_output=True, text=True, check=True)
    lines = result.stdout.splitlines()
    if len(lines) != len(pairs) or any(not line.startswith("OK\t") for line in lines):
        raise AssertionError(result.stdout + result.stderr)
    return [dict(item.split("=", 1) for item in line.split("\t")[1:]) for line in lines]


def check_subnormal_result(probe: Path) -> None:
    """Use exact orientation where GEOS's floating calculations underflow."""
    a = "POLYGON ((0.0380859375 -0.03125,0 -0.02294921875,-0.01806640625 0.0234375,0.01708984375 0.03564453125,0.03466796875 -0.0068359375,0.0380859375 -0.03125))"
    b = "POLYGON ((0.0380859375 -0.03125,8e-323 -0.02294921875,-0.01806640625 0.0234375,0.01708984375 0.0356445312500001,0.03466796875 -0.0068359375,0.0380859375 -0.03125))"
    result = shape_geometry(read_structure(responses(probe, [(a, b)])[0]["difference"]))
    assert isinstance(result, sh.Polygon) and not result.is_empty
    assert not result.interiors
    points = [(Fraction(row[0]), Fraction(row[1])) for row in result.exterior.coords[:-1]]
    assert len(points) == len(set(points)) == 4

    def turn(p: tuple[Fraction, Fraction], q: tuple[Fraction, Fraction], r: tuple[Fraction, Fraction]) -> Fraction:
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])

    # Each opposite edge has both endpoints on the same side of its partner.
    # Thus neither pair can intersect, even though GEOS reports a self-intersection at the original scale.
    p, q, r, s = points
    assert turn(p, q, r) * turn(p, q, s) > 0
    assert turn(q, r, s) * turn(q, r, p) > 0
    area = sum(p[0] * q[1] - p[1] * q[0] for p, q in zip(points, points[1:] + points[:1], strict=True)) / 2
    assert area > 0


def main() -> None:
    """Keep result differences small and confined to the input boundaries."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--cases", type=int, default=100)
    parser.add_argument("--seed", type=int, default=20261005)
    arguments = parser.parse_args()
    probe = Path(arguments.probe)
    pairs = cases(arguments.cases, arguments.seed)
    for (wa, wb), fields in zip(pairs, responses(probe, pairs), strict=True):
        a, b = sh.from_wkt(wa), sh.from_wkt(wb)
        magnitude = max(abs(value) for value in a.bounds + b.bounds)
        area_limit = 1e-9 * magnitude * magnitude
        boundary_band = a.boundary.union(b.boundary).buffer(1e-8 * magnitude)
        for name, operation in OPERATIONS.items():
            context = f"{name}: {wa}; {wb}; {fields[name]}"
            assert not fields[name].startswith("!"), context
            actual = shape_geometry(read_structure(fields[name]))
            expected = operation(a, b)
            assert actual.is_valid, context
            delta = sh.symmetric_difference(actual, expected)
            assert delta.area <= area_limit, context
            if not delta.is_empty:
                assert boundary_band.covers(delta), context
    check_subnormal_result(probe)
    print(f"GEOS {sh.geos_version_string}: {4 * len(pairs)} precision comparisons and one exact subnormal check passed")


if __name__ == "__main__":
    main()
