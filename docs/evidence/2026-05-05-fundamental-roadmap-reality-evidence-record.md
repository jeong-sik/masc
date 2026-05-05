# Evidence Record — fundamental_roadmap.md Reality Check

## 공통 헤더

- 날짜(ISO8601): `2026-05-05T18:00:00+09:00`
- 작성자: Claude (Opus 4.7) for jeong-sik (vincent)
- 결정 ID: `fundamental-roadmap-reality-check-2026-05-05`
- 적용 대상: `~/me/planning/claude-plans/joyful-tumbling-dragon.md`, `docs/audit/2026-05-05-fundamental-roadmap-reality-check.md`
- 결정 상태: 확정 (10-week re-scoped plan; 26-week roadmap rejected as authoritative source)

## 근거 (Evidence)

| 항목 | 출처 (파일:줄 또는 명령) | 확인일시 | 신뢰도 | 비고 |
|---|---|---|---|---|
| `env_config_keeper.ml` 949 lines (claim 2,278) | `wc -l lib/config/env_config_keeper.ml` @ HEAD `5806519c0b` | 2026-05-05T17:55:00+09:00 | High | 직접 측정 |
| `keeper_unified_turn.ml` records FSM transitions, not silent skip | `lib/keeper/keeper_unified_turn.ml:60,159,188,203,324,344,419,468,2279` | 2026-05-05T17:56:00+09:00 | High | 8 사이트 모두 telemetry 동반 |
| `lib/cascade/capabilities.ml` does not exist | `find . -name 'capabilities*.ml'` returned empty | 2026-05-05T17:57:00+09:00 | High | 파일 자체 부재; 로드맵 §3-1 검증 불가 |
| 6/7 cited PRs already merged | `gh pr view <N> --json state,mergedAt` for #12955,12959,12971,12986,12988,12990,12992 | 2026-05-05T17:00:00+09:00 (Explore agent) | High | #12988만 OPEN |
| oas backend 5종 분리 이미 존재 | `wc -l ~/me/workspace/yousleepwhen/oas/lib/llm_provider/backend_*.ml` | 2026-05-05T17:58:00+09:00 | High | OpenAI 1550 + Anthropic 210 + Gemini 363 + Ollama 641 + GLM 452 |
| `backend.mli` signature 부재 | `lsd ~/me/workspace/yousleepwhen/oas/lib/llm_provider/backend.mli` → ENOENT | 2026-05-05T17:58:00+09:00 | High | Sprint 2 신규 |
| `cancellation.ml:135` `Atomic.set t.cancelled true;` only | `rg -n 'Atomic\.set\|Eio\.Cancel\.cancel' lib/cancellation.ml` | 2026-05-05T17:56:00+09:00 | High | `Eio.Cancel.cancel` 0건 |
| Recovery Strategy GADT 정의됨, 실행 1곳 | `rg -n 'type _ strategy' lib/resilience/recovery.ml` (line 26) + `strategy_to_tla_symbol` (line 60) | 2026-05-05T17:56:00+09:00 | High | 호출 사이트 수동 검증 필요 (Sprint 1) |
| Mutex/Atomic 비율 54:31 (lib/keeper + lib/cascade) | `rg -c 'Mutex\.\|Eio\.Mutex' lib/keeper lib/cascade \| wc -l` = 54; `rg -c 'Atomic\.' ... \| wc -l` = 31 | 2026-05-05T17:56:00+09:00 | Medium | 파일 단위 카운트, 인스턴스 카운트 아님 |
| `.github/workflows/fundamental-check.yml` 부재 | `ls .github/workflows/` 출력 | 2026-05-05T17:58:00+09:00 | High | 11 workflow 중 해당 없음 |
| RFC 0008/0019/0020/0022/0024/0026 존재 | `ls docs/rfc/` | 2026-05-05T17:58:00+09:00 | High | 22 RFC 활성 |
| TLA+ specs 9개 존재 (CascadeKeeperRecovery 포함) | `find . -name '*.tla'` | 2026-05-05T17:58:00+09:00 | High | 신규 spec 작성 시 기존 자산 확장 우선 |

## 검증 (Verification)

- 1차: `wc -l`, `rg -n`, `find`, `gh pr view`로 직접 측정
- 2차: 메모리 `feedback_self_audit_grep_only_false_positive_trap.md`(2026-05-05) 가드 적용 — Explore agent 보고를 그대로 받지 않고 worktree 안 main `5806519c0b`에서 재측정. 결과: Explore가 보고한 911줄/57:35는 실측 949줄/54:31로 ±5% 오차(타이밍 차이로 추정)
- 3차: 본 evidence record와 audit 문서 두 곳에 같은 수치를 인용해 향후 변경 시 cross-check 가능
- 재현 결과: 성공. 모든 측정 명령은 `worktree pwd`에서 1회 실행으로 동일 결과 재현

## 불확실성 (Uncertainty)

- `lib/cascade/capabilities.ml` 부재의 시점: git log에서 reflog 안 잡힘. 이전부터 없었을 가능성과 다른 이름(예: `cascade_capability*.ml`)으로 존재할 가능성 — Sprint 1 시작 시 재확인 필요
- Mutex/Atomic 카운트는 **파일 수** 기준. 한 파일 내 다중 사용 인스턴스는 미측정. Sprint 3에서 인스턴스 단위 측정 스크립트 도입(`scripts/audit/concurrency-balance.sh`)
- Recovery Strategy 호출 사이트 정확히 몇 곳인지 — Sprint 1-2 시작 시 `rg -l "Recovery\\.execute"` 전수 검증

## 적용범위 (Scope)

- 영향 받는 영역: `~/me/planning/claude-plans/joyful-tumbling-dragon.md`(plan), `docs/audit/2026-05-05-fundamental-roadmap-reality-check.md`(audit), `.github/workflows/fundamental-check.yml`(CI gate), `scripts/lint/no-roadmap-stale-hardcoding.{sh,allowlist}`, `scripts/lint/no-fabricated-telemetry.{sh,allowlist}`, `scripts/lint/godfile-size-regression.sh`
- 제약/배제: 본 record는 `fundamental_roadmap.md`(외부 문서)의 evidence base만 평가. 로드맵 자체의 *원칙*(SRP, lock-free by default, fail-loud)은 수용
- 롤백 조건:
  1. 본 record가 인용한 PR 상태가 며칠 이내 변경되면 (예: #12988 머지) → §3 재측정
  2. `capabilities.ml`이 다른 경로/이름으로 발견되면 → §1, §9 갱신
  3. 본 plan 진행 중 같은 영역의 별도 PR이 등장하면 → 해당 sprint 일시 정지 + 동기화

## 다음 액션

- Sprint 0 PR(이 worktree, branch `chore/sprint-0-roadmap-reset`)에 audit + CI workflow + 본 record 함께 머지
- masc-mcp `.gitignore:144`가 `memory/`를 ignore하므로 본 record는 `docs/evidence/`에 보관. 사본 동기화는 사용자 요청 시 `~/me/memory/procedural-memory/`로
- Sprint 0 dogfood에서 발견된 gap #6(`provider_adapter.ml` 모델 리스트)는 audit §1·§8에 추가 기록됨
