---
rfc: "health-rollup-folds-what-the-response-serves"
title: "/health 롤업은 응답에 실린 구역을 한 번 접는다"
status: Draft
created: 2026-11-27
updated: 2026-11-27
author: claude
supersedes: []
superseded_by: null
related: ["0484"]
---

# RFC health-rollup-folds-what-the-response-serves: /health 롤업은 응답에 실린 구역을 한 번 접는다

- 이슈: #34893
- 코드 좌표는 `origin/main` `b3c9e636a37b8` 에서 읽었다.
- 운영자 결정(2026-11-27): 코드보다 이 RFC 를 먼저 쓴다.
- 이 문서는 설계만 담는다. 코드는 §6 의 층에서 쓴다.

용어는 셋이다.

- 구역(section): `/health` 본문의 최상위 키 하나와 그 값.
- 등급(grade): `Health_status.t` 값. `overall_status` 가 이 값의 최댓값이다.
- probe 계산과 snapshot 계산: 요청마다 새로 하는 계산과 배경 워커가 해 둔 계산.

## 0. 요약

`/health?full=1` 은 두 계산을 합쳐 답한다.
롤업은 그중 snapshot 계산 안에서만 돈다.
그래서 probe 계산에만 있는 `schedule_runner` 는 등급이 있어도 롤업에 닿지 않는다.
`internal_mcp_auth` 는 운영자 조치를 요구해도 `overall_status` 를 움직이지 못한다.
`runtime_startup_degradation` 은 두 번 계산된다.
롤업이 판정한 값과 응답이 싣는 값이 다를 수 있다.

결정은 다섯이다.

1. 롤업은 응답이 싣는 구역 목록을 접는다. 두 계산은 `section list` 를 돌려준다. 구역마다 `Graded` 나 `Ungraded` 를 고르지 않으면 컴파일되지 않는다. 롤업 안의 이름 목록은 지운다.
2. 등급 구역은 지금 목록의 등급 구역에 `internal_mcp_auth` 와 `schedule_runner` 를 더한 것이다. `dashboard_surface` 는 서비스 등급과 출처 판정을 나눌 때까지 `Ungraded` 다.
3. 첫 snapshot 전에도 probe 구역은 접는다. `overall_status` 는 `warming` 보다 낫게 나오지 않는다.
4. 등급 구역은 한 계산에서만 만든다. `runtime_startup_degradation` 은 probe 계산이 한 번 만든다.
5. 일반 `/health` 의 운영자 필드도 같은 fold 로 채운다. snapshot 에서 복사하지 않는다.

## 1. 지금

### 1.1 두 계산과 롤업의 자리

- probe 계산은 `make_health_probe_fields` 다(`lib/server/server_routes_http_runtime.ml:278-328`).
- snapshot 계산은 `make_health_fields` 다(`:388-708`). 구역 목록은 `:596-683` 이다.
- 롤업은 snapshot 계산 끝에서 돈다(`:685-694`). 결과 다섯 필드를 구역 뒤에 붙인다(`:696-708`).
- `?full=1` 은 probe 구역 뒤에 snapshot 구역을 붙인다(`:1706-1720`).
- 이때 probe 가 이미 가진 키는 snapshot 쪽에서 뺀다(`:1712-1713`). 그래서 본문의 키는 겹치지 않는다.
- 롤업이 읽는 구역은 이름 목록 30개가 정한다(`lib/server/server_health_rollup.ml:18-50`).
- 목록 안의 구역도 `status` 문자열을 `Health_status.of_string_opt` 로 읽어서 접는다(`server_health_rollup.ml:97-159`).

### 1.2 구역 넷의 자리

| 구역 | probe 계산 | snapshot 계산 | 본문이 싣는 값 | 롤업 |
|---|---|---|---|---|
| `internal_mcp_auth` | `:307-309` | `:608-609` | probe | 안 읽음(목록 밖) |
| `schedule_runner` | `:314` | 없음 | probe | 못 읽음(값이 없음) |
| `runtime_startup_degradation` | `:315-319` | `:576-580`, `:617` | probe | snapshot 값을 따로 읽음(`server_health_rollup.ml:165`) |
| `dashboard_surface` | `:320-322` | `:618` | probe | 안 읽음(목록 밖) |

- `server_health_rollup.mli:84-87` 은 세 구역이 probe 에만 있다고 적는다. #54022 뒤로 `internal_mcp_auth` 와 `dashboard_surface` 는 snapshot 에도 있다. 그 문장은 틀렸다.
- `runtime_startup_degradation` 은 두 번 계산된다. 롤업은 snapshot 값을 보고, 본문은 probe 값을 싣는다. `server_health_rollup.mli:79-82` 가 이 불일치를 적어 두었다.

### 1.3 운영자가 못 보는 경보

- `internal_mcp_auth` 는 토큰과 해시가 맞지 않으면 `status=degraded` 다(`server_routes_http_runtime.ml:202`).
- 그때 `operator_action_required=true` 와 다음 조치 `sync_internal_keeper_token_and_restart_runtime` 를 싣는다(`:203-205`, `:216-217`).
- 롤업은 이 구역을 읽지 않는다. 그래서 `overall_status` 는 `ok` 로 남을 수 있다.
- TUI 와 대시보드 코드에는 이 구역을 읽는 곳이 없다. `rg -l internal_mcp_auth dashboard/src lib/masc_tui bin` 이 0건이다. 운영자는 날것 JSON 에서만 이 경보를 본다.

### 1.4 `dashboard_surface` 의 `unknown`

- 이 구역의 `status` 는 다섯 단어 중 하나다. `unavailable`, `missing`, `unknown`, `mismatched`, `ok` 다(`lib/web_dashboard.ml:507-546`).
- `unknown` 은 빌드 출처를 모른다는 뜻이다(`Unknown_identity`, `web_dashboard.ml:509`). 이때도 `index.html` 은 서비스된다(`index_present`, `:498`).
- `Health_status.of_string_opt` 는 `"unknown"` 을 `Unknown` 으로 읽는다(`lib/types/health_status.ml:57`). 롤업은 `Unknown` 이면 운영자 조치를 연다(`server_health_rollup.ml:130-133`).
- 이 구역을 문자열 그대로 접으면 빌드 출처가 없는 설치는 늘 degraded 가 된다.
- 대시보드는 이 구역을 이미 자기 띠로 보여 준다(`dashboard/src/components/bundle-stale-banner.ts:25-45`).

### 1.5 일반 `/health` 의 운영자 필드

- RFC-0484 §3.3 이 일반 `/health` 에 운영자 필드를 싣게 했다.
- 지금 그 값은 마지막 snapshot 의 롤업을 복사한 것이다(`server_routes_http_runtime.ml:1863-1874`). 필드는 넷이다(`server_health_rollup.ml:12-14`).
- 첫 snapshot 전에는 아무 필드도 싣지 않는다(`:1866`).
- 이 값을 읽던 TUI 꼬리말(#48186)은 #54402 에서 옛 TUI 와 함께 지워졌다. 지금 `lib`, `bin`, `dashboard/src` 에 읽는 곳이 없다.

## 2. 결정

### D1. 롤업의 입력은 응답이 싣는 구역 목록이다

`Server_health_rollup` 에 구역 타입을 둔다.

```ocaml
type graded =
  { grade : Health_status.t
  ; status_reasons : string list
  ; operator_actions : Operator_action_reason.t list
      (* 답이 필요한 것만. 비면 운영자 조치가 없다. *)
  }

type kind =
  | Graded of graded option
      (* 등급을 말하는 구역. None 은 이번 관측에 등급이 없다는 뜻이다. *)
  | Ungraded
      (* 상태 이름, 수치, 출처 판정. 롤업이 읽지 않는다. *)

type section = { name : string; json : Yojson.Safe.t; kind : kind }

type absence = Warming | Refresh_raised | Refresh_timed_out

type snapshot_view =
  | Observed of section list
  | Not_observed of absence

val fold : probe:section list -> snapshot:snapshot_view -> t
```

- probe 계산과 snapshot 계산은 `section list` 를 돌려준다. 지금은 `(string * Yojson.Safe.t) list` 다.
- 본문은 합친 목록의 `name` 과 `json` 을 그대로 싣는다. 롤업은 같은 목록을 접는다. 둘째 목록은 없다.
- 합치는 규칙은 지금과 같다. snapshot 쪽에서 probe 가 가진 이름을 뺀다(`server_routes_http_runtime.ml:1712-1713`).
- 그래서 이름마다 값은 하나다. 롤업이 읽는 값과 본문이 싣는 값이 같다.
- `fold` 의 규칙은 지금 규칙을 옮긴 것이다.
  - `overall_status` 는 `Graded (Some g)` 의 `g.grade` 최댓값이다. 시작 값은 `Ok` 다.
  - 0 보다 높은 등급은 `overall_status_reasons` 에 줄을 남긴다(#34895).
  - `operator_actions` 는 구역 순서대로 잇는다. 비지 않으면 `operator_action_required=true` 다.
- `status` 문자열을 읽는 곳은 경계 decoder `graded_of_json` 하나다. 지금 `note_status` 의 규칙을 그대로 쓴다(`server_health_rollup.ml:97-159`). 어휘는 `of_string_opt`, 조치 문턱은 rank 3 이상·`Unknown`·선언된 조치다.
- decoder 는 구역을 만들 때 한 번 돈다. `fold` 는 문자열을 읽지 않는다.

새 등급 구역이 조용히 빠지지 않는 까닭은 셋이다.

- 두 계산의 반환 타입이 `section list` 다. 본문에 키를 넣으려면 `section` 을 만들어야 한다. `kind` 는 필수 필드다. 빠지면 "Some record fields are undefined" 로 컴파일이 멈춘다.
- 롤업은 본문이 싣는 목록을 읽는다. 이름을 따로 적는 곳이 없다. `Graded` 로 만든 구역은 어디에 있든 접힌다.
- `fold` 는 `kind`, `snapshot_view`, `absence` 의 생성자를 모두 적는다. `dune:57-65` 는 경고 4를 켜고 모든 경고를 오류로 만든다. `_ ->` 는 컴파일되지 않는다. 생성자를 더하면 빠진 갈래에서 빌드가 멈춘다.

남는 위험도 적는다.
등급이 있는 구역을 `Ungraded` 로 만드는 것은 사람의 판단이다.
타입은 이 판단을 막지 못한다.
다만 그 판단은 구역을 만드는 줄에 보인다. 지금처럼 다른 파일의 목록을 잊는 일과 다르다.
합친 뒤에 붙는 키는 `full_health_snapshot` 메타데이터와 fold 결과뿐이다(`:1714-1720`).
이 자리에 구역을 날것으로 붙이는 길도 타입이 막지 못한다. 리뷰가 본다.

### D2. 등급 구역

| 구역 | kind | 등급을 만드는 곳 |
|---|---|---|
| 지금 목록(`server_health_rollup.ml:18-50`)에서 `status` 객체를 내는 구역 | `Graded` | `graded_of_json`, 지금 규칙 그대로 |
| 같은 목록의 수치·목록 키(`keeper_fibers`, `keeper_config_*` 목록과 수) | `Ungraded` | 없음. 지금도 `status` 가 없어 건너뛴다 |
| `keeper_config_schema_status` | `Graded` | `blocking` 값. `Blocked` 와 조치 하나, 또는 `Ok` |
| `internal_mcp_auth` | `Graded` | `ready` 값. 아래 참조 |
| `schedule_runner` | `Graded` | `Schedule_contract_values.runner_status`. 아래 참조 |
| `runtime_startup_degradation` | `Graded` | `graded_of_json`. producer 가 이미 `status_reasons`·`operator_action_reasons` 를 낸다(`lib/runtime/runtime.mli:326-334`) |
| `dashboard_surface` | `Ungraded` | 출처와 서비스를 나눌 때까지 |
| 그 밖(`http_listener`, `https_listener`, `logs`, `otel`, `librarian`, `subsystems`, `server_hibernation` 등) | `Ungraded` | 지금과 같다 |

`internal_mcp_auth` 는 typed 값에서 바로 등급을 만든다.

- `ready=true` 면 `Ok` 다.
- `ready=false` 면 `Degraded` 다. `status_reasons` 는 `missing` 목록이다. 조치는 `Operator_action_reason.other ~component:"internal_mcp_auth" ~reason:"sync_internal_keeper_token_and_restart_runtime"` 하나다.
- 정상 기동한 서버는 시작할 때 토큰을 맞춘다(`lib/server/server_runtime_startup_credentials.ml:34`). 그래서 이 구역의 degraded 는 운영 중에 생긴 어긋남이다.

`schedule_runner` 도 typed 값에서 만든다(`lib/schedule/schedule_contract_values.mli:132-139`).

- `Runner_ok` → `Ok`, `Runner_degraded` → `Degraded`, `Runner_stale` → `Stale`.
- `Runner_running`, `Runner_not_started` → `Graded None`. 지금 `of_string_opt` 가 두 단어를 건너뛰는 것과 같다.
- 조치는 없다. `Degraded` 와 `Stale` 은 rank 2 라 지금 규칙에서도 조치를 열지 않는다(`health_status.ml:86-96`).

`keeper_config_schema` 는 지금 `operator_summary` 의 인자 넷이다(`server_health_rollup.ml:166-177`).
이 RFC 는 그 넷을 `keeper_config_schema_status` 구역 하나의 등급으로 바꾼다.
그러면 `fold` 는 구역 목록만 받는다.
줄 이름은 구역 이름을 따라 `keeper_config_schema_status:blocked` 가 된다. 지금은 `keeper_config_schema:blocked` 다(`server_health_rollup.ml:170`).

`dashboard_surface` 를 나누는 모양은 이렇다. 이 RFC 의 층에는 넣지 않는다.

- producer 가 닫힌 합 두 개를 따로 낸다.
- 서비스: `Served | Index_missing | Assets_unavailable`. `index_present`, 바인딩 검사, 설치본 검증에서 나온다(`web_dashboard.ml:498-546`).
- 출처: 지금의 `bundle_freshness`(`Fresh | Mismatched | Unknown_identity`, `lib/web_dashboard.mli:13-16`).
- 서비스만 등급이 된다. `Served` → `Ok`, 나머지 둘 → `Unavailable`.
- 출처는 어떤 등급도 만들지 않는다. `Unknown_identity` 가 degraded 로 접히는 길이 없다.
- wire 의 `status` 는 그대로 둔다. 대시보드 띠가 그 단어를 읽는다.

### D3. warming

- 첫 snapshot 전에는 `snapshot_view = Not_observed Warming` 이다.
- `fold` 는 이때 이름이 `full_health_snapshot` 인 등급 하나를 더한다. 등급은 `Warming` 이고 조치는 없다.
- probe 구역은 그대로 접힌다. `overall_status` 는 `Warming` 과 probe 등급의 최댓값이다.
- `Warming` 은 rank 1, `Degraded` 는 rank 2 다(`health_status.ml:86-90`). 기동 중에 토큰이 어긋나면 `degraded` 와 조치 한 줄이 바로 보인다.

지금 warming 계약에서 지키는 것과 바꾸는 것을 나눈다.

- 지킨다: snapshot 이 맡은 구역은 지금 자리 채움 JSON 을 싣는다(`server_routes_http_runtime.ml:783-946`). `overall_status` 는 `warming` 보다 낫게 나오지 않는다. 준비 여부의 권위는 `full_health_snapshot.status` 다(`:1486-1497`).
- 바꾼다: 자리 채움은 `operator_action_required=false` 와 빈 이유를 박아 둔다(`:786-790`). 같은 본문의 probe 구역은 `operator_action_required=true` 를 실을 수 있다(`:216`). 한 본문이 스스로 어긋난다. 이 부분이 틀렸다. 앞으로는 probe 구역의 조치가 그대로 올라온다.
- 더해진다: `overall_status_reasons` 에 `full_health_snapshot:warming` 한 줄이 생긴다. 0 보다 높은 등급은 줄을 남긴다는 #34895 규칙 그대로다.

실패한 snapshot 도 같은 길이다.

- 좋은 값 없이 실패하면 `Not_observed Refresh_raised` 나 `Not_observed Refresh_timed_out` 이다(`:995`, `:1822-1824`). 등급은 `Error` 나 `Timeout` 이다. 조치는 없다. 지금 자리 채움과 같다(`:787`).
- 실패했어도 좋은 값이 남아 있으면 `Observed` 다. 그 값이 오래됐다는 사실은 `full_health_snapshot.status=stale` 이 말한다. 롤업에는 접지 않는다. 지금과 같다(§8-3).

### D4. 등급 구역은 한 계산에서만 만든다

- probe 계산이 맡는 구역: `internal_mcp_auth`, `schedule_runner`, `runtime_startup_degradation`, `dashboard_surface`, `auxiliary_startup`, `tla_source_observation`.
- snapshot 계산은 이 여섯을 만들지 않는다. `:576-580` 과 목록의 `:608-609`, `:617-618`, `:620-621` 을 지운다.
- `runtime_startup_degradation` 은 요청마다 한 번 계산된다. 롤업과 본문이 그 한 값을 쓴다.
- `auxiliary_startup` 과 `tla_source_observation` 은 지금 일반 `/health` 에만 덧붙는다(`:335-337`). `?full=1` 은 snapshot 값을 싣는다. 이 RFC 는 둘을 probe 계산에 넣어 두 본문 모두에 싣는다.
- 둘 다 메모리 값을 읽는다(`lib/server/server_tla_source_events.ml:16-25`, `lib/server/server_auxiliary_startup.ml:186`). warming 자리 채움도 이미 둘을 새로 계산한다(`server_routes_http_runtime.ml:926-928`).
- 앞으로 누가 같은 구역을 두 계산에 다시 넣어도 판정은 틀리지 않는다. 합치는 규칙이 probe 값 하나만 남기고, 롤업은 그 값을 읽는다. 남는 것은 헛계산뿐이다.

### D5. 운영자 필드

- `?full=1` 과 일반 `/health` 는 같은 `fold` 를 부른다.
- 일반 `/health` 는 자기 probe 구역과 snapshot 의 `snapshot_view` 를 넘긴다. snapshot 구역을 본문에 싣지는 않는다.
- 싣는 필드는 지금과 같은 넷이다(`server_health_rollup.ml:12-14`). 받는 요청도 지금과 같다. `Reads` 갈래만 받는다(`server_routes_http_runtime.ml:1932-1940`).
- snapshot 에서 복사하는 `probe_operator_rollup_fields`(`:1867-1874`)는 지운다.
- 첫 snapshot 전에도 일반 `/health` 가 이 필드를 싣는다. `overall_status` 는 D3 대로 `warming` 이거나 그보다 나쁘다.
- 같은 순간의 두 본문은 같은 `overall_status` 를 말한다. 같은 입력을 접기 때문이다.
- 사본을 아예 지울지는 §8-1 에 남긴다.

## 3. 하지 않는 것

- 새 health 구역이나 새 키를 만들지 않는다. 새로 생기는 것은 이유 줄의 글자뿐이다.
- 새 Gate 를 만들지 않는다. `fold` 는 아무것도 막지 않는다.
- 화면을 고치지 않는다. 대시보드는 이미 `overall_status` 와 `operator_action_*` 를 읽는다(`dashboard/src/api/dashboard-tools-prompts.ts:756`, `:846-852`). 새 카드를 만들지 않는다. 운영자 결정(2026-11-22)은 화면에 운영자가 손쓸 것만 두라고 했다.
- `dashboard_surface` 의 서비스·출처 분리는 D2 에 모양만 적는다. 코드는 따로 낸다.
- `graded_of_json` 으로 읽는 구역의 producer 는 바꾸지 않는다. 규칙은 지금과 같고, 읽는 곳이 하나로 모일 뿐이다.
- 등급 없는 중복 계산(`server`, `build`, `paths`, `transport` 등, `:293-327` 과 `:597-629`)은 그대로 둔다. 본문은 이미 probe 값 하나만 싣고, 롤업이 읽지 않는다.
- 오래된 snapshot 을 `overall_status` 에 접지 않는다.

## 4. 고르지 않은 길

1. **인자 셋을 더 붙인다.** `runtime_startup_degradation` 과 같은 방식이다.
   - 장점: diff 가 작다.
   - 단점: 판정한 값과 싣는 값의 불일치가 넷이 된다. 09-30 판정이 N-of-M 덧붙이기를 막았다.
2. **세 구역을 snapshot 계산으로 옮긴다**(09-10 댓글 (b)).
   - 장점: 롤업 자리를 안 바꾼다. 이름 목록에 적으면 닿는다.
   - 단점: 요청마다 새로 재던 값이 snapshot 주기만큼 늦어진다. `dashboard_surface` 는 비용을 따로 재는 단계다(`:320-322`).
3. **목록에 `internal_mcp_auth` 이름만 더한다.**
   - 장점: 한 줄이다.
   - 단점: 롤업은 snapshot 값을, 본문은 probe 값을 쓴다. `schedule_runner` 는 여전히 닿지 않는다.
4. **모든 구역 JSON 에 `grade` 키를 새로 싣고 롤업이 그 키를 읽는다.**
   - 장점: producer 가 등급을 선언한다.
   - 단점: wire 키가 늘어난다. 롤업은 여전히 문자열을 비교한다. 키를 빠뜨린 구역은 조용히 빠진다.
5. **`[@@deriving enumerate]` 로 등급 구역 variant 를 만들고 이름별 match 로 값을 찾는다.**
   - 장점: 등급 구역 집합이 타입에 보인다.
   - 단점: variant 와 본문 목록이 둘로 갈라진다. 값을 찾는 match 가 본문과 다른 값을 고를 수 있다.
6. **목록의 producer 를 모두 typed 등급으로 한 번에 바꾼다.**
   - 장점: 문자열 읽기가 사라진다.
   - 단점: 약 스무 개 모듈을 고친다. 이 결함과 무관한 범위다. decoder 하나로 같은 규칙을 한 곳에서 적용한다.

## 5. 먼저 있는 결정

- **09-10 댓글 제안 (a).** 롤업을 합친 자리로 옮긴다. 따른다.
- **09-30 판정.** 인자를 덧붙이지 않는다. `unknown` 을 degraded 로 접지 않는다. producer typed 계약과 합친 응답의 fold 가 필요하다. 따른다(D1, D2).
- **11-05 정리.** 이 이슈를 RFC 가 필요한 설계 문제로 분류했다. 원문 위치는 찾지 못했다(§9).
- **#35047, #35051, #35060.** 이름 목록 유도, 답할 이유만 올리기, 0 보다 높은 등급의 줄. 규칙은 `graded_of_json` 과 `fold` 로 옮겨 그대로 둔다.
- **#54022.** snapshot 이 계산한 구역은 모두 본문에 싣는다. 그대로 둔다. D4 가 빼는 여섯은 probe 가 싣는다.
- **RFC-0484 §3.3.** 일반 `/health` 에 운영자 필드를 싣는다. 필드와 받는 사람은 그대로다. 값의 출처만 바뀐다(D5).
- **헌법.** `closed_sum_over_string` 과 `strict_parse_no_default` 를 따른다. `gates` 의 기본값대로 Gate 를 더하지 않는다.
- **열린 PR.** 2026-11-27 에 `gh pr list --state open --search "health"` 가 0건이었다.

## 6. 층과 크기

Native stack 두 층이다.

| 층 | 내용 | 파일 | 크기(바뀌는 줄) |
|---|---|---|---|
| L1 | `section`, `graded`, `snapshot_view`, `graded_of_json`, `fold` 를 둔다. `operator_summary` 는 이름 목록으로 구역을 만들어 `fold` 를 부른다. 답은 지금과 같다. 기존 시험을 옮긴다. | `server_health_rollup.ml`, `.mli`, `test/test_server_health_rollup.ml` | 150~250 |
| L2 | 두 계산이 `section list` 를 돌려준다. snapshot 이 구역을 typed 로 든다. 합친 자리와 일반 `/health` 가 `fold` 를 부른다. D4 의 중복, 이름 목록, `operator_summary`, `probe_operator_rollup_fields` 를 지운다. `.mli` 의 낡은 문장(`:79-87`)을 고친다. | `server_routes_http_runtime.ml`, `server_full_health_observation.ml`, `.mli`, `server_health_rollup.ml`, `.mli`, 시험 다섯 | 200~300 |

처음 추정은 4파일, 80~150줄이었다. 두 까닭으로 더 크다.

- snapshot 레코드가 typed 구역을 들어야 한다. 지금은 JSON 만 든다(`lib/server/server_full_health_observation.mli:4-14`).
- `operator_summary` 를 직접 부르는 시험이 넷 더 있다. `test_tla_source_events.ml:101`, `test_runtime_config_validity.ml:4916`, `test_server_auxiliary_startup.ml:270`, `test_server_skill_catalog_health.ml:74` 다.

`make_health_json` 은 시험이 쓰는 한 번에 다 하는 계산이다(`server_routes_http_runtime.mli:118-124`).
L2 뒤로는 probe 구역, snapshot 구역, `fold` 결과를 함께 낸다.
그래서 `operator_action_reasons` 를 읽는 시험(`test_server_runtime_bootstrap.ml:1530`, `:1827`, `:1899`)은 그대로 돈다.

## 7. 검증

### 7.1 feature 시험(L2, `test/test_server_health_rollup.ml`)

구역은 실제 producer 의 생성 함수로 만든다.

1. `internal_mcp_auth` 가 `ready=false` 면 `overall_status=degraded` 다. `operator_action_required=true` 다. 이유에 `internal_mcp_auth:sync_internal_keeper_token_and_restart_runtime` 이 있다.
2. `schedule_runner` 가 `Runner_degraded` 면 `overall_status=degraded` 다. 줄 `schedule_runner:degraded` 가 남는다. 조치는 없다. `Runner_running` 이면 등급이 바뀌지 않는다.
3. `dashboard_surface` 의 `status` 가 `unknown` 이고 `index_present=true` 면 `overall_status=ok` 다. 줄도 조치도 없다.
4. `Not_observed Warming` 만 있으면 `overall_status=warming` 이다. 조치는 없다. 줄 `full_health_snapshot:warming` 이 있다.
5. `Not_observed Warming` 과 4번의 `internal_mcp_auth` 가 함께 있으면 `overall_status=degraded` 이고 조치가 있다.
6. 같은 이름이 probe 와 snapshot 에 다른 등급으로 있으면 `fold` 는 probe 값을 읽는다.

### 7.2 응답 시험(L2)

- 빈 임시 base path 와 `MASC_INTERNAL_MCP_TOKEN` 없는 환경을 만든다. `For_testing.reset_full_health_snapshot`(`server_routes_http_runtime.ml:1787`)으로 snapshot 을 비운다.
- `?full=1` 본문의 `internal_mcp_auth.status` 는 `degraded` 다. 같은 본문의 `overall_status` 도 `degraded` 다.
- 일반 `/health` 본문의 `overall_status` 도 `degraded` 다. 지금은 이 필드가 없다.

### 7.3 운영 확인

헌법 `<evidence>` 대로 배포 뒤 PR 본문에 남긴다.

- 운영 서버의 `/health?full=1` 에서 `internal_mcp_auth`, `schedule_runner`, `overall_status`, `overall_status_reasons` 를 함께 뽑는다.
- 같은 순간의 일반 `/health` 의 `overall_status` 와 비교한다.

상태 기계나 동시성 프로토콜은 바뀌지 않는다. TLA+ spec 은 더하지 않는다.

## 8. 열린 질문

1. **일반 `/health` 의 운영자 필드 사본을 지울까.**
   #54402 뒤로 저장소 안에 읽는 곳이 없다(§1.5).
   권장: 이 RFC 는 남기고 같은 `fold` 로 채운다. 지우는 일은 바깥 사용자를 확인한 뒤 따로 정한다.
2. **`otel` 을 등급 구역으로 둘까.**
   `otel_health_json` 은 `degraded` 를 낸다(`server_routes_http_runtime.ml:220-246`). 지금은 롤업 밖이다.
   권장: 지금처럼 `Ungraded`. 수집기 고장이 MASC 기능 고장인지 운영자가 정한다.
3. **오래된 snapshot 을 접을까.**
   권장: 접지 않는다. `full_health_snapshot.status` 가 이미 말한다.
4. **`graded_of_json` 이 어휘 밖 단어를 만나면 어떻게 할까.**
   지금은 조용히 건너뛴다.
   권장: 이 RFC 에서는 지금 동작을 지킨다. 근본 해결은 그 producer 를 typed 로 옮기는 것이다.

## 9. 확인하지 못한 것

- 운영 값을 이번에 재지 않았다. 2026-11-27 00:26Z 에 `localhost:8935/health?full=1` 은 credential 없는 요청에 공개 본문(키 6개)만 줬다.
- 11-05 정리의 원문을 찾지 못했다. 이슈 댓글, 타임라인, 부모 이슈 #29440 을 봤다.
- 크기는 코드를 쓰지 않고 읽어서 어림했다.
- 시험 환경의 `internal_mcp_auth` 는 토큰이 없어 degraded 일 수 있다. `overall_status` 를 `ok` 로 못박는 실제 응답 시험은 찾지 못했다. 찾은 시험은 `List.exists` 로 이유를 찾는다.

## 10. 에이전트용: 다시 세는 명령

워크트리 루트에서 돌린다.

```sh
git rev-parse --short=13 HEAD                                    # b3c9e636a37b8
sed -n 18,50p lib/server/server_health_rollup.ml                 # 이름 목록 30개
sed -n 84,87p lib/server/server_health_rollup.mli                # 낡은 "probe 에만 셋"
sed -n 278,328p lib/server/server_routes_http_runtime.ml         # probe 계산
sed -n 596,683p lib/server/server_routes_http_runtime.ml         # snapshot 구역 목록
sed -n 1700,1720p lib/server/server_routes_http_runtime.ml       # 합치는 자리
sed -n 1863,1874p lib/server/server_routes_http_runtime.ml       # 일반 /health 사본

# 두 계산에 모두 있는 등급 구역
rg -n '"(internal_mcp_auth|runtime_startup_degradation|dashboard_surface|auxiliary_startup|tla_source_observation|schedule_runner)"' \
  lib/server/server_routes_http_runtime.ml

# internal_mcp_auth 를 읽는 화면 코드: 0건
rg -l internal_mcp_auth dashboard/src lib/masc_tui bin

# operator_summary 를 부르는 시험
rg -n "Server_health_rollup.operator_summary" test
```
