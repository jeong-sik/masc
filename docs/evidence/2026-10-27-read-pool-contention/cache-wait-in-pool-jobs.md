# 풀 job 안에서 캐시를 기다리는 곳 (RFC-0204 L4b)

2026-10-27, `feat/rfc-0204-cache-lane` `1f6cfa2df42` 소스를 읽어 정리했다. 빌드나 실행으로 확인하지 않았다.

## 왜 문제인가

- 풀 job 무게는 1.0 이다(`Executor_pool_ref.submit_or_inline` 기본값). job 이 쉬는 동안에도 그 worker 는 다른 job 을 받지 않는다.
- `Dashboard_cache` 는 키가 없고 다른 fiber 가 계산 중이면(`Computing { stale = None }`) 0.25초마다 확인하며 기다린다(`Wait`).
- 이 기다림이 풀 job 안에서 일어나면 worker 하나가 쉰다. L3 읽기 풀은 1~2 domain 이라 둘이면 읽기가 다 멈춘다.
- 더 나쁜 경우: 그 키를 계산하는 쪽(owner)이 요청 fiber 이고, 계산을 `offloaded_value` 로 같은 풀에 넣었다. 그 계산은 기다리는 job 뒤에 줄을 선다. 기다리는 job 은 계산이 끝나야 비키고, 계산은 job 이 비켜야 시작한다. 기다림 timeout 까지 풀린다.

## 풀 job 으로 들어가는 길

- `run_dashboard_compute`(`Offloaded_readonly`): compute 전체가 job 이다.
- `Dashboard_cache.offloaded_value`: 캐시 계산 하나가 job 이다. 그 계산 안의 다른 캐시 조회는 job 안에서 일어난다.
- 풀 안에서 부른 `_or_inline` 제출은 그 자리에서 실행되므로, 중첩 조회와 그 계산은 같은 worker 에 남는다.

## `run_dashboard_compute` 호출 11곳

| 곳 | 부르는 쪽 | job 안에서 닿는 캐시 조회 |
|---|---|---|
| `server_dashboard_http_core.ml:94` | mission 갱신 루프 | P1, P2, OPS |
| `server_dashboard_http_core.ml:140` | GET briefing | P1, P2, OPS |
| `server_routes_http_routes_channel_gate.ml:447` | GET gate/keepers | 없음 |
| `server_dashboard_http_execution_surfaces.ml:1341` | execution 갱신 루프 | P1, OPS |
| `server_dashboard_http_execution_surfaces.ml:1535` | execution_trust 루프·GET | 없음 |
| `server_dashboard_http_execution_surfaces.ml:1602` | GET execution | P1, OPS |
| `server_dashboard_http_core_operator_snapshot_http.ml:59` | GET operator | OPS |
| `server_dashboard_http_core_operator_snapshot_http.ml:162` | GET operator(인자) | OPS |
| `server_dashboard_http_core_operator_digest_http.ml:125` | GET operator digest | 없음 |
| `server_dashboard_http_core_digest_refresh.ml:49` | digest 루프 | 없음 |
| `server_dashboard_http_core_snapshot_refresh.ml:41` | operator snapshot 루프 | OPS |

- P1 `dashboard_projection_cache.ml:232` 키 `snapshot:<masc_dir>:<actor>`, P2 `:263` 키 `digest:<masc_dir>:<actor>`.
- OPS = `Operator_control_snapshot_cache.get_or_compute` → `compute_snapshot` → 키 셋: `operator_control_snapshot.ml:662` board quarantines, `operator_control_snapshot_trust.ml:71` Keeper 마다 하나(`Fiber.all` 안), `operator_control_snapshot_tool_audit.ml:41` Keeper 마다 하나.

## 캐시 계산 안의 캐시 조회 (중첩)

- `respond_cached_read`(`server_routes_http_common.ml:249`) 의 briefing 키 → `briefing:default` 또는 `mission:<masc_dir>:<actor>` → P1/P2 → OPS. 4단까지.
- `mission_briefing` 질의 키 → `mission_briefing:<masc_dir>:<actor>`(`core.ml:215`) → `Dashboard_briefing.json` → P1/P2 → OPS.
- workspace GET(`server_routes_http_dashboard_handlers.ml:130`) → `dashboard.workspace:…`(`dashboard_workspace.ml:233`).
- `execution:default:light`(`execution_surfaces.ml:862`), `execution:parameterized:…`(`:1749`) → P1 → OPS.

## 기다림이 생기기 쉬운 때

1. `invalidate_snapshot_json`(`dashboard_projection_cache.ml:240`) 뒤. Keeper 생명주기 POST 와 operator 동작이 부른다. `snapshot:<masc_dir>:dashboard` 가 사라지고, 위 표의 job 들이 operator snapshot 을 다시 만드는 job 하나를 기다린다.
2. 부팅 직후. 서로 다른 OPS 키가 동시에 계산되며 Keeper 마다의 키를 같이 쓴다.
3. 같은 키를 HTTP/2 는 요청 fiber 에서, HTTP/1 은 job 안에서 조회한다: `mission:…`(h2 `server_h2_gateway.ml:1314`), `mission_briefing:…`(h2 `:1321`, h1 `routes_dashboard.ml:3398`), `dashboard.workspace:…`(h2 `:1046`, h1 `handlers.ml:130`). 요청 fiber 가 owner 면 계산이 풀에 줄을 서고, job 안의 h1 조회가 그 뒤를 막는다(위 "더 나쁜 경우").

## `Operator_control_snapshot_cache`

자기 0.25초 기다림 루프가 있다(`operator_control_snapshot_cache.ml:307`). 그러나 owner 가 계산을 풀에 넘기지 않고 자기 fiber 에서 바로 한다(`run_compute_inline`). 기다리는 job 은 이미 도는 계산을 기다리므로 순서가 꼬여 멈추지는 않는다. worker 를 쉬게 쥐는 시간은 그 계산 시간을 넘지 않는다.

## 확인하지 못한 것

- `dashboard_briefing_sections.ml:205` 비동기 갱신이 무엇에 닿는지.
- `compute_full_health_snapshot` 안쪽.
- `routes_dashboard.ml:3388`(sections force), `provider_runs.ml:109`, `routes_http_runtime.ml:1423` 는 얕게만 봤다.
