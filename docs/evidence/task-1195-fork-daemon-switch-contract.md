# task-1195 — 끝나지 않는 fiber 를 남의 switch 에 얹는 자리 판정 (#32111)

Eio 의 `Switch` 는 `Fiber.fork` 로 얹은 fiber 가 전부 끝나야 닫힌다. 끝나지 않는
루프를 얹으면 그 switch 를 `Switch.run` 으로 감싼 호출자가 영원히 반환하지 못한다.
각 자리의 switch 를 `Switch.run` 까지 거슬러 "누가 닫기를 기다리는가" 로 가른다.

## 판정 원칙

- **서버 수명 switch** (`bin/main_stdio_eio.ml` 의 `Switch.run`, 종료 시
  `main_eio.ml:817` 이 `Graceful_shutdown` 을 던져 switch 를 취소로 끝냄):
  아무도 닫기를 기다리지 않는다 → **그대로 둠 (fork 유지)**.
- **호출자가 닫기를 기다리는 switch** (`Switch.run` 을 감싸고 정상 반환):
  → **fork_daemon**.

실측 결과, 아래 12곳의 switch 는 전부 서버 수명 switch 로 수렴한다. 즉
**판정이 fork_daemon 인 자리는 없다.** 수정은 계약이 남는 자리의 `.mli` 에
"이 switch 는 취소로 끝내야 한다" 를 적는 것뿐이다.

## 12곳 표

| # | 위치 | switch 주인 (코드 위치) | 판정 |
|---|------|------------------------|------|
| 1 | `lib/rate_limit.ml:142` | 서버 수명 (`server_runtime_bootstrap.ml:1621` 체인 → `main_stdio_eio.ml` `Switch.run`) | 그대로 둠 |
| 2 | `lib/gc_sampler.ml:21` | 서버 수명 (`server_bootstrap_maintenance.ml:558` 체인) | 그대로 둠 |
| 3 | `lib/server/server_imessage_in_process_gateway.ml:267` | 서버 수명 (`server_runtime_bootstrap.ml:1630`) | 그대로 둠 |
| 4 | `lib/gate/discord_gateway_client.ml:195` | 서버 수명 (`server_discord_in_process_gateway.ml:817` → `server_runtime_bootstrap.ml:1621`) | 그대로 둠 |
| 5 | `lib/keeper/keeper_event_bridge.ml:676` | 서버 수명 (`server_bootstrap_maintenance.ml` 체인) | 그대로 둠 |
| 6 | `lib/keeper/keeper_telemetry_consumer.ml:35` | 서버 수명 (`server_bootstrap_maintenance.ml` 체인) | 그대로 둠 |
| 7 | `lib/session.ml:660` (`McpSessionStore.start_loop`) | 서버 수명 (`server_bootstrap_loops.ml:1672` → `start_mcp_session_cleanup_loop`) | 그대로 둠 |
| 8 | `lib/session.ml:728` (`start_mcp_session_cleanup_loop`) | 서버 수명 (`server_bootstrap_loops.ml:1672`) | 그대로 둠 |
| 9 | `lib/session.ml:378` (`Session.start_loop registry`) | 서버 수명 — **이미 `fork_daemon` 사용** | 그대로 둠 (이미 올바름) |
| 10 | `lib/server/host_fd_pressure_poller.ml:160` | 서버 수명 (`server_bootstrap_maintenance.ml:558`) | 그대로 둠 |
| 11 | `lib/otel_spans/otel_spans.ml:227` (recovery_loop) | 서버 수명 (`server_bootstrap_maintenance.ml:721` → `setup_exporter ~sw`) | 그대로 둠 |
| 12 | `lib/otel_spans/otel_spans.ml:246` (supervisor_loop) | 서버 수명 (동일 체인) | 그대로 둠 |

## fork 를 유지하는 이유 (한 줄)

모든 자리의 switch 는 서버 수명 switch 로 수렴하고, 서버 종료는
`main_eio.ml:817` 의 `Graceful_shutdown` 이 switch 를 취소로 끝내므로 아무도
닫기를 기다리지 않는다. `fork_daemon` 으로 바꾸면 오히려 서버 종료 시 이 fiber 가
switch 밖으로 새어 정리되지 않는다. 따라서 fork 를 유지하고, 계약을 `.mli` 에
적는다.

## .mli 계약 추가 (4개)

계약이 남는 자리(7개 .mli 노출 모듈 중 계약이 없던 4개)에 "이 switch 는 취소로
끝내야 한다" 를 적었다.

- `lib/rate_limit.mli` — `start_global_cleanup_loop`
- `lib/gate/discord_gateway_client.mli` — `run`
- `lib/keeper/keeper_telemetry_consumer.mli` — `spawn_subscriber`
- `lib/keeper/keeper_event_bridge.mli` — `start`

이미 계약이 있던 3개(`gc_sampler`, `server_imessage_in_process_gateway`,
`session`)는 그대로 둔다.

## 그대로 두기로 한 자리의 switch 소유자 (코드 위치)

- 서버 수명 switch: `bin/main_stdio_eio.ml` 의 `Switch.run` (종료는
  `main_eio.ml:817` `Graceful_shutdown`).
- 각 자리의 fork 가 이 switch 로 수렴하는 경로:
  - `server_runtime_bootstrap.ml:1621` (discord), `:1630` (imessage)
  - `server_bootstrap_maintenance.ml:558` (host_fd_pressure_poller),
    `:721` (otel_spans `setup_exporter ~sw`)
  - `server_bootstrap_loops.ml:1672` (session cleanup loop)
