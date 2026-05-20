# RFC-0154 PR-4 — `masc.telemetry_coverage_gap` schema v2 cutover runbook

본 문서는 RFC-0154 §4 (wire format) 과 §5 (phase plan) 을 운영자 관점에서 실행 단계로 풀어낸다. 설계 근거는 RFC body 참조: `docs/rfc/RFC-0154-system-error-class-typed-ssot.md`.

## 1. 개요

`masc.telemetry_coverage_gap.v1` 은 `error: string` 단일 필드로 OS-level 실패 (FD storm, disk pressure 등) 의 원본 메시지를 wire 에 실어 보냈다. backend 가 이미 `Keeper_fd_pressure.is_fd_exhaustion_exn` 등으로 분류했음에도 그 결과가 boolean 으로 축약되고, dashboard 가 다시 `classifyCoverageError` 의 substring matcher 로 *재분류* 했다 (RFC-0154 §1.5 정보 손실 cycle). schema v2 는 backend 분류 결과를 `error_class` typed tag 로 wire 에 보존하여 dashboard 가 lookup-only 가 되도록 한다.

cutover 의 목표는 두 가지다.

- writer 가 emit 하는 모든 row 에 `error_class` 가 present 인 상태로 안정화.
- reader 가 `error` substring 에 의존하는 경로를 제거하고 `error_class` 단일 키 lookup 으로 대체.

## 2. Schema v1 → v2 diff

### Before (`masc.telemetry_coverage_gap.v1`)

```json
{
  "schema": "masc.telemetry_coverage_gap.v1",
  "ts": 1716220800.0,
  "surface": "keeper.tool_call_log",
  "error": "Sys_error(\"Eio.Io Unix_error (Too many open files...\")"
}
```

reader 는 `error` 문자열을 substring 매칭하여 `fd_exhaustion` 인지 추정.

### After (`masc.telemetry_coverage_gap.v2`)

```json
{
  "schema": "masc.telemetry_coverage_gap.v2",
  "ts": 1716220800.0,
  "surface": "keeper.tool_call_log",
  "error": "Sys_error(\"Eio.Io Unix_error (Too many open files...\")",
  "error_class": "fd_exhaustion"
}
```

`error` 원본은 그대로 유지 (debug / human read). `error_class` 는 closed sum `System_error_class.t` 의 `to_short_tag` 결과로, 다음 7 값 중 하나다: `fd_exhaustion`, `disk_exhaustion`, `permission_denied`, `connection_refused`, `timeout`, `other`, `unknown` (reader fallback).

스키마 식별 키는 `schema` 필드의 v1 → v2 문자열 차이로 구분한다.

## 3. Reader compatibility matrix

본 cutover 가 영향을 주는 reader 인벤토리. 측정 명령은 §6 참조.

| Reader | 위치 | v1 처리 | v2 처리 (PR-3 이후) | PR-4 이후 |
|--------|------|--------|---------------------|-----------|
| `lib/telemetry_coverage_gap.ml` (writer) | backend | v1 emit | v2 emit (`error_class` present) | v2 only |
| `dashboard/src/components/common/coverage-gap-block.ts` | dashboard UI | `classifyCoverageError` substring | `errorClassFromBackend` lookup + substring fallback | lookup only |
| `dashboard/src/components/tool-quality-panel.ts` | dashboard UI | `classifyCoverageError` 재노출 | 동일 (alias) | export 제거 |
| `dashboard/src/components/fleet-health-panel.ts` | dashboard UI | `CoverageGapBlock` 사용 | 동일 (block 내부에서 lookup) | 동일 |
| dashboard `*.test.ts` fixture (8 파일) | test | v1 fixture | v1 + v2 fixture 병행 | v2 fixture only |
| `lib/prometheus.ml` / `lib/prometheus_builtin_metric_names.ml` | metric 이름 | 영향 없음 (metric 이름만 참조) | 동일 | 동일 |
| `test/test_keeper_lifecycle_hooks.ml` | backend test | v1 emit assertion | v2 emit assertion | v2 only |

repo 외부 consumer 는 §6 의 grep 결과로는 잡히지 않는다. 외부 reader 가 있을 경우 PR-4 머지 전 별도 공지가 필요하다 (§7 sunset criteria 참조).

## 4. Cutover sequence

각 단계는 독립적으로 revert 가능하다. revert 절차는 단순 `git revert <merge-commit>` 으로 충분하다 (코드 변경이 SSOT 모듈 / wire 필드 / lookup table 로 국소화되어 있음).

### Step 1 — PR-1: `System_error_class.t` typed SSOT (선행)

- 변경: `lib/system_error_class.ml` 신규 + `lib/system_error_class.mli` + tests.
- wire 영향: 없음 (모듈 dead code 로 추가).
- rollback: PR revert. dead code 만 사라지므로 안전.

### Step 2 — PR-2: writer 측 typed wiring

- 변경: `Telemetry_coverage_gap.record` 시그니처에 `?error_class:System_error_class.t` 추가. 13 caller codemod. 4 inline substring matcher → `System_error_class.classify_*` 호출 치환.
- wire 영향: 모든 신규 row 에 `error_class` 필드 present. `schema` 값은 여전히 `masc.telemetry_coverage_gap.v1` (backward compat 유지).
- rollback: PR revert. caller 가 다시 raw string 만 전달, dashboard 는 substring fallback 으로 자동 회귀.

### Step 3 — PR-3: dashboard reader typed-aware

- 변경: `coverage-gap-block.ts` 에 `errorClassFromBackend` lookup table 추가. v1 fixture 에 대비해 substring fallback (`classifyCoverageError`) 은 *유지*. test fixture 에 v2 row 추가.
- wire 영향: 없음 (reader 만 변경).
- rollback: PR revert. dashboard 는 substring 전용으로 회귀, 정보 손실 cycle 재개되지만 동작 자체는 멈추지 않음.

### Step 4 — Wire stability window (14 일)

- 목적: PR-3 머지 후 writer 의 `error_class` emit 율 + reader 의 lookup hit 율을 측정. v1 row 가 잔존하는지 확인.
- 측정: §6 의 검증 명령으로 v1 / v2 row 비율 확인. 0 v1 row 가 7 일 연속 측정되어야 PR-4 진입.
- rollback: PR-4 진입하지 않는 것 자체가 rollback. PR-2/PR-3 는 그대로 유지.

### Step 5 — PR-4: schema v2 cutover (본 PR 의 후속)

- 변경: writer 의 `schema` 필드를 `masc.telemetry_coverage_gap.v2` 로 bump. `error_class` 를 required 로 격상 (`?error_class` → `~error_class`). dashboard 의 substring fallback (`classifyCoverageError`) 제거.
- wire 영향: 모든 신규 row 가 v2. v1 reader 는 schema 값 mismatch 로 row 를 무시하거나 fallback 처리 필요.
- rollback: PR revert. writer 가 v1 schema 로 돌아가고 reader 는 substring fallback 이 복원되지만, PR-4 머지 후 누적된 v2 row 는 그대로 남는다 (v1 reader 가 v2 row 를 본 경우 `error_class` 필드는 단순히 ignore 됨 — `error` 원본은 유지되므로 substring matching 동작).

### Step 6 — Closeout

- RFC-0154 status: Draft → Implemented. README index update. `implementation_prs` 필드에 PR 번호 기록.

## 5. Failure modes 와 대응

### 5.1 writer v1 / reader v2 (PR-2 머지 전 PR-3 머지 사고)

증상: dashboard 가 `error_class` 를 기대하지만 wire 에 absent. `errorClassFromBackend(undefined)` → `null` 반환.

대응: PR-3 의 lookup 은 substring fallback (`classifyCoverageError`) 을 *유지*하도록 구현. fallback path 가 정보 손실 cycle 을 재개하지만 dashboard 동작 자체는 멈추지 않음. PR 순서를 PR-2 → PR-3 로 강제하여 본 상태가 정상 운영에서 발생하지 않도록 보장.

### 5.2 writer v2 / reader v1 (PR-4 머지 후 외부 reader 미마이그레이션)

증상: 외부 reader 가 `schema: masc.telemetry_coverage_gap.v1` 만 처리하도록 hard-code 되어 있을 경우, v2 row 를 skip.

대응: `error` 원본 string 은 v2 에서도 그대로 유지되므로, 외부 reader 가 `schema` 값을 ignore 하고 `error` 만 보면 backward compat. `schema` 값에 strict match 하는 reader 가 있을 경우, PR-4 머지 전에 §6 의 외부 인벤토리 grep 으로 식별하고 사전 공지.

### 5.3 `Other of string` 폭증

증상: `System_error_class.classify_exn` 이 named variant 에 매핑하지 못한 exception 이 누적되어 `error_class: "other"` row 비율이 상승.

대응: dashboard 의 `error_class: "other"` row 를 정기적으로 확인. 새 패턴이 5% 이상 차지하면 RFC-0154 §9 open question #1 에 따라 후속 RFC 또는 명명 variant 추가 검토.

### 5.4 codemod 누락 caller

증상: PR-2 codemod 후에도 `Telemetry_coverage_gap.record ~error:(Printexc.to_string exn)` 패턴이 잔존, 해당 caller 의 row 에만 `error_class` 가 absent.

대응: PR-2 self-review 단계에서 §6 의 grep 으로 13 caller 전수 확인. PR-4 진입 전 wire stability window 측정 시 `error_class` absent row 가 0 이 아닐 경우 누락 caller 식별 후 보강 PR.

## 6. Verification commands

### 6.1 Writer caller 인벤토리

```bash
rg -n "Telemetry_coverage_gap\.record" lib/ --type-add 'ocaml:*.ml' -t ocaml
```

기대값 (2026-05-20 측정): 13 caller. PR-2 머지 후 caller 수는 변하지 않으나 모두 `~error_class:` 명시 인자를 가짐.

### 6.2 Backend substring matcher SSOT 단일화 확인

```bash
rg -n "too many open files|enospc|disk full" lib/ --type-add 'ocaml:*.ml' -t ocaml
```

PR-2 머지 후 기대값: `lib/system_error_class.ml` 단 1 파일. 그 외 사이트는 0 (RFC-0154 §1.1 의 4 사이트 dedup 완료).

### 6.3 Dashboard schema 참조 인벤토리

```bash
rg -n "masc\.telemetry_coverage_gap" dashboard/src/ --type-add 'ts:*.ts' -t ts
```

기대값 (2026-05-20 측정): 8 파일 (test fixture + tool-quality-panel + fleet-telemetry-panel + telemetry-unified + api/dashboard). PR-4 머지 후 모두 `masc.telemetry_coverage_gap.v2`.

### 6.4 외부 (repo 밖) reader 인벤토리

repo 내부 consumer 는 §6.3 으로 잡힌다. repo 밖 consumer (별도 서비스, 외부 대시보드) 는 다음 명령으로 후보 식별.

```bash
gh search code "masc.telemetry_coverage_gap" --owner jeong-sik --owner kidsnote
```

후보가 있으면 PR-4 머지 전 owner 에게 공지. 후보 0 일 경우 외부 reader 없음으로 간주.

### 6.5 Wire stability window 측정

PR-3 머지 후 14 일간 다음을 정기 측정 (예: 일 1회).

```bash
# 최근 24시간 row 중 error_class absent 비율
jq -r 'select(.schema == "masc.telemetry_coverage_gap.v1") | .error_class // "absent"' \
  logs/telemetry/coverage-gap-$(date -u +%Y-%m-%d).jsonl \
  | sort | uniq -c
```

기대값: PR-4 진입 조건은 `absent` row 가 7 일 연속 0.

## 7. Sunset criteria

PR-4 머지 후, v1 reader path (`classifyCoverageError` 및 dashboard substring fallback) 제거 시점은 다음 조건을 *모두* 만족할 때다.

- PR-4 머지 후 7 일 연속 wire 에 `schema: masc.telemetry_coverage_gap.v1` row 0 (`6.5` 명령으로 측정).
- §6.4 외부 reader 인벤토리에서 v1-strict consumer 0.
- dashboard `*.test.ts` fixture 가 v2 로 마이그레이션 완료 (v1 fixture 0).

세 조건 모두 만족 시 RFC-0154 closeout PR 에서 `lib/system_error_class.ml` 의 `classify_string` 의 backward compat 주석을 정리하고, dashboard `coverage-gap-block.ts` 의 substring fallback 코드 경로를 삭제한다. 잔존 v1 fixture 가 있을 경우 sunset 보류 — v1 reader path 는 fixture 가 0 될 때까지 유지.
