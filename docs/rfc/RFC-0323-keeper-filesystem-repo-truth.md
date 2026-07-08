# RFC-0323: keeper repo 경로를 filesystem 진실로 (catalog 거짓 주입 제거)

## Status
Draft

## Context

keeper들이 매 턴 `cwd_not_directory` 에러로 자기 repo 경로를 못 찾는 현상이 상시 발생한다.

- garnet keeper → `repos/masc` 시도 (실제 clone은 `masc-mcp`, `oas`)
- nick0cave keeper → `repos/jeong-sic-masc` 시도 (실제 clone은 `masc`)

### 근본 원인

keeper prompt assembly(`lib/keeper/keeper_prompt.ml`의 `registered_repositories_block`)가 `repositories.toml` catalog의 **globally registered repo ID**를 "유효한 `repos/<name>` 세그먼트"로 keeper에게 주입한다. 하지만 catalog ID와 keeper playground에 **실제로 clone된 디렉토리 이름** 사이에 invariant가 없다:

- provisioning은 clone을 basename/별칭(`masc`, `masc-mcp`, `oas`)으로 깐다.
- catalog/합성은 다른 이름(`masc`, `jeong-sik-masc`)을 쓴다.
- keeper는 catalog를 진실로 믿고 → 디스크에 없는 경로를 Execute cwd로 시도 → `cwd_not_directory`.

이중 두 경로로 스며든다:

1. **prompt 주입** — `keeper_prompt.ml` + `keeper_run_context.ml:61-82`(`Repo_store.load_all`).
2. **Execute 경로 gate** — `lib/exec_policy/exec_policy_paths.ml:97,104`가 `Keeper_repo_mapping.validate_access`로 catalog whitelist 기반 repo 접근 통제. filesystem에 실제로 있어도 catalog에 없으면 거절.

추가로, 이 결함을 숨기는 회피 프롬프트(`cwd_not_directory 발생 시 repo repair flow로 전환하라`)가 runtime keeper config에 박혀 있었다(symptom 억제). 이는 별도 작업으로 runtime에서 이미 제거됨.

### 비판적 메모

"globally registered repo ID" 개념은 `lib/repo_manager/` 전체 + sandbox provisioning(`keeper_sandbox_control.ml:373,603`) + dashboard repo 목록(`server_dashboard_http.ml:16`) + repo sync(`repo_sync.ml:90`)까지 시스템 SSOT로 깔려 있다. catalog를 **전면 폐지**하면 이 의존 전부를 재설계해야 한다. 본 RFC는 catalog 자체가 아니라 **keeper가 catalog에 의존해 거짓을 믿거나 Execute가 막히는 두 경로**만 filesystem 진실로 바꾼다. catalog는 provisioning/dashboard/sync 용도로 유지한다.

## Principle

keeper가 아는 "내 repo"의 진실은 **filesystem(keeper playground에 실제 clone된 디렉토리)**이다. keeper는 이를 **주입받지 않고 tool로 스스로 확인**한다. Execute 경로 판단도 catalog whitelist가 아니라 filesystem 실존 여부로 한다.

## Changes (scope)

### B-1: keeper prompt에서 catalog 주입 제거

- `lib/keeper/keeper_prompt.ml`:
  - `type registered_repositories` variant(178-180)와 `registered_repositories_block`(243-278) 폐기.
  - `<registered_repositories>` XML 블록 제거.
- `lib/keeper/keeper_run_context.ml:61-82`: `Repo_store.load_all` catalog read 제거, `~registered_repositories` 파라미터 폐기.
- keeper는 기존 tool(`Execute`로 playground `repos/`를 ls / `Grep` / `Read`)로 **매 작업 직전에** 실제 clone을 스스로 확인한다. 항상 최신, stale 불가, keeper autonomy에 부합.
- 연쇄 갱신: `keeper_prompt.mli`, `keeper_execution.mli:64`, `keeper_context_runtime.mli:321`, `test/test_keeper_prompt_metrics.ml:233-277`.
- (설계 결정) keeper 조회 편의용 전용 tool(`keeper_repos_list` 등)을 추가할지, 기존 Execute/Grep으로 cover되는지는 구현 PR에서 정한다. 기존 tool이면 base keeper instructions에 "repo 접근 전 playground/repos를 tool로 확인하라"는 짧은 규율만 추가.

### B-2′: exec_policy repo gate를 filesystem 기반으로

- `lib/exec_policy/exec_policy_paths.ml:97,104`: catalog `validate_access` 대신 keeper playground 경계 내에서 **해당 디렉토리가 실제로 존재하는가**로 판단.
- keeper가 Execute를 부를 때 catalog whitelist가 아니라 filesystem 실존 여부로 허용. catalog ID와 clone 디렉토리명 불일치로 keeper가 막히는 현상 제거.
- sandbox 경계(playground 밖 접근 차단)는 유지 — filesystem 기반이라도 playground 밖은 거절.

### 재발 방지: prompt 주입 회귀 테스트

prompt assembly가 "사실"로 주입하는 값이 runtime(filesystem)과 일치하는지, 또는 주입이 제거된 상태가 유지되는지 단정하는 회귀 테스트를 `test/test_keeper_prompt_metrics.ml`(또는 신규 테스트)에 추가. 향후 누군가 catalog 주입을 재도입하면 잡힌다. "거짓 주입을 자주 청소"해야 하는 상황을 사전에 차단하는 게 본 검증의 목적이다.

## Out of scope

- catalog(`Repo_store`, `repositories.toml`) 자체 폐지 — sandbox provisioning, dashboard repo 목록, repo_sync가 의존. 별도 설계 필요.
- `lib/repo_manager/` authorization gate(`access_decision`/`is_allowed`)의 provisioning/dashboard 용도 호출은 유지.
- keeper runtime json의 과거 instructions 갱신 — keeper reload/restart로 자연 반영(별도 hygiene).

## Verification

```bash
dune build
dune runtest test_keeper_prompt_metrics test_keeper_prompt_external
# exec_policy 테스트 (filesystem 기반 gate)
dune runtest test_exec_policy
```

- keeper 새 턴에서 prompt에 `<registered_repositories>` 블록이 더 이상 렌더링되지 않는지.
- garnet/nick0cave keeper가 tool로 playground를 조회한 뒤 정확한 clone 경로(`masc-mcp`, `oas`, `masc`)를 사용하는지 로그 모니터링.
- keeper Execute가 filesystem 실존 디렉토리에 대해 catalog 무관하게 허용되는지.
- `cwd_not_directory` 에러 빈도 감소 확인.

## Migration

- 백업 보관: `~/.masc/config/keepers/` tar(`masc-config-keepers-backup-2026-07-08.tar.gz`).
- keeper runtime json 갱신: keeper reload/restart로 toml SSOT 반영.

## Risks

- keeper가 "tool로 먼저 확인하라"는 규율이 없으면 다시 추측으로 회귀 → instructions 규율 + (선택) 전용 tool로 보완.
- exec_policy filesystem 기반 판단이 sandbox escape를 허용하지 않도록 playground 경계 검사는 회귀 테스트로 고정.
