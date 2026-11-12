"""Runs the script test of the invitation page over mutants of its source.

Each mutant changes one thing in a copy of lib/auth_preview.ml; the test
reads the copy, so the source in the tree is never changed. Each mutant says
what it should come to:
- breaks: the page no longer does what it did; the test should fail (caught).
- works: the page does the same work otherwise; the test should pass.
- words: the page says something otherwise. The test does not check words;
  the browser measure of README.md shows them.
usage: python3 invite-mutants.py REPO OUT_DIR
"""
import pathlib
import subprocess
import sys

repo, out = map(pathlib.Path, sys.argv[1:3])
source = (repo / "lib/auth_preview.ml").read_text(encoding="utf-8")
test = repo / "test/test_auth_preview_invite.js"
out.mkdir(parents=True, exist_ok=True)

OFF = '  document.getElementById("go").disabled = true;\n'
HIDE = '  document.getElementById("accept").hidden = true;\n'
SAY = (
    '  document.getElementById("note").textContent =\n'
    '    "새 초대 링크를 불러오고 있어요. 화면이 바뀌지 않으면 새로고침해 주세요.";\n'
)
RELOAD = '  location.reload();\n});'
LISTENER = 'addEventListener("hashchange", () => {\n' + OFF + HIDE + SAY + RELOAD

# name, what the mutant should come to, replacements
MUTANTS = [
    ("no change", "works", []),
    ("the page does not hear a change of the fragment", "breaks", [(LISTENER + "\n", "")]),
    ("the button stays on while the server answers", "breaks", [(OFF + HIDE + SAY, HIDE + SAY)]),
    ("the form stays while the server answers", "breaks", [(OFF + HIDE + SAY, OFF + SAY)]),
    ("the page turns its form off and does not load again", "breaks", [(RELOAD, "});")]),
    ("the page drops the new link before it loads again", "breaks",
     [(RELOAD, '  history.replaceState(null, "", location.pathname);\n' + RELOAD)]),
    ("the page empties the fragment before it loads again", "breaks", [(RELOAD, '  location.hash = "";\n' + RELOAD)]),
    ("the page listens once", "breaks", [(RELOAD, '  location.reload();\n}, { once: true });')]),
    ("the page puts the token back in the address", "breaks",
     [(LISTENER, LISTENER + '\nlocation.hash = "#" + token;')]),
    ("the address keeps the fragment", "breaks",
     [('history.replaceState(null, "", location.pathname);', 'history.replaceState(null, "", location.pathname + location.hash);')]),
    ("the tab gets a new entry that keeps the token", "breaks",
     [('history.replaceState(null, "", location.pathname);', 'history.pushState(null, "", location.pathname);')]),
    ("the script names an element the page lacks", "breaks",
     [('document.getElementById("title").textContent', 'document.getElementById("titel").textContent')]),
    ("the markup names the field otherwise", "breaks",
     [('id=\\"invite\\" name=\\"invite\\"', 'id=\\"invitation\\" name=\\"invite\\"')]),
    ("the markup names the form otherwise", "breaks", [('"<div id=\\"accept\\">"', '"<div id=\\"form\\">"')]),
    ("the markup names the button otherwise", "breaks", [('<button id=\\"go\\"', '<button id=\\"send\\"')]),
    ("the way back is shown at first", "breaks", [('<p id=\\"back\\" hidden>', '<p id=\\"back\\">')]),
    ("an address with no token keeps the form", "breaks",
     [('  document.getElementById("accept").hidden = true;\n  document.getElementById("back").hidden = false;',
       '  document.getElementById("back").hidden = false;')]),
    ("an address with no token offers no way back", "breaks",
     [('  document.getElementById("back").hidden = false;\n}', '}')]),
    ("the form takes half of the token", "breaks",
     [('document.getElementById("invite").value = token;', 'document.getElementById("invite").value = token.slice(0, 32);')]),
    ("the page hides the way back in place of the form", "breaks",
     [(OFF + HIDE, OFF + '  document.getElementById("back").hidden = true;\n')]),
    ("an address with no token loads again at once", "breaks",
     [('if (token === "") {', 'if (token === "") {\n  location.reload();')]),
    ("the page listens through window", "works",
     [('addEventListener("hashchange", () => {', 'window.addEventListener("hashchange", () => {')]),
    ("the page asks for the load before it turns the form off", "works",
     [(OFF + HIDE + SAY + RELOAD, '  location.reload();\n' + OFF + HIDE + SAY + '});')]),
    ("the page says nothing of the wait", "words", [(SAY, "")]),
]

rows = []
for index, (name, keeps, replacements) in enumerate(MUTANTS):
    text = source
    for old, new in replacements:
        assert text.count(old) == 1, (name, old)
        text = text.replace(old, new)
    path = out / f"m{index:02d}.ml"
    path.write_text(text, encoding="utf-8")
    run = subprocess.run(["node", str(test), str(path)], capture_output=True, text=True, timeout=60)
    passed = run.returncode == 0
    if keeps == "works":
        result = "passes" if passed else "REJECTED"
    elif keeps == "words":
        result = "read in the browser" if passed else "caught"
    else:
        result = "NOT CAUGHT" if passed else "caught"
    reason = ""
    if not passed:
        lines = [line for line in (run.stderr or run.stdout).splitlines() if line.strip()]
        reason = next((line.strip() for line in lines if "Error" in line), lines[0] if lines else "")
    rows.append((name, keeps, result, reason))
    print(f"{name}\t{keeps}\t{result}\t{reason}")

(out / "invite-mutants.tsv").write_text(
    "".join(f"{name}\t{keeps}\t{result}\t{reason}\n" for name, keeps, result, reason in rows), encoding="utf-8")
