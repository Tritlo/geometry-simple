# pyright: strict
"""Check that the published source archive contains only the MIT library."""

from pathlib import PurePosixPath
import sys
import tarfile


def check_archive(path: str) -> None:
    """Reject development files and components in one release archive."""
    allowed = {"src", "docs", "LICENSE", "README.md", "CHANGELOG.md", "geometry-simple.cabal", "Setup.hs"}
    with tarfile.open(path) as archive:
        files = [member for member in archive.getmembers() if member.isfile()]
        for member in files:
            parts = PurePosixPath(member.name).parts
            if len(parts) < 2 or parts[1] not in allowed:
                raise SystemExit(f"Unexpected release file: {member.name}")
        package = next(member for member in files if member.name.endswith("/geometry-simple.cabal"))
        source = archive.extractfile(package)
        if source is None:
            raise SystemExit("Missing package description")
        description = source.read().decode()
        if any(line.startswith(("test-suite ", "benchmark ", "executable ")) for line in description.splitlines()):
            raise SystemExit("Development component found in the release package")
        if "license: MIT\n" not in description:
            raise SystemExit("The release package must declare the MIT license")
    print(f"Library-only source archive: {path}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check_sdist.py ARCHIVE.tar.gz")
    check_archive(sys.argv[1])
