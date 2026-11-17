---
rfc: "keeper-row-facts-are-kept-in-memory-by-their-writers"
title: "Keeper 행이 보여 주는 사실은 쓰는 곳이 메모리에도 고치고, 읽는 쪽은 파일을 열지 않는다"
status: Draft
created: 2026-11-17
updated: 2026-11-17
author: vincent + claude
related: ["0477", "0474", "0204", "http-transport-runs-on-its-own-domain-and-each-route-names-where-it-runs"]
---

# RFC — Keeper 행이 보여 주는 사실은 쓰는 곳이 메모리에도 고친다

## 0. 요약

주기 루프 셋이 Keeper 31개의 행을 1~2분마다 따로 다시 만든다. 행 하나를 만들 때마다 meta 파일과 Keeper 기록 다섯 묶음의 끝을 다시 읽고, 날짜 파일을 목록으로 훑고 stat 한다. 2026-11-17 22:22~22:56(34분)에 300 ms 를 넘긴 Keeper 행이 867개 쌓였다. 근거는 연구 노트 [2026-11-17-read-path-inventory](../research/2026-11-17-read-path-inventory.md)(PR #52888)에 있다.

이 RFC 는 규칙 하나를 세운다.

> 화면이 보는 Keeper 사실은 그 사실을 쓰는 함수가 메모리 값도 고친다. 읽는 쪽은 메모리 값만 읽고 파일을 열지 않는다.

결정은 다섯 가지다.

1. 사실 다섯(결정 기록의 끝, 최근 도구 호출 6건, 최근 execution receipt, 최근 TurnRecord, 최근 metrics 120행)은 쓰는 함수가 메모리 값도 고친다. meta 는 이미 있는 Owner projection 을 읽는다(§3.1).
2. 파일 쓰기와 메모리 고치기는 Keeper·사실마다 잠금 하나 안에서 한다. 그래야 메모리 순서가 파일 순서와 같다(§3.3).
3. 비어 있는 값은 첫 읽기가 파일에서 한 번 채운다. 쓰는 쪽이 먼저 넣은 값은 덮지 않는다(§3.4).
4. 메모리 값은 디스크에 저장하지 않는 파생 값이다. 권위는 파일에 있다. 메모리 값은 그 순간 파일에서 다시 계산한 값과 같아야 하고, 차분 시험과 TLA+ 로 이를 지킨다(§5).
5. 다 옮기면 `read_policy` 의 Current/Reuse 구분, 10초 캐시 둘, Keeper 세마포어, `Tool_audit_cache` 를 지운다(§4 L4).

고치지 않는 것: `Systhread_host` 와 풀(다른 RFC), `schedules.json` 쓰기, 서버 밖에서도 고치는 profile TOML, Keeper 행을 SSE 로 나르는 일(RFC-0477 다음 층), serving domain.

## 1. 지금 상태 (origin/main `bf7d4b468b7a6`)

### 1.1 Keeper 행 하나가 읽는 것

`Operator_control_snapshot.keepers_json` 은 `snapshot_read` 한 곳에서만 불린다(`operator_control_snapshot.ml:710`). 행 하나는 이렇게 만든다.

| 묶음 | 읽는 것 | 어디서 | 이미 메모리에 있나 |
|---|---|---|---|
| meta | Keeper meta 파일 통째 | `Keeper_meta_store.read_meta` | 있다. Owner 가 커밋 뒤 `Atomic` 에 둔다(`keeper_owner.ml:936`). 행은 그 값을 안 읽는다 |
| phase·진단 | registry | `Keeper_registry.get_phase`, 행 하나에서 두 번 | 있다 |
| 승인 대기 | 승인 큐 | `keeper_approval_queue_rules.ml:35` 의 `Atomic` map, 행 하나에서 두 번 | 있다 |
| trust | 결정 기록 끝 40 KB·20줄, 최근 도구 호출 6건, 최근 receipt, 승인 audit 최근 행 | `keeper_runtime_trust_snapshot.ml:686-713`, `:896` | 없다 |
| tool audit | metrics 최근 120행과 최근 tool audit | `operator_control_snapshot_tool_audit.ml:14-38` | 일부. `Tool_audit_cache` 가 있지만 읽을 때마다 날짜 파일을 모두 stat 한다(`keeper_status_metrics.ml:240-275`, `dated_jsonl.ml:1600-1609`) |
| 최근 활동 | metrics 최근 5행 | `operator_control_snapshot.ml:428` | 없다 |
| context | 최근 TurnRecord 1행 | `keeper_context_observation_projection.ml:85` | 없다 |
| blocker | registry 와 최근 receipt | `Keeper_status_bridge.runtime_blocker_fields_json` | receipt 는 없다. 행 하나에서 receipt 를 세 번까지 읽는다 |

응답마다 더하는 관측도 있다. `with_current_keeper_observations` 는 응답 하나에 candle ledger 를 한 번 읽고, Keeper 마다 meta 파일을 한 번 더 읽는다(board address, `dashboard_projection_cache.ml:113-135`, `keeper_board_address.ml:14-24`). health-line, execution, briefing 응답이 모두 이 길을 지난다.

### 1.2 누가 행을 만드나

| 부르는 곳 | 읽기 방식 | 무엇이 부르나 |
|---|---|---|
| operator snapshot 루프 | Current | `MASC_OPERATOR_REFRESH_INTERVAL_S`(기본 60초, `server_dashboard_http_core_snapshot_refresh.ml:55`) |
| execution 루프 | Current | 60초(`server_dashboard_http_execution_surfaces.ml:1576`). `GET /api/v1/dashboard/execution` 도 |
| mission 루프 | Current | 120초(`server_dashboard_http_core_mission.ml:80`). `GET /api/v1/dashboard/briefing` 도 |
| MCP 도구 `masc_operator_snapshot` | Reuse | 도구 호출 |
| `GET /api/v1/dashboard/briefing/sections` | Reuse | 요청 |

세 루프는 보는 사람이 없어도 돈다. 바뀐 것이 와도 직전 변경 읽기에서 간격이 지나야 다시 읽는다(`proactive_refresh.mli:37-41`). 그래서 Keeper 가 바쁘면 루프마다 간격에 한 번 돈다.

Current 는 10초 캐시(trust `operator_control_snapshot_trust.ml:5`, audit `operator_control_snapshot_tool_audit.ml:157`)를 일부러 건너뛴다. 10초 안에 들어온 커밋도 봐야 해서다(`operator_control_snapshot_tool_audit.ml:155-156`). 세 루프와 요청은 16칸짜리 세마포어 하나를 나눠 쓴다(`operator_control_snapshot.ml:41`).

### 1.3 이미 있는 두 모양

메모리 값을 쓰는 곳에서 고치는 모양:

| 무엇 | 쓰는 곳 | 읽는 곳 |
|---|---|---|
| Owner meta projection | 커밋 뒤 `Atomic.set`(`keeper_owner.ml:936`) | `Keeper_owner_projection.lookup`. `/keepers/turns` 가 이미 쓴다(`server_keeper_waiting_inventory.ml:1273`) |
| `Keeper_turn_pulse` | 기동 때 결정 기록으로 채우고(`server_bootstrap_maintenance.ml:741`), 턴이 끝나면 `record`(`keeper_heartbeat_loop_cycle.ml:121`) | `get`(`keeper_tool_surface_ops.ml:438`) |
| 승인 큐 | 바꾸는 함수가 저장 잠금 안에서 `Atomic` map 을 바꾼다(`keeper_approval_queue_rules.ml:35`) | 메모리만 읽는다 |

읽을 때 바뀐 만큼만 다시 읽는 모양:

| 무엇 | 읽을 때마다 하는 일 |
|---|---|
| `Dated_jsonl.count_entries` | 날짜 파일을 모두 목록으로 얻고 stat 한다. 늘어난 바이트만 읽는다 |
| `Tool_audit_cache` | 위 행 수를 세고, 늘어난 행만 읽는다 |
| 승인 audit `Audit_recent_index`(RFC-0474 L4f) | 지난 읽기 뒤 바뀐 만큼 먼저 따라간다 |
| `File_version_cache`(`schedules.json`) | stat 한 번. 쓰는 쪽이 해석본을 남긴다(`schedule_store.ml:575`) |

두 번째 모양은 서버 밖에서 고친 파일도 본다. 그 대신 읽을 때마다 목록과 stat 이 남는다. `dated_jsonl.ml:1605-1608` 은 TTL 캐시를 지운 이유를 "바깥 쓰기를 숨긴다"고 적었다.

### 1.4 쓰는 곳

| 사실 | 쓰는 함수 | 부르는 곳 | 서버 밖에서 쓰나 |
|---|---|---|---|
| 결정 기록 | `Keeper_types_support.append_decision_record`(`keeper_types_support.ml:292`). 크기가 차면 `.1` 로 돌린다(`:250`) | 4곳 | 없다 |
| 도구 호출 기록 | `Keeper_tool_call_log.log_call` → `Dated_jsonl.append_rotating`(`keeper_tool_call_log.ml:639`) | `mcp_server_eio_call_tool.ml:459` | 없다 |
| execution receipt | `Keeper_execution_receipt.append` → `Dated_jsonl.append`(`keeper_execution_receipt.ml:554`) | 2곳 | 없다 |
| TurnRecord | `Keeper_turn_record_writer.write` → `Dated_jsonl.append`(`keeper_turn_record_writer.ml:71`) | 1곳 | 없다 |
| metrics | `Keeper_types_support.append_keeper_metrics`(`keeper_types_support.ml:48`) | 2곳 | 없다 |
| meta | Owner 커밋이 메모리의 meta 를 통째로 쓴다(`keeper_meta_store.ml:726-729`) | Owner 하나 | `scripts/migrate-keeper-meta-sandbox.sh` 가 파일을 바꾼다 |
| profile TOML | 여러 곳 | — | `masc init`, `masc setup`, 운영자 편집 |

다섯 사실은 쓰는 함수가 하나씩이고 모두 서버 안에서 돈다. 지우는 일도 서버 안이다. 날짜 파일은 `prune_shared_jsonl_stores` 가 지우고(`server_runtime_startup_maintenance.ml:73`), 대시보드 purge 가 Keeper 저장소를 지운다(`server_dashboard_http_delete_actions.ml:672`, `:805`).

### 1.5 측정

연구 노트 6절의 숫자다. 서버 로그는 Keeper 하나의 일이 300 ms 를 넘을 때만 남는다.

- 22:22~22:56: 300 ms 넘는 Keeper 행 867개, 35번 몰림, 몰림 하나에 중앙값 25행.
- 느린 행의 중앙값: trust 186 ms, audit 164 ms, meta 23 ms.
- 세마포어 대기: p90 4.5 s.
- TUI 1초 넘는 요청: `/keepers/turns` 16번(1,011~3,081 ms), `/gate/keepers` 3번.

## 2. 규칙에서 나오는 것

> 화면이 보는 Keeper 사실은 그 사실을 쓰는 함수가 메모리 값도 고친다. 읽는 쪽은 메모리 값만 읽고 파일을 열지 않는다.

1. 값 하나는 (base path, Keeper, 사실) 하나다. 사실은 닫힌 합타입이다. 모든 `match` 가 모든 사실을 적는다.
2. 쓰는 함수가 파일에 쓰고, 같은 잠금 안에서 메모리 값을 고친다(§3.3).
3. 쓰기가 실패했거나 됐는지 모르면 메모리 값을 지운다. 다음 읽기가 파일에서 다시 채운다.
4. 지우기(prune, purge)도 쓰기다. 지우는 함수가 메모리 값을 지운다.
5. 비어 있는 값은 첫 읽기가 파일에서 채운다. 쓰는 쪽이 이미 넣은 값은 덮지 않는다.
6. 메모리 값은 디스크에 저장하지 않는다. 권위는 파일이고, 메모리 값은 그 파일에서 다시 계산한 값과 같아야 한다.
7. 서버 밖에서도 고치는 파일(profile TOML)은 이 규칙에 넣지 않는다. 지금처럼 내용 키 캐시로 읽는다.

## 3. 설계

### 3.1 meta 는 Owner 를 읽는다

`keepers_json` 과 board address 는 meta 파일 대신 `Keeper_owner_projection.lookup` 을 읽는다. Owner 는 커밋할 때 메모리의 meta 를 파일에 통째로 쓰고, 쓰기가 성공했을 때만 메모리 값을 바꾼다(`keeper_owner.ml:916-936`). 그래서 둘은 같은 값이다. 쓰기가 실패하면 Owner 는 이전 값을 두고 metadata fault 를 남긴다. 새 상태는 없다.

`Owner_absent` 는 기본값으로 바꾸지 않는다. 지금 meta 를 못 읽을 때와 같이 그 이름을 `Keeper_unread` 로 낸다. 이유는 `Owner_absent` 로 적는다.

`migrate-keeper-meta-sandbox.sh` 는 서버를 멈추고 돌린다고 스크립트 머리에 적는다. 지금도 서버가 돌 때 파일을 고치면 Owner 의 다음 커밋이 덮는다.

### 3.2 새 모듈 `Keeper_row_facts`

모양 예시다. 행 타입 이름은 구현 때 정한다.

```ocaml
type fact = Decision_tail | Recent_tool_calls | Latest_receipt | Latest_turn_record | Recent_metrics

type view =
  { decision_tail : Decision_row.t list      (* 최근 20행 *)
  ; recent_tool_calls : Tool_call_row.t list (* 최근 6건 *)
  ; latest_receipt : Keeper_execution_receipt.t option
  ; latest_turn_record : Turn_record.t option
  ; recent_metrics : Metrics_row.t list      (* 최근 120행 *)
  }
```

- 저장은 `Keeper_turn_pulse` 와 같다. 불변 map 하나를 `Atomic` 에 두고, 고칠 때는 compare-and-set 으로 바꾼다.
- 값은 타입이 있는 행이다. JSON 을 들고 다니지 않는다. 행은 쓰는 쪽이 이미 들고 있는 값이라 다시 풀지 않는다.
- 행 수(20, 6, 1, 1, 120)는 지금 읽는 쪽이 쓰는 수다. 읽는 쪽 상수를 이 모듈로 옮기고, 두 곳에 두지 않는다.

### 3.3 순서: 쓰기와 고치기를 한 잠금 안에서

`Fs_compat.append_file` 은 systhread 로 넘길 뿐 경로 잠금이 없다(`fs_compat_owned_file.ml:9-18`). 쓰기 syscall 동안 domain 잠금이 풀리므로 두 쓰기가 엇갈릴 수 있다. 메모리 값을 잠금 밖에서 고치면, 파일의 마지막 줄은 B 인데 메모리는 A 를 가리킬 수 있다.

그래서 쓰는 함수는 (Keeper, 사실)마다 잠금 하나를 잡고 [돌리기 → 쓰기 → 메모리 고치기]를 한다. `Dated_jsonl` 에는 커밋 뒤 부르는 훅 `append_notifying_commit ~on_committed`(`dated_jsonl.ml:887`)가 이미 있다. 메모리 고치기는 그 훅에 둔다. 결정 기록은 `append_jsonl_line`(`keeper_types_support.ml:285`)이 같은 잠금을 잡는다.

잠금을 기다리는 쪽은 같은 Keeper 의 같은 사실을 쓰는 쪽뿐이다. 턴 하나에서 쓰는 횟수만큼이다.

### 3.4 채우기

- 값이 없으면 읽는 쪽이 지금의 파일 읽기로 채우고, 없을 때만 넣는다(`Keeper_turn_pulse.seed` 와 같다).
- 채우는 동안 쓰기가 끝나면 쓰는 쪽 값이 먼저 들어간다. 채우는 쪽은 넣지 않고 그 값을 쓴다.
- 기동 직후 첫 루프는 지금처럼 파일을 읽는다. 그 뒤로는 읽지 않는다.
- 같은 값을 두 루프가 동시에 채울 수 있다. 결과가 같으니 막지 않는다.

### 3.5 행과 루프에서 바뀌는 것

- trust, tool audit, 최근 활동, context, blocker 는 `Keeper_row_facts` 를 읽는다.
- 행 하나에서 registry, 승인 큐, receipt 를 한 번씩만 읽는다.
- `read_policy` 는 이 사실들에서 뜻이 없어진다. 메모리 값이 늘 새 값이라서다. Current/Reuse 구분, 10초 캐시 둘(`kta:*`, `operator:keeper-runtime-trust:compact:v1:*`), 세마포어 `_keeper_sem` 을 지운다.
- `dt_profile` 은 값이 들어가지 않는다(`operator_control_snapshot.ml:187`). 같이 지운다.

## 4. 층

층마다 부르는 길이 이어진 채로 들어간다. 부르는 곳이 없는 층은 만들지 않는다.

| 층 | 무엇 | 확인 |
|---|---|---|
| L1 | meta 를 Owner 에서 읽는다(§3.1). 새 상태 없음 | 같은 Keeper 에서 파일 meta 로 만든 행과 Owner meta 로 만든 행이 같다. 운영: 느린 행 로그의 `meta` 가 0 ms 다 |
| L2 | `Keeper_row_facts` 와 사실 넷(결정 기록 끝, 최근 도구 호출, 최근 receipt, 최근 TurnRecord). trust·context·blocker 가 이것을 읽는다 | 차분 시험, 동시 쓰기 시험, TLA+ 정상·버그 cfg(§5). 운영: trust 가 300 ms 넘는 행 0 |
| L3 | 최근 metrics 120행. tool audit 와 최근 활동이 이것을 읽는다. `keeper_metrics_store` 를 숨기고 쓰기 함수만 내보낸다 | 차분 시험. 운영: audit 가 300 ms 넘는 행 0 |
| L4 | 지우기: Current/Reuse 구분(이 사실들), 10초 캐시 둘, `_keeper_sem`, `Tool_audit_cache`, `dt_profile`, 행 안의 중복 읽기 | 같은 34분 창에서 300 ms 넘는 Keeper 행 0. 지운 이름을 `rg` 로 찾으면 0 |

L3 이 `keeper_metrics_store` 를 숨기는 까닭: 지금은 raw `Dated_jsonl.t` 를 돌려줘서, 새 코드가 쓰기 함수를 건너뛰고 바로 써도 타입이 막지 못한다. 쓰기 함수만 남기면 메모리를 건너뛰는 쓰기를 컴파일러가 막는다.

측정 뒤 정하는 것: 승인 audit 최근 행, 응답마다 읽는 candle ledger, `/keepers/turns` 의 event queue 읽기. L2·L3 뒤에도 느린 요청이 남으면 같은 규칙으로 다음 RFC 를 쓴다.

## 5. 검증

**차분 시험.** 사실마다 실제 쓰기 함수(`append_decision_record`, `log_call`, receipt `append`, TurnRecord `write`, `append_keeper_metrics`)와 돌리기, prune, purge 를 무작위 순서로 부른다. 한 걸음마다 메모리 값과 파일에서 다시 계산한 값이 같은지 본다. 시험마다 base path 를 새로 만들어서 `reset_for_tests` 를 쓰지 않는다.

**동시 쓰기 시험.** domain 둘에서 같은 Keeper 의 결정 기록에 N 줄씩 쓴다. 끝나면 메모리의 마지막 줄이 파일의 마지막 줄과 같다.

**TLA+.** `KeeperRowFacts.tla` 에 쓰는 쪽 둘과 채우는 쪽 하나를 둔다. 불변식은 "쓰는 중이 아니면 메모리 값은 파일 끝과 같다"이다. `Next` 는 잠금 안에서 고치고 불변식을 지킨다. `BugAction` 은 잠금을 푼 뒤 고친다. `NextBuggy == Next \/ BugAction` 은 불변식을 어겨야 spec 이 맞다. 정상 cfg 와 버그 cfg 를 둘 다 돌린다.

**운영 측정.** 재시작 뒤 같은 34분 창에서 센다.

| 무엇 | 지금 | 목표 |
|---|---|---|
| 300 ms 넘는 Keeper 행 | 867 | 0 |
| `/gate/keepers`·`/dashboard/health-line` 1초 넘는 TUI 요청 | 3·1(TUI 로그 `masc-tui-28494.log`) | 0 |
| 주기 루프 한 번이 여는 Keeper 파일 수 | Keeper 수에 비례 | 기동 직후 첫 번 말고 0 |

마지막 줄은 L2 에서 셀 방법을 정한다. 서버 로그 sub-op 가 0 이 되는 것만으로는 부족하다. 로그가 300 ms 아래를 안 찍기 때문이다.

## 6. 고르지 않은 길

1. **TTL 을 늘린다.** Current 는 10초 안의 커밋도 봐야 한다. TTL 은 그 커밋을 숨긴다.
2. **루프 셋을 하나로 합친다.** 일은 1/3 로 줄지만 행 하나가 여전히 파일을 읽는다. health-line·gate/keepers 요청 경로는 그대로다.
3. **보는 사람이 있을 때만 루프를 돌린다.** 볼 때 비용이 그대로 돌아오고, 요청이 루프를 기다린다.
4. **읽는 쪽 증분 캐시를 더 만든다.** 읽을 때마다 목록과 stat 이 남는다. 서버 밖에서 쓰는 파일에는 맞는 모양이다. 여기 다섯 사실은 쓰는 곳이 모두 서버 안의 함수 하나다.
5. **SQLite 로 옮긴다.** 저장소 모양을 바꾸는 하드컷이다. 읽기는 여전히 부른 domain 을 막는다.

## 7. 대가와 한계

- 메모리: Keeper 마다 최근 행 수십~120개를 든다.
- 쓰는 쪽이 조금 길어진다. (Keeper, 사실) 잠금을 잡고 메모리를 고친다.
- 재시작 직후 첫 루프는 지금처럼 파일을 읽는다.
- 서버 밖에서 다섯 사실의 파일을 고치면 메모리 값이 틀린다. 지금 그런 쓰는 곳은 없다(§1.4). 손으로 고치려면 서버를 멈춘다.
- 이 RFC 는 화면 경로 밖의 읽기를 줄이지 않는다. `Systhread_host` 를 지나는 읽기 299곳 가운데 화면 경로에서 빠지는 것만 줄어든다.

## 8. 정할 것

1. **승인 audit 최근 행을 이 스택에 넣을지.** 권장: L2·L3 를 잰 뒤 정한다. 이미 증분 색인(RFC-0474 L4f)이 있어서 남은 비용이 목록 읽기뿐일 수 있다.
2. **Keeper 행을 SSE 로 나르는 일.** 권장: RFC-0477 §3.6 의 다음 층으로 둔다. 이 RFC 는 값을 만들고, RFC-0477 이 나른다.
3. **이름 목록.** `keepers_json` 은 이름을 meta 파일 목록에서 얻는다. 권장: L1 에서는 그대로 두고 meta 값만 Owner 에서 읽는다. 이름 목록은 L4 뒤에 잰다.
