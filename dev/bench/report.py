# pyright: strict
"""Check public-function coverage and summarize audit CSV files as Markdown."""

import argparse
from collections import defaultdict
import csv
from dataclasses import dataclass
from pathlib import Path
import re
from statistics import median
import sys


Key = tuple[str, str, str, int]
Case = tuple[str, str, str]
SIZES = (100, 400, 1600)


@dataclass(frozen=True)
class Trial:
    """One completed batch or a time limit, divided by its iteration count."""

    ns: float
    allocated: float
    completed: bool


@dataclass(frozen=True)
class Result:
    """The median completed sample, or the largest exceeded time limit."""

    ns: float
    allocated: float | None
    samples: int
    timeouts: int


def public_functions(root: Path) -> set[str]:
    """Read function names from the four stable module export lists."""
    names: set[str] = set()
    for module in ("Geometry", "Geometry/SimpleFeatures", "Geometry/WKB", "Geometry/WKT"):
        source = (root / "src" / "Data" / f"{module}.hs").read_text()
        match = re.search(r"\bmodule\s+[\w.]+\s*\((.*?)\)\s*where", source, re.DOTALL)
        if match is None:
            raise ValueError(f"Missing export list: {module}")
        exports = re.sub(r"--[^\n]*", "", match[1])
        names.update(name.strip() for name in exports.split(",") if re.fullmatch(r"\s*[a-z]\w*\s*", name))
    return names


def read_results(paths: list[str]) -> dict[Key, Result]:
    """Combine trials from separate invocations without dropping timeouts."""
    trials: dict[Key, list[Trial]] = defaultdict(list)
    for path in paths:
        with Path(path).open(newline="") as source:
            for row in csv.DictReader(source):
                key = (row["group"], row["operation"], row["case"], int(row["size"]))
                status = row["status"]
                if status not in ("ok", "timeout"):
                    raise ValueError(f"Unknown result status: {status}")
                trials[key].append(Trial(float(row["ns_per_call"]), float(row["allocated_bytes_per_call"]), status == "ok"))
    results: dict[Key, Result] = {}
    for key, values in trials.items():
        completed = [value for value in values if value.completed]
        timeouts = len(values) - len(completed)
        results[key] = Result(
            median(value.ns for value in completed) if completed else max(value.ns for value in values),
            median(value.allocated for value in completed) if completed else None,
            len(completed),
            timeouts,
        )
    return results


def check_coverage(results: dict[Key, Result], expected: set[str]) -> list[Case]:
    """Require every stable function and each workload at all three main sizes."""
    observed = {operation for group, operation, _, size in results if group != "harness" and size in SIZES}
    if observed != expected:
        raise ValueError(f"Function coverage: missing={sorted(expected - observed)}, extra={sorted(observed - expected)}")
    cases = sorted({(group, operation, case) for group, operation, case, _ in results})
    missing = [(group, operation, case, size) for group, operation, case in cases for size in SIZES if (group, operation, case, size) not in results]
    if missing:
        raise ValueError(f"Missing workload sizes: {missing}")
    return cases


def time_text(result: Result) -> str:
    """Keep sub-microsecond figures coarse enough to show harness overhead."""
    ns = result.ns
    if ns < 100:
        value = "<0.1 µs"
    elif ns < 1e6:
        value = f"{ns / 1e3:.3g} µs"
    elif ns < 1e9:
        value = f"{ns / 1e6:.3g} ms"
    else:
        value = f"{ns / 1e9:.3g} s"
    if result.samples == 0:
        return ">" + value
    return value + (" †" if result.timeouts else "")


def allocation_text(result: Result) -> str:
    """Show cumulative allocation per call, not retained or peak memory."""
    value = result.allocated
    if value is None:
        return "—"
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.3g} {unit}"
        value /= 1024
    raise AssertionError("Unreachable allocation unit")


def case_row(case: Case, results: dict[Key, Result]) -> str:
    """Report one fixed workload across sizes; do not mix different cases."""
    group, operation, label = case
    samples = [results[(group, operation, label, size)] for size in SIZES]
    small, large = samples[1:]
    ratio = f"{large.ns / small.ns:.1f}×" if small.ns >= 1000 and all(result.samples and not result.timeouts for result in (small, large)) else "—"
    return f"| `{operation}` | {label} | " + " | ".join(time_text(result) for result in samples) + f" | {ratio} | {allocation_text(large)} |"


def write_report(results: dict[Key, Result], cases: list[Case], expected: set[str], before: dict[Key, Result] | None = None) -> None:
    """Write complete results plus a compact worst-case table for each function."""
    print("# Performance audit results\n")
    print(f"Coverage: **{len(expected)} stable public functions**, **{sum(group != 'harness' for group, _, _ in cases)} workloads**, at sizes 100, 400, and 1,600. The harness baseline is separate.\n")
    print("Record the source revision, compiler, hardware, and commands with these results. See CONTRIBUTING.md for the benchmark commands.\n")
    print("Times below 200 ms use the median of three measured batches after a pilot call. Slower calls have one sample. Additional invocations contribute more samples when present. Allocation is cumulative per call; it is not peak memory. `>` denotes a timeout lower bound. `†` marks completed samples accompanied by a timeout. Ratios compare the same workload at 400 and 1,600.\n")
    print("## Slowest measured workload for each function\n")
    print("Selection uses time at size 1,600 in " + ("the previous audit where available, otherwise this audit" if before is not None else "this audit") + ". These are the slowest cases in that corpus, not proven worst-case bounds.\n")
    header = "| Function | Case | 100 | 400 | 1,600 | Time ratio, 4× input | Allocation at 1,600 |\n| --- | --- | ---: | ---: | ---: | ---: | ---: |"
    if before is None:
        print(header)
    else:
        labels, dividers = header.splitlines()
        print(labels + " Previous time at 1,600 | Speedup |")
        print(dividers + " ---: | ---: |")
    for operation in sorted(expected):
        choices = [case for case in cases if case[1] == operation]
        common = [] if before is None else [case for case in choices if (*case, 1600) in before]
        reference = before if common and before is not None else results
        worst = max(common or choices, key=lambda case: reference[(*case, 1600)].ns)
        row = case_row(worst, results)
        if before is not None:
            old = before.get((*worst, 1600))
            current = results[(*worst, 1600)]
            speedup = f"{old.ns / current.ns:.3g}×" if old is not None and old.samples and current.samples and current.ns > 0 and not (old.timeouts or current.timeouts) else "—"
            row += f" {time_text(old) if old is not None else '—'} | {speedup} |"
        print(row)
    print("\n## Every workload\n")
    for group in sorted({case[0] for case in cases}):
        print(f"### {group}\n")
        print(header)
        for case in cases:
            if case[0] == group:
                print(case_row(case, results))
        print()
    print("## Larger inputs\n")
    print("These runs cover selected accessors, measurements, measured locations, and codecs. Topology remains in the smaller sweep. The `nested` case measures collection depth; line cases measure coordinate count.\n")
    print("| Function | Case | Size | Time | Allocation | Completed samples | Timeouts |\n| --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for (group, operation, case, size), result in sorted(results.items()):
        if size not in SIZES:
            print(f"| `{operation}` | {case} | {size:,} | {time_text(result)} | {allocation_text(result)} | {result.samples} | {result.timeouts} |")


def main(paths: list[str]) -> None:
    """Validate coverage before producing a report from one or more CSV files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", help="Previous audit CSV; missing workloads have no comparison")
    parser.add_argument("paths", nargs="+", help="Current audit CSV files")
    arguments = parser.parse_intermixed_args(paths)
    before = None if arguments.before is None else read_results([arguments.before])
    root = Path(__file__).resolve().parents[2]
    expected = public_functions(root)
    results = read_results(arguments.paths)
    write_report(results, check_coverage(results, expected), expected, before)


if __name__ == "__main__":
    main(sys.argv[1:])
