# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb==1.5.5"]
# ///
# pyright: strict
"""Check geometry codecs against DuckDB's core WKT and WKB functions."""

import argparse
import subprocess

import duckdb


def fixtures() -> list[str]:
    """Cover every layout, nested collections, and empty multipoint members."""
    result = [
        "GEOMETRYCOLLECTION EMPTY",
        "GEOMETRYCOLLECTION (GEOMETRYCOLLECTION EMPTY, POINT (1 2))",
    ]
    for tag, first, second in [
        ("", "1 2", "3 4"),
        (" Z", "1 2 3", "4 5 6"),
        (" M", "1 2 3", "4 5 6"),
        (" ZM", "1 2 3 4", "5 6 7 8"),
    ]:
        point = f"POINT{tag} ({first})"
        line = f"LINESTRING{tag} ({first}, {second})"
        empty = f"POINT{tag} EMPTY"
        nested = f"GEOMETRYCOLLECTION{tag} ({empty}, {line})"
        for members in [point, f"{point}, {line}", f"{point}, {nested}", f"{empty}, LINESTRING{tag} EMPTY"]:
            result.append(f"GEOMETRYCOLLECTION{tag} ({members})")
        containers = ", ".join(f"{family}{tag} EMPTY" for family in ["MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON"])
        result.append(f"GEOMETRYCOLLECTION{tag} ({point}, {containers}, GEOMETRYCOLLECTION{tag} ({containers}))")
        for members in [
            f"EMPTY, ({first}), ({second})",
            f"({first}), EMPTY, ({second})",
            f"({first}), ({second}), EMPTY",
            f"EMPTY, ({first}), EMPTY, ({second}), EMPTY",
        ]:
            result.append(f"MULTIPOINT{tag} ({members})")
        result.append(f"GEOMETRYCOLLECTION{tag} (MULTIPOINT{tag} (EMPTY, ({first}), EMPTY), {point})")
    return result


def codec_outputs(probe: str, inputs: list[str]) -> list[dict[str, str]]:
    """Decode each input and return the probe's checked codec outputs."""
    output = subprocess.run(
        [probe],
        input="".join(f"CODEC-WKT\t{text}\n" for text in inputs),
        text=True,
        capture_output=True,
        check=True,
    )
    responses = output.stdout.splitlines()
    assert len(responses) == len(inputs), output.stdout
    result: list[dict[str, str]] = []
    for source, response in zip(inputs, responses, strict=True):
        status, *fields = response.split("\t")
        assert status == "OK", (source, response)
        result.append(dict(field.split("=", 1) for field in fields))
    return result


def check(probe: str) -> None:
    """Compare source WKT and actual ST_AsText output with stored native WKB."""
    cases: list[tuple[str, bytes]] = []
    with duckdb.connect() as connection:
        for source in fixtures():
            row = connection.execute(
                "SELECT ST_AsText(?::GEOMETRY), ST_AsWKB(?::GEOMETRY)", [source, source]
            ).fetchone()
            assert row is not None
            rendered, expected = row
            assert isinstance(rendered, str) and isinstance(expected, bytes)
            cases.extend([(source, expected), (rendered, expected)])
        outputs = codec_outputs(probe, [source for source, _ in cases])
        for (source, expected), values in zip(cases, outputs, strict=True):
            from_text = connection.execute(
                "SELECT ST_AsWKB(?::GEOMETRY)", [values["encodeWKT"]]
            ).fetchone()
            from_binary = connection.execute(
                "SELECT ST_AsWKB(ST_GeomFromWKB(?))", [bytes.fromhex(values["encodeWKB"])]
            ).fetchone()
            assert (expected,) == from_text == from_binary, (source, values)

        mixed = [
            "GEOMETRYCOLLECTION (POINT (1 2), POINT Z (3 4 5))",
            "GEOMETRYCOLLECTION (POINT Z (1 2 3), POINT M (4 5 6))",
        ]
        for source, values in zip(mixed, codec_outputs(probe, mixed), strict=True):
            blob = bytes.fromhex(values["encodeWKB"])
            stored = connection.execute("SELECT ST_AsWKB(ST_GeomFromWKB(?))", [blob]).fetchone()
            assert stored == (blob,), (source, stored)
            try:
                connection.execute("SELECT ST_AsText(ST_GeomFromWKB(?))", [blob]).fetchone()
            except duckdb.InvalidInputException as error:
                assert "inconsistent Z/M dimensions" in str(error), str(error)
            else:
                raise AssertionError(("mixed-layout WKB unexpectedly converted to WKT", source))
    print(f"DuckDB {duckdb.__version__}: {len(cases)} WKT inputs and {len(mixed)} mixed-layout WKB fixtures passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, help="Path to geometry-simple-shapely-probe")
    check(parser.parse_args().probe)
