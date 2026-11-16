#!/usr/bin/env python3
# pyright: strict
"""raw_token_auth_calls.py on OCaml snippets and a throwaway tree. Offline.

Run: python3 -I scripts/ci/test_raw_token_auth_calls.py
"""

from __future__ import annotations

import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import raw_token_auth_calls as check  # noqa: E402


def functions(text: str) -> list[str]:
    return [call.function for call in check.scan_text("lib/x.ml", text).calls]


def hidden(text: str) -> list[str]:
    return [place.text for place in check.scan_text("lib/x.ml", text).hidden]


class CodeOnly(unittest.TestCase):
    def test_keeps_every_line(self) -> None:
        text = '(* one\n two *)\nlet s = "a\nb" in\n{|c\nd|}\n'
        self.assertEqual(check.code_only(text).count("\n"), text.count("\n"))

    def test_a_call_in_a_comment_is_not_a_call(self) -> None:
        self.assertEqual(functions("(* Auth.check_permission *)"), [])

    def test_comments_nest(self) -> None:
        text = "(* a (* b *) Auth.check_permission *) Auth.authorize_tool"
        self.assertEqual(functions(text), ["authorize_tool"])

    def test_a_string_in_a_comment_does_not_close_it(self) -> None:
        text = '(* "*)" Auth.check_permission *) Auth.authorize_tool'
        self.assertEqual(functions(text), ["authorize_tool"])

    def test_a_call_in_a_string_is_not_a_call(self) -> None:
        text = 'let s = "Auth.check_permission \\" Auth.authorize_tool" in Auth.authorize_tool'
        self.assertEqual(functions(text), ["authorize_tool"])

    def test_a_call_in_a_quoted_string_is_not_a_call(self) -> None:
        text = (
            "let a = {|Auth.check_permission|} in\n"
            "let b = {id|Auth.check_permission |} Auth.authorize_tool|id} in\n"
            "Auth.find_credential_by_token"
        )
        self.assertEqual(functions(text), ["find_credential_by_token"])

    def test_a_quote_character_does_not_open_a_string(self) -> None:
        text = "let q = '\"' in Auth.check_permission"
        self.assertEqual(functions(text), ["check_permission"])

    def test_a_type_variable_is_not_a_character(self) -> None:
        text = "let f : 'a -> 'b = fun x -> Auth.check_permission x"
        self.assertEqual(functions(text), ["check_permission"])


class Calls(unittest.TestCase):
    def test_counts_each_watched_call_with_its_line(self) -> None:
        text = (
            "let a = Auth.find_credential_by_token\n"
            "let b = Auth_credential_token.find_credential_by_token\n"
            "let c = Masc_auth.Auth.resolve_agent_from_token\n"
        )
        calls = check.scan_text("lib/x.ml", text).calls
        self.assertEqual(
            [(call.line, call.function) for call in calls],
            [
                (1, "find_credential_by_token"),
                (2, "find_credential_by_token"),
                (3, "resolve_agent_from_token"),
            ],
        )

    def test_other_names_and_modules_are_not_watched(self) -> None:
        text = (
            "Auth.authorize_tool_for_role Auth.admit_request "
            "Server_auth.check_permission Types_auth.check_permission "
            "My_Auth.check_permission"
        )
        self.assertEqual(functions(text), [])


class Hiding(unittest.TestCase):
    def test_reaching_the_module_without_its_name_is_reported(self) -> None:
        for text in (
            "open Auth",
            "open! Auth",
            "let open Auth in x",
            "include Auth",
            "open Masc_auth.Auth",
            "module A = Auth",
            "module T = Masc_auth.Auth_credential_token",
            "Auth.(check_permission x)",
            "Auth_credential_token.[x]",
        ):
            with self.subTest(text=text):
                self.assertEqual(len(hidden(text)), 1)

    def test_keeping_the_name_is_not_hiding(self) -> None:
        for text in (
            "module Auth = Auth",
            "module Auth = Masc_auth.Auth",
            "open Auth_config",
            "open Server_auth",
            "(* open Auth *)",
            'let s = "open Auth"',
        ):
            with self.subTest(text=text):
                self.assertEqual(hidden(text), [])


class Mismatches(unittest.TestCase):
    def calls(self, *keys: tuple[str, str]) -> tuple[check.Call, ...]:
        return tuple(check.Call(path, 1, function) for path, function in keys)

    def test_equal_counts_pass(self) -> None:
        found = self.calls(("lib/a.ml", "check_permission"))
        self.assertEqual(check.mismatches(found, {("lib/a.ml", "check_permission"): 1}), [])

    def test_a_new_call_fails(self) -> None:
        found = self.calls(("lib/a.ml", "check_permission"), ("lib/a.ml", "check_permission"))
        [wrong] = check.mismatches(found, {("lib/a.ml", "check_permission"): 1})
        self.assertEqual((wrong.allowed, len(wrong.found)), (1, 2))
        self.assertIn("reads the raw bearer again", check.report(wrong))

    def test_a_file_not_in_the_list_fails(self) -> None:
        found = self.calls(("lib/b.ml", "authorize_tool"))
        [wrong] = check.mismatches(found, {})
        self.assertEqual((wrong.path, wrong.allowed), ("lib/b.ml", 0))

    def test_a_removed_call_fails_until_the_count_drops(self) -> None:
        [wrong] = check.mismatches((), {("lib/a.ml", "check_permission"): 1})
        self.assertEqual((wrong.allowed, wrong.found), (1, ()))
        self.assertIn("Lower the count", check.report(wrong))


class Allowed(unittest.TestCase):
    def test_every_entry_names_a_scanned_file_and_a_watched_function(self) -> None:
        for (path, function), count in check.ALLOWED.items():
            with self.subTest(path=path, function=function):
                self.assertTrue(path.startswith("lib/") and path.endswith(".ml"))
                self.assertFalse(path.startswith(check.EXEMPT_PREFIX))
                self.assertIn(function, check.WATCHED)
                self.assertGreaterEqual(count, 1)


class Scan(unittest.TestCase):
    def test_reads_lib_ml_files_outside_lib_auth(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "lib" / "auth").mkdir(parents=True)
            (root / "lib" / "server").mkdir()
            (root / "lib" / "auth" / "auth.ml").write_text("Auth.check_permission\nopen Auth\n")
            (root / "lib" / "server" / "door.ml").write_text("\nAuth.authorize_tool\n")
            (root / "lib" / "server" / "door.mli").write_text("Auth.check_permission\n")
            found = check.scan(root)
        self.assertEqual(found.calls, (check.Call("lib/server/door.ml", 2, "authorize_tool"),))
        self.assertEqual(found.hidden, ())


if __name__ == "__main__":
    unittest.main()
