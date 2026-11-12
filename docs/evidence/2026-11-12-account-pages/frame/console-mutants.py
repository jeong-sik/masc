"""Changes one line of the console frame at a time and runs its tests.

usage: python3 -I console-mutants.py WORKTREE OUT.tsv

Each mutant replaces one string of dashboard/src/accounts/console.ts that
occurs exactly once, runs `vitest run src/accounts/console.test.ts`, and puts
back the text the file had when the script started. A mutant is caught when
the run fails. The source is checked first: unchanged, the tests must pass.
"""
import pathlib
import subprocess
import sys

WORKTREE = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])
SOURCE = WORKTREE / "dashboard/src/accounts/console.ts"

MUTANTS = [
    ("no change", None, None),
    ("a refused sign-out cannot be sent again",
     "before.signOut.kind === 'sending') return",
     "before.signOut.kind !== 'idle') return"),
    ("the wait is announced over a failed view",
     "if (view.value.kind === 'reading') view.value = { kind: 'reading', slow: true }",
     "view.value = { kind: 'reading', slow: true }"),
    ("the heading takes the focus on every sign-in",
     "if (shown.current === 'failed' && view.kind === 'signed_in') heading.current?.focus()",
     "if (view.kind === 'signed_in') heading.current?.focus()"),
    ("a refused whoami leaves for the sign-in page",
     "if (!who.ok) return who",
     "if (!who.ok) return { ok: false, problem: { kind: 'signed_out' } }"),
    ("two answers that name two people are shown",
     "if (who.value.id !== session.value.userId) return { ok: false, problem: { kind: 'unreadable' } }\n",
     ""),
    ("the sign-out button is never marked",
     "aria-disabled=${signOut.kind === 'sending'}",
     "aria-disabled=${false}"),
    ("the retry button is never marked",
     "aria-disabled=${view.retrying}",
     "aria-disabled=${false}"),
    ("the line of the reading is no status",
     "<p class=\"hint\" role=\"status\">${view.slow",
     "<p class=\"hint\">${view.slow"),
    ("the line of the leaving is no status",
     "<p class=\"hint\" role=\"status\">로그인 화면으로",
     "<p class=\"hint\">로그인 화면으로"),
    ("the line of the retry is no status",
     "<p class=\"hint\" role=\"status\">${view.retrying",
     "<p class=\"hint\">${view.retrying"),
    ("the note of a reading stays for the next failure",
     "<${ProblemNote} key=${view.failure.attempts} ",
     "<${ProblemNote} "),
    ("the note of a sign-out stays for the next failure",
     "<${ProblemNote} key=${view.signOut.failure.attempts} ",
     "<${ProblemNote} "),
    ("failed readings are not counted",
     "attempts: failedBefore + 1",
     "attempts: 1"),
    ("refused sign-outs are not counted",
     "attempts: refusedBefore + 1",
     "attempts: 1"),
    ("a refused sign-out does not read the session again",
     "const now = await readSession(send)",
     "const now: Answer<Session> = { ok: false, problem: { kind: 'unreachable' } }"),
    ("the token of now is not sent",
     ": ended(await endSession(send, session.csrfToken))",
     ": first"),
    ("a session of another person is kept",
     "    if (now.ok && now.value.userId !== before.session.userId) return leave()\n",
     ""),
    ("a session that ended meanwhile is kept",
     "    if (!now.ok && now.problem.kind === 'signed_out') return leave()\n",
     ""),
    ("the token of now is dropped for the next press",
     "view.value = { ...before, session, signOut:",
     "view.value = { ...before, signOut:"),
    ("a sign-out that worked changes the page",
     "if (first.kind === 'out') return leave()",
     "if (first.kind === 'out') { view.value = { kind: 'leaving' }; return leave() }"),
    ("a sign-out is not marked as sending",
     "    view.value = { ...before, signOut: { kind: 'sending' } }\n",
     ""),
    ("the count is never said",
     "${attempts > 1 ? html`<p class=\"hint\">${attempts}번 시도했어요.</p>` : null}",
     "${null}"),
    ("the way back is a link inside a sentence again",
     "<p><a class=\"button\" href=\"/\">처음 화면으로</a></p>",
     "<p><a href=\"/\">처음 화면으로</a></p>"),
]


def run_tests() -> bool:
    done = subprocess.run(
        ["npx", "vitest", "run", "src/accounts/console.test.ts"],
        cwd=WORKTREE / "dashboard",
        capture_output=True,
        text=True,
        timeout=300,
    )
    return done.returncode == 0


def main() -> None:
    pristine = SOURCE.read_text(encoding="utf-8")
    rows = []
    try:
        for name, old, new in MUTANTS:
            if old is not None:
                if pristine.count(old) != 1:
                    rows.append((name, f"NOT APPLIED ({pristine.count(old)} matches)"))
                    continue
                SOURCE.write_text(pristine.replace(old, new), encoding="utf-8")
            passed = run_tests()
            SOURCE.write_text(pristine, encoding="utf-8")
            if old is None:
                verdict = "passes" if passed else "FAILS UNCHANGED"
            else:
                verdict = "NOT CAUGHT" if passed else "caught"
            rows.append((name, verdict))
            print(f"{verdict}\t{name}", flush=True)
    finally:
        SOURCE.write_text(pristine, encoding="utf-8")
    OUT.write_text("".join(f"{name}\t{verdict}\n" for name, verdict in rows), encoding="utf-8")


if __name__ == "__main__":
    main()
