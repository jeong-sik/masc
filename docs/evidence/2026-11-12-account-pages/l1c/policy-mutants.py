"""Runs test_login_routes over mutants of the policy and the sheet nonce of
the refused and completed login pages. A mutant the test does not catch is a
fact the test does not hold.
usage: policy-mutants.py WORKTREE OUT_TSV
The source file is restored after each mutant and at the end."""
import pathlib, re, subprocess, sys

wt = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
src = wt / "lib" / "auth" / "login_routes.ml"
original = src.read_text(encoding="utf-8")

MUTANTS = [
    ("a refused page may run a script of the server",
     'Printf.sprintf "default-src \'none\'; %s; %s" (Account_page.style_source ~nonce) page_limits',
     'Printf.sprintf "default-src \'none\'; script-src \'self\'; %s; %s" (Account_page.style_source ~nonce) page_limits'),
    ("a refused page names no style source",
     'Printf.sprintf "default-src \'none\'; %s; %s" (Account_page.style_source ~nonce) page_limits',
     'Printf.sprintf "default-src \'none\'; %s" page_limits'),
    ("the sheet of a refused page is under another nonce",
     '        ~nonce\n        ~title:"MASC 로그인 실패"',
     '        ~nonce:(nonce ^ "0")\n        ~title:"MASC 로그인 실패"'),
    ("the sheet of a completed page is under another nonce",
     '        ~nonce\n        ~title:"MASC 로그인 완료"',
     '        ~nonce:(nonce ^ "0")\n        ~title:"MASC 로그인 완료"'),
]

build = ["opam", "exec", "--switch=5.5.2", "--", "dune", "build", "--root", ".", "-j", "6", "./test/test_login_routes.exe"]
rows = []
try:
    for name, old, new in MUTANTS:
        assert original.count(old) == 1, name
        src.write_text(original.replace(old, new), encoding="utf-8")
        built = subprocess.run(build, cwd=wt, capture_output=True, text=True)
        if built.returncode != 0:
            rows.append((name, "does not compile", built.stderr.strip().splitlines()[-1][:120] if built.stderr.strip() else ""))
            continue
        ran = subprocess.run([str(wt / "_build/default/test/test_login_routes.exe")], cwd=wt / "_build/default/test", capture_output=True, text=True)
        text = re.sub(r"\x1b\[[0-9;]*m", "", ran.stdout + ran.stderr)
        failed = re.findall(r"\[FAIL\]\s+\S+\s+\d+\s+(.+?)\.\n", text)
        rows.append((name, "caught" if ran.returncode != 0 else "NOT CAUGHT", "; ".join(sorted(set(failed)))))
finally:
    src.write_text(original, encoding="utf-8")
    subprocess.run(build, cwd=wt, capture_output=True, text=True)
out.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
for row in rows:
    print(" | ".join(row))
