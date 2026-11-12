"""Runs test_server_accounts over mutants of the routes of the console. A
mutant the test does not catch is a fact the test does not hold.
usage: route-mutants.py WORKTREE OUT_TSV
The test is first run on the sources as they are: a mutant says something
only when that run passes. Each source file is restored after its mutant and
at the end, and the test is built once more from the restored sources."""
import pathlib
import re
import subprocess
import sys

wt = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
CONSOLE = "lib/server/server_account_console.ml"
SERVER = "lib/server/server_accounts.ml"
TEST = "test_server_accounts"

MUTANTS = [
    ("the console may run inline script", CONSOLE,
     "script-src 'self'; style-src 'self';",
     "script-src 'self' 'unsafe-inline'; style-src 'self';"),
    ("the console takes what no directive names from this origin", CONSOLE,
     "\"default-src 'none'; script-src 'self';",
     "\"default-src 'self'; script-src 'self';"),
    ("the console drops the limits of a page without a form", CONSOLE,
     "connect-src 'self'; \"\n  ^ Account_page.formless_limits",
     "connect-src 'self'\""),
    ("a browser may keep the page of the console", CONSOLE,
     "~headers:[ no_store; referrer_policy; \"content-security-policy\", policy ]",
     "~headers:[ referrer_policy; \"content-security-policy\", policy ]"),
    ("a link of the console sends its address to another site", CONSOLE,
     "~headers:[ no_store; referrer_policy; \"content-security-policy\", policy ]",
     "~headers:[ no_store; \"content-security-policy\", policy ]"),
    ("a bundle without the console answers 200", CONSOLE,
     "~status:`Service_unavailable\n    ~headers:\n      [ no_store",
     "~status:`OK\n    ~headers:\n      [ no_store"),
    ("the page that stands in may be kept", CONSOLE,
     "      [ no_store\n      ; referrer_policy\n      ; ( \"content-security-policy\"",
     "      [ referrer_policy\n      ; ( \"content-security-policy\""),
    ("the page that stands in may run a script of the server", CONSOLE,
     "\"default-src 'none'; %s; %s\"",
     "\"default-src 'none'; script-src 'self'; %s; %s\""),
    ("the page of the console is the page of the operator dashboard", CONSOLE,
     'let bundle_page = "accounts/index.html"',
     'let bundle_page = "index.html"'),
    ("the files of the console are the files of the operator dashboard", CONSOLE,
     'let bundle_assets = "accounts/assets/"',
     'let bundle_assets = "assets/"'),
    ("the name of a file is not checked before the bundle is asked", CONSOLE,
     "if Web_dashboard.is_public_asset_relative_path relative\n  then",
     "if true\n  then"),
    ("a browser keeps the base sheet for a year", CONSOLE,
     '~cache_control:"no-cache"',
     '~cache_control:"public, max-age=31536000, immutable"'),
    ("the tag of the base sheet does not follow its bytes", CONSOLE,
     "let base_sheet_etag = Http.Response.etag_of_body Account_page.base_sheet",
     'let base_sheet_etag = Http.Response.etag_of_body ""'),
    ("the routes of the console are not registered", SERVER,
     "  |> Server_account_console.add_routes ~draw:login.Login_routes.draw\n",
     ""),
]

build = ["opam", "exec", "--switch=5.5.2", "--", "dune", "build", "--root", ".", "-j", "6", f"./test/{TEST}.exe"]


def run_test():
    """What the test says: None when the build fails, else (passed, the first
    assertion that failed in the words of the test)."""
    built = subprocess.run(build, cwd=wt, capture_output=True, text=True)
    if built.returncode != 0:
        lines = [line for line in built.stderr.strip().splitlines() if line.strip()]
        return None, lines[-1][:160] if lines else ""
    ran = subprocess.run([str(wt / f"_build/default/test/{TEST}.exe")], cwd=wt / "_build/default/test", capture_output=True, text=True)
    text = re.sub(r"\x1b\[[0-9;]*m", "", ran.stdout + ran.stderr)
    said = re.findall(r"^\s*FAIL (.+)$", text, re.M) or re.findall(r"\[FAIL\]\s+\S+\s+\d+\s+(.+?)\.\n", text)
    return ran.returncode == 0, said[0].strip() if said else ""


originals = {name: (wt / name).read_text(encoding="utf-8") for name in (CONSOLE, SERVER)}
for name, file, old, new in MUTANTS:
    assert originals[file].count(old) == 1, name
rows = []
try:
    passed, said = run_test()
    rows.append(("no change", "passes" if passed else "DOES NOT PASS", said))
    if passed:
        for name, file, old, new in MUTANTS:
            original = originals[file]
            (wt / file).write_text(original.replace(old, new), encoding="utf-8")
            try:
                passed, said = run_test()
                verdict = "does not compile" if passed is None else ("NOT CAUGHT" if passed else "caught")
                rows.append((name, verdict, said))
            finally:
                (wt / file).write_text(original, encoding="utf-8")
            out.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
finally:
    for name, text in originals.items():
        (wt / name).write_text(text, encoding="utf-8")
    subprocess.run(build, cwd=wt, capture_output=True, text=True)
out.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
for row in rows:
    print(" | ".join(row))
