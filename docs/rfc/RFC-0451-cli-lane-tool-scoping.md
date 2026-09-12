---
rfc: "0451"
title: "CLI 레인은 턴이 시작될 때 집합을 고른다 — 매 요청 82KB 는 스스로 안 실려도 된다고 적은 도구들이다"
status: Draft
created: 2026-09-13
author: claude
related: ["attached-service-tool-scoping", "0434", "0413"]
---

# RFC-0451 — CLI 레인의 도구 집합은 턴 시작에 정해진다

- Status: Draft
- 선행: RFC-attached-service-tool-scoping (Accepted, 2026-08-31). 이 문서는 그 RFC 가 **범위 밖으로 남긴 한 줄**을 다시 연다.
- 관계: RFC-0413(Draft)이 고르는 기전을 정한다. 이 문서는 그것을 대체하지 않고 CLI 레인 쪽 실측과 두 제약(§3, §5)을 보탠다.
- 경계: 그 RFC 는 "매 요청 전량 적재를 그만둔다" 를 agent_core 레인에서 닫았다. 이 문서는 닫히지 않은 레인만 다룬다. 지연 적재를 CLI 레인에 이식하자는 것이 **아니다** — 그건 전송 제약상 불가능하고, §2 가 왜인지 적는다.

## 0. Summary

선행 RFC 의 실측표 마지막 줄은 이렇다.

| keeper | 전 | 후 |
|---|---|---|
| analyst | 133개 127,314B | 86개 85,967B |
| edgar.a.poe | 145개 141,702B | 94개 94,325B |
| **rondo · taskmaster** | **133개** | **133개 — CLI 레인, 지연 불가(설계대로)** |

CLI 레인은 아무것도 못 돌려받았다. 그리고 오늘 함대의 주력이 그 레인이다.

지금 모델이 보는 표면은 **113,822 바이트 / 133개**다. 그중 **77개, 선언 텍스트 82,269 바이트**가 자기 파일에 `defer_loading = true` 라고 적어 두었다. 즉 **매 요청의 약 72% 가 "나는 매 요청에 실릴 필요 없다" 고 스스로 선언한 도구들**이고, CLI 레인에서는 그 선언이 아무 일도 하지 않는다.

이 문서의 제안: **CLI 레인에서 `defer_loading` 을 "턴이 시작될 때 고른다" 로 읽는다.** 턴 중에 넓히는 것이 아니라, 턴이 시작되기 전에 이 Keeper 가 무엇을 들고 갈지 정한다. 무엇으로 고르는지는 RFC-0413 이 이미 정했고(§4), 이 문서는 그 위에 CLI 레인이 지켜야 할 조건 둘을 얹는다 — 광고 목록과 디스패치 재고를 나눌 것(§3), 집합을 바꾸면 세션이 새로 시작한다는 것(§5).

## 1. 지금 무엇이 도구를 고르는가

Keeper 하나의 턴 도구 집합은 `Keeper_capability_surface.create` 가 정한다. 인자는 하나뿐이다.

```ocaml
val create : tool_deny:string list -> ... -> t
```

`tool_deny` 는 **거부 목록**이다. 프로필이 이름을 대고 빼지 않으면 모든 Keeper 가 모든 모델 가시 도구를 든다. 허용 목록은 없다.

그래서 표면 증가를 막는 유일한 장치가 전역 바이트 상한(`test_keeper_tool_schema_bytes.ml`)이다. 상한은 범위 지정의 대역이지 범위 지정이 아니다. 도구가 하나 늘 때마다 숫자를 올리고 "무엇을 샀는지" 를 적는 일이 반복되는 이유다 — 파일에 그 기록이 아홉 번 쌓여 있다.

## 2. 왜 CLI 레인은 지연 적재를 못 하는가 (기존 판단은 옳다)

agent_core 레인의 지연 적재는 턴 중간에 도구를 **넓히는** 것으로 동작한다 (`Agent.extend_tools`). CLI 레인에는 그 동작을 실어 나를 채널이 없다. `runtime_official_client_mcp.ml` 이 그 이유를 정확히 적어 두었다:

- `handle_message` 는 `response : Yojson.Safe.t option` 을 돌려준다 — 요청에 답할 뿐 먼저 말하지 않는다.
- HTTP 전송은 GET 에 405 로 답한다. SSE 스트림이 없다.
- Claude Code 전송은 `control_response` 만 되돌린다.

그래서 이 서버는 `listChanged` 능력을 선언하지 않는다. MCP 2025-11-25 가 "선언했으면 `notifications/tools/list_changed` 를 보내야 한다(SHOULD)" 고 하는데 보낼 길이 없기 때문이다. **이 판단을 뒤집자는 제안이 아니다.** 전송에 서버→클라이언트 채널을 내는 일은 별도 축이고, 이 문서는 그것 없이 얻을 수 있는 것을 다룬다.

## 3. 고를 수는 있다 — 다만 목록 하나가 두 일을 한다

`tools/list` 응답은 이미 함수다.

```ocaml
tool_specs : (unit -> Yojson.Safe.t list) -> ...
```

같은 주석이 "`tool_specs` 는 턴이 시작될 때 묶인 불변 목록을 닫는다" 고 적는다. 그러니 **그 목록을 무엇으로 묶느냐**는 열려 있다. 턴이 시작될 때 정해지기만 하면 된다.

여기서 이 문서의 초안이 틀린 말을 했다. `call_tool` 의 **타입**은 목록과 독립이지만 — 이름을 받아 디스패치한다 — **호출 지점**은 그렇지 않다.

```ocaml
(* runtime_claude_code.ml:524-529 *)
let tool_specs () = List.map dynamic_tool_spec tools in
let call_tool ~name ~call_id ~arguments =
  match find_dynamic_tool tools name with
  | None -> None
```

같은 `tools` 가 광고 목록이자 디스패치 재고다. Codex 런타임도 같은 조회에서 `unknown dynamic tool` 로 답한다. 그러니 목록을 좁히면 **보는 것만 줄어드는 게 아니라 부를 수 있는 것도 끊긴다.** 재개된 대화가 이전 턴에서 본 도구를 부르면 그 호출이 실패한다.

이건 좁히기를 막는 사실이 아니라, 좁히기가 지켜야 할 조건이다: **광고 재고와 디스패치 재고를 나눠야 한다.** 모델에게는 고른 것만 보여주고, 들어온 호출은 전량에서 찾는다. 나누지 않으면 §4 의 어떤 선택 기전도 재개 대화를 깬다.

## 4. 고르는 기전은 이미 정해져 있다 — RFC-0413

초안은 여기에 "도구가 무리를 선언하고 프로필이 무리를 부른다" 를 적었다. **철회한다.** 두 가지 이유다.

하나, RFC-0413(Draft)이 같은 자리를 이미 정했다. `tools.attached_allow` 를 `tools.deferred_allow` 로 넓혀, 붙임 도구와 `defer_loading = true` 내장 도구를 **한 필드가 이름으로** 고른다. 기본 의미도 정해 뒀다 — 필드가 없으면 전부, 비어 있으면 없음. 같은 레인에 서로 못 맞추는 초안 둘을 두면 구현하는 사람이 고를 수 없다.

둘, 무리는 이 저장소가 한 번 지운 축이다. `keeper.tools.groups` 가 #31728 에서 제거됐고, RFC-0413 §8 이 그 근거를 다시 적는다 — 그룹은 **두 번째 이름 층**이라 멤버십을 따로 맞춰야 한다. 도구가 이미 가진 이름을 한 곳에 적는 쪽이 새 층을 안 만든다. 18개를 한 줄씩 적기 싫다는 건 근거가 못 된다.

그래서 이 문서는 선택 기전을 제안하지 않는다. **RFC-0413 을 CLI 레인 쪽에서 보강한다.** 남는 건 0413 이 안 가진 것들이다: 이 레인의 실측, §3 의 재고 분리 조건, §5 의 세션 조건.

기본값 논의(빼기냐 넣기냐)도 철회한다. 0413 이 "없으면 전부" 로 정했으므로 새 Keeper 는 지금과 같다. 남는 건 결정이 아니라 배포 순서다 — **어느 Keeper 부터 목록을 적게 할 것인가.** `tool_calls/` 가 함대의 실제 사용을 들고 있으니, 한 번도 안 불린 것부터다.

## 5. 집합을 바꾸면 세션이 새로 시작한다

0413 도 초안도 안 적은 조건이 하나 있다. 도구 집합은 `tool_surface_sha256` 에 들어간다.

```ocaml
(* keeper_official_client_session_store.ml:822-827 *)
let reconcile_tool_surface plan ~tool_surface_sha256 =
  match plan.required_tool_surface_sha256 with
  | Some stored when String.equal stored tool_surface_sha256 -> plan
  | Some _ -> { previous_settlement = None; turn_count = 1; ... }
```

운영자가 어느 Keeper 의 `deferred_allow` 를 고치면 digest 가 움직이고, 다음 청구는 **새 공식 클라이언트 세션**으로 시작한다. 이전 정착은 버려지고 턴 수는 1로 돌아간다. 대화를 이어가려면 부트스트랩을 다시 치러야 한다.

이건 버그가 아니라 이미 정해진 자세다 — 주석이 "이전 세션이 정착시킨 것이 더 이상 이 실행을 설명하지 않는다" 고 적는다. 다만 **범위 지정이 무료가 아니라는 뜻**이다. 목록을 자주 만지면 세션이 자주 끊긴다. 배포는 한 번에 정하고 두는 쪽이어야 한다.

## 6. 판정 기준

- CLI 레인 Keeper 하나의 요청 스키마 바이트가 줄어야 한다.
- **역량을 잃지 않아야 한다.** 초안은 "`tool_calls/` 에 '없는 도구' 실패가 안 늘어야 한다" 고 적었는데, 이건 못 잰다 — 스키마를 못 받은 도구는 모델이 애초에 못 부르므로 실패 기록도 안 생긴다. §4.3 이 인정한 회귀가 정확히 그 모양이다. 그래서 호출 실패가 아니라 **그 Keeper 가 쓰던 도구가 목록에 남아 있는지**를 배포 전에 대조한다. `tool_calls/` 의 과거 사용 집합 ⊆ 새 허용 집합이 조건이다.
- 재개된 대화가 이전 턴의 도구를 불러도 성공해야 한다(§3 의 재고 분리).
- 전역 상한(`ceiling_bytes`)은 안 줄어든다. 줄어드는 건 Keeper 하나가 실제로 지는 무게다.

## 7. 지금 바로 할 수 있는 것 (이 RFC 없이)

상한 가드가 재는 숫자의 이름을 바로잡는다. 이 문서의 초안은 그것을 "CLI 레인 청구서" 라고 고쳤는데, 그것도 틀렸다.

`measured` 는 전역 `model_visible_schemas` 를 읽는다. 실제 Keeper 하나가 지는 무게는 그것과 두 방향으로 다르다.

- `Keeper_capability_surface.create` 가 `tool_deny` 로 거부한 것을 **뺀다**(`keeper_capability_surface.ml:116-124`).
- 고정 레인 묶음은 composition 과 identity 도구를 **더한다**(`keeper_tools_agent_core_bundle.ml:657`).

그러니 이 숫자는 어느 Keeper 의 청구서도 아니다. **거르지 않은 서술자 총합**이고, 표면이 자라는지 보는 데 쓰인다. 가드가 그렇게 말해야 다음 사람이 실패했을 때 엉뚱한 곳을 안 본다.

## 8. 하지 않는 것

- CLI 전송에 서버→클라이언트 채널을 내지 않는다. 그건 이 문서의 축이 아니다.
- 선택 기전을 새로 만들지 않는다. RFC-0413 의 `tools.deferred_allow` 를 쓴다.
- provider 스키마를 줄여 쓰지 않는다 (선행 RFC §6 그대로).
- 상한을 올려서 해결하지 않는다. 올리는 일은 도구가 늘 때의 기록이지 이 문제의 답이 아니다.
