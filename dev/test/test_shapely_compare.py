# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely==2.1.2", "types-shapely==2.1.0.20260728"]
# ///
# pyright: strict
"""Check that comparison adapters reject coordinate and layout regressions."""

import json
import unittest

import shapely as sh
from shapely_compare import OperationError, Shape, matches, operation_matches, point_on_surface_matches, signature, stored_point


def raw_geometry(wkt: str) -> str:
    """Encode an independent fixture in the Haskell probe's JSON format."""
    def node(shape: Shape) -> list[object]:
        body: object = [[str(float.fromhex(value)) for value in row] for row in shape.coordinates] if shape.kind in (0, 1) else [node(child) for child in shape.children]
        return [shape.kind, shape.layout, body]
    return json.dumps(node(signature(sh.from_wkt(wkt))))


class PlanarResultTests(unittest.TestCase):
    """Keep XY geometry and output layout checks independent of native Z/M."""

    def test_empty_containers_inherit_only_their_parent_layout(self) -> None:
        for tag in ("Z", "M", "ZM"):
            ordinates = "1 2 3 4" if tag == "ZM" else "1 2 3"
            expected = sh.from_wkt(f"GEOMETRYCOLLECTION {tag} (MULTIPOINT {tag} EMPTY,POINT {tag} ({ordinates}))")
            good = f"GEOMETRYCOLLECTION {tag} (MULTIPOINT {tag} EMPTY,POINT {tag} ({ordinates}))"
            self.assertTrue(matches("encodeWKT", good, expected, True))
            self.assertFalse(matches("encodeWKT", good.replace(f"MULTIPOINT {tag}", "MULTIPOINT"), expected, True))
            self.assertFalse(matches("encodeWKT", good.replace(f"POINT {tag} (", "POINT ("), expected, True))
            native = bytearray(sh.to_wkb(expected, byte_order=1, output_dimension=4, flavor="iso"))
            dimension_tag = {"Z": 1000, "M": 2000, "ZM": 3000}[tag]
            native[10:14] = (4 + dimension_tag).to_bytes(4, "little")
            self.assertTrue(matches("encodeWKB", native.hex(), expected, True))
            if tag != "ZM":
                native[19:23] = (2001 if tag == "Z" else 1001).to_bytes(4, "little")
                self.assertFalse(matches("encodeWKB", native.hex(), expected, True))

    def test_explicit_topology_errors_are_not_successful_geometries(self) -> None:
        error = "!error: OverlayPrecisionFailure"
        self.assertTrue(operation_matches("intersection", error, OperationError("precision failure")))
        self.assertFalse(operation_matches("intersection", error, sh.Point(1, 2)))

    def test_extra_ordinates_are_rejected(self) -> None:
        self.assertFalse(operation_matches("intersection", raw_geometry("POINT Z (1 2 3)"), sh.from_wkt("POINT (1 2)")))

    def test_changed_xy_is_rejected(self) -> None:
        self.assertFalse(operation_matches("intersection", raw_geometry("POINT (1.01 2)"), sh.from_wkt("POINT (1 2)")))

    def test_changed_family_is_rejected(self) -> None:
        self.assertFalse(operation_matches("intersection", raw_geometry("MULTIPOINT ((1 2))"), sh.from_wkt("POINT (1 2)")))

    def test_overlay_line_grouping_preserves_the_point_set(self) -> None:
        joined = "LINESTRING (0 0,2 0,2 2)"
        split = "MULTILINESTRING ((0 0,2 0),(2 0,2 2))"
        for actual, expected in [(joined, split), (split, joined)]:
            self.assertTrue(operation_matches("intersection", raw_geometry(actual), sh.from_wkt(expected)))
        for actual in ["LINESTRING (0 0,2 0)", "LINESTRING (0 0,2 0,3 2)", "LINESTRING Z (0 0 1,2 0 1,2 2 1)"]:
            self.assertFalse(operation_matches("intersection", raw_geometry(actual), sh.from_wkt(split)))

    def test_overlay_collection_lines_can_join(self) -> None:
        expected = sh.from_wkt("GEOMETRYCOLLECTION (POINT (8 8),LINESTRING (0 0,2 0),LINESTRING (2 0,2 2))")
        actual = "GEOMETRYCOLLECTION (POINT (8 8),LINESTRING (0 0,2 0,2 2))"
        self.assertTrue(operation_matches("union", raw_geometry(actual), expected))
        self.assertFalse(operation_matches("union", raw_geometry(actual.replace("8 8", "9 9")), expected))
        self.assertFalse(operation_matches("union", raw_geometry("LINESTRING (0 0,2 0,2 2)"), expected))

    def test_other_structure_contracts_remain_exact(self) -> None:
        self.assertFalse(operation_matches("intersection", raw_geometry("LINESTRING EMPTY"), sh.from_wkt("MULTILINESTRING EMPTY")))
        self.assertFalse(operation_matches("boundary", raw_geometry("LINESTRING (0 0,2 0,2 2)"), sh.from_wkt("MULTILINESTRING ((0 0,2 0),(2 0,2 2))")))

    def test_representative_point_membership_replaces_native_selection(self) -> None:
        source = sh.from_wkt("POLYGON ((0 0,10 0,10 10,0 10,0 0),(2 2,8 2,8 8,2 8,2 2))")
        for point in ["POINT (1 5)", "POINT (9 5)", "POINT (0 5)"]:
            self.assertTrue(point_on_surface_matches(raw_geometry(point), source))
        for point in ["POINT (5 5)", "POINT (11 5)", "POINT Z (1 5 3)", "POINT EMPTY", "MULTIPOINT ((1 5))"]:
            self.assertFalse(point_on_surface_matches(raw_geometry(point), source))

    def test_representative_point_uses_nonempty_dimension(self) -> None:
        source = sh.from_wkt("GEOMETRYCOLLECTION (POINT (8 8),LINESTRING (0 0,2 0))")
        self.assertFalse(point_on_surface_matches(raw_geometry("POINT (8 8)"), source))
        self.assertTrue(point_on_surface_matches(raw_geometry("POINT (0 0)"), source))
        with_empty = sh.from_wkt("GEOMETRYCOLLECTION (POINT (8 8),LINESTRING EMPTY)")
        self.assertTrue(point_on_surface_matches(raw_geometry("POINT (8 8)"), with_empty))
        self.assertFalse(point_on_surface_matches(raw_geometry("POINT EMPTY"), with_empty))
        self.assertTrue(point_on_surface_matches(raw_geometry("POINT EMPTY"), sh.from_wkt("POLYGON EMPTY")))

    def test_degenerate_surface_still_requires_a_finite_point(self) -> None:
        source = sh.from_wkt("POLYGON ((1e308 0,1e308 2,1e308 0))")
        self.assertTrue(point_on_surface_matches(raw_geometry("POINT (1e308 0)"), source))
        self.assertFalse(point_on_surface_matches(raw_geometry("POINT (Infinity 1)"), source))

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
    """Require uniform collection tags and retain mixed member data."""

    def test_uniform_collection_requires_matching_tags(self) -> None:
        for tag, ordinates in [("Z", "1 2 3"), ("M", "1 2 3"), ("ZM", "1 2 3 4")]:
            text = f"GEOMETRYCOLLECTION {tag} (GEOMETRYCOLLECTION {tag} (POINT {tag} ({ordinates})), POINT {tag} EMPTY)"
            expected = sh.from_wkt(text)
            with self.subTest(tag=tag):
                self.assertTrue(matches("encodeWKT", text, expected, True))
                self.assertFalse(matches("encodeWKT", text.replace(f"GEOMETRYCOLLECTION {tag}", "GEOMETRYCOLLECTION", 1), expected, True))
                self.assertFalse(matches("encodeWKT", text.replace(f"GEOMETRYCOLLECTION {tag}", "GEOMETRYCOLLECTION"), expected, True))

    def test_nested_mixed_collection_has_no_parent_tag(self) -> None:
        text = "GEOMETRYCOLLECTION (GEOMETRYCOLLECTION (POINT (1 2), POINT Z (3 4 5)), POINT Z (6 7 8))"
        expected = sh.from_wkt(text)
        self.assertTrue(matches("encodeWKT", text, expected, True))
        self.assertFalse(matches("encodeWKT", text.replace("GEOMETRYCOLLECTION", "GEOMETRYCOLLECTION Z", 1), expected, True))

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
