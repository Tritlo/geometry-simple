# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely==2.1.2", "types-shapely==2.1.0.20260728"]
# ///
# pyright: strict
"""Check that the native ambiguity diagnostic rejects unrelated regressions."""

from dataclasses import replace
import unittest

import shapely as sh
from shapely_compare import COINCIDENT_SHELLS, PairCase, Shape, coincident_ordinate_difference, restore_closing_m, signature


ACTUAL = signature(sh.from_wkt("POLYGON ZM ((5 4 45 24,6 4 47 25,7 2 47 32,6 2 45 31,5 4 45 24))"))
EXPECTED = sh.union(sh.from_wkt(COINCIDENT_SHELLS.first), sh.from_wkt(COINCIDENT_SHELLS.second))


def changed_ordinate(index: int, ordinate: int, value: float) -> Shape:
    """Change one output ordinate without changing the diagnostic inputs."""
    ring = ACTUAL.children[0]
    rows = list(ring.coordinates)
    row = list(rows[index])
    row[ordinate] = value.hex()
    rows[index] = tuple(row)
    return replace(ACTUAL, children=(replace(ring, coordinates=tuple(rows)),))


class CoincidentOrdinateTests(unittest.TestCase):
    """Keep the documented exception smaller than the geometry contract."""

    def test_complete_source_tuples_are_accepted(self) -> None:
        self.assertTrue(coincident_ordinate_difference(COINCIDENT_SHELLS, "union", ACTUAL, EXPECTED))

    def test_invented_z_is_rejected(self) -> None:
        self.assertFalse(coincident_ordinate_difference(COINCIDENT_SHELLS, "union", changed_ordinate(1, 2, 999.0), EXPECTED))

    def test_mixing_two_source_tuples_is_rejected(self) -> None:
        self.assertFalse(coincident_ordinate_difference(COINCIDENT_SHELLS, "union", changed_ordinate(1, 3, 1.0), EXPECTED))

    def test_changed_xy_is_rejected(self) -> None:
        self.assertFalse(coincident_ordinate_difference(COINCIDENT_SHELLS, "union", changed_ordinate(1, 0, 6.01), EXPECTED))

    def test_changed_family_is_rejected(self) -> None:
        self.assertFalse(coincident_ordinate_difference(COINCIDENT_SHELLS, "union", replace(ACTUAL, kind=6), EXPECTED))

    def test_changed_nonshared_ordinate_is_rejected(self) -> None:
        expected = sh.intersection(sh.from_wkt(COINCIDENT_SHELLS.first), sh.from_wkt(COINCIDENT_SHELLS.second))
        actual = restore_closing_m(signature(expected))
        shell, hole = actual.children
        rows = list(hole.coordinates)
        rows[1] = rows[1][:2] + (float(999).hex(),) + rows[1][3:]
        actual = replace(actual, children=(shell, replace(hole, coordinates=tuple(rows))))
        self.assertFalse(coincident_ordinate_difference(COINCIDENT_SHELLS, "intersection", actual, expected))

    def test_different_inputs_or_methods_are_rejected(self) -> None:
        other = PairCase(COINCIDENT_SHELLS.name, "POLYGON EMPTY", COINCIDENT_SHELLS.second)
        self.assertFalse(coincident_ordinate_difference(other, "union", ACTUAL, EXPECTED))
        self.assertFalse(coincident_ordinate_difference(COINCIDENT_SHELLS, "difference", ACTUAL, EXPECTED))


if __name__ == "__main__":
    unittest.main()
