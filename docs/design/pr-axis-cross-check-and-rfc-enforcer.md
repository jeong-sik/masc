# P3 Process Tools Design: PR Axis Cross-Check + RFC §1 Enforcer

> **Status**: Draft sketch
> **Created**: 2026-05-09
> **Author**: jeong-sik
> **Related**: RFC-0052, RFC-0053, RFC-0038 Phase 2

## §0 Summary

masc-mcp 개발에서 반복적으로 발생하는 두 가지 프로세스 실패:

1. **Wave-pattern PR stale**: 단일 main merge(예: #14179 metric refactor)가 병렬로 열린 4-5개 Draft PR을 동시에 stale하게 만듦. 각 PR author는 자신의 PR만 보고 cross-axis 영향을 인식하지 못함.
2. **RFC §1 caller-context 누락**: RFC sketch 작성 시 §1 Problem 섹션에 TODO 주석만 남기고 caller-context 수집을 미룸. 나중에 sub-agent가 수집하더라도 RFC 본문과 `.tmp/` 파일이 분리되어 drift 발생.

본 설계는 두 가지 프로세스 도구를 제안:
- **PR Axis Cross-Check**: PR 병렬 스택의 cross-axis stale 위험을 pre-merge에 탐지
- **RFC §1 Enforcer**: RFC draft의 §1 섹션이 caller-context 기준을 충족하는지 CI에서 강제

## §1 PR Axis Cross-Check

### §1.1 Problem

`feedback_main_blocker_chain_4x_session.md` (2026-05-05):
> admin-merge가 IN_PROGRESS Build CI 우회 → main 깨짐 → 보충 fix 4회 반복

`feedback_wave_pattern_60_80_stale_resolved.md` (2026-05-05):
> wave-style multi-issue roadmap는 60~80% pre-resolved. static audit 기반 wave LOC plan을 검증하면 이미 main에 fix되어 있다.

`feedback_check_open_prs_before_fixing_pasted_build_error.md` (2026-05-05, **3rd recidivism**):
> pasted build error가 이미 flight 중인 fix와 중복되어 3회 반복.

**근본 원인**: PR author는 자신의 axis만 보고, 다른 axis의 main 변화가 자신의 PR을 invalid하게 만들 가능성을 체크하지 않음.

### §1.2 Design

#### Trigger
- PR push 시 GitHub Actions workflow
- 또는 `/loop` cron이 10분마다 open PR 스택 스캔

#### Algorithm

```python
def check_pr_axis_stale(pr_number: int, repo: str) -> List[AxisRisk]:
    pr = fetch_pr(pr_number)
    changed_files = pr.changed_files

    # 1. Find recently merged PRs (last 24h)
    recently_merged = fetch_merged_prs(since=now() - 24h, limit=20)

    risks = []
    for merged in recently_merged:
        # 2. Check file overlap
        overlap = changed_files & merged.changed_files
        if overlap:
            # 3. Check if merged PR's changes make this PR's logic stale
            if is_logic_superseded(pr, merged, overlap):
                risks.append(AxisRisk(
                    type="SUPERSEDED",
                    merged_pr=merged.number,
                    overlap_files=overlap,
                    confidence=compute_confidence(pr, merged)
                ))

        # 4. Check build dependency: if merged PR changed dune/libraries
        if merged.touches_dune_deps() and pr.depends_on(merged):
            risks.append(AxisRisk(
                type="BUILD_DEP_BREAK",
                merged_pr=merged.number,
                confidence="HIGH"
            ))

    return risks
```

#### Risk Types

| Type | Description | Example |
|------|-------------|---------|
| `SUPERSEDED` | Merged PR's fix makes this PR's change unnecessary | PR A fixes bug X, PR B (merged) also fixes bug X |
| `BUILD_DEP_BREAK` | Merged PR changed dune deps, this PR's build may fail | cdal_runtime migration adds new library |
| `TYPE_CONFLICT` | Merged PR changed type definitions this PR uses | `Cascade_ref.cascade_item` field change |
| `API_SIGNATURE_CHANGE` | Merged PR changed function signature this PR calls | `run_keeper_cycle` added `unit` param |

#### Output

PR에 코멘트로 자동 포스팅:

```markdown
🔄 **PR Axis Cross-Check Alert**

Recent merges that may affect this PR:

| Merged PR | Risk Type | Overlap Files | Confidence |
|-----------|-----------|---------------|------------|
| #14241 | `BUILD_DEP_BREAK` | `lib/cdal_runtime/dune` | HIGH |
| #14255 | `TYPE_CONFLICT` | `lib/cascade/cascade_ref.mli` | MEDIUM |

**Recommended action**: Rebase on latest main and run `dune build @check`.
```

### §1.3 Implementation Plan

**PR-A: GitHub Actions workflow**
- `.github/workflows/pr-axis-check.yml`
- Python script using `gh api` (no external dependencies)
- Runs on `pull_request` synchronize + cron schedule (every 10 min)

**PR-B: Risk detection heuristics**
- File overlap: simple path prefix matching
- dune dep change: parse `dune` file diff for `(libraries ...)` changes
- Type/function signature change: OCaml `cmt` file comparison (advanced)

**PR-C: Confidence scoring**
- HIGH: direct file overlap + function signature change
- MEDIUM: file overlap in same directory
- LOW: transitive dependency overlap

## §2 RFC §1 Enforcer

### §2.1 Problem

RFC sketch 작성 시 §1에 다음 anti-pattern 반복:

```markdown
## §1 Problem

**caller-context (sub-agent Topic X 결과 통합 영역)**:
<!-- TODO: Topic X — 호출 사이트 N건의 file:line + 30-50줄 발췌 -->
```

→ TODO만 남기고 커밋. 나중에 sub-agent가 수집하더라도:
1. RFC 본문에 통합되지 않음 (drift)
2. `.tmp/` 파일은 ephemeral, 세션 종료 시 사라짐
3. RFC 리뷰어는 §1이 비어있는 것을 모름

### §2.2 Design

#### Rule Set

RFC §1 section은 다음 기준을 충족해야 함:

| # | Rule | Enforcement |
|---|------|-------------|
| 1 | `<!-- TODO` 주석 0개 | grep 실패 시 CI fail |
| 2 | `file:line` 인용 최소 3건 | grep `\.ml:` 패턴 3개 미만 시 fail |
| 3 | code block 최소 1개 | markdown code block (```) 1개 미만 시 fail |
| 4 | "sub-agent" 미통합 표시 없음 | "sub-agent ... 결과 통합 영역" 문구 금지 |
| 5 | caller-context 파일 생성 | `.tmp/rfc-NNNN-caller-context.md` 존재 확인 |

#### CI Integration

```yaml
# .github/workflows/rfc-enforcer.yml
name: RFC §1 Enforcer
on:
  pull_request:
    paths:
      - 'docs/rfc/**'

jobs:
  enforce:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check RFC §1 completeness
        run: python scripts/rfc_enforcer.py --check docs/rfc/
```

#### Python Script

```python
# scripts/rfc_enforcer.py
import re
from pathlib import Path
from dataclasses import dataclass

@dataclass
class Violation:
    file: Path
    line: int
    rule: str
    message: str

def check_rfc_section1(file: Path) -> List[Violation]:
    content = file.read_text()
    violations = []

    # Rule 1: No TODO comments in §1
    todo_matches = list(re.finditer(r'<!--\s*TODO', content))
    for m in todo_matches:
        violations.append(Violation(file, content[:m.start()].count('\n') + 1,
            "R1_NO_TODO", "TODO comment found in §1"))

    # Rule 2: At least 3 file:line citations
    file_line_pattern = re.compile(r'`?[\w/]+\.ml[i]?:(\d+)`?')
    citations = file_line_pattern.findall(content)
    if len(citations) < 3:
        violations.append(Violation(file, 0, "R2_MIN_CITATIONS",
            f"Only {len(citations)} file:line citations found (minimum 3)"))

    # Rule 3: At least 1 code block
    code_blocks = re.findall(r'```[\w]*\n', content)
    if len(code_blocks) < 1:
        violations.append(Violation(file, 0, "R3_MIN_CODE_BLOCK",
            "No code block found in §1"))

    # Rule 4: No "sub-agent ... 통합 영역" placeholder
    if re.search(r'sub-agent.*통합 영역|sub-agent.*pending|sub-agent.*TODO', content):
        violations.append(Violation(file, 0, "R4_NO_PLACEHOLDER",
            "Sub-agent placeholder text found"))

    return violations
```

### §2.3 Graceful Degradation

- **Draft PR**: 경고만 (comment), block 아님
- **Ready for review**: required check로 block
- **RFC-WAIVED label**: 특정 rule skip 가능 (예: 신규 도메인 RFC는 citation이 적을 수 있음)

## §3 Alternatives

| 접근법 | 강점 | 약점 | 적합도 |
|--------|------|------|--------|
| GitHub Actions | Native integration, free for public repos | 2000 min/month limit | **높음** |
| Pre-commit hook | Local, fast feedback | Developer discipline 필요 | **중간** — 보조 |
| Dedicated bot | Rich formatting, stateful | Maintenance cost | **낮음** — overkill |
| Manual checklist | Human judgment | Inconsistent, forgotten | **낮음** — 현재 실패 중 |

## §4 Implementation Plan

### PR-A: PR Axis Cross-Check (MVP)
- [ ] `.github/workflows/pr-axis-check.yml` 생성
- [ ] `scripts/pr_axis_check.py` — file overlap + recent merged PR scan
- [ ] 1개 repo에서 2주간 pilot 운영
- [ ] false positive rate 측정 (목표: <20%)

### PR-B: RFC §1 Enforcer (MVP)
- [ ] `scripts/rfc_enforcer.py` — 5 rule check
- [ ] `.github/workflows/rfc-enforcer.yml` 생성
- [ ] 기존 RFC에 소급 적용 ( grandfathering: 기존 RFC는 skip )
- [ ] 실패 시 PR 코멘트에 구체적인 수정 가이드 제공

### PR-C: Integration
- [ ] 두 도구를 `masc-mcp` repo에 배포
- [ ] 다른 repo(`me`, kidsnote)에 재사용 가능하도록 config 외부화

## §5 References

- `memory/feedback_main_blocker_chain_4x_session.md` (2026-05-05)
- `memory/feedback_wave_pattern_60_80_stale_resolved.md` (2026-05-05)
- `memory/feedback_check_open_prs_before_fixing_pasted_build_error.md` (2026-05-05, 3rd recidivism)
- `instructions/workflow-pr.md` — PR 운영 체크리스트
- `instructions/software-development.md` — 워크어라운드 거부 기준
