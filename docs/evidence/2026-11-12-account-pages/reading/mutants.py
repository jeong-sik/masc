"""Runs the cases of test_account_page_reading over one-line mutants of the
reading. A mutant the cases do not catch is a fact the cases do not hold.
usage: mutants.py WORKTREE OUT_TSV
The source file is restored after each mutant and at the end."""
import pathlib, re, subprocess, sys

wt = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
src = wt / "test" / "account_page_reading.ml"
original = src.read_text(encoding="utf-8")

MUTANTS = [
    ("any namespace is HTML",
     "String.equal element.namespace Markup.Ns.html && String.equal element.name name",
     "String.equal element.name name"),
    ("every button submits, whatever its type",
     '      | Some ("button" | "reset") -> false\n',
     '      | Some ("button" | "reset") -> true\n'),
    ("a button may name another form, route or method",
     '&& not (List.exists (fun name -> has name node) [ "form"; "formaction"; "formmethod" ])',
     "&& true"),
    ("a disabled fieldset does not disable",
     '  has "disabled" node || List.exists (fun holder -> named "fieldset" holder && has "disabled" holder) inside\n',
     '  ignore inside; has "disabled" node\n'),
    ("nothing is hidden",
     'let rendered (node, inside) = not (List.exists (has "hidden") (node :: inside))',
     "let rendered (node, inside) = ignore node; ignore inside; true"),
    ("a blank description passes",
     'if String.equal (String.trim text) "" then Error Description_blank else Ok ())',
     "ignore text; Ok ())"),
    ("a button anywhere belongs to the form",
     "submits node && List.memq form inside",
     "ignore form; ignore inside; submits node"),
    ("a form that does not post counts",
     'named "form" node && keyword "method" node = Some "post" && Doc.attribute "action" node = Some start',
     'named "form" node && Doc.attribute "action" node = Some start'),
    ("an element of any kind is the button",
     '  named "button" node\n  && (match keyword "type" node with',
     '  (match keyword "type" node with'),
    ("a missing description passes",
     "      | None -> Error (Description_missing id)\n",
     '      | None -> Ok ""\n'),
    ("a disabled button with no description passes",
     "  | None | Some [] -> Error No_description\n",
     "  | None | Some [] -> Ok ()\n"),
]

build = ["opam", "exec", "--switch=5.5.2", "--", "dune", "build", "--root", ".", "-j", "4", "./test/test_account_page_reading.exe"]
rows = []
try:
    for name, old, new in MUTANTS:
        assert original.count(old) == 1, name
        src.write_text(original.replace(old, new), encoding="utf-8")
        built = subprocess.run(build, cwd=wt, capture_output=True, text=True)
        if built.returncode != 0:
            rows.append((name, "does not compile", built.stderr.strip().splitlines()[-1][:120] if built.stderr.strip() else ""))
            continue
        ran = subprocess.run([str(wt / "_build/default/test/test_account_page_reading.exe")], cwd=wt / "_build/default/test", capture_output=True, text=True)
        text = re.sub(r"\x1b\[[0-9;]*m", "", ran.stdout + ran.stderr)
        failed = re.findall(r"\[FAIL\]\s+login\s+\d+\s+(.+?)\.\n", text)
        rows.append((name, "caught" if ran.returncode != 0 else "NOT CAUGHT", "; ".join(sorted(set(failed)))))
finally:
    src.write_text(original, encoding="utf-8")
out.write_text("".join("\t".join(row) + "\n" for row in rows), encoding="utf-8")
for row in rows:
    print(" | ".join(row))
