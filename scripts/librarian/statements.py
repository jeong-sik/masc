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
Whitespace is ASCII whitespace on both sides (the scorer used Python's
Unicode \\s; memories with non-ASCII whitespace would cut differently there).
"""
import json
import re
import sys

MIN_STATEMENT_CHARS = 20

_MARKUP = re.compile(r"\*\*|`")
_LINES = re.compile(r"\n+")
_ENDS = re.compile(r"(?<=[.!?])[ \t\r\f\v]+|(?<=다\.)[ \t\r\f\v]*|(?<=[;])[ \t\r\f\v]+|[ \t\r\f\v]+—[ \t\r\f\v]+")
_ASCII_WS = " \t\r\n\f\v"


def statements(text):
    """Line breaks, then sentence ends; markup dropped; a piece under
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
