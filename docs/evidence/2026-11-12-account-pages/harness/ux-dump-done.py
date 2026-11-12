"""Writes a scratch program that saves the page of a completed sign-in as the
server answers it (headers and bytes).

A browser cannot reach that page without a GitHub login, so the page comes
from the login test: the program is a copy of test/test_server_login_http.ml
with one statement added after its first completed sign-in. It is written to
WORKTREE/tmp_edit/page_dump, which git ignores, and is never committed.

usage: python3 ux-dump-done.py WORKTREE OUT_DIR
  then, in WORKTREE:
    dune build ./tmp_edit/page_dump/dump.exe
    (cd _build/default/tmp_edit/page_dump && ./dump.exe)
  The run writes OUT_DIR/done.hdr and OUT_DIR/done.body. Pass OUT_DIR to
  ux-layer.sh as EXTRA_PAGES_DIR; the stand-in answers the page at
  /__saved/done, and at /__saved/done?hold with its script refused, so the
  page stays where a browser can measure it."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2]).resolve()
source = (root / "test/test_server_login_http.ml").read_text()
anchor = '    Alcotest.(check int) ("signed in: " ^ back.body) 200 back.status;\n'
first = source.index(anchor)
out_literal = '"' + str(out).replace("\\", "\\\\").replace('"', '\\"') + '"'
dump = (
    anchor
    + "    (let save name text =\n"
    + f"       let channel = open_out_bin (Filename.concat {out_literal} name) in\n"
    + "       output_string channel text;\n"
    + "       close_out channel\n"
    + "     in\n"
    + '     save "done.hdr"\n'
    + '       (String.concat "\\n"\n'
    + '          ("HTTP/1.1 200 OK"\n'
    + "           :: List.filter_map\n"
    + '                (fun name -> match all name back with [] -> None | value :: _ -> Some (name ^ ": " ^ value))\n'
    + '                [ "content-type"; "cache-control"; "referrer-policy"; "content-security-policy" ])\n'
    + '         ^ "\\n");\n'
    + '     save "done.body" back.body);\n'
)
patched = source[:first] + dump + source[first + len(anchor) :]
stanza = (root / "test/stanzas/test_server_login_http.inc").read_text()
libraries = stanza[stanza.index("(libraries") : stanza.index(")", stanza.index("(libraries")) + 1]
target = root / "tmp_edit/page_dump"
target.mkdir(parents=True, exist_ok=True)
(target / "dump.ml").write_text(patched)
(target / "dune").write_text(f"(executable\n (name dump)\n (modules dump)\n {libraries})\n")
out.mkdir(parents=True, exist_ok=True)
print("wrote", target / "dump.ml")
