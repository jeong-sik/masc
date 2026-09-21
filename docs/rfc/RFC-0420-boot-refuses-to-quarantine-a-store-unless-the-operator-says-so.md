---
rfc: "0420"
title: "부팅은 store 를 격리하지 않고 거부한다 — 운영자가 명시하지 않는 한"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
supersedes: []
superseded_by: null
related: ["0044", "0418"]
---

## 1. 문제

2026-09-05 08:13Z, #33241(fact 코덱에서 `reinforcement` 필드 제거)이 머지된 13분 뒤
새 바이너리가 `scripts/deploy.sh` 가 아니라 셸에서 `main_eio.exe --host … --port
8935 --base-path=/Users/dancer/me` 로 직접 떴다. `deploy.sh` 는 옛 프로세스를 내린
뒤 `deployment_preflight_helper validate-stores` 를 돌리고, 못 읽는 store 가 하나라도
있으면 배포를 멈춘다. 셸은 그 게이트를 지나지 않는다.

바이너리는 부팅 때 `Keeper_store_boot_reconcile` (#32515) 을 돈다. 이 build 가 못
읽는 store 를 `<path>.rejected-<ts>` 로 옮기고 WARN 한 줄씩, 요약 INFO 한 줄을 남긴
뒤 뜬다. 그날 snapshot 15개, 사실 1,122건이 옮겨졌고 keeper 들은 빈 기억으로 다시
시작했다. journal 15개에는 옛 필드가 남아 TUI 의 journal 창이 줄마다 "unreadable"
을 찍었다. 복구는 09:35Z, 격리본을 strip 하고 부팅 뒤 새 사실 78건과 합쳐 되돌렸다
(#33241 코멘트).

### 1.1 격리는 설계였다

`server_bootstrap_loops.ml` 의 주석은 이렇다: "이 build 가 못 읽는 store 는 지금
한 곳에서 옮긴다. 스키마 hard cut 이 첫 부팅에서 끝나고, 몇 시간 뒤 keeper 마다
읽기·쓰기 중 먼저 오는 쪽에서 터지지 않는다." 맞는 목표다. 빠진 것은 **누가
결정하느냐**다. `deploy.sh` 경로에서는 운영자가 preflight 의 거부를 보고 strip 을
하거나 배포를 물린다. 셸 경로에서는 부팅 코드가 운영자 대신 결정하고, 그 결정은
로그 두 줄이다.

### 1.2 왜 스크립트로 닫을 수 없나

게이트가 스크립트에만 있으면 스크립트를 쓰지 않는 손이 게이트를 없앤다. 이번이
그 손이었다. 런북에 "직접 실행 금지" 를 적어도 같은 일이 다시 난다. 바이너리가
스스로 거부해야 어느 경로로 떠도 같은 답을 한다.

## 2. 지금의 두 게이트

| | 어디 | 무엇을 보나 | 못 읽으면 |
|---|---|---|---|
| `validate-stores` | `deploy.sh` 4단계, preflight helper | keeper meta, memory current, memory source, paused-work 영수증, board posts, provider-input, turn record, 공식 클라이언트 세션 — 8종 | **배포 중단**, exit 1 |
| boot reconcile | 바이너리 부팅, keeper 루프 전 | keeper meta, memory current — 2종 | **옮기고 계속** |

두 게이트는 같은 디코더를 쓴다. 답이 다른 것은 정책이다.

## 3. 판단

- 못 읽는 store 를 옮기는 것은 durable truth 를 바꾸는 일이다. 파일은 남지만
  keeper 는 그 뒤로 그것을 읽지 않는다. 그런 결정은 운영자의 것이다.
- 부팅은 **거부**가 기본이다. 운영자가 격리를 원하면 플래그로 말한다. 그러면
  지금 코드가 하는 일을 그대로 한다.
- `deploy.sh` 경로는 바뀌지 않는다. preflight 가 이미 막았으므로 부팅이 거부할
  일이 없다. 거부가 나면 preflight 와 부팅이 다른 답을 낸 것이고, 그건 override 가
  아니라 조사할 결함이다.
- 새 상태·필드·계측은 없다. 이미 계산하는 보고서(`report.quarantined`)를 옮기기
  전에 한 번 더 보는 것뿐이다.

## 4. 설계

### 4.1 두 단계

`Keeper_store_boot_reconcile` 을 **살피기**와 **옮기기**로 나눈다.

```ocaml
type undecodable = { store : store; keeper : string; path : string; rejection : string }

(* 읽기만 한다. 이름을 바꾸지 않는다. *)
val examine : Workspace.config -> undecodable list

(* 지금의 reconcile. 살핀 것을 옮기고 보고서를 돌려준다. *)
val quarantine : now:float -> Workspace.config -> undecodable list -> report
```

`examine` 은 두 store 에 지금과 같은 디코더를 쓴다. keeper meta 는
`Keeper_meta_store.validate_current_meta_file_result`, memory current 는 스냅샷
읽기(`read_for_keepers_dir`)다. `quarantine_undecodable_for_keepers_dir` 안에 묶여 있던
"읽고 못 읽으면 바로 rename" 을, 읽기와 rename 으로 가른다.

### 4.2 부팅의 결정

`prepare_keeper_persistence_owned` 에서:

```ocaml
match Keeper_store_boot_reconcile.examine config, accept_store_quarantine with
| [], _ -> (* 지금처럼 진행. 보고서는 examined/readable 만 *)
| undecodable, false -> Error (Store_quarantine_refused undecodable)
| undecodable, true -> (* quarantine 하고 지금처럼 진행 *)
```

`keeper_persistence_prepare_error` 에 `Store_quarantine_refused of undecodable list`
를 더한다. 닫힌 variant 라 `failure_cause_of_prepare_error`,
`keeper_persistence_prepare_error_to_string` 등 소비자는 컴파일러가 짚는다.
거부 메시지는 store 마다 한 줄이다: 경로, 거부 사유, 그리고 다음 두 길.

```
boot refused: 15 store(s) this build cannot read
  memory_current sangsu /Users/…/sangsu.memory-current.json: facts[0]: field set mismatch (unexpected: reinforcement)
  …
strip or repair the files, run `deployment_preflight_helper validate-stores --base-path=…`,
or start with --accept-store-quarantine to move them aside and start empty.
```

### 4.3 플래그

`bin/main_eio.ml` 에 Cmdliner 플래그 `--accept-store-quarantine` (기본 false).
환경변수 짝은 두지 않는다. 격리는 한 번 내리는 결정이고, 환경에 남으면 다음 부팅도
말없이 격리한다. `deploy.sh` 의 `lease-handoff --next-argument` 에는 넣지 않는다.

### 4.4 `failed` 는 그대로

rename 자체가 실패한 경우(`report.failed`)는 지금처럼 보고서에 남고 부팅은 계속
된다. 그것은 파일시스템 오류이고, 이 RFC 가 다루는 "읽을 수 없어 옮기는 결정" 이
아니다.

## 5. 판정 기준

1. 못 읽는 snapshot 하나를 둔 base path 로 `main_eio.exe` 를 플래그 없이 띄우면
   프로세스가 뜨지 않고 exit 코드가 0 이 아니며, 표준 오류에 그 파일 경로와
   거부 사유가 있다. 파일은 그 자리에 그대로 있다.
2. 같은 base path 에 `--accept-store-quarantine` 을 주면 지금과 같이 뜬다.
   `*.rejected-<ts>` 가 생기고 WARN 과 요약 줄이 남는다 (#32515 의 테스트
   `undecodable stores are moved aside once` 가 이 경로로 그대로 통과).
3. `deploy.sh` 로 배포한 것은 동작이 같다. preflight 가 통과한 base path 에서 부팅
   거부가 나지 않는다.
4. `examine` 은 파일을 바꾸지 않는다. 두 번 불러도 같은 답이다.

## 6. 대안과 비채택

- **런북과 런처 스크립트만 고친다.** 스크립트를 안 쓴 손이 이번 사고다. 게이트가
  경로에 붙어 있으면 경로를 벗어나는 순간 없다.
- **격리를 TUI·대시보드에 보이게 한다.** 발견은 빨라지지만 손실은 같다. 결정을
  운영자에게 돌려주는 것이 먼저다. 보이게 하는 것은 그 뒤에 따로.
- **못 읽는 keeper 만 빼고 뜬다 (부분 부팅).** keeper 하나의 기억이 사라진 채 나머지가
  도는 것은 지금과 같은 결과를 조용히 만든다.
- **환경변수 override.** 4.3.
- **부팅이 알아서 strip 한다.** 어느 필드를 지워야 하는지는 이 build 가 알지만,
  그 판단을 부팅에 심으면 스키마 cut 마다 부팅 코드에 마이그레이션이 쌓인다.
  hard cut 은 마이그레이션 코드를 만들지 않는다(projects.md).

## 7. 구현 범위와 순서

1. `Keeper_store_boot_reconcile`: `examine` / `quarantine` 분리, 타입, 테스트
   (살피기는 rename 하지 않는다, 옮기기는 살핀 것만 옮긴다).
2. `Server_bootstrap_loops`: `Store_quarantine_refused`, 결정, 메시지. 결정 함수는
   순수 함수로 빼서 테스트한다(빈 목록·플래그 없음·플래그 있음 세 갈래).
3. `bin/main_eio.ml`: 플래그, `Server_runtime_bootstrap` 까지 전달.
4. 런북(`docs/KEEPER-CONTINUITY-PRODUCTION-RUNBOOK.md` 또는 배포 문서)에 거부
   메시지와 두 길을 적는다.

## 8. 건드리지 않는 것

- `validate-stores` 와 `deploy.sh`.
- 격리의 파일 이름 규칙(`.rejected-<ts>`, 번호 접미사)과 journal 의 `quarantined` 줄.
- reconcile 이 보지 않는 여섯 store. 그것들은 부팅에서 옮겨진 적이 없다.

## 출처

- #32515 `feat(boot): move aside every store this build cannot decode, once, before keepers start` (623a4b2ca7, 2026-09-02).
- #33241 코멘트 (2026-09-05): 격리 15건, 복구 절차, 복구 증명.
- `scripts/deploy.sh` 4단계와 `deployment_preflight_helper validate-stores`.
