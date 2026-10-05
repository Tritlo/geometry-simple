# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely==2.1.2", "types-shapely==2.1.0.20260728"]
# ///
# pyright: strict
"""Check that comparison adapters reject coordinate and layout regressions."""

import json
import unittest

import shapely as sh
from shapely_compare import Shape, matches, operation_matches, signature, stored_point


def raw_geometry(wkt: str) -> str:
    """Encode an independent fixture in the Haskell probe's JSON format."""
    def node(shape: Shape) -> list[object]:
        body: object = [[str(float.fromhex(value)) for value in row] for row in shape.coordinates] if shape.kind in (0, 1) else [node(child) for child in shape.children]
        return [shape.kind, shape.layout, body]
    return json.dumps(node(signature(sh.from_wkt(wkt))))


class PlanarResultTests(unittest.TestCase):
    """Keep XY geometry and output layout checks independent of native Z/M."""

    def test_extra_ordinates_are_rejected(self) -> None:
        self.assertFalse(operation_matches("intersection", raw_geometry("POINT Z (1 2 3)"), sh.from_wkt("POINT (1 2)")))

    def test_changed_xy_is_rejected(self) -> None:
        self.assertFalse(operation_matches("intersection", raw_geometry("POINT (1.01 2)"), sh.from_wkt("POINT (1 2)")))

    def test_changed_family_is_rejected(self) -> None:
        self.assertFalse(operation_matches("intersection", raw_geometry("MULTIPOINT ((1 2))"), sh.from_wkt("POINT (1 2)")))

    def test_hull_winding_and_vertices_are_checked(self) -> None:
        expected = sh.from_wkt("POLYGON ((0 0,0 1,1 0,0 0))")
        self.assertTrue(matches("convexHull", raw_geometry("POLYGON ((1 0,0 1,0 0,1 0))"), expected, True))
        self.assertFalse(matches("convexHull", raw_geometry("POLYGON ((0 0,0 1,1 0,0 0))"), expected, True))
        self.assertFalse(matches("convexHull", raw_geometry("POLYGON ((0 0,2 0,0 1,0 0))"), expected, True))

    def test_point_observers_retain_unknown_ordinates(self) -> None:
        line = sh.from_wkt("LINESTRING ZM (1 2 NaN 7,3 4 6 NaN)")
        expected = stored_point(line, 0)
        self.assertTrue(matches("pointN", '[0,"XYZM",[["1","2","NaN","7"]]]', expected, True))
        self.assertFalse(matches("pointN", raw_geometry("POINT M (1 2 7)"), expected, True))


class CollectionWKTTests(unittest.TestCase):
    """Permit omitted collection tags while checking all member data."""

    def test_readable_mixed_collection_is_accepted(self) -> None:
        text = "GEOMETRYCOLLECTION (POINT (1 2), GEOMETRYCOLLECTION (POINT Z (3 4 5), POINT M EMPTY))"
        self.assertTrue(matches("encodeWKT", text, sh.from_wkt(text), True))

    def test_member_changes_are_rejected(self) -> None:
        text = "GEOMETRYCOLLECTION (POINT (1 2), POINT Z (3 4 5))"
        expected = sh.from_wkt(text)
        for changed in [text.replace("POINT Z", "POINT M"), text.replace("3 4 5", "3 4 6"), text.replace("POINT (1 2)", "POINT EMPTY")]:
            with self.subTest(changed=changed):
                self.assertFalse(matches("encodeWKT", changed, expected, True))


if __name__ == "__main__":
    unittest.main()
