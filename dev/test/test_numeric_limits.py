# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely==2.1.2", "types-shapely==2.1.0.20260728"]
# ///
# pyright: strict
"""Check numerical contracts with exact orientation and high-precision distances."""

import argparse
from decimal import Decimal, localcontext
from fractions import Fraction
import math
from pathlib import Path
import random
import subprocess
from typing import TypeAlias

from shapely_compare import read_structure

Point: TypeAlias = tuple[float, float]
Triangle: TypeAlias = tuple[Point, Point, Point]


def responses(probe: Path, requests: list[str]) -> list[dict[str, str]]:
    """Run the public operations and retain explicit errors as failures."""
    result = subprocess.run([str(probe)], input="\n".join(requests) + "\n", text=True, capture_output=True, check=True)
    lines = result.stdout.splitlines()
    if len(lines) != len(requests) or any(not line.startswith("OK\t") for line in lines):
        raise AssertionError(result.stdout + result.stderr)
    return [dict(field.split("=", 1) for field in line.split("\t")[1:]) for line in lines]


def turn(a: Point, b: Point, c: Point) -> Fraction:
    """Determine orientation from the stored binary64 values without rounding."""
    ax, ay = map(Fraction, a)
    bx, by = map(Fraction, b)
    cx, cy = map(Fraction, c)
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


def triangles(count: int, seed: int) -> list[Triangle]:
    """Move one vertex of a collinear triple by one ULP at several scales."""
    rng = random.Random(seed)
    result: list[Triangle] = []
    for _ in range(count):
        scale = 2.0 ** rng.choice([-500, -40, 0, 40, 500])
        offset = rng.choice([0, 1000, 1e10]) * scale
        xs = [rng.uniform(-4, 4) * scale + offset for _ in range(3)]
        slope = rng.choice([0.5, 1, 1.5, 2, 3])
        ys = [slope * x for x in xs]
        index = rng.randrange(3)
        ys[index] = math.nextafter(ys[index], math.inf)
        triangle = ((xs[0], ys[0]), (xs[1], ys[1]), (xs[2], ys[2]))
        if turn(*triangle):
            result.append(triangle)
    return result


def check_representatives(probe: Path, count: int, seed: int) -> int:
    """Require a finite point inside or on each independently valid triangle."""
    inputs = triangles(count, seed)
    wkts = ["POLYGON ((" + ",".join(f"{x!r} {y!r}" for x, y in points + points[:1]) + "))" for points in inputs]
    for triangle, wkt, fields in zip(inputs, wkts, responses(probe, [f"TOPO-WKT\tunary\t{wkt}" for wkt in wkts]), strict=True):
        assert fields["isValid"] == "True", wkt
        shape = read_structure(fields["pointOnSurface"])
        assert shape.kind == 0 and shape.layout == "XY" and len(shape.coordinates) == 1, (wkt, shape)
        x, y = (float.fromhex(value) for value in shape.coordinates[0])
        assert math.isfinite(x) and math.isfinite(y), (wkt, shape)
        point = (x, y)
        signs = [turn(a, b, point) for a, b in zip(triangle, triangle[1:] + triangle[:1], strict=True)]
        assert all(value >= 0 for value in signs) or all(value <= 0 for value in signs), (wkt, point)
    return len(inputs)


def check_distances(probe: Path) -> int:
    """Compare point-to-segment distances with a 200-digit square root."""
    requests: list[str] = []
    expected: list[float] = []
    for power in [-1074, -1070, -1022, -500, 0, 500, 1000]:
        scale = 2.0 ** power
        for i in range(1, 9):
            for j in range(1, 9):
                x, y = i * scale, j * scale
                with localcontext() as context:
                    context.prec = 200
                    a, b = Decimal(x), Decimal(y)
                    distance = float(a * b / (a * a + b * b).sqrt())
                line = f"LINESTRING ({x!r} 0,0 {y!r})"
                for first, second in [("POINT (0 0)", line), (line, "POINT (0 0)")]:
                    requests.append(f"PAIR-WKT\trelations\t{first}\t{second}")
                    expected.append(distance)
    for request, target, fields in zip(requests, expected, responses(probe, requests), strict=True):
        actual = float(fields["distance"])
        assert fields["disjoint"] == "True", request
        assert math.isfinite(actual) and actual > 0, (request, actual, target)
        assert abs(actual - target) <= math.ulp(target), (request, actual, target)
    return len(requests)


def main() -> None:
    """Keep independent checks separate from the GEOS comparison tolerances."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--cases", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=20261005)
    arguments = parser.parse_args()
    probe = Path(arguments.probe)
    points = check_representatives(probe, arguments.cases, arguments.seed)
    distances = check_distances(probe)
    print(f"Independent numeric checks: {points} representative points and {distances} distances passed")


if __name__ == "__main__":
    main()
