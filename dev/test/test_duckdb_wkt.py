# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb==1.5.5"]
# ///
# pyright: strict
"""Check collection codec output with DuckDB's spatial reader."""

import argparse
import subprocess

import duckdb


def fixtures() -> list[str]:
    """Cover every layout, nested collections, and typed empty members."""
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
    return result


def check(probe: str) -> None:
    """Read Haskell WKT and WKB output and compare DuckDB's stored geometry."""
    inputs = fixtures()
    output = subprocess.run(
        [probe],
        input="".join(f"CODEC-WKT\t{text}\n" for text in inputs),
        text=True,
        capture_output=True,
        check=True,
    )
    responses = output.stdout.splitlines()
    assert len(responses) == len(inputs), output.stdout
    with duckdb.connect() as connection:
        try:
            connection.execute("LOAD spatial")
        except duckdb.IOException:
            connection.execute("INSTALL spatial FROM 'https://extensions.duckdb.org'")
            connection.execute("LOAD spatial")
        for source, response in zip(inputs, responses, strict=True):
            status, *fields = response.split("\t")
            assert status == "OK", (source, response)
            values = dict(field.split("=", 1) for field in fields)
            expected = connection.execute("SELECT ST_AsWKB(ST_GeomFromText(?))", [source]).fetchone()
            from_text = connection.execute(
                "SELECT ST_AsWKB(ST_GeomFromText(?))", [values["encodeWKT"]]
            ).fetchone()
            from_binary = connection.execute(
                "SELECT ST_AsWKB(ST_GeomFromWKB(?))", [bytes.fromhex(values["encodeWKB"])]
            ).fetchone()
            assert expected == from_text == from_binary, (source, response)
    print(f"DuckDB {duckdb.__version__}: {len(inputs)} collection fixtures passed through both WKT and WKB")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, help="Path to geometry-simple-shapely-probe")
    check(parser.parse_args().probe)
