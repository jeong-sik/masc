"""Runs test_login_routes over mutants of the policies, the nonces and the
sheet of the refused and completed login pages. A mutant the test does not
catch is a fact the test does not hold.
usage: policy-mutants.py WORKTREE OUT_TSV
Each source file is restored after each mutant and at the end."""
import pathlib, re, subprocess, sys

wt = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
ROUTES = "lib/auth/login_routes.ml"
FRAME = "lib/auth/account_page.ml"
originals = {rel: (wt / rel).read_text(encoding="utf-8") for rel in (ROUTES, FRAME)}

REFUSED_POLICY = 'Printf.sprintf "default-src \'none\'; %s; %s" (Account_page.style_source ~nonce) page_limits'
COMPLETED_POLICY = (
    '"default-src \'none\'; script-src \'nonce-%s\'; %s; %s"\n'
    "            nonce\n"
    "            (Account_page.style_source ~nonce)\n"
    "            page_limits )"
)

MUTANTS = [
    ("a refused page may run a script of the server", ROUTES,
     REFUSED_POLICY,
     'Printf.sprintf "default-src \'none\'; script-src \'self\'; %s; %s" (Account_page.style_source ~nonce) page_limits'),
    ("a refused page names no style source", ROUTES,
     REFUSED_POLICY,
     'Printf.sprintf "default-src \'none\'; %s" page_limits'),
    ("the sheet of a refused page is under another nonce", ROUTES,
     '        ~nonce\n        ~title:"MASC 로그인 실패"',
     '        ~nonce:(nonce ^ "0")\n        ~title:"MASC 로그인 실패"'),
    ("the sheet of a completed page is under another nonce", ROUTES,
     '        ~nonce\n        ~title:"MASC 로그인 완료"',
     '        ~nonce:(nonce ^ "0")\n        ~title:"MASC 로그인 완료"'),
    ("a completed page names no style source", ROUTES,
     COMPLETED_POLICY,
     '"default-src \'none\'; script-src \'nonce-%s\'; %s"\n'
     "            nonce\n"
     "            page_limits )"),
    ("the style source of a completed page has another nonce", ROUTES,
     COMPLETED_POLICY,
     COMPLETED_POLICY.replace("(Account_page.style_source ~nonce)", '(Account_page.style_source ~nonce:(nonce ^ "0"))')),
    ("a completed page may run any inline script", ROUTES,
     COMPLETED_POLICY,
     COMPLETED_POLICY.replace("script-src 'nonce-%s'", "script-src 'nonce-%s' 'unsafe-inline'")),
    ("a completed page has none of the page limits", ROUTES,
     COMPLETED_POLICY,
     '"default-src \'none\'; script-src \'nonce-%s\'; %s"\n'
     "            nonce\n"
     "            (Account_page.style_source ~nonce) )"),
    ("a completed page takes anything from its own server", ROUTES,
     COMPLETED_POLICY,
     COMPLETED_POLICY.replace("default-src 'none'", "default-src 'self'")),
    ("every refused page has the same nonce", ROUTES,
     "let refused_page ~nonce failure =",
     'let refused_page ~nonce:_ failure =\n  let nonce = "0123456789abcdef" in'),
    ("a refused page has an empty nonce", ROUTES,
     "let refused_page ~nonce failure =",
     'let refused_page ~nonce:_ failure =\n  let nonce = "" in'),
    ("the sheet of the frame is empty", FRAME,
     "nonce Account_page_css.sheet",
     'nonce ""'),
]

build = ["opam", "exec", "--switch=5.5.2", "--", "dune", "build", "--root", ".", "-j", "6", "./test/test_login_routes.exe"]
rows = []
try:
    for name, rel, old, new in MUTANTS:
        original = originals[rel]
        assert original.count(old) == 1, name
        (wt / rel).write_text(original.replace(old, new), encoding="utf-8")
        built = subprocess.run(build, cwd=wt, capture_output=True, text=True)
        if built.returncode != 0:
            rows.append((name, "does not compile", built.stderr.strip().splitlines()[-1][:120] if built.stderr.strip() else ""))
        else:
            ran = subprocess.run([str(wt / "_build/default/test/test_login_routes.exe")], cwd=wt / "_build/default/test", capture_output=True, text=True)
            text = re.sub(r"\x1b\[[0-9;]*m", "", ran.stdout + ran.stderr)
            failed = re.findall(r"\[FAIL\]\s+\S+\s+\d+\s+(.+?)\.\n", text)
            rows.append((name, "caught" if ran.returncode != 0 else "NOT CAUGHT", "; ".join(sorted(set(failed)))))
        (wt / rel).write_text(original, encoding="utf-8")
finally:
    for rel, original in originals.items():
        (wt / rel).write_text(original, encoding="utf-8")
    subprocess.run(build, cwd=wt, capture_output=True, text=True)
out.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
for row in rows:
    print(" | ".join(row))
