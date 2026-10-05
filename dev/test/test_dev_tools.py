# pyright: strict
"""Exercise benchmark reports and release checks without uploading a package."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DevelopmentToolTests(unittest.TestCase):
    """Run the command-line entry points against isolated local fixtures."""

    def test_report_accepts_partial_baselines_and_option_positions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "dev/bench/report.py"
            report.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "dev/bench/report.py", report)
            for module in ("Geometry", "Geometry/SimpleFeatures", "Geometry/WKB", "Geometry/WKT"):
                source = root / "src/Data" / f"{module}.hs"
                source.parent.mkdir(parents=True, exist_ok=True)
                exports = "foo, bar" if module == "Geometry" else ""
                source.write_text(f"module Data.{module.replace('/', '.')} ({exports}) where\n")
            header = "group,operation,case,size,status,ns_per_call,allocated_bytes_per_call\n"
            current = root / "current.csv"
            current.write_text(header + "".join(
                f"measurements,{operation},{case},{size},ok,1000,100\n"
                for operation, case in (("foo", "old"), ("foo", "new"), ("bar", "new"))
                for size in (100, 400, 1600)))
            baseline = root / "baseline.csv"
            baseline.write_text(header + "measurements,foo,old,1600,ok,2000,200\n")
            for arguments in (("--before", str(baseline), str(current)),
                              (str(current), "--before", str(baseline))):
                result = subprocess.run([sys.executable, str(report), *arguments], text=True, capture_output=True, check=True)
                self.assertIn("| `bar` | new |", result.stdout)
                self.assertIn("2×", result.stdout)
                self.assertIn(" — | — |", result.stdout)

    def test_release_requires_clean_pushed_source(self) -> None:
        for state in ("dirty", "untracked", "unpushed", "pushed"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                repository = root / "repo"
                remote = root / "remote.git"
                subprocess.run(["git", "init", "--quiet", "--bare", str(remote)], check=True)
                subprocess.run(["git", "init", "--quiet", "--initial-branch=main", str(repository)], check=True)

                def git(*arguments: str) -> None:
                    subprocess.run(["git", "-C", str(repository), *arguments], check=True, capture_output=True)

                git("config", "user.name", "Release test")
                git("config", "user.email", "release@example.invalid")
                scripts = repository / "scripts"
                scripts.mkdir()
                shutil.copyfile(ROOT / "scripts/release.sh", scripts / "release.sh")
                git("add", ".")
                git("commit", "--quiet", "-m", "Initial source")
                git("remote", "add", "origin", str(remote))
                git("push", "--quiet", "origin", "main")
                if state == "dirty":
                    with (scripts / "release.sh").open("a") as source:
                        source.write("\n# Changed source.\n")
                elif state == "untracked":
                    (repository / "untracked.hs").write_text("module Untracked where\n")
                elif state == "unpushed":
                    git("commit", "--quiet", "--allow-empty", "-m", "Unpushed source")
                binaries = root / "bin"
                binaries.mkdir()
                stub = binaries / "cabal"
                stub.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RELEASE_CHECK_LOG"\nexit 77\n')
                stub.chmod(0o755)
                log = root / "cabal.log"
                environment = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"], RELEASE_CHECK_LOG=str(log))
                result = subprocess.run(["bash", str(scripts / "release.sh")], env=environment, text=True, capture_output=True)
                if state == "pushed":
                    self.assertEqual(result.returncode, 77, result.stderr)
                    self.assertEqual(log.read_text(), "check\n")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(log.exists(), result.stderr)
                    self.assertIn("clean working tree" if state in ("dirty", "untracked") else "pushed origin/main", result.stderr)


if __name__ == "__main__":
    unittest.main()
