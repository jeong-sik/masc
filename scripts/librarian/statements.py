#!/usr/bin/env python3
"""The reference cut of a memory into statements (RFC-librarian-absorb-gate).

This is the cut the scorer of issue #37079 used to calibrate the question
"the claim under review conveys this statement" (floor 0.94, ceiling 0.10;
88% statement-level agreement with the list scorer). The OCaml gate
(lib/keeper/keeper_librarian_absorb_gate.ml, `statements`) must cut the same
way, or that calibration does not apply to it. The two are tied through one
golden file:

    test/fixtures/librarian_statements_golden.json

which this script writes and checks, and which the OCaml test reads:

    python3 scripts/librarian/statements.py --write test/fixtures/librarian_statements_golden.json
    python3 scripts/librarian/statements.py --check test/fixtures/librarian_statements_golden.json

The inputs in the golden are fixed below; they hold no keeper memory text.

Whitespace policy, the same on both sides: only ASCII whitespace (space,
tab, CR, LF, FF, VT) is a boundary or is stripped. A non-ASCII space
(U+00A0, U+202F, U+3000, ...) is an ordinary character inside a statement.
The scorer that produced the calibration in #37079 used Python's Unicode
\\s; none of the 196 calibration sources held a non-ASCII space, and 4 of
the 35,613 memory texts on this machine did (all U+202F), measured on
2026-09-21, so the calibration holds under this policy and the golden below
pins it with such characters.

Markup: only backticks are dropped. The calibration scorer also dropped
"**"; that is kept here because a memory about code can hold it as an
operator (Codex review on #37369), and an emphasis marker left in a
statement does not change what it says.
"""
import json
import re
import sys

MIN_STATEMENT_CHARS = 20

_MARKUP = re.compile(r"`")   # backticks only; ** may be an operator in a code memory
_LINES = re.compile(r"\n+")
_ENDS = re.compile(r"(?<=[.!?])[ \t\r\f\v]+|(?<=다\.)[ \t\r\f\v]*|(?<=[;])[ \t\r\f\v]+|[ \t\r\f\v]+—[ \t\r\f\v]+")
_ASCII_WS = " \t\r\n\f\v"


def statements(text):
    """Line breaks, then sentence ends; backticks dropped; a piece under
    MIN_STATEMENT_CHARS characters carried into the next; a short tail joined
    to the last. Every statement is kept."""
    text = _MARKUP.sub("", text)
    pieces = []
    for line in _LINES.split(text):
        pieces += _ENDS.split(line)
    out, carry = [], ""
    for piece in (p.strip(_ASCII_WS) for p in pieces if p and p.strip(_ASCII_WS)):
        carry = (carry + " " + piece).strip(_ASCII_WS)
        if len(carry) >= MIN_STATEMENT_CHARS:
            out.append(carry)
            carry = ""
    if carry:
        if out:
            out[-1] += " " + carry
        else:
            out.append(carry)
    return out


# The golden inputs. Each exercises one rule; none is a keeper's memory.
GOLDEN_INPUTS = [
    "배포는 **매주 화요일** 09:00 에 돈다. 다섯 분쯤 걸린다; 실패하면 `rollback.sh` 를 돌린다 — 운영자에게 알린다.\n한 줄 더: 이 규칙은 2026-09-01 부터다.",
    "Short. Also short! Third one is long enough to stand alone as a statement? Yes it is.",
    "다.다.다.\n\n" + " ".join("문장 %d 은 충분히 길게 써서 스무 자를 넘긴다." % i for i in range(1, 25)),
    "",
    "— a dash with no space before it is kept, and this sentence stands\nsecond line ends without a period",
    "했다.그리고 바로 이어진다. 마침표 뒤 공백이 없어도 다. 는 자른다! 느낌표 뒤도 자른다? 물음표 뒤도 자른다.",
    "a; b; c; d; e; f; g; h; i; j; k; l; m; n; o; p; q; r; s; t; u; v; w; x; y; z; short pieces gather until twenty characters",
    # Non-ASCII spaces are not boundaries and are not stripped: U+00A0 after the
    # period, U+3000 inside the second sentence, U+202F before the third.
    "first sentence ends here.\u00a0second\u3000sentence keeps its space. \u202fthird sentence follows the narrow one.",
    # Backticks go, ** stays: an operator in a code memory is part of what it says.
    "in python `x ** y` raises x to the power y; the **emphasis** stays as written.",
]


def golden():
    return [{"input": text, "expected": statements(text)} for text in GOLDEN_INPUTS]


def main(argv):
    if len(argv) == 3 and argv[1] == "--write":
        with open(argv[2], "w", encoding="utf-8") as f:
            json.dump(golden(), f, ensure_ascii=False, indent=1)
            f.write("\n")
        return 0
    if len(argv) == 3 and argv[1] == "--check":
        with open(argv[2], encoding="utf-8") as f:
            on_disk = json.load(f)
        fresh = golden()
        if on_disk != fresh:
            for i, (a, b) in enumerate(zip(on_disk, fresh)):
                if a != b:
                    print("golden entry %d differs from this script's cut" % i, file=sys.stderr)
            if len(on_disk) != len(fresh):
                print("golden has %d entries, this script produces %d" % (len(on_disk), len(fresh)), file=sys.stderr)
            print("rewrite it with: python3 scripts/librarian/statements.py --write %s" % argv[2], file=sys.stderr)
            return 1
        print("golden matches this script's cut (%d inputs)" % len(fresh))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
