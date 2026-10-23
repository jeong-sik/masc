#!/usr/bin/env python3
"""task-2321 — count-guideless-added.py 를 실행으로 고정한다.

검증자가 지적한 것처럼 스크립트를 검증하는 CI가 없으면 독립 영수증을 만들
수 없다. 이 테스트를 dune runtest에 포함해 CI가 자동으로 실행하게 하면
검증자도 CI 결과를 근거로 삼을 수 있다.

실행하는 것:
- count-guideless-added.py 를 임시 노트 파일과 함께 세 시나리오로 실행한다.
  A: 마커 없음 → guideless 0
  B: 한국어 마커 2개 → guideless 2
  C: 영어 마커 2개 → guideless 2
- 각 시나리오가 --expect-added / --expect-guideless 와 일치하는지
  스크립트가 스스로 판정하게 한다. 불일치면 exit 1이므로 이 테스트도
  실패한다.
"""

import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COUNT = os.path.join(REPO, "scripts", "release", "count-guideless-added.py")


def run_counter(tag, note_text, expect_added, expect_guideless):
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".md", delete=False, encoding="utf-8"
    ) as f:
        f.write(note_text)
        note_path = f.name
    try:
        result = subprocess.run(
            [
                sys.executable, COUNT,
                "--tag", tag,
                "--note-path", note_path,
                "--expect-added", str(expect_added),
                "--expect-guideless", str(expect_guideless),
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
    finally:
        os.unlink(note_path)
    return result


def scenario_a():
    """구형 노트: 가이드 없음 마커가 없으면 guideless = 0."""
    note = "## [v0.51.0]\n\n### Added\n\n- 새 기능 A (#1)\n- 새 기능 B (#2)\n"
    r = run_counter("v0.51.0", note, 2, 0)
    assert r.returncode == 0, f"scenario A: expected exit 0, got {r.returncode}\n{r.stderr}"
    print("scenario A (no markers): PASS")


def scenario_b():
    """한국어 마커: `가이드 없음(대상 문서: ...)` 를 센다."""
    note = (
        "## [v0.52.0]\n\n### Added\n\n"
        "- 기능 A. 가이드 없음(대상 문서: docs/guides/TUI-GUIDE.md) (#1)\n"
        "- 기능 B. 가이드 없음(대상 문서: docs/guides/KEEPER-USER-MANUAL.md) (#2)\n"
        "- 기능 C (#3)\n"
    )
    r = run_counter("v0.52.0", note, 3, 2)
    assert r.returncode == 0, f"scenario B: expected exit 0, got {r.returncode}\n{r.stderr}"
    print("scenario B (Korean markers): PASS")


def scenario_c():
    """영어 마커: `No guide yet (none found in ...)` 를 센다.

    task-2321의 본체 — v0.54.0 노트에 쓰인 영어 표기가 계수기에 잡히는지
    고정한다.
    """
    note = (
        "## [v0.54.0]\n\n### Added\n\n"
        "- Feature A. No guide yet (none found in docs/guides/TUI-GUIDE.md) (#1)\n"
        "- Feature B. No guide yet (none found in docs/guides/KEEPER-USER-MANUAL.md) (#2)\n"
        "- Feature C (#3)\n"
    )
    r = run_counter("v0.54.0", note, 3, 2)
    assert r.returncode == 0, f"scenario C: expected exit 0, got {r.returncode}\n{r.stderr}"
    print("scenario C (English markers): PASS")


def main():
    scenario_a()
    scenario_b()
    scenario_c()
    print("test_count_guideless_added: all scenarios PASS")


if __name__ == "__main__":
    main()
