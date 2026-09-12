---
rfc: "0447"
title: "서버는 영속 포트에 붙거나 기동을 거부한다"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["0052"]
implementation_prs: []
---

# RFC-0447: 서버는 영속 포트에 붙거나 기동을 거부한다 (port-bind-or-refuse)

## 0. Summary

`masc start` 는 workspace 의 영속 포트(`connection.toml`) 하나에만 bind 한다. 전임 서버가 그 포트를 잡고 있으면 전임이 스스로 광고한 종료 기한까지 lease 해제를 기다린 뒤 bind 한다. 기한이 지나도 잡혀 있으면 typed 이유를 남기고 기동을 거부한다. 다른 포트를 고르는 경로는 없다. 포트가 바뀌는 길은 운영자의 명시적 `--port` 하나다.

관계: #35133 의 "비어 있는 포트 선택" 과 `suggested_port` 는 지운다(narrows). #35241 의 포트 영속은 유지하되 쓰는 시점을 bind + readiness 뒤로 옮기고 쓰는 조건을 `--port` 로 좁힌다(narrows). RFC-0052 의 boot-time required invariant 를 네트워크 endpoint 까지 넓힌다(extends). 이슈 #35270 이 지목한 원인을 이 문서가 닫는다. 결정 원문은 memory `masc-runtime-decisions-2026-09-12` 2번.

## 1. 배경 (실측)

- 2026-09-11T15:59:51Z 부터 09-12T07:40:42Z 까지 16시간 안에 포트가 네 번 옮겨졌다: 8935 → 56209 → 54984 → 60690 → 56492. 09-11 bind 줄 20개(8935 16, 56209 3, 54984 1), 09-12 bind 줄 9개(60690 6, 56492 3). 지금 살아 있는 서버는 pid 38621, `127.0.0.1:56492`, `connection.toml` 도 56492 다.
- 원인은 B6 가 코드 위치까지 잡았다. SIGTERM 을 받은 전임은 `force_timeout_s = 10.0`(`lib/shutdown.ml:28`) 동안 drain 한다. 후임은 `bin/masc_cli_owner_upgrade.ml:stop` 에서 `Owner_draining | Port_busy` 를 0.2초 × 25회, 즉 5초만 기다리고 `port_available=false` 를 돌려준다. setup 은 `Server_upgrade_preparation.suggest_loopback_port`(`:0` bind 로 OS 임시 포트) 가 준 값으로 후임을 띄우고, `server_runtime_bootstrap.ml:run_serving` 이 readiness 전에 `Workspace_connection.save` 로 그 임시 포트를 영속시킨다. 18:54:09Z SIGTERM 뒤 전임은 18:54:09Z 까지 56209 로 stats 를 찍었고 후임은 18:54:25Z 에 54984 를 잡았다(16초 겹침).
- 포트를 따라가는 소비자는 `Workspace_connection.resolve` 를 읽는 TUI 와 CLI 뿐이다. 나머지는 8935 리터럴이다: `~/me/.mcp.json`(운영자가 손으로 56492 로 고쳐 둔 상태), Cloudflare 터널(`~/.cloudflared/config.yml`, `scripts/deploy.sh:11-12` 주석), `dashboard/src/config/constants.ts:7 DEFAULT_MASC_PORT`, `scripts/` 42개 파일 56줄, docs 217개 파일. 스크립트는 같은 값을 여섯 가지 env 이름으로 읽는다(R11). `connection.toml` 을 읽는 스크립트는 `install-runtime-setup.py` 하나다.
- 대시보드 connector 힌트는 `gate_base_url` 이 없으면 `DEFAULT_MASC_ORIGIN` 을 찍는다. 살아 있는 connector 4행 중 3행이 죽은 8935 를 "서버 확인" 위치로 보여줬다(U7).
- 두 번째 기동 경로도 같은 결함을 갖고 있다. `bin/main_eio.ml:880` 는 EADDRINUSE 를 2^n 초(최대 30초) × 5회 재시도하고, `server_startup_takeover.ml:520-570` 은 pid 파일의 pid 를 `looks_like_server_command` 문자열 판정으로 거른 뒤 SIGTERM → SIGKILL 까지 보낸다.

## 2. 설계

### 2.1 포트 출처와 우선순위

```ocaml
(* lib/workspace_connection *)
type port_source =
  | Cli_explicit of port      (* --port N *)
  | Environment of port       (* MASC_HTTP_PORT, 이 프로세스에만 *)
  | Persisted of port         (* .masc/config/connection.toml [server].http_port *)
  | Default of port           (* 파일이 없을 때만. Masc_network_defaults.masc_http_default_port *)
```

- 우선순위는 지금과 같다: `Cli_explicit > Environment > Persisted > Default`.
- 영속되는 출처는 `Cli_explicit` 뿐이다. `Environment` 는 그 프로세스에서만 쓰고 파일에 쓰지 않는다. `Persisted` 는 이미 파일이다. `Default` 는 파일이 없을 때 첫 기동이 readiness 뒤 `Persisted` 로 승격한다.
- `--port 0` 은 파서가 거부한다(`Workspace_connection.port`: 1..65535 밖은 `Invalid_port`). OS 가 고르는 포트는 어떤 경로에도 없다.
- bind 주소는 `--host` 가 정한다. `connection.toml` 은 `[server] host` 와 `http_port` 둘을 갖는다. host 는 `Ipaddr.of_string` 으로 한 번 파싱해 V4 또는 V6 한 family 로만 bind 한다. dual-stack 이나 `::` → `0.0.0.0` 대체는 없다. 파싱 실패는 `Address_unusable` 이다. `listen_socket` 의 `Error _ -> V4.loopback` 대체(`server_bootstrap_http.ml:32`) 는 지운다. 전임을 살피는 probe 와 bind 검사도 전부 이 파싱된 주소를 쓴다. 지금은 `PF_INET` + `inet_addr_loopback` 이 세 곳에 박혀 있다.

### 2.2 bind 결과

```ocaml
type bind_outcome =
  | Bound of { address : Ipaddr.t; port : port; source : port_source; handoff : handoff }
  | Refused of bind_refusal

and bind_refusal =
  | Port_held_by_known_owner of
      { port : port; pid : int; workspace : string; version : string }
      (* lease F_GETLK 로 잡은 pid + /health?full=1 identity 가 같은 프로세스를 가리킬 때만 *)
  | Port_held_by_unknown_process of { port : port; health : unknown_health }
  | Address_unusable of { address : string; reason : address_failure }

and unknown_health = Not_masc | Different_workspace of string | No_response
and address_failure = Invalid_host | Permission_denied | Address_not_available
```

- `Port_held_by_known_owner` 의 pid 는 `Owner_process_identity.capture`(F_GETLK) 가 준 값이다. pid 파일 내용은 쓰지 않는다. F_GETLK 가 pid 를 못 주면(`Unsupported`) `Port_held_by_unknown_process` 다. 잡고 있는 프로세스가 `/health?full=1` 에 답하지 않거나 다른 workspace 면 pid 를 알아도 unknown 이다.
- `Address_unusable` 은 점유가 아니다. EACCES, EADDRNOTAVAIL, host 파싱 실패가 여기다. 전임을 기다리지 않는다.

### 2.3 전임 인계

```ocaml
type handoff =
  | No_predecessor                                        (* lease 없음, 첫 bind 성공 *)
  | Predecessor_released of { pid : int; waited_ms : int } (* lease 해제를 보고 bind *)
  | Handoff_failed of handoff_failure

and handoff_failure =
  | Predecessor_still_holds of { pid : int; deadline_s : float }
  | Predecessor_identity_changed                          (* Owner_process_identity: Owner_changed *)
  | Predecessor_not_masc of { pid : int }
  | Cancelled_by_operator
```

- 관찰 조건은 workspace lease(`Host_config.base_path_lease_dir` 아래 파일) 의 잠금 해제다. 후임은 `F_SETLKW` 를 systhread 에서 걸어 커널이 깨울 때까지 기다린다. 폴링 간격이 없다. 전임이 정상 종료하든 watchdog 이 exit 124 로 죽이든 fd 는 닫히고 잠금은 풀린다.
- 기다리는 기한은 후임이 정하지 않는다. 전임이 `/health?full=1` 에 `shutdown.force_timeout_s` 와 `pid` 를 광고하고, 후임은 그 값을 `Eio.Time.with_timeout` 의 기한으로 쓴다. 기한이 지나면 `Predecessor_still_holds {pid; deadline_s}` 로 `Refused` 다. 전임이 광고하지 않으면 기다리지 않고 `Port_held_by_unknown_process` 다.
- lease 가 풀린 뒤 bind 가 또 EADDRINUSE 면 재시도 없이 `Port_held_by_unknown_process` 다. 그 사이 다른 프로세스가 잡은 것이다.
- 기동 경로는 어떤 프로세스에도 시그널을 보내지 않는다. `server_startup_takeover.ml` 의 `looks_like_server_command` 판정, SIGTERM, SIGKILL, takeover breadcrumb 는 지운다. 전임에게 종료를 요청하는 곳은 `masc setup` 의 stop 하나이고, 그 전에 `authorize_initial`(운영자 로그인) 과 `Owner_process_identity.capture` 가 같은 incarnation 임을 확인해야 `request_termination` 을 부른다. SIGTERM 한 번, SIGKILL 없음은 `owner_process_identity.mli` 가 이미 정한 계약이다.
- Ctrl-C 는 `Cancelled_by_operator` 다. 후임은 아무것도 쓰지 않고 exit 1 한다.

### 2.4 영속 시점과 크래시 경계

- `connection.toml` 을 쓰는 곳은 서버 하나다. `bin/masc_cli_setup.ml:221` 과 `bin/main_eio.ml:2997` 의 save 는 지운다.
- 쓰는 조건은 셋을 다 만족할 때다: `Bound`, `Server_startup_state.state_ready`, `source = Cli_explicit` 이거나 파일이 없어 `Default` 였을 때. 값이 파일과 같으면 쓰지 않는다.
- bind 전 크래시: 파일 그대로, 전임 그대로(시그널을 보낸 적이 없다).
- bind 뒤 readiness 전 크래시: 기존 startup watchdog 이 exit 1, 파일 그대로, 포트는 OS 가 회수한다.
- 파일 쓰기 실패(`Write_failed`): 이미 bind 되어 있으므로 서버는 그대로 서빙한다. `Connection_publish_failed {file; reason}` 를 로그·대시보드·`masc_status` 에 낸다. 쓰기 자체는 `write_file_atomic_strict_staged` 라 반쯤 쓰인 파일은 생기지 않는다.
- 전임 종료 경계: 전임이 기한 안에 못 끝낸 요청은 전임의 exit 124 계약대로 끊긴다. 후임은 그 요청을 이어받지 않는다.

### 2.5 소비자 목록과 통지

| 소비자 | 소유 | 포트를 아는 방법 | 변경 시 |
|---|---|---|---|
| `.masc/config/connection.toml` | 서버 | 2.4 | 서버가 쓴다 |
| TUI (`bin/masc_tui.ml:861`), CLI 하위 명령 (`bin/main_eio.ml:414`) | repo | `Workspace_connection.resolve` | 없음 |
| dashboard | repo | `window.location.origin` + shell payload 의 endpoint | 없음. `DEFAULT_MASC_PORT`·`DEFAULT_MASC_ORIGIN` 은 지운다 |
| `scripts/` 42개 파일 | repo | `masc connection --json` 하나로 읽는다. env 는 `MASC_HTTP_PORT` 하나 | 없음 |
| `scripts/install-runtime-setup.py` | repo | 이미 파일을 읽는다 | 없음 |
| `~/me/.mcp.json` | 운영자 | 리터럴 | setup 이 `Endpoint_changed {from; to}` 를 stdout JSON 과 board 에 남긴다. 파일은 안 건드린다 |
| Cloudflare 터널 `~/.cloudflared/config.yml` | 운영자 | 리터럴 | 같음 |

- 같은 포트로 반복 업그레이드: `Endpoint_changed` 는 나지 않는다. setup 출력은 `endpoint_unchanged=true`, `predecessor_pid`, `successor_pid`, 후임 `/health?full=1` 의 `effective_base_path`·`version` 을 담는다. 후임 identity 는 이 health 응답으로 확인하고, pid 가 전임과 같으면 `Incumbent_changed` 오류다.

### 2.6 각 표면

- 로그 한 줄: `[bind] bound 127.0.0.1:8935 source=persisted handoff=predecessor_released pid=64903 waited_ms=812`. 거부는 `[bind] refused port=8935 reason=port_held_by_known_owner pid=64903 workspace=/Users/dancer/me version=0.35.4 deadline_s=10`.
- `masc start` 종료 코드: `Bound` 0, `Refused` 1, 파서 거부(`--port 0`) 2. `Refused` 는 stderr 에 `masc.start_refused.v1` JSON 을 낸다. 필드는 2.2 의 생성자 이름과 같다.
- `masc_status` (MCP tool result): `server.endpoint = {host; port; source; handoff; published}`.
- dashboard runtime/config 패널: 같은 레코드 한 줄. connector 힌트는 `window.location.origin`.
- TUI 연결 배지: `127.0.0.1:8935 (persisted)`.
- board: `Endpoint_changed` 만 게시한다. 거부는 서버가 없으므로 board 에 못 쓰고 로그와 stderr 가 증거다.

## 3. 판정 기준

- P1 재기동 20회: 8935 가 영속된 workspace 에 SIGTERM 재기동 20회. `rg -c "auto 127.0.0.1:8935\] HTTP auto-detect" system_log_*.jsonl` 이 20 늘고 다른 포트의 bind 줄은 0. `connection.toml` mtime 이 안 바뀐다.
- P2 외부 점유: `python3 -m http.server 8935` 를 띄운 채 `masc start`. 기한 없이 곧바로 exit 1, stderr 에 `reason=port_held_by_unknown_process health=not_masc`. http.server 는 살아 있고 `connection.toml` 은 그대로.
- P3 전임 기한 초과: 전임의 drain 을 테스트 훅 없이 실제 긴 요청으로 붙잡은 채 후임 기동. 후임은 전임이 광고한 `deadline_s` 안에 `Predecessor_still_holds` 로 exit 1. 전임은 자기 watchdog 으로 exit 124.
- P4 `--port 0`: exit 2, bind 줄 0.
- P5 env: `MASC_HTTP_PORT=9000 masc start` 는 9000 에 붙고 로그 `source=environment`, `connection.toml` 그대로.
- P6 명시 변경: `masc start --port 9001` 은 `state_ready` 뒤에만 파일이 9001 이 된다. init 도중 `kill -9` 하면 파일은 이전 값이다.
- P7 IPv6: `--host ::1` 로 기동하면 `curl http://127.0.0.1:PORT/health` 가 connection refused, 로그 `address=[::1]`.
- P8 리터럴 0: `rg -n "8935" scripts dashboard/src lib bin` 이 `masc_network_defaults.ml:58` 한 줄만 남긴다. `scripts/check-ssot.sh` 가 이 조건을 검사한다.
- F: setup 출력에 `suggested_port` 나 `port_available` 키가 있으면 실패. 로그에 `Port %d in use, retrying` 이 한 줄이라도 있으면 실패.

## 4. 단계

- PR-1 `lib/workspace_connection`: `port_source`, `[server] host` 필드, 쓰기 조건(2.4). setup 과 main_eio 의 save 두 곳 제거. 판정 P5, P6.
- PR-2 bind 경로: `bind_outcome`·`handoff` 도입, `F_SETLKW` 대기와 전임 광고 기한, `/health?full=1` 에 `pid`·`shutdown.force_timeout_s` 추가. `main_eio.ml` 의 EADDRINUSE 재시도, `server_startup_takeover.ml` 의 문자열 판정·시그널·breadcrumb, `suggest_loopback_port`·`replacement_readiness` 폴링 제거. 판정 P1, P2, P3, P4, F.
- PR-3 주소 family: `listen_socket` 대체 제거, probe 세 곳이 파싱된 주소를 쓴다. 판정 P7.
- PR-4 소비자: dashboard 상수 제거와 `window.location.origin`, `masc connection --json`, 스크립트 42개와 env 이름 통일, `check-ssot.sh` 규칙. 판정 P8.
- PR-5 표면: 로그 한 줄, `masc_status` endpoint 레코드, TUI 배지, `Endpoint_changed` board 게시, setup 의 반복 업그레이드 출력(2.5).

## 5. 반론과 답

- **"전임을 기다리다 영영 멈춘다"** — 기한은 후임의 추측이 아니라 전임이 광고한 자기 watchdog 기한이다. 전임은 그 시각에 exit 124 로 반드시 죽고 lease fd 가 닫힌다. 후임은 `F_SETLKW` 로 그 순간 깨어나거나 기한에 `Predecessor_still_holds` 로 끝난다. 두 경우 모두 끝이 있다.
- **"`Port_held_by {pid}` 는 OS 가 못 주는 정보를 약속한다"** — 그래서 생성자를 둘로 나눴다. pid 는 F_GETLK 가 준 것만 싣고, 못 주면 `Port_held_by_unknown_process` 다. pid 파일과 `lsof` 는 쓰지 않는다.
- **"pid 를 안다고 죽일 권한이 생기는 건 아니다"** — 기동 경로는 아무에게도 시그널을 보내지 않는다. 종료 요청은 setup 이 운영자 로그인과 incarnation 일치를 확인한 뒤 SIGTERM 한 번만 보낸다. SIGKILL 경로는 지운다.
- **"운영자 파일을 왜 안 고쳐 주나"** — `.mcp.json` 과 터널 설정은 다른 도구의 설정 파일이라 masc 가 고쳐 쓰면 그 도구와 충돌한다. 대신 포트가 바뀌는 순간이 `Endpoint_changed` 한 건으로 남고, 바뀌는 길이 `--port` 하나라 운영자가 그 시각을 안다.
- 헌법 forbidden: `magic_number` — 0.2초 × 25, 2^n × 5 를 지우고 남는 숫자는 전임이 광고한 기한 하나다. `string_matching` — `looks_like_server_command` 를 지운다. `budget_gate` — 기한은 누적 예산이 아니라 전임 프로세스의 종료 계약이고 재시도 횟수 상한은 없다. `greedy_shortcut` — 임시 포트 대체가 바로 이것이라 지운다. `hardcoded_path` — 파일 경로는 `Common.masc_dir_from_base_path` 로만 만든다. `env_var_sprawl` — env 는 `MASC_HTTP_PORT` 하나이고 영속되지 않는다. `legacy_residue` — `suggested_port`, `port_available`, `DEFAULT_MASC_PORT`, breadcrumb 를 남기지 않고 지운다. host 없는 옛 `connection.toml` 은 `Invalid_configuration` 이며 호환 reader 를 만들지 않는다. 운영자가 `--host --port` 를 한 번 주면 된다.
- 헌법 invariants: `closed_sum_over_string` — 2.2·2.3 의 합타입이 전부이고 로그 줄은 그 생성자 이름의 투영이다. `strict_parse_no_default` — host 파싱 실패와 `--port 0` 은 오류이지 loopback·기본 포트가 아니다. `failure_keeps_evidence` — 거부는 파일을 안 바꾸고 로그 한 줄과 stderr JSON 을 남기며 전임을 소비하지 않는다.

## 6. 근거

- 감사 finding: `/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/merged.md` B6(high, confirmed), U7(medium, confirmed), R11(unverified). 종합 `synthesis-adversarial.md` §1 표 4행. Codex 검토 `codex-roadmap.json` `decision_critiques[1]`(agree, 다섯 항목은 2.1·2.3·2.2·2.4·2.5 가 순서대로 답한다).
- 포트 이동: bind 줄 `[auto 127.0.0.1:<port>] HTTP auto-detect mode` — 09-11 8935 ×16(마지막 14:41:33Z), 56209 ×3(16:00:02Z, 16:00:29Z, 16:29:46Z), 54984 ×1(18:54:30Z); 09-12 60690 ×6(첫 03:34:58Z), 56492 ×3(첫 07:40:42Z). SIGTERM 15:59:17Z, 16:00:10Z, 16:28:59Z, 18:54:09Z. 파일 `system_log_2026-09-11.jsonl`, `system_log_2026-09-12.jsonl`.
- 지금 상태(2026-09-12 확인): `lsof` pid 38621 `127.0.0.1:56492 LISTEN`, `.masc/config/connection.toml` `http_port = 56492`, `~/me/.mcp.json` url `127.0.0.1:56492`.
- 코드: `bin/masc_cli_owner_upgrade.ml:stop`(0.2s × 25 대기, `suggested_port`), `lib/server/server_upgrade_preparation.ml:suggest_loopback_port`(`:0` bind), `:replacement_readiness`(PF_INET loopback 고정), `lib/server/server_runtime_bootstrap.ml:2081`(`run_serving`, readiness 전 save), `lib/workspace_connection/workspace_connection.ml:resolve`·`save`, `bin/masc_cli_setup.ml:221`, `bin/main_eio.ml:880`(EADDRINUSE 2^n × 5), `:2997`(두 번째 save), `lib/server/server_startup_takeover.ml:520-570`(문자열 판정 + SIGTERM/SIGKILL), `:probe_liveness`(PF_INET 고정), `lib/server/server_bootstrap_http.ml:listen_socket`(host 파싱 실패 시 V4 loopback), `lib/shutdown.ml:28`(`force_timeout_s = 10.0`), `lib/owner_process_identity/owner_process_identity.mli`(F_GETLK, SIGTERM 한 번, SIGKILL 없음).
- 리터럴 개수(main d0e1263562 에서 `rg`): `scripts/` 42개 파일 56줄, docs 217개 파일, `dashboard/src/config/constants.ts:7`, `lib/config/masc_network_defaults.ml:58`. 스크립트 env 이름 6종(MASC_PORT, MASC_HTTP_PORT, PORT, MCP_URL, MASC_MCP_URL, MASC_DASHBOARD_PROXY_TARGET).
- 관련: #35133(2026-09-11T11:58Z 머지), #35241(14:42Z 머지), 이슈 #35270, RFC-0052, 결정 memo `masc-runtime-decisions-2026-09-12`.
