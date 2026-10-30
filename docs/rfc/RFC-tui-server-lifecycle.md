---
rfc: "tui-server-lifecycle"
title: "TUI 안에서 서버를 켠다 — opt-in 온디맨드 서버 시작으로 TUI 를 기본 진입점으로"
status: Draft
created: 2026-08-29
updated: 2026-08-29
author: claude
supersedes: []
superseded_by: null
related: []
---

# RFC: TUI-initiated server start (tui-server-lifecycle)

## 0. Summary

`masc-tui` 를 사용자의 **기본 진입점**으로 만든다. 지금 TUI 는 세 가지가 이미 된다:
디스크 `.masc/` 직접 읽기(서버 없이 관찰), 자체 bearer 발급(`Masc_tui_credential`
30일 self-mint), 서버 부재 시 우아한 degrade(`Masc_tui_credential.Unavailable`,
`bin/masc_tui_http.ml:90,106`). 유일하게 빠진 것은 **서버 라이프사이클** — 라이브 화면
(keeper 조종·채팅·실행중 상태)은 별도로 켠 `masc` 서버가 있어야 한다.

이 RFC 는 그 갭만 메운다: 사용자가 라이브 화면에 들어갔는데 서버가 없으면, TUI 가
**한 키로 "여기서 서버 시작"을 제안**하고, 형제 `masc` 바이너리를 감시되는 자식
프로세스로 띄운 뒤, TUI 종료 시 함께 정리한다. **자동 시작이 아니라 opt-in** 이다.

## 1. Motivation

- 엔드유저 온보딩의 가장 흔한 막힘은 "서버를 따로 켜야 한다"는 두 프로세스 모델이다.
- TUI 는 이미 인증·디스크읽기·degrade 를 갖춰, front door 에 한 걸음만 남았다.
- 서버를 따로 띄우라고 문서로만 안내하면, 라이브 화면이 왜 비었는지 사용자가 모른다.

## 2. 경계 입장 (Non-goals 포함)

이 변경은 masc 의 경계 원칙(`instructions/projects.md`)을 지킨다.

- **디스크 단독 관찰이 기본으로 남는다.** 서버 시작은 라이브 화면에서만, 명시적 키로만.
- **TUI 는 서버가 되지 않는다.** 서버 코드를 in-process 로 링크하지 않고, 별도 바이너리
  (`masc` / `main_eio.exe`)를 자식 프로세스로 exec 한다. authority 는 여전히 서버.
- **TUI 는 자기가 띄운 서버만 정리한다.** 이미 떠 있던(자기가 연결만 한) 서버는 절대
  죽이지 않는다. "owned" vs "connected" 를 구분해 소유한 것만 tree-kill.
- **자동 시작 금지.** 헤드리스/CI/스크립트가 우연히 서버를 스폰하지 않도록, TTY 있는
  대화형 세션의 명시적 키 입력에서만 발동.
- Non-goals: TUI 안 프로바이더 키 마법사(별도), 원격 서버 관리, 다중 서버, 자동 재시작.

## 3. Design

### 3.1 발동 지점 (trigger)

라이브 화면(keeper 조종/채팅 등)이 `Masc_tui_credential.Unavailable`
(`no_workspace_detail`, `bin/masc_tui_http.ml:90,106`) 로 판정될 때, footer/빈 상태에
**"s: 이 워크스페이스에서 서버 시작"** 힌트를 띄운다. 사용자가 그 키를 누를 때만 진행.

### 3.2 서버 바이너리 탐색 (discovery)

install.sh 는 `masc` 와 `masc-tui` 를 같은 PREFIX 에 나란히 설치한다(`scripts/install.sh`
detect_asset). 따라서 `Filename.dirname (Sys.executable_name)` + `"masc"` 를 우선 탐색한다.
없으면(소스 실행 등) `$PATH` 의 `masc` 를 시도하고, 그래도 없으면 **추측하지 않고**
수동 시작 명령을 그대로 보여준다(silent failure 금지).

### 3.3 스폰 + 감시 (spawn + supervise)

- `lib/process/process_eio_detached` 의 `detached_handle { pid; pgid; ... }` 로
  `masc --base-path <현재 base> --host 127.0.0.1 --port <현재 port>` 를 detached 스폰.
  `pgid == pid` 라 종료 시 tree-kill 이 깔끔하다.
- 자식 stdout/stderr 는 `<base>/.masc/logs/` 로 리다이렉트(TUI 화면을 오염시키지 않게).
- 스폰 직후 `/health` 를 바운드 폴링(예: 30 회 × 1s)해 `status:ok` 확인 후에야 화면을
  라이브로 전환. 진행/실패를 화면에 표시.

### 3.4 정리 (cleanup)

- `detached_handle` 를 TUI 메인 Eio switch(또는 `lib/process/spawn_handle`/`spawn_registry`)
  에 등록. `Switch.on_release` 에서 **owned 서버만** pgid 로 tree-kill.
- Eio 정리 규칙(`/ocaml-coding`): `Switch.run` + `Switch.on_release` 사용. `Fun.protect`
  finally 가 원 예외를 덮는 경로를 피한다.

### 3.5 크래시 처리

자식이 예기치 않게 죽으면 조용히 재스폰하지 않는다. "서버가 종료됨"을 표면화하고,
사용자가 원하면 같은 키로 재시작. (cap/cooldown/자동 재시작은 워크어라운드 신호이므로
넣지 않는다 — `instructions/software-development.md` 워크어라운드 거부 기준.)

### 3.6 프로바이더 키 갭

서버는 프로바이더 키 없이도 뜨지만 keeper 는 LLM 작업을 못 한다. TUI 는 "서버 up,
프로바이더 키 미설정 → keeper 유휴" 상태를 명시적으로 보여준다(왜 비었는지 사용자가
알 수 있게). 키 설정 마법사는 이 RFC 범위 밖.

## 4. 검증 / 하네스

**TTY 문제**: `masc-tui` 는 TTY 없이 시작을 거부(release.yml 주석)해서 CI 가 전체 렌더
루프를 못 띄운다. 그래서 서버 라이프사이클 로직을 **TUI 렌더에서 분리한 테스트 가능
모듈**(예: `masc_tui_server_lifecycle`)로 추출하고 다음을 단위 테스트한다:

- 바이너리 탐색(형제 → PATH → 없으면 명령 문자열 반환, 추측 금지)
- 스폰 argv 구성(base-path/host/port 정확)
- health-wait 폴링(성공/타임아웃/서버 즉사)
- owned vs connected 추적(연결만 한 서버는 kill 대상에서 제외)
- switch 종료 시 owned 서버만 정리

`test/test_tui_keyboard_input.py` PTY 스위트로 키→발동 경로를, OCaml 단위 테스트로
비-TUI 로직을 덮는다. 헤드리스 통합 테스트는 렌더 루프 없이 라이프사이클 모듈을 직접
호출해 스폰→health→cleanup 을 검증.

## 5. Boundary checklist (projects.md)

- producer→store→consumer→caller: 새 store/필드/Gate 없음. 서버는 여전히 authority,
  TUI 는 projection + opt-in launcher.
- 파생 상태로 Gate 만들지 않음. "owned server" 는 프로세스 핸들일 뿐 durable 필드 아님.
- facade 가 facade 를 호출하지 않음: TUI → `process_eio_detached` 직접.

## 6. Scope

- In: opt-in 서버 시작, 감시, owned-only 정리, 상태 표면화, 라이프사이클 모듈 + 테스트.
- Out: 프로바이더 키 마법사, 자동 시작, 원격/다중 서버, 자동 재시작.

## 7. Rollout

1. `masc_tui_server_lifecycle` 모듈 + 단위 테스트(비-TUI 로직).
2. TUI 발동 지점(키/힌트) + health-wait 화면 전환.
3. cleanup(switch on_release, owned-only).
4. PTY 스위트 + 문서(README TUI 절: "라이브가 필요하면 s 로 서버 시작").
