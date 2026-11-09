# pyright: strict
"""Tests for scripts/tinker/librarian/yojson_wire.py against what Yojson 3.0.0 reads and writes."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import yojson_wire as W


class YojsonWireTest(unittest.TestCase):
    """Cases checked against a compiled Yojson 3.0.0 probe (2026-11-08)."""

    def test_reader_accepts_what_yojson_accepts(self) -> None:
        self.assertEqual(W.parse("{a:1 /* c */} // c"), W.JsonObject((("a", 1),)))
        self.assertEqual(W.parse('{"a":1,"a":2}'), W.JsonObject((("a", 1), ("a", 2))))
        self.assertEqual(W.parse("4611686018427387904"), W.IntLit("4611686018427387904"))
        self.assertEqual(W.parse("-4611686018427387904"), -(2**62))
        self.assertEqual(W.parse('"\\udc00"'), "\udc00")
        self.assertEqual(W.parse('"x\ny"'), "x\ny")

    def test_reader_refuses_what_yojson_refuses(self) -> None:
        for text in ('"\\ud800"', "[1,]", "{'a':1}", "01", "nan", "﻿{}", "\x0c{}", '{"a":1 // c\r}', "/* */"):
            with self.subTest(text=text):
                self.assertIsInstance(W.parse(text), W.JsonError)

    def test_integers_past_the_ocaml_range_stay_text_at_any_length(self) -> None:
        # CPython's int() refuses more than 4300 digits; Yojson reads any length as Intlit.
        self.assertEqual(W.parse("4611686018427387903"), 2**62 - 1)
        self.assertEqual(W.parse("9999999999999999999"), W.IntLit("9999999999999999999"))
        for text in ("1" * 4301, "-" + "9" * 100_000):
            with self.subTest(length=len(text)):
                self.assertEqual(W.parse(text), W.IntLit(text))

    def test_depth_is_bounded_by_memory_not_the_call_stack(self) -> None:
        depth = 100_000
        text = '{"a":' * depth + "[" * depth + "]" * depth + "}" * depth
        value = W.parse(text)
        assert not isinstance(value, W.JsonError)
        self.assertEqual(W.write(value), text)
        self.assertEqual(W.parse("[" * depth + "]" * (depth - 1)), W.JsonError(2 * depth - 1, "expected ',' or ']'"))

    def test_writer_matches_yojson(self) -> None:
        self.assertEqual(W.write(1e16), "1e+16")
        self.assertEqual(W.write(-0.0), "-0.0")
        self.assertEqual(W.write(100.0), "100.0")
        self.assertEqual(W.write(123456789012345678.0), "1.2345678901234568e+17")
        self.assertEqual(W.write("\b\x0c\x01\x7f/é"), '"\\b\\f\\u0001\\u007f/é"')


if __name__ == "__main__":
    unittest.main()
