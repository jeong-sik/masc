---
rfc: "0151"
title: "4-metric monotone-decrease ratchet for code-smell metrics"
status: Draft
created: 2026-05-20
updated: 2026-05-20
author: vincent
supersedes: []
superseded_by: null
related: ["0085", "0088", "0126"]
implementation_prs: []
---

# RFC-0151 — 4-metric monotone-decrease ratchet for code-smell metrics

> Note on numbering: 본 RFC 는 처음 `.next-number` 0149 슬롯으로 할당됐으나,
> PR #16930 (RFC-0148 3-way collision recovery, #16909→0149 + #16908→0150)
> 와 race 발생. 사이클 외부 사고(머지된 0148 3 collision) 우선순위에 따라
> 본 PR 이 0151 으로 yield. `.next-number` 는 0152 로 set. 사전 작업 PR
> #16833 의 title "RFC-0146" 은 docs/rfc/README.md §정책 "누락 번호 재사용
> 금지" 에 따라 0146 slot 사용 불가. 본 docs-only PR 은 #16833 3-split 의
> 첫 번째 step 으로, scripts/baseline
> 변경은 별도의 narrow follow-up PR 로 분리한다.

## 1. Goal

masc-mcp 코드베이스의 4 개 *code-smell* 지표를 CI 에서
monotone-decreasing baseline 으로 ratchet 한다. 새 PR 은 baseline 위로
지표를 *증가*시킬 수 없다. *감소*시키는 PR 은 baseline 을 자동으로
갱신한다. 절대 임계치 (예: `LoC < 1000`) 가 아니라 *방향성* (recent commit
이후 추가 누적 0) 을 enforce 하므로, 단발적 godfile split / catch-all
elimination 작업이 자연스럽게 baseline 을 끌어내린다.

이 접근은 CLAUDE.md §"워크어라운드 거부 기준" 시그니처 3종 중 #2
(string/substring 분류기) + #3 (N-of-M 패치) 의 누적을 사후가 아니라
*PR 게이트 단계에서* 감지하는 것을 목적으로 한다. 기존 godfile cap 식
(`prometheus.ml` 등의 LoC 상한) 은 cap 자체가 PR-evasion 을 유도했기에
(memory feedback `feedback_prometheus_extract_too_evasive.md` 참조),
*상한* 이 아닌 *증가 금지* 로 전환한다.

## 2. Non-goals

- 코드 자동 수정 / codemod 제공 (별도 RFC).
- 절대 threshold 제거 시점에서 모든 godfile 을 분해하는 것 (점진적).
- 다른 PR 의 머지 순서 차단 (ratchet 은 *증가* 만 거부; 감소 + flat 통과).
- `_test.ml` / `test/` / `vendor/` / `_build/` 경로는 측정 제외 (별도
  §6 참조).

## 3. 4 측정 지표

| # | Metric ID | 정의 | Tooling |
|---|---|---|---|
| 1 | `godfile_loc_1000plus` | `lib/**/*.ml` (단, `_intf.ml` 제외) 중 LoC ≥ 1000 인 파일 수 | `wc -l` + `rg --files` |
| 2 | `catch_all_arms` | `lib/**/*.ml` 의 ` \| _ -> ` catch-all match arm 총 발생 횟수 (주석/문자열 리터럴 제외) | OCaml-parser 기반 카운터; impl PR 동봉 |
| 3 | `contains_substring_defs` | `String.starts_with`/`Astring.is_prefix`/`String.is_substring` 등 *substring 분류기* 가 외부 분류 결정에 사용된 함수 정의 수 (`let is_X_error s = ...` 류) | OCaml-parser + heuristic |
| 4 | `ignore_no_comment` | `ignore (...)` 호출 중 직전 / 직후 줄에 `(* WORKAROUND` 또는 `(* OK:` 주석이 *없는* 사이트 수 | line-based scanner |

### 3.1 측정 baseline (2026-05-20)

| Metric | Baseline | Source measurement |
|---|---|---|
| `godfile_loc_1000plus` | **51** | `find lib -name '*.ml' -not -name '*_intf.ml' \| xargs wc -l \| awk '$1 >= 1000'` (origin/main 시점) |
| `catch_all_arms` | **3843** | 24h sampling 2026-05-20 — `rg '\\| _ ->' lib/ \| wc -l` 1차 근사. 정식 OCaml-parser 카운터는 PR-2 에서 도입; baseline 은 동일 측정 함수로 재 계산. |
| `contains_substring_defs` | **29** (1차) / 28 (2차 정련) | heuristic grep 의 over-counting 1 건 제거. impl PR 에서 28 로 baseline 확정. |
| `ignore_no_comment` | **113** | line-based scanner. *동봉 baseline JSON* 에 site list 포함. |

baseline 정확도는 RFC scripts 가 *동일 measurement* 로 재현 가능해야
하므로, 본 RFC 는 *측정 함수* (script 의 contract) 만 정의하고 *script
내용* 은 별도 narrow PR (§7) 으로 보낸다.

## 4. Baseline 정책

1. **저장 위치**: `ci/code-smell-baseline.json` (impl PR 에서 추가).
2. **포맷**: 4 metric → 정수 + per-file breakdown 배열 (drift 분석용).
3. **갱신 규칙**:
   - PR 의 metric N ≤ baseline N → CI pass. PR 이 N < baseline N
     이면, 머지 후 같은 PR 의 후속 commit (또는 별도 closeout PR) 이
     `ci/code-smell-baseline.json` 을 새 N 으로 갱신한다.
   - PR 의 metric N > baseline N → CI fail (escape hatch 는 §5).
   - per-file breakdown 은 총합 비교 후 informational. file-level
     drift (총합 동일하지만 다른 파일로 이동) 는 pass.
4. **재 측정 시점**: PR 의 `Build and Test` job 안 step `code-smell-ratchet`.
5. **Ledger 와 분리**: `docs/rfc/.next-number` 와 달리, code-smell
   baseline 은 CI 자동 갱신 가능 (저자가 손으로 commit 갱신할 수도 있음).

## 5. Escape hatch: `RATCHET-WAIVED`

production-blocking 또는 RFC-driven *legitimate increase* (예: 새
godfile 이 ratchet 도입 *이전* 부터 존재하던 dead surface 를 RFC 분해
도중 일시 +1 시키는 경우) 에는 PR body 에 다음 라인을 포함하면 CI
`code-smell-ratchet` step 이 통과한다:

```
RATCHET-WAIVED: <metric_id> <reason>
```

CI 는 `RATCHET-WAIVED` 라인을 *count* 하고 `do-not-merge` 라벨을
자동 부착하지 *않는다* (이 RFC 는 강제 차단이 아니라 *명시 트래킹*
이 목적). 단, `RATCHET-WAIVED` 가 한 PR 에 2+ metric 동시 사용 시
adversarial-reviewer agent invoke 를 트리거 (impl PR 에서 wiring).

## 6. Override 3-요건 (CLAUDE.md §"Override 조건" 정합)

본 ratchet 자체는 *Workaround* 가 아니라 *Workaround 감지기* 이므로
"CLAUDE.md §워크어라운드 거부 기준" 의 직접 대상이 아니다. 그러나
*ratchet 도입에 의해 새로 생기는 워크어라운드 패턴* (예: 사람이 metric
회피용으로 한 파일을 두 파일로 가짜 split) 을 막기 위해 다음 3 가지
조건을 RFC 본문에 명시:

1. **측정은 코드 정의 단위**: split 후에도 동일 모듈 namespace 안 LoC
   합이 baseline 에 반영되도록 metric 정의가 `_intf.ml` 외에는 sum 으로
   계산. 단순 ms split 회피 차단.
2. **deprecated path 명시 의무**: `RATCHET-WAIVED` 사용 시, 대체 RFC
   번호를 reason 에 포함해야 함 (`RATCHET-WAIVED: godfile_loc_1000plus
   RFC-0085 phase-3` 형식). RFC 번호가 없으면 동시 작성.
3. **removal target**: `ci/code-smell-baseline.json` 에 절대 임계치
   (`hard_cap`) 는 두지 않는다. ratchet 단방향 감소가 자연스럽게
   threshold 역할을 한다.

## 7. 향후 narrow PR (별도 분리)

본 PR 은 docs-only. 다음 narrow PR 이 implementation 을 담당:

- **PR follow-up #1**: `scripts/code-smell/measure.{ml,sh}` 4 metric
  카운터 + `ci/code-smell-baseline.json` baseline 동봉 + GH Actions step
  `code-smell-ratchet` 추가.
- **PR follow-up #2**: baseline JSON drift recovery test (sample
  insertion → fail; sample removal → baseline auto-update verify).

두 PR 은 `RFC-0151-impl-1` / `RFC-0151-impl-2` 식으로 RFC 본 ID 를
다시 cross-link 한다. measurement contract 변경 (§3.1 의 baseline 숫자
재정의 포함) 은 본 RFC 본문 수정 PR 로만 가능.

## 8. References

- 사전 attempt: PR #16833 (CLOSED, "DIRTY + CI/RFC policy surfaces").
- CLAUDE.md §"워크어라운드 거부 기준" 시그니처 3종 + 체크리스트 7항.
- `memory/feedback_prometheus_extract_too_evasive.md` (godfile cap 의
  evasion 패턴 → ratchet 으로 전환 근거).
- RFC-0085 keeper godfile decomp track.
- RFC-0088 telemetry-as-fix umbrella.
- RFC-0126 lint stack sprint.
