"""Changes one part of the console frame at a time and runs its tests.

usage: python3 -I console-mutants.py WORKTREE OUT.tsv

The script copies dashboard/ of WORKTREE, without node_modules, into a new
temporary directory and links node_modules there. Each mutant replaces one
string of the copy of src/accounts/console.ts that occurs exactly once and
runs `vitest run src/accounts/console.test.ts` in the copy. The files of
WORKTREE are never written, so a run that is stopped leaves them as they
were. A row goes to OUT as soon as its run ends.

Each mutant says what it should come to:
- breaks: the console no longer does what it did, for some order of the
  answers and the drawings of the page; the tests should fail (caught).
- same: the console does the same for every such order; the tests should
  pass.
- words: the page says or places something otherwise. The tests do not
  check words or places (constitution `execution_protocol`); the browser
  measure of frame/README.md reads them.
The source is checked first: unchanged, the tests must pass.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

WORKTREE = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
CONSOLE = pathlib.Path("src/accounts/console.ts")

MUTANTS = [
    ("no change", "same", None, None),
    ("a refused sign-out cannot be sent again", "breaks",
     "before.signOut.kind === 'sending' || before.signOut.kind === 'out') return",
     "before.signOut.kind !== 'idle') return"),
    ("a sign-out is sent again after the person is out", "breaks",
     "before.signOut.kind === 'sending' || before.signOut.kind === 'out') return",
     "before.signOut.kind === 'sending') return"),
    ("the wait is announced over a failed view", "breaks",
     "if (view.value.kind === 'reading') view.value = { kind: 'reading', slow: true }",
     "view.value = { kind: 'reading', slow: true }"),
    ("the heading takes the focus on every sign-in", "breaks",
     "if (takesThePressedButton(shown.current, view.kind)) heading.current?.focus()",
     "if (view.kind === 'signed_in') heading.current?.focus()"),
    ("the heading does not take the focus when the account changed", "breaks",
     "|| (from === 'signed_in' && to === 'changed')",
     ""),
    ("a refused whoami leaves for the sign-in page", "breaks",
     "if (!who.ok) return { kind: 'problem', problem: who.problem }",
     "if (!who.ok) return { kind: 'problem', problem: { kind: 'signed_out' } }"),
    ("two answers that name two people are shown", "breaks",
     "  if (who.value.id !== session.value.userId) return { kind: 'changed' }\n",
     ""),
    ("two answers that name two people are a fault of the server", "breaks",
     "return { kind: 'changed' }",
     "return { kind: 'problem', problem: { kind: 'unreadable' } }"),
    ("a reading runs while someone is signed in", "breaks",
     "if (before.kind === 'signed_in' || before.kind === 'leaving') return",
     "if (before.kind === 'leaving') return"),
    ("a page that leaves reads again", "breaks",
     "    if (before.kind !== 'reading' && before.next === 'leaving') return\n",
     ""),
    ("a retry that found no session takes the page away", "breaks",
     "view.value = before.kind === 'reading' ? { kind: 'leaving' } : { ...before, next: 'leaving' }",
     "view.value = { kind: 'leaving' }"),
    ("the sign-out button is never marked", "breaks",
     "aria-disabled=${signOut.kind === 'sending' || signOut.kind === 'out'}",
     "aria-disabled=${false}"),
    ("the sign-out button is not marked when the person is out", "breaks",
     "aria-disabled=${signOut.kind === 'sending' || signOut.kind === 'out'}",
     "aria-disabled=${signOut.kind === 'sending'}"),
    ("the retry button is never marked", "breaks",
     "aria-disabled=${next !== 'idle'}",
     "aria-disabled=${false}"),
    ("the line of the reading is no status", "breaks",
     "<p class=\"hint\" role=\"status\">${view.slow",
     "<p class=\"hint\">${view.slow"),
    ("the line of the leaving is no status", "breaks",
     "<p class=\"hint\" role=\"status\">로그인 화면으로",
     "<p class=\"hint\">로그인 화면으로"),
    ("the line of the retry is no status", "breaks",
     "<p class=\"hint\" role=\"status\">${nextWords(next)}",
     "<p class=\"hint\">${nextWords(next)}"),
    ("the line of a sign-out is no status", "breaks",
     "<p class=\"hint\" role=\"status\">${view.signOut.kind === 'out'",
     "<p class=\"hint\">${view.signOut.kind === 'out'"),
    ("a sign-out that worked says nothing", "breaks",
     "${view.signOut.kind === 'out' ? '로그아웃했어요. 로그인 화면으로 이동해요…' : ''}",
     "${''}"),
    ("a retry that found no session says nothing", "breaks",
     "case 'leaving': return '세션이 끝났어요. 로그인 화면으로 이동해요…'",
     "case 'leaving': return ''"),
    ("the note of a reading stays for the next failure", "breaks",
     "<${ProblemNote} key=${view.failure.attempts} ",
     "<${ProblemNote} "),
    # A sign-out that is sent again passes through 'sending', which takes the
    # note away when the page draws it. In a browser the page draws it before
    # the answer comes. An answer that comes before that drawing, as the fake
    # of the tests gives, leaves the old note in place without the key.
    ("the note of a sign-out stays for the next failure", "breaks",
     "<${ProblemNote} key=${view.signOut.failure.attempts} ",
     "<${ProblemNote} "),
    ("failed readings are not counted", "breaks",
     "attempts: failedBefore + 1",
     "attempts: 1"),
    ("refused sign-outs are not counted", "breaks",
     "attempts: refusedBefore + 1",
     "attempts: 1"),
    ("a sign-out with no answer, or one it cannot read, counts as done", "breaks",
     "answer.ok || answer.problem.kind === 'signed_out'",
     "answer.ok || answer.problem.kind !== 'refused'"),
    ("a sign-out answer it cannot read counts as done", "breaks",
     "answer.ok || answer.problem.kind === 'signed_out'",
     "answer.ok || answer.problem.kind === 'signed_out' || answer.problem.kind === 'unreadable'"),
    ("a refused sign-out does not read the session again", "breaks",
     "const now = await readSession(send)",
     "const now: Answer<Session> = { ok: false, problem: { kind: 'unreachable' } }"),
    ("the token of now is not sent", "breaks",
     ": ended(await endSession(send, session.csrfToken))",
     ": first"),
    ("a session of another person is taken for the person's own", "breaks",
     "    if (now.ok && now.value.userId !== before.session.userId) {\n"
     "      view.value = { kind: 'changed', next: 'idle' }\n"
     "      return\n"
     "    }\n",
     ""),
    ("a session of another person leaves the page without a word", "breaks",
     "      view.value = { kind: 'changed', next: 'idle' }\n      return\n    }",
     "      return out()\n    }"),
    ("a session that ended meanwhile is kept", "breaks",
     "    if (!now.ok && now.problem.kind === 'signed_out') return out()\n",
     ""),
    ("the token of now is dropped for the next press", "breaks",
     "view.value = { ...before, session, signOut:",
     "view.value = { ...before, signOut:"),
    ("a sign-out that worked changes the page", "breaks",
     "if (first.kind === 'out') return out()",
     "if (first.kind === 'out') { view.value = { kind: 'leaving' }; return leave() }"),
    ("a sign-out is not marked as sending", "breaks",
     "    view.value = { ...before, signOut: { kind: 'sending' } }\n",
     ""),
    ("the count is never said", "words",
     "${attempts > 1 ? html`<p class=\"hint\">${attempts}번 시도했어요.</p>` : null}",
     "${null}"),
    ("the way back is a link inside a sentence again", "words",
     "<p><a class=\"button\" href=\"/\">처음 화면으로</a></p>",
     "<p><a href=\"/\">처음 화면으로</a></p>"),
]


def run_tests(copy: pathlib.Path) -> bool:
    done = subprocess.run(
        ["npx", "vitest", "run", "src/accounts/console.test.ts"],
        cwd=copy,
        capture_output=True,
        text=True,
        timeout=300,
    )
    return done.returncode == 0


def verdict(keeps: str, passed: bool) -> str:
    if keeps == "breaks":
        return "NOT CAUGHT" if passed else "caught"
    if keeps == "same":
        return "passes" if passed else "REJECTED"
    return "read in the browser" if passed else "caught"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="console-mutants-") as scratch:
        copy = pathlib.Path(scratch) / "dashboard"
        shutil.copytree(WORKTREE / "dashboard", copy, ignore=shutil.ignore_patterns("node_modules"))
        (copy / "node_modules").symlink_to((WORKTREE / "dashboard/node_modules").resolve())
        source = copy / CONSOLE
        pristine = source.read_text(encoding="utf-8")
        OUT.write_text("", encoding="utf-8")
        for name, keeps, old, new in MUTANTS:
            if old is not None:
                if pristine.count(old) != 1:
                    row = (name, keeps, f"NOT APPLIED ({pristine.count(old)} matches)")
                    with OUT.open("a", encoding="utf-8") as out:
                        out.write("\t".join(row) + "\n")
                    print("\t".join(row), flush=True)
                    continue
                source.write_text(pristine.replace(old, new), encoding="utf-8")
            row = (name, keeps, verdict(keeps, run_tests(copy)))
            source.write_text(pristine, encoding="utf-8")
            with OUT.open("a", encoding="utf-8") as out:
                out.write("\t".join(row) + "\n")
            print("\t".join(row), flush=True)


if __name__ == "__main__":
    main()
