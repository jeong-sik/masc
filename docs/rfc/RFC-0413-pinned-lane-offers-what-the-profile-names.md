---
rfc: "0413"
title: 넓힐 수 없는 레인은 프로필이 지명한 것만 싣는다
status: Draft
created: 2026-09-04
author: Claude Opus 5
supersedes: []
superseded_by: null
related: ["0403"]
---

## 0. 한 줄 요약

공식 클라이언트 레인(codex app-server, antigravity CLI, claude code)은 도구를
프로세스 시작 시점에 고정하고 도중에 넓히지 못한다. 그래서 이 레인은 붙은 도구를
전부 스키마로 싣는다. 실측으로 그 바이트의 33.4%는 여드레 동안 한 번도 불리지 않은
도구가 차지한다. 유예(deferral)는 이 레인에서 원리적으로 불가능하므로, 남은 답은
"보낼 것을 세션이 시작되기 전에 정한다" 하나다. 이 문서는 RFC-0403이 붙임 도구에
만든 지명 축을 내장 도구까지 넓히고 —— **RFC-0403 이 명시적으로 안 하기로 한 일이라
§4.4.1 에서 그 판단을 뒤집는다** —— 그 선언이 바뀌면 세션이 새로 시작한다는 대가를
적어 둔다.

## 1. 측정 출처

이 문서의 숫자는 세 곳에서 나왔다. 출처가 없는 숫자는 이 문서의 결함이다.

| 무엇 | 어디서 | 창 |
|---|---|---|
| 받은 도구 집합 | `~/me/.masc/wire-capture/2026-09/*.jsonl` 의 `kind:"request"` 행. 배열은 `tools_ref._blob.sha256` 로 `~/me/.masc/tool_blobs/<sha[:2]>/<sha>` 에서 복원 | 2026-09-03T04:06:42Z .. 2026-09-04T01:43:49Z, 21.6시간. 6,182행, 미해결 blob 0 |
| 호출 | `~/me/.masc/logs/system_log_<date>.jsonl` 의 `keeper:<name> tool_call tool=<name>` 행 | 2026-08-28 .. 2026-09-04, 여드레 |
| 캐시·귀속 | `~/me/.masc/keepers/*/metrics/2026-09/0[1-4].jsonl`, `record_kind:"turn"` 8,669행 | 2026-09-01 .. 04 |

측정 시점의 기계 부하(`uptime`): 2026-09-04 10:40 KST 110.14 / 150.04 / 166.92,
같은 날 10:51 376.31 / 371.62 / 290.43. 이 문서에는 벽시계 수치가 없으므로 부하가
결론을 좌우하는 자리는 없다. 부하를 적는 이유는 재측정하는 사람이 같은 조건을
가정하지 않게 하기 위해서다.

**창이 서로 다르다는 점을 먼저 적는다.** 받은 집합은 하루치, 호출은 여드레치다.
wire-capture 는 회전으로 `03.000`·`03.001` 을 이미 지운 뒤였고, 앞으로 더 지운다.
그래서 "이 Keeper 가 지난 여드레 내내 같은 배열을 받았다"는 말은 할 수 없다. 회전은
측정 **이전에** 파일을 지운 것이고, 아래 어느 숫자의 차이도 회전으로 설명하지 않는다
(§2.1).

**바이트 총량은 재현 가능한 값이 아니다.** blob 에서 복원한 도구 배열을 다시 문자열로
만들어 길이를 재는 방식이라, 공백·키 순서·비ASCII 이스케이프 처리에 따라 총량이
달라진다. 같은 창을 세 번 독립적으로 재서 435,122,280 / 439,558,046 / 459,939,613 을
얻었다. 그러니 이 문서에서 **비율은 근거로 쓰고 절대 바이트는 규모를 보여주는
용도로만 쓴다.** 행 수(6,182)와 도구 개수는 직렬화와 무관하므로 세 번 모두 같았다.

재현 방법: 창 안의 `kind:"request"` 행을 모아 `tools_ref._blob.sha256` 으로 배열을
복원하고, 배열에 `keeper_tool_search` 가 없으면 고정 레인으로 센다. 호출 쪽은
`(keeper, tool)` 쌍의 집합으로 만들어 이름으로 조인한다.

## 2. 문제

### 2.1 목록 없는 요청이 전체 도구 스키마 바이트의 34%를 나른다

2026-09-04 측정. 창은 `2026-09-03T04:06:42Z .. 2026-09-04T01:43:49Z`, wire capture 의
`kind:request` 6,182행, 각 행의 도구 배열을 `tools_ref._blob.sha256` 으로 `tool_blobs`
에서 복원(미해결 0건).

```
총 도구 스키마 바이트                     435,122,280
그중 keeper_tool_search 가 없는 요청      149,939,300   (34.5%)
```

세 번의 독립 측정이 34.3% / 34.4% / 34.5% 를 냈고, 행 수는 세 번 모두 6,182 였다.
차이는 §1 에 적은 직렬화 편차다.

Keeper 별로 고정 레인 요청 수와, 그 Keeper 가 받은 전체 도구 바이트 중 고정 레인의
몫이다.

| keeper | 고정 레인 요청 | 배열 크기 | 그 Keeper 도구 바이트 중 고정 레인 몫 |
|---|---|---|---|
| lane-smith | 272 | 138 → 139 | 95.7% |
| code-reviewer | 277 | 94 → 95 | 68.5% |
| edgar.a.poe | 182 | 150 → 151 | 63.9% |
| rondo | 189 | 138 → 139 | 49.6% |
| sangsu | 180 | 138 → 139 | 34.3% |
| kidsnote-pr-jira-checker | 38 | 99 → 137 | 17.2% |
| analyst | 38 | 122 → 138 | 8.2% |

합 1,176 요청. 이 초안이 앞서 실었던 lane-smith 98.1% / code-reviewer 71.7% 와
"(138개) 374건, (150개) 177건" 은 재현되지 않아 위 표로 바꾼다.

이 초안이 앞서 실었던 **28.2% (162,412,956 / 575,346,108) 는 철회한다.** 회전 보존이
앞쪽 파일을 지웠다는 초안의 설명도 함께 철회한다 —— 회전은 행을 지우므로 행 수가
같을 수 없는데, 행 수는 세 번 모두 6,182 였다. 두 값의 차이는 시점이 아니라 §1 의
직렬화 편차이고, 편차가 24% 까지 벌어지는 이유는 확인되지 않았다. 재현되는 값만
남긴다.

**레인 판별은 이름의 부재로 한다.** `keeper_tool_search` 가 배열에 없으면 고정
레인으로 셌다. `keeper_tools_agent_core_bundle.ml:612-616` 을 보면 목록이 없는
경우가 하나 더 있다 —— 붙임 표면도 없고 `deferred_builtin_tools` 도 비었을 때다.
`config/tools` 145개 중 55개가 `defer_loading` 을 선언하는 지금은 이 조합이 실제로
나오지 않지만, 위 34.5% 는 그 가정 위에 서 있다(§8).

### 2.2 그중 3분의 1은 여드레 동안 불리지 않는다 —— 사흘로 자르면 절반

요청 가중으로 다시 센 값 —— 각 요청 행의 복원된 배열 바이트를 그대로 합한 값:

```
고정 레인 도구 스키마 바이트, 09-03T04:06Z..09-04T01:43Z:  149,939,300
  여드레(08-28..09-04) 동안 한 번도 안 불린 도구 몫:        50,031,342  (33.4%)
  사흘(09-01..03) 창으로 좁히면:                            68,296,181  (45.5%)
```

세 번의 독립 측정이 (32.9%, 44.9%), (33.0%, 44.9%), (33.4%, 45.5%) 를 냈다. 편차
0.6%p 안이다.

창을 사흘에서 여드레로 넓히면 "죽었다"는 몫이 45.5%에서 33.4%로 줄어든다. 이
차이가 이 문서에서 가장 중요한 숫자다.

**한 도구로 보면 이렇다.** 사흘 창(09-01..03)에 한 번도 안 불렸지만 그 앞 나흘
(08-28..08-31)에는 불린 도구를, 그 Keeper 의 호출 수와 함께 적는다.

| keeper | 도구 | 앞 나흘 호출 수 | 사흘 창 호출 수 |
|---|---|---|---|
| sangsu | `keeper_spawn_read` | 534 | 0 |
| edgar.a.poe | `slack_slack_read_channel` | 449 | 0 |
| lane-smith | `keeper_tasks_audit` | 164 | 0 |
| lane-smith | `masc_board_stats` | 159 | 0 |
| rondo | `masc_board_comment_vote` | 34 | 0 |

사흘짜리 관찰로 선언을 쓰면 sangsu 에게서 나흘 동안 534번 불린 도구를 지운다.

이 초안이 앞서 적었던 "이틀 전에 1,229번 불린 도구" 는 철회한다. 여드레 어느
날에도 어느 도구도 1,229 를 기록하지 않았고, 가리키던 참조 `§3.4` 는 존재하지 않는
절이다.

Keeper 별, 여드레 기준:

| keeper | 런타임 | 받는 도구 | wire KB | 여드레 미호출 KB | % | 사흘 기준 % |
|---|---|---|---|---|---|---|
| kidsnote-pr-jira-checker | claude_code | 99 → 137 | 6,340 | 4,583 | 72.3 | 72.3 |
| lane-smith | antigravity | 138 → 139 | 36,043 | 13,517 | 37.5 | 58.3 |
| analyst | antigravity | 122 → 138 | 4,629 | 1,623 | 35.1 | 43.1 |
| edgar.a.poe | antigravity | 150 → 151 | 26,616 | 8,876 | 33.3 | 46.9 |
| sangsu | antigravity | 138 → 139 | 23,948 | 7,797 | 32.6 | 45.3 |
| rondo | antigravity | 138 → 139 | 25,088 | 7,532 | 30.0 | 40.1 |
| code-reviewer | antigravity | 94 → 95 | 23,760 | 4,932 | 20.8 | 24.0 |

"받는 도구" 가 두 값인 것은 창 안에서 배열이 한 번씩 바뀌었기 때문이다. 무엇이
바뀌었는지는 §4.3 에 적었다.

kidsnote-pr-jira-checker 의 71.5%는 다른 여섯과 같은 값이 아니다. 이 Keeper 는
08-28..08-31 에 `tool_call` 행을 하나도 남기지 않았다(돌지 않았다). 여드레와 사흘
값이 같은 것이 그 증거다. 사흘짜리 근거를 여드레 이름표로 쓴 값이다.

### 2.3 무엇이 실제로 죽었나 —— 그리고 무엇이 죽은 것처럼 보이나

일곱 Keeper 중 누구도 여드레 동안 부르지 않은 도구는 182개 중 64개, 219.0 KB 중
**98.2 KB** 다.

| 계열 | KB | 미호출 / 받은 수 |
|---|---|---|
| atlassian | 44.0 | 25 / 31 |
| slack | 32.5 | 10 / 12 |
| github | 11.9 | 16 / 44 |
| masc_fusion | 2.6 | `masc_fusion` (형제 `_status` 는 불렸다) |
| masc_board | 2.4 | `_cleanup`, `_curation_submit`, `_profile` |
| keeper_ide | 1.8 | `keeper_ide_annotate` |
| keeper_voice | 1.3 | 4 / 4 |
| keeper_person | 0.6 | `keeper_person_note_set` |
| masc_keeper | 0.4 | `masc_keeper_delegate_cancel` |
| masc_gc | 0.3 | `masc_gc` |
| keeper_composition | 0.3 | `keeper_composition_cancel` |

계열 전체가 함대 차원에서 죽은 것은 넷뿐이고(`keeper_ide`, `keeper_person`,
`masc_gc`, `masc_fusion` 본체) 합쳐 5.1 KB 다. 무게는 다른 데 있다.

**`github_*` 는 이 문제를 계열 단위로 풀 수 없다는 증거다.** 44개 46.9 KB, 일곱 중
다섯이 받는다. 받는 Keeper 전원이 매일 쓴다(rondo 8/8일, edgar.a.poe·lane-smith·sangsu
7/8일). 그런데 **44개 중 23개보다 많이 쓰는 Keeper 가 없다**(여드레 기준 rondo 23,
lane-smith 21, sangsu 20, edgar.a.poe 19, analyst 16).

두 창을 섞지 않고 나란히 적는다. 받는 사본은 다섯 다 같은 44개 46.9 KB 다.

| keeper | 여드레 미호출 | 여드레 미호출 KB | % | 사흘 미호출 | 사흘 미호출 KB | % |
|---|---|---|---|---|---|---|
| analyst | 28 | 26.2 | 56 | 28 | 26.2 | 56 |
| edgar.a.poe | 25 | 20.0 | 43 | 33 | 28.6 | 61 |
| lane-smith | 23 | 19.4 | 41 | 36 | 35.8 | 76 |
| rondo | 21 | 15.8 | 34 | 25 | 20.3 | 43 |
| sangsu | 24 | 19.6 | 42 | 24 | 19.6 | 42 |

이 초안이 앞서 적었던 "lane-smith 46.9 중 35.8 KB, edgar.a.poe 28.6 KB" 는 **사흘
값인데 여드레 문장에 들어가 있었다.** 여드레로 재면 lane-smith 19.4 KB, edgar.a.poe
20.0 KB 다. "절반" 이라는 말도 뺀다 —— 여드레 기준으로 34~56% 다.

결론은 어느 창에서도 같다. 계열은 살아 있고 각 Keeper 가 받는 사본의 3분의 1에서
절반 남짓은 죽어 있으며, **죽은 쪽의 구성이 Keeper 마다 다르다.** 계열 단위로
자르면 46.9 KB 를 통째로 남기거나 레인을 망가뜨린다.

## 3. 왜 유예로는 안 되는가

### 3.1 코드가 그렇게 적어 두었다

`lib/keeper/keeper_tools_agent_core_bundle.ml:569-572`:

> Attached tools, as schemas. What the lanes that cannot widen a running turn
> are given: they pin their tool set at process spawn or thread start, and that
> set is part of a resumable session's identity, so a listing would name tools
> they can never make callable.

같은 파일 :637-639:

> The lanes that cannot widen a turn get every tool as a schema: holding one
> back there would name a tool nothing can load.

그리고 :641 이 실제 배열이다.

```ocaml
{ tools = descriptor_tools @ composition_tools @ identity_agent_tools
; agent_core_tools = always_loaded @ (listing :: already_used)
```

`tools` 는 고정 레인이 보내는 것이고, `defer_loading` 으로 나뉜
`always_loaded_builtin_tools` / `deferred_builtin_tools` 구분(:595-603)을 통과하지
않는다. `agent_core_tools` 만 그 구분을 읽는다.

`lib/tool_surface/tool_loading_declarations.mli` 도 같은 말을 한다.

> It reaches the Agent Core lane only. The codex, antigravity and claude_code
> runtimes are handed the whole tools array and never read this key.

### 3.2 그래서 선언이 한쪽에서만 읽힌다

이 worktree 의 `config/tools/` 는 145개 파일 중 **55개가 `defer_loading = true`** 를
선언하고, 라이브 트리는 144개 중 54개다. 두 트리의 차이는 파일 하나
(`keeper_task_cancel`, worktree 에만 있음)이고, 두 트리에 다 있는 144개 중 선언이
서로 다른 파일은 0개다. 런타임은 라이브 트리가 아니라 바이너리에 박힌 사본을 읽는다
(`tool_loading_declarations.ml:32-35` 의 `loading_of_tool`, 파일이 없는 이름은
`Always_loaded`).

일곱 Keeper 가 **공통으로 받는 내장은 94개**이고, 그중 `defer_loading = true` 를
선언한 것이 **54개**다. 그 차이 나는 파일 하나는 이 94개 밖이라 54는 정확한 값이고,
앞선 초안의 `±1` 은 뺀다. 바이트로는 48,103 B 인데 §1 의 직렬화 편차 안에 있다
(다른 측정에서 49,915 B, 50,125 B). 이 문서는 개수 54를 근거로 쓴다.

이 초안이 앞서 이 자리와 §6.1 에 적었던 **95는 94의 오기다.** 94는 일곱 배열의
교집합이고(§4.5), 95는 code-reviewer 한 Keeper 의 큰 쪽 배열 크기이거나 §6.3 이
근거로 쓰지 말라고 한 대시보드 투영이 돌려주는 값이다. 어느 쪽이든 "일곱이 공통으로
받는 집합" 이 아니다.

정리하면 **고정 레인 내장 94개 중 54개는 운영자가 이미 "유예해도 된다"고 써 두었는데
이 레인이 그 파일을 읽지 않는다.** `attached_allow` 는 설계상 붙임 도구 전용이라 이
54개에 닿지 않는다 —— 근거는 `keeper_identity_tool_allow.mli:1-2` ("narrow an
attached-service offering") 와 `:10-11` ("attached tools have no tool file to declare
it in") 이다. 앞선 초안이 인용한 `:29-33` 은 `unnamed` 필드 설명이라 이 주장을
받치지 않는다.

남은 빈자리는 하나다: **Keeper 별 × 내장 도구**. 이 축은 지금 존재하지 않는다.

## 4. 제약

### 4.1 세션 재개 —— #27992 의 "출구 없음" 은 이미 닫혔다

`lib/keeper/keeper_official_client_session_store.ml:805-824` 를 직접 읽었다.

```ocaml
let reconcile_tool_surface plan ~tool_surface_sha256 =
  match plan.required_tool_surface_sha256 with
  | None -> plan
  | Some stored when String.equal stored tool_surface_sha256 -> plan
  | Some _ ->
    { previous_settlement = None; turn_count = 1; required_tool_surface_sha256 = None }
```

바로 위 주석이 #27992 을 이름으로 부르며 "a refusal here strands every settled
session on the next release" 라고 적는다. 지금은 거절이 아니라 **새 세션** 가지로
간다. `client_kind`·`runtime_id` 가 바뀌었을 때와 같은 가지다. 세 어댑터가
`claim` 전에 적용하고(`keeper_codex_runtime.ml:543`,
`keeper_antigravity_runtime.ml:444`, `keeper_claude_code_runtime.ml:500`),
`claim` 자신도 :830 에서 한 번 더 적용해서 호출자가 건너뛸 수 없다.

라이브 확인: `~/me/.masc/logs/system_log_2026-09-0{2,3,4}.jsonl` 에서
`tool surface changed before session resume` 0건. 코드에는 **이 문구를 내보내는
자리가 없고**, 문구 자체는 `test/test_official_client_session_store.ml:264` 의 주석에
남아 지워진 동작을 설명한다. 앞선 초안의 "그 문자열은 코드에 더 없다" 는 문구가
아니라 발신 지점을 말한 것이므로 그렇게 고쳐 적는다.

**금지하는 것**: "표면을 좁히면 세션이 좌초한다"를 근거로 이 설계를 막는 것.
그 상태는 존재하지 않는다. 다만 아래 §4.2 의 값은 그대로 남는다.

해시가 무엇에 반응하는지(`keeper_official_client_session_store.ml:187-217`):
도구 이름·서술·입력 스키마를 이름순으로 정규화한 JSON, `native_posture`,
`context_message_schema` 셋. 도구 순서와 필드 순서는 해시를 움직이지 않는다.
**도구를 하나 빼는 것은 해시를 움직인다.**

### 4.2 그 대신 대가가 있다 —— 그리고 그 대가는 아직 갚을 사람이 있다

새 세션 가지의 대가는 셋이다.

1. `previous_settlement` 이 사라지고 `turn_count` 가 1로 돌아간다.
2. 다음 턴이 목표만 보내는 대신 투영된 대화 전체를 bootstrap 으로 다시 보낸다
   (`keeper_claude_code_runtime.ml:539-544`; codex 는 `thread/inject_items`,
   `keeper_codex_runtime.ml:569-576`).
3. 그 bootstrap 이 안 맞으면 `Recovery_required { failure = Input_rejected _ }`
   로 떨어지고, `keeper_official_client_session_store.ml:760-784` 는 이 상태만은
   자동 재진입을 거절한다. 운영자 resolve 없이는 안 열린다.

3번은 죽은 코드가 아니다. `bootstrap_floor_exceeded` 의 여드레 분포다(같은 로그
파일들).

```
08-28   0 | 08-29  21 | 08-30 5229 | 08-31  76
09-01   0 | 09-02   0 | 09-03   27 | 09-04   0
```

08-30 의 5,229 는 하루짜리 사건이다. **여드레 중 이틀이 0이고 하루가 5,229 인
분포에는 "기준선" 이라 부를 값이 없다.** 앞선 초안이 09-02·03·04 세 날만 뽑아
`27 / 0 / 0` 을 기준선으로 쓴 것은 이 문서가 §2.2 에서 비판하는 창 자르기와 같은
잘못이다. §6.2 의 판정 기준도 이에 맞춰 고쳤다.

반대 방향도 같은 세션 저장소가 적어 둔다(`:10-21`): floor 를 넘긴 세션이 다시 맞게
되는 길은 "시스템 프롬프트, 목표, 도구 표면, 런타임 변경" 넷뿐이다. **도구 표면을
줄이는 것은 그 막다른 골목에서 나가는 인정된 출구 중 하나다.**

**`turn_count` 스냅샷으로는 이 대가를 값매길 수 없다.** 같은 파일
(`~/me/.masc/keepers/<k>/official-client-runtime/session.json`) 을 하루 안에 세 번
읽어 세 번 다른 값을 얻었다: `1,1,1,5,6,17,36` / `1,4,5,6,14,17,36` /
`3,4,5,7,17,36,37`. 이 값이 움직이는 이유를 저장소가 직접 적어 둔다
(`keeper_official_client_session_store.ml:814-816`): "Deployments move this digest.
Adding a tool, or editing a descriptor, is enough." 즉 `turn_count` 는 세션이 얼마나
길 수 있는지가 아니라 **마지막으로 표면이 움직인 뒤 몇 턴이 지났는지**를 잰다. 이
설계가 매기려는 대가가 곧 이 숫자를 깎는 사건이므로, 이 숫자로 그 대가가 작다고
말하는 것은 순환이다.

또 이 일곱만 보면 안 된다. 공식 클라이언트 세션을 가진 Keeper 는 아홉이고
(`polisher` 24, `microvm-probe-829` 6 이 더 있다), `polisher` 는 측정 창에 고정 레인
요청이 0이라 §2 에서는 빠지는 게 맞지만 이 논증에서는 빠질 이유가 없다.

**대신 직접 잰 것이 있다.** 측정 창 21.6시간 안에 일곱 Keeper 의 고정 레인 배열이
각각 정확히 한 번씩, 모두 일곱 번 바뀌었다(§4.3). 두 사건으로 묶인다 —— 05:23Z 에
붙임 카탈로그가 늘어 둘, 17:57–18:00Z 에 배포가 도구 하나를 더해 다섯이다. 즉
**아무도 요청하지 않은 표면 이동을 이 함대는 이미 치르고 있고, 하루치 창에서 그것이
두 번이었다.** 하루가 표본 하나라 "하루에 두 번" 이 평균이라는 말은 아니다. 이
설계가 더하는 것은 사람이 파일을 고칠 때마다 Keeper 당 한 번이다.

**금지하는 것**: 표면 변경을 무료로 취급하는 것. 그리고 세션을 자동으로 자주
갈아 끼우는 어떤 장치도.

### 4.3 프로바이더 캐시 —— 오늘 가진 값으로는 매길 수 없다

**먼저 배열이 얼마나 자주 바뀌는지부터.** 앞선 초안은 이 값을 잴 수 없다고 §8 에
적었는데, §2 가 이미 쓰는 wire capture 로 잴 수 있다. 창 안의 고정 레인 요청
1,176건을 Keeper 별로 시간순 정렬해 이웃한 두 요청의 도구 이름 집합을 비교했다.

| keeper | 요청 | 변화 | 무엇이 바뀌었나 | 시각 |
|---|---|---|---|---|
| code-reviewer | 277 | 1 | `+keeper_task_cancel` | 09-03T17:57:35Z |
| lane-smith | 272 | 1 | `+keeper_task_cancel` | 09-03T17:57:34Z |
| edgar.a.poe | 182 | 1 | `+keeper_task_cancel` | 09-03T17:57:36Z |
| rondo | 189 | 1 | `+keeper_task_cancel` | 09-03T18:00:51Z |
| sangsu | 180 | 1 | `+keeper_task_cancel` | 09-03T18:00:44Z |
| analyst | 38 | 1 | `+github_*` 16개 | 09-03T05:23:42Z |
| kidsnote-pr-jira-checker | 38 | 1 | `+atlassian_*`·`+slack_*` 38개 | 09-03T05:23:49Z |

**1,176 요청에 변화 7회, 0.6%.** 배열이 어떤 형태로 같은지를 더 엄격히 보는
독립 측정(이름이 아니라 배열 전체 비교)은 12회, 1.0% 를 냈다. 어느 쪽이든 1% 아래다.
`4.3 턴 변수가 아니라 세션 상수` 라는 말이 이 숫자다.

그리고 이 표가 §4.2 의 대가를 함께 값매긴다. 17:57–18:00Z 의 다섯 줄은 **#32974
(`55c92b6751`, main 병합 2026-09-03T17:26Z)가 `keeper_task_cancel` 하나를 더한
결과**다. 병합 31~34분 뒤 다섯 Keeper 의 `tool_surface_sha256` 이 움직였고 다섯
세션이 새로 시작했다. **아무도 그 대가를 요청하지 않았고 아무도 알아채지 못했다.**
05:23Z 의 두 줄은 배포가 아니라 붙임 서비스 카탈로그가 늘어난 것이다.

도구를 하나 더하는 평범한 PR 이 이 레인의 세션 다섯 개를 버린다. **이 설계가 새로
만드는 종류의 대가가 아니라, 이미 매일 치러지고 있는 대가를 사람이 의도적으로
치르게 하는 것이다.**



`packages/agent_core/lib/llm_provider/backend_anthropic.ml:441-462` 는 마지막 도구에
`cache_control` 을 얹는다. 배열이 바뀌면 시스템 프롬프트와 히스토리의 캐시 읽기까지
같이 잃는 모양이다. 그런데 **이 파일에 묶인 라이브 프로바이더가 없다.**
`~/me/.masc/config/runtime.toml:730-790, 2285-2290` 의 모든 provider 는
`openai-compatible-http` / `ollama-http` / `codex-app-server` / `claude-code` /
`antigravity-cli` 다. Anthropic 네이티브 바인딩은 0개다. 살아 있는
`backend_openai.ml:78` 은 `supports_prompt_caching = false` 이고 `cache_control` 을
아예 내보내지 않는다.

라이브 와이어에서 직접 본 것(`usage_scope = "per_request"` 행만):

| 런타임 | 버킷 | n | cache_read 중앙값 | input 중앙값 | 0 읽기 % |
|---|---|---|---|---|---|
| glm-coding.glm-5.3 | 배열 그대로 | 284 | 47,968 | 56,946 | 0.4 |
| glm-coding.glm-5.3 | 배열 바뀜 | 38 | 37,984 | 58,808 | 0.0 |

배열이 캐시 접두사를 통째로 지배한다면 "바뀜" 38건이 전부 0을 읽어야 한다. 0건이
그랬다. 관찰이지 통제 실험이 아니고 n=38 이다.

모델별 캐시(8,669 turn 행, 09-01..04):

| runtime_id | 턴 | cache_read>0 | 중앙값 | usage_scope |
|---|---|---|---|---|
| glm-coding.glm-5.3 | 1,452 | 99.7% | 48,000 | per_request |
| claude_code.claude-sonnet-5 | 703 | 91.6% | 510,422 | per_request |
| ollama_cloud.deepseek-v4-flash-0731 | 2,829 | 0.0% | — | per_request |
| ollama_cloud.minimax-m3 | 1,424 | 0.0% | — | per_request |
| codex_subscription.gpt-5.6-luna | 254 | 0.0% | — | unavailable/none |
| antigravity_subscription.gemini-3-7-flash-high | 948 | 81.5% | 4,267,814 | conversation_cumulative |
| antigravity_subscription.gemini-3-8-flash-high | 929 | 61.7% | 225,974 | conversation_cumulative |

아래 두 행의 중앙값은 CLI 가 가진 누적 카운터의 차분이라 masc 가 계산한 값이 아니다.
`codex_subscription` 의 0은 "캐시 안 됨"이 아니라 "보고 안 됨"이다(`usage_scope`
가 `unavailable`). 둘 다 근거로 쓰지 않는다.

**그리고 이 레인에서는 질문 자체가 틀렸다.** #33009 병합 뒤 고정 레인의 지문은
세션 시작 행에만 남는다. 재개는 도구 배열을 아예 보내지 않고, 그래서
`Client_session_holds_input` 으로 기록된다(09-04 새 모양 110행 중 antigravity
attributed 6 / not_measured 58, 6건 전부 `basis.position = "fresh"`).
고정 레인의 도구 배열은 **턴 변수가 아니라 세션 상수**다.

**한 가지는 아직 안 쟀다.** §5.1 의 새 배열은 `always_loaded_builtin_tools` 를 앞에
두므로, 아무것도 선언하지 않은 Keeper 도 **같은 도구를 다른 순서로** 받는다(§5.1).
해시는 이름순 정규화라 세션은 그대로지만, 캐시 접두사를 바이트 그대로 잡는
프로바이더가 있다면 배포 시점에 한 번 그 접두사를 잃는다. 위 표의 관측은 내용이
바뀐 경우이지 순서만 바뀐 경우가 아니라서 이 물음에 답하지 않는다(§8).

**금지하는 것**: 이 레인의 표면 변경을 "턴마다 잃는 캐시"로 값매기는 것. 대가는
§4.2 의 세션 하나다. 그리고 `backend_anthropic` 의 `cache_control` 을 현재 상태의
근거로 인용하는 것.

### 4.4 RFC-0403 이 이미 만든 축 —— 그리고 그 축의 채택률은 0이다

#32679 는 Keeper 가 자기 서비스의 전체 목록이 아니라 프로필이 지명한 붙임 도구만
받게 했다. 기전은 `Keeper_identity_tool_allow.apply ~allow offered` 하나이고
(`keeper_run_tools_setup.ml:429-431`), 이름 정확 일치만 한다. 접두사도 provider
묶음도 없다. `allow = None` 은 전부, `Some []` 은 없음 —— 두 값이 반대다.
`unnamed` 로 오타를 경고한다.

이 `.mli` 는 이 RFC 가 하려는 일을 미리 적어 두었다.

> Static also sidesteps what stops the official-client lanes from deferring at
> all -- those pin their tool set at process spawn, and a selection made before
> spawn is a set they can pin.

**그런데 라이브 함대에서 이 선언을 쓰는 Keeper 는 0개다.**
`rg -l attached_allow ~/me/.masc/config/` 결과 없음. 즉 #32679 는 배포됐고 한 번도
작동한 적이 없다.

`[keeper.tools]` 블록 자체는 하나 있다 —— `~/me/.masc/config/keepers/rondo.toml:24-25`
가 `native = "read"` 를 쓴다. 앞선 초안의 "어떤 keeper TOML 에도 `[keeper.tools]`
블록이 없다" 는 틀렸다. 값이 0인 것은 `attached_allow` 이지 그 표가 아니고, 이
차이는 §5.1 의 이름 짓기에 영향을 준다.

이것이 두 번째 제약이다. **#31728 은 정확히 같은 모양의 축을 지웠다** —— RFC-0389
의 `keeper.tools.groups` 는 "살아있는 Keeper 9개 중 선언 0개" 라서 타입·변환·필터·
meta 필드·프로필 기본값·TOML 분기·`keeper_up` 인자·영속화·투영 셋을 통째로
들어냈다.

**금지하는 것**: 기전만 넣고 선언은 나중에 넣는 PR. 이 저장소는 그런 PR 을 이미
한 번 지웠다.

### 4.4.1 이 문서는 RFC-0403 이 하지 않기로 한 것을 한다

RFC-0403 은 내장 도구를 대상에서 뺐고, 그 이유를 세 자리에 적었다.

`RFC-0403:128-129`:

> 부착 도구만 대상으로 한다. 내장 도구에는 이미 `defer_loading` 이 있고, 두 축이
> 같은 도구를 두고 다투면 어느 쪽이 이겼는지 읽을 수 없게 된다.

`:167` 은 "내장 도구 선택 —— `defer_loading` 의 축이다" 를 안 하는 것에 넣었고,
`:216` 은 "두 축(`defer_loading`) 과 겹침" 리스크의 완화책으로 "§3.1 부착 도구만
대상" 을 적었다.

**이 문서는 그 셋을 모두 뒤집는다.** 뒤집는 이유는 이 RFC 가 다루는 레인에서
`defer_loading` 이 **읽히지 않기 때문**이다(§3.1). RFC-0403 이 걱정한 "두 축이
같은 도구를 두고 다툰다" 는 두 축이 같은 자리에서 동시에 읽힐 때 성립하는데,
고정 레인에는 `defer_loading` 을 읽는 코드가 없어 다툴 상대가 없다. 유예 레인에서는
두 축이 같이 읽히므로 순서를 여기서 못 박는다.

**고정 레인**: `defer_loading` 은 읽히지 않는다. 지명된 것만 실린다.
**유예 레인**: `defer_loading = true` 가 유예 후보를 정하고, 그중 지명된 것만
목록에 오른다. 즉 두 축은 겹치지 않고 **직렬**이다 —— 앞 축이 후보 집합을 만들고
뒤 축이 그 안에서 고른다. `always_loaded` 인 도구는 어느 쪽에서도 이 필터를
지나지 않는다(§5.1).

RFC-0403 은 아직 `Draft` 이고 이 문서가 그것을 통째로 대체하지는 않는다 —— 0403 의
측정과 하네스 조사는 여기 다시 싣지 않는다. 그래서 `supersedes` 로 적지 않고,
**RFC-0403 §3.1·§3.4·§5 의 해당 항목이 이 문서로 수정된다**고 여기에 적는다. 0403
의 `attached_allow` 라는 이름도 §5.1 에서 바뀐다.

### 4.5 항상 실리는 핵심은 안 쓰는 바이트가 아니다

**고정 레인 일곱 Keeper 가 공통으로 받는 집합은 94개**다. 그 94개를 선언으로 갈라
보면 이렇다.

| 갈래 | 개수 | 이 축이 닿는가 |
|---|---|---|
| `defer_loading = true` | 54 | 닿는다 (§5.1) |
| tool 파일이 있고 `Always_loaded` | 34 | 안 닿는다 |
| tool 파일이 아예 없음 | 6 | 안 닿는다 |

파일이 없는 6개는 `Execute`, `WebFetch`, `WebSearch`, `keeper_compose_background-snapshot`,
`keeper_compose_mission-snapshot`, `keeper_compose_work-intake` 다. 이들이 필터 밖에
있는 것은 정책이 아니라 구조다 —— `tool_loading_declarations.ml:32-35` 의
`loading_of_tool` 이 이름을 못 찾으면 `Always_loaded` 를 돌려준다.

**그래서 "항상 실리는" 집합은 40개(34 + 6)다.** 앞선 초안이 여기와 §6.2·§7 에 쓴
`47` 은 이 문서 안의 어떤 집합도 가리키지 않아 뺀다. 앞선 초안이 §8 에 미해결로
남겼던 "47 과 94 중 어느 집합인가" 도 40으로 닫는다.

94개 중 21개(14.4 KB)는 사흘 창에서 미호출이다. 여드레로 넓히면
`keeper_ide_annotate`, `keeper_person_note_set`, `masc_gc`, `masc_fusion`,
`masc_keeper_delegate_cancel`, `keeper_composition_cancel`, `masc_board_cleanup`,
`masc_board_curation_submit`, `masc_board_profile`, `keeper_voice_*` 4개가 남는다.
이 RFC 는 40개를 건드리지 않고, 54개에만 닿는다(§5.1).

## 5. 설계

### 5.1 무엇을 바꾸나

`keeper_tools_agent_core_bundle.ml:641` 의 `tools` 를 이렇게 바꾼다.

```
현재:  descriptor_tools @ composition_tools @ identity_agent_tools
제안:  always_loaded_builtin_tools
       @ named_of deferred_builtin_tools
       @ identity_agent_tools
```

`deferred_builtin_tools` / `always_loaded_builtin_tools` 분할은 이미 :595-603 에
있다. `named_of` 는 `Keeper_identity_tool_allow.apply` 와 같은 정확 이름 일치
필터다.

**같은 필터를 두 계열에 쓰려면 한 군데를 고쳐야 한다.** `apply` 의 타입은
`Keeper_identity_tools.offered_tool list` 인데 내장 도구는
`Agent_core.Tool.t list` 다(`keeper_identity_tool_allow.mli:38-41`). 이름을 뽑는
함수를 인자로 받게 일반화한다. 앞선 초안의 "새 기전을 만들지 않는다" 는 정확하지
않아 이렇게 고쳐 적는다 —— 새 축은 만들지 않고, 기존 필터의 타입만 넓힌다.

#### 필드 이름

```
tools.attached_allow  ->  tools.deferred_allow
```

의미: "기본으로 유예되는 도구 중 이 Keeper 가 받을 것". 붙임 도구는 자기 tool 파일이
없어 언제나 유예 대상이고, 내장 도구는 `defer_loading = true` 를 선언했을 때만
유예 대상이다. 두 계열이 한 문장으로 설명된다.

**`tools.allow` 로는 안 짓는다.** 같은 표에 `tools.native` 가 이미 있고
(`keeper_turn_up_config_persistence.ml:383, 393`, 라이브 사용례는
`~/me/.masc/config/keepers/rondo.toml:24-25`), 그것은 핵심 내장 도구에 대한
자세다. 그 옆에 가장 넓은 낱말인 `allow` 를 놓으면, 정작 natives 와
`always_loaded` 내장에는 닿지 않는 필드가 전부에 닿는 것처럼 읽힌다.
`attached_allow` 는 적어도 어느 계열인지를 말했다. `deferred_allow` 는 그 자리를
정확한 계열 이름으로 채운다.

경고의 `error_kind` 도 같은 컷에서 따라간다:
`keeper_attached_tool_allow_unnamed` → `keeper_deferred_tool_allow_unnamed`.
필드 이름과 그것이 내는 경고 이름이 어긋나면 §6.2 를 재는 사람이 옛 이름으로 세고
0을 얻는다.

호환 리더·변환기는 쓰지 않는다(masc 의 hard cut 규칙). 라이브 선언이 0개이므로
(§4.4) 이 컷의 대가는 측정상 0이다.

#### 세 가지 값, 그리고 세 번째가 위험하다

| 값 | 뜻 |
|---|---|
| `None` (필드 없음) | 유예 대상 전부를 싣는다 |
| `Some []` | 유예 대상 전부를 뺀다 |
| `Some names` | 이름이 있는 것만 싣는다 |

세 번째가 이 컷에서 뜻이 바뀌는 자리다. **붙임 도구 이름만 적은 선언은 그 Keeper 의
`defer_loading = true` 내장 54개를 전부 지운다.** `RFC-0403:120` 의 예시가 정확히
붙임 이름만 나열한 목록이라, 그것을 그대로 새 필드에 옮겨 적는 사람이 이 자리에
걸린다. 필드 이름이 바뀌는 이유도 여기 있다 —— `attached_allow` 를 그대로 두고
뜻만 넓히면 이 함정이 조용해진다. `§5.5` 1단계의 선언 여섯 개도 두 계열을 모두
적어야 하고, 이 문서는 그것을 같은 변경에 넣는다.

#### `unnamed` 는 합집합 한 번으로만 낸다

`Keeper_identity_tool_allow.apply` 는 `unnamed = wanted \ kept` 를 낸다
(`keeper_identity_tool_allow.ml:21-27`). 목록 하나를 두 자리에서 각각 거르면
**붙임 쪽 필터가 내장 이름을 전부 `unnamed` 로 신고하고 내장 쪽 필터가 붙임 이름을
전부 신고한다.** 올바른 선언이 구조적으로 경고를 낸다.

그래서 거르는 것은 두 자리에서 하되, **`unnamed` 는 두 제공 집합의 합집합에 대해 한
번만 낸다.** 지금 경고를 내보내는 자리는 `keeper_run_tools_setup.ml:432-445` 한 곳뿐이라
(`rg attached_tool_allow_unnamed lib/` 가 이 한 줄만 낸다) 자리를 옮기지 않는다.
붙임 쪽 `kept` 는 이미 두 곳에서 읽히므로(`:470` 의 `identity_surface`, `:630` 의
`attached_names`) 거르는 결과 자체는 지금 모양 그대로 쓴다. 이것이 §6.2 의
`unnamed = 0` 판정을 성립시키는 조건이다.

#### 투영 검사에 빼는 이름을 알려야 한다

`keeper_run_tools_setup.ml:662` 는 `tools` 표면을 `expected_model_tool_names` 와
비교하고 어긋나면 `keeper_model_tool_projection_mismatch` 를 `Log.Error` 로 낸다.
이 호출은 `?deferred_names` 를 넘기지 않아 기본값 `[]` 이고, 그래서 기대 집합은
`model_visible_descriptors` 전부다. **§5.1 이 도구를 빼면 이 검사는 선언한 Keeper 의
모든 턴에서 실패한다.**

가설이 아니다. 같은 함수의 주석 `:118-122` 가 같은 모양의 사고를 기록한다.

> Reading the declaration instead cost 60 [keeper_model_tool_projection_mismatch]
> errors in an hour on 2026-08-31

라이브에서도 확인했다: 이 `error_kind` 는 08-30 에 259건, 08-31 에 88건 나왔고 모두
`"surface":"agent_core_tools"` 이며, 9월에는 0건이다. 지금 이 가드는 조용하고 옳다.

그러므로 §5.1 은 `agent_core_tools` 호출이 이미 하는 것과 같은 방식으로, 빼는
이름을 `~deferred_names` 로 `tools` 호출에도 넘긴다. 빼는 것을 빼기만 하고 검사에
알리지 않으면 이 RFC 는 **살아 있는 불변식 하나를 끄면서 그 사실을 적지 않은 것이
된다.** §6.2 의 "움직이면 안 되는 값" 에 이 항목을 넣었다.

넘길 값은 두 레인에서 모양이 다르다. `agent_core_tools` 는 `deferred_names_absent_from`
으로 **실제로 빠진 것**을 세야 한다 —— 그 레인에서는 대화가 한 번 부른 도구의 스키마가
다시 실려서, 선언만 읽으면 정당하게 있는 도구를 없다고 기대한다(위 주석이 기록한
2026-08-31 사고가 그것이다). 고정 레인에는 그 되싣기가 없다. 배열이 세션 상수이므로
(§4.3) 빠지는 집합은 "유예 대상 중 지명 안 된 것" 으로 정해진다. 이쪽이 더 단순하다.

#### 순서가 바뀐다

`allow = None` 이어도 배열은 지금과 **같은 도구를 다른 순서로** 담는다.
`List.partition` 은 각 편 안에서만 순서를 지키므로,
`always_loaded_builtin_tools @ named_of deferred_builtin_tools` 는
`descriptor_tools @ composition_tools` 와 다르게 섞인다. 앞선 초안의 "지금과 같은
바이트" 는 틀렸다.

해시는 이름순 정규화라 세션은 이 재배열만으로 새로 시작하지 않는다(§4.1). 남는 것은
캐시 접두사이고, 그것은 아직 안 잰 값이다(§4.3, §8).

항상 실리는 40개는 이 필드의 사정권 밖이다 —— 정책이 아니라 구조로.
`always_loaded_builtin_tools` 는 필터를 지나지 않고, tool 파일이 없는 6개는
`loading_of_tool` 이 `Always_loaded` 를 돌려주므로 애초에 `deferred_builtin_tools`
에 들어가지 않는다.

**두 레인 모두에서 읽는다.** 유예 레인에서도 지명 안 된 도구는 목록에서 빠진다.
구체적으로는 `:613`·`:625` 가 `deferred_builtin_tools` 를 그대로 `deferred` 목록에
넣는데, 여기도 `named_of` 를 지난 값을 넣는다. 한 선언이 레인마다 다른 뜻을 갖게
하지 않기 위해서다. 같은 파일 :595-599 가 같은 이유로 두 계열을 함께 나눈다.

> a declaration is either read wherever it can be written or it is a trap

유예 레인에서 아끼는 것은 스키마가 아니라 요약 한 줄이므로 이득은 작다. 대신
"이 Keeper 는 이 도구를 안 쓴다"가 한 곳에만 적힌다.

### 5.2 누가 정하나

운영자가 `<base_path>/config/keepers/<name>.toml` 에서 정한다. 그 파일 하나가
유일한 출처다.

- `masc_keeper_up` 인자가 없다. 코드가 그렇게 적어 두었다
  (`keeper_turn_up_config_persistence.ml:376-378`: "this axis has no
  `masc_keeper_up` argument, so the file is its only source").
- 대시보드에 읽기·쓰기 어느 쪽도 없다.
- 런타임은 호출 기록에서 이 목록을 **유도하지 않는다.** 유도하면 파생 값 위에
  게이트를 세우는 것이고(masc 규칙), 세션이 도는 중에 집합이 바뀐다. §2.2 의
  창 민감도가 그 유도가 왜 위험한지를 보여준다.

이 RFC 는 목록을 정하는 자리에 사람을 둔다. 여드레 호출 기록은 그 사람이 읽는
근거이지 런타임의 입력이 아니다.

### 5.3 언제 효력이 생기나 —— 그리고 도는 세션은 어떻게 되나

선언은 턴 준비 시점에 읽히지만(`keeper_run_tools_setup.ml:429-431`), 고정 레인에서
**효력이 생기는 순간은 세션 claim 이다.** 배열이 달라지면 `tool_surface_sha256` 이
움직이고, `reconcile_tool_surface` 가 새 세션 가지를 탄다(§4.1).

**정직한 답: 변경은 새 세션을 요구한다.** 도는 세션을 좁힐 방법은 없고, 만들지도
않는다.

운영자가 하는 일:

1. TOML 을 고친다.
2. 아무것도 더 하지 않는다. 다음 claim 이 새 세션으로 시작한다. 되돌리는 명령도,
   지우는 명령도 없다 —— `keeper_official_client_session_store.mli` 에 reset 이
   없고, `POST /api/v1/runtime/sessions/official-client/resolve` 는 `recovery_id`
   를 요구하는데 `Settled` 세션에는 그 id 가 없다.
3. 그 Keeper 의 다음 턴이 `bootstrap_floor_exceeded` 로 떨어지는지 본다(§4.2).
   떨어지면 그때는 운영자 resolve 가 필요하다. 이 값은 이 설계가 만드는 것이
   아니라 이미 있는 것이고, 표면을 줄이는 것 자체가 그 상태에서 나가는 출구다.

세션 하나를 버리는 대가가 작다는 근거는 §4.3 이다 —— 이 함대는 21.6시간에 일곱 번,
아무도 요청하지 않은 표면 이동을 이미 치렀다. `turn_count` 스냅샷은 근거로 쓰지
않는다(§4.2).

### 5.4 전제 조건 하나 —— 그리고 그것은 고침이 아니다

`reconcile_tool_surface` 는 **아무것도 기록하지 않는다.** 형제 경로인 자동 supersede
는 `:849-856` 에서 로그를 남기는데 이 가지는 남기지 않고, 턴마다 지문을 적는 곳도
없다. 그래서 지금 표면을 좁히면 N개의 대화를 버리고 그 사실의 증거를 0건 남긴다.

claim 시점에 지문과 "새로 시작/재개" 둘 중 무엇이었는지를 한 번 적는다.

**이것은 이 RFC 의 고침이 아니다.** 고침은 §5.1 이다. 이 기록이 없으면 §6 의 판정을
할 수 없어서 같은 변경에 함께 들어갈 뿐이고, 이 한 줄만 넣고 표면을 그대로 두는
단계는 없다.

### 5.5 단계 —— 각 단계가 동작을 바꾼다

**1단계.** §5.1 코드 컷 + §5.4 기록 + **여섯 antigravity Keeper 의 TOML 선언을
같은 변경에 넣는다.** 기전만 넣고 선언을 나중으로 미루지 않는다(§4.4, #31728).
선언은 여드레 호출 기록으로 사람이 고르고, 사흘 기록으로는 고르지 않는다(§2.2).
**여섯 선언은 붙임 이름과 내장 이름을 모두 담아야 한다** —— 한쪽만 적으면 다른
계열이 통째로 빠진다(§5.1). 세션 여섯 개가 한 번 새로 시작한다.

**2단계.** kidsnote-pr-jira-checker 의 커넥터 선언. **이 Keeper 한 명 기준, 여드레
창**으로 slack 은 받은 12개 중 11개 33.9 KB, atlassian 은 31개 중 25개 44.0 KB 가
미호출이다(§2.3 의 표는 일곱 전체가 안 부른 것이라 값이 다르다). 뒤로 미루는 이유는
하나다 —— 여드레 기록 중 나흘이 비어 있어(§2.2) 근거가 가장 얇고, 유일한
`claude_code` 레인이라 bootstrap 여유를 1단계에서 먼저 보고 싶기 때문이다. 코드
변경은 없고 파일만 바뀐다.

## 6. 무엇을 재서 성공을 판정하는가

### 6.1 움직여야 하는 값

| 값 | 지금 | 재는 법 |
|---|---|---|
| 고정 레인 요청당 스키마 바이트 (Keeper 별) | lane-smith 135,691 / edgar.a.poe 149,750 / code-reviewer 87,835 | wire-capture `kind:"request"` 행, blob 복원. **같은 직렬화로 전후를 재야 한다**(§1) |
| 여드레 미호출 몫 | 50,031,342 / 149,939,300 = 33.4% | §1 의 두 창을 조인 |

이 축이 닿을 수 있는 천장: 공통 내장 94개 중 `defer_loading` 을 선언한 54개(§3.2),
더하기 붙임 쪽 lane-smith ≤48,002 B(34.7%), edgar.a.poe ≤62,374 B(41.1%),
code-reviewer 0(붙임 카탈로그 없음). 실제로 얼마가 줄어드는지는 선언이 정하므로
여기에 목표 %를 적지 않는다. 아직 안 잰 값이다.

### 6.2 움직이면 안 되는 값

| 값 | 지금 | 왜 |
|---|---|---|
| `tools` 표면의 `keeper_model_tool_projection_mismatch` | 0 (2026-09-01..04, 로그 전체. 08-30 259건 / 08-31 88건은 모두 `surface:"agent_core_tools"`) | §5.1 이 빼는 이름을 이 검사에 넘기지 않으면 선언한 Keeper 의 **모든 턴**에서 `Log.Error` 가 난다. 이 값이 0에서 떠나면 검사가 아니라 검사를 끄는 변경을 한 것이다 |
| 고정 레인 연속 요청 배열 변화율 | 7 / 1,176 = 0.6% (§4.3, wire capture 창) | 선언 반영 배포에서 Keeper 당 한 번 늘고 그친다. 계속 늘면 선언이 턴마다 다시 읽히고 있다 |
| 유예 레인 연속 요청 배열 변화율 | 72 / 4,996 쌍 = 1.4% (같은 창, 같은 방법) | 이 선언은 후보를 줄일 뿐이므로 변화율은 그대로거나 내려간다. 올라가면 선언이 읽히면 안 되는 자리에서 읽히고 있다 |
| `bootstrap_floor_exceeded` | 여드레 분포 `0 / 21 / 5229 / 76 / 0 / 0 / 27 / 0` (§4.2) | 하루 5,229 를 포함한 분포라 **"기준선으로 돌아왔나" 는 판정 가능한 물음이 아니다.** 대신 이렇게 본다: 컷을 넣은 Keeper 가 컷 이후 이 실패를 내는지, 그리고 그것이 **연속 세 턴 이상 이어지는지.** 이어지면 그 Keeper 의 선언을 되돌린다 |
| `keeper_deferred_tool_allow_unnamed` 경고 (컷 이전 이름 `keeper_attached_tool_allow_unnamed`) | 0 (08-28..09-04 전 구간, 선언 0개) | 선언을 넣은 뒤 이 값이 0이 아니면 오타이거나 provider 가 꺼져 있다. **이 판정은 §5.1 의 합집합 보고를 전제로만 성립한다** —— 두 자리에서 각각 신고하면 올바른 선언도 0을 못 낸다 |

두 항목을 뺐다.

- **`config_error` 턴 수.** 앞선 초안은 "문자열 자체가 코드에 없음" 을 근거로
  0이라 적었는데, 그 문자열은 `error_domain.mli:91` 의 타입 이름이고
  `keeper_official_client_session_store.ml:807` 의 주석에도 있다. 로그에서도 09-03
  387건 / 09-04 153건이 잡히는데 전부 `preflight_config_error`(385)와
  `remote_ssh_shim_config_error`(2)라 이 물음과 무관하다. **판정할 수 있는 술어가
  없어서 뺀다.** §4.1 이 되돌아왔는지는 §5.4 가 남기는 claim 기록으로 본다.
- **"항상 실리는 47개의 미호출 수".** 47은 이 문서의 어떤 집합도 아니었다(§4.5).
  올바른 수는 40이고, 그 40개는 §5.1 의 필터를 **구조적으로** 지나지 않으므로
  세어서 지킬 것이 아니라 코드 모양으로 지켜진다. 게이트를 중복으로 두지 않는다.

### 6.3 판정에 쓰면 안 되는 것

`GET /api/v1/dashboard/tools?keeper=<name>` 의 `effective_keeper_surface` 를
근거로 쓰지 않는다. 2026-09-04 10:51 라이브에서 이 투영은 네 Keeper 에게
바이트까지 같은 95개 / 84,854 B / 같은 다이제스트를 돌려주는데(§3.2 가 바로잡은
94와 다른 값이 여기서 나온다), 저장소의
`tool_surface_sha256` 은 code-reviewer 만 일치하고 lane-smith·rondo·sangsu 는
다르다. 이 투영은 붙임 도구를 아예 담지 않아서(`tool_origin` 이
`Descriptor | Instruction_skill | Composition_skill | Composition_control` 넷뿐)
lane-smith 실제 표면의 34.9%인 48,002 바이트가 보이지 않는다. 파생 값 위에
게이트를 세우지 않는다는 규칙이 그대로 적용된다.

## 7. 하지 않는 것

- **항상 실리는 40개를 줄이지 않는다.** "20개쯤으로" 줄이자던 이전 계획은
  철회한다. 구조적으로도 §5.1 의 필터는 `always_loaded_builtin_tools` 를 지나지
  않고, tool 파일이 없는 6개는 `deferred_builtin_tools` 에 들어가지도 않는다(§4.5).
- **고정 레인에 목록(listing)을 만들지 않는다.** 부를 수 없는 도구의 이름을
  부르는 일이 된다(§3.1).
- **계열 단위로 자르지 않는다.** `github_*` 44개는 매일 쓰이고 Keeper 당 절반이
  죽어 있다(§2.3). 계열 단위는 두 답 다 틀린다.
- **호출 기록에서 목록을 유도하지 않는다.** 사흘 창에서 미호출이던 것 중
  13~33%가 그 앞 나흘에 불렸다(§8). 런타임이 이걸 하면 파생 값 위의 게이트다.
- **도구 개수·바이트 상한을 두지 않는다.** 상한은 증상을 덮고 어느 도구가
  사라졌는지 말하지 않는다.
- **두 번째 로스터·투영·그룹 축을 만들지 않는다.** #31728 이 지운 자리다.
- **세션을 자동으로 갈아 끼우지 않는다.** 이 설계가 더하는 표면 변경은 사람이
  파일을 고칠 때만 생긴다.

## 8. 미해결

1. **받은 집합과 호출 창의 비대칭.** 받은 쪽은 21.6시간, 호출 쪽은 여드레다.
   회전이 앞쪽 파일을 지우므로 이 조인은 오늘 이후 재현되지 않는다. 정하는 법:
   `keeper` + `tools_ref._blob.sha256` 를 하루 한 번 작은 파일로 남긴다.
2. **바이트 총량이 직렬화에 달려 있다.** 같은 창을 세 번 재서 435.1M / 439.6M /
   459.9M 을 얻었다(§1). 24% 편차가 어디서 오는지 —— 공백인지 유니코드
   이스케이프인지 배열 자체를 다르게 세는 것인지 —— 확인하지 않았다. 이 문서는
   비율만 근거로 쓰지만, §6.1 의 전후 비교를 하려면 재는 사람이 같은 직렬화를
   써야 한다. 정하는 법: wire capture 가 blob 의 원본 바이트 길이를 함께 적는다.
3. **`tool_call` 행에 레인 표시가 없다.** 유예 턴에서 부른 도구가 그 Keeper 의
   "불렸음"으로 잡힌다. 방향은 안전하다(안 쓰는 바이트를 실제보다 적게 신고한다).
   가장 영향이 큰 것은 analyst 로, 창 안에서 고정 38 요청 대 유예 816 요청이다.
   정하는 법: `tool_call` 행에 턴의 레인을 적거나 `turn_id` 로 turn-record 와
   조인한다.
4. **공식 클라이언트 네이티브 호출이 전부 로그에 남는지.** `core_builtin`
   (Execute/Read/Write/Edit/Grep/WebFetch/WebSearch) 은 남는 것을 확인했다. MCP
   브리지를 거치지 않는 호출이 있다면 그 도구들을 과대 신고한 것인데, 그 도구들은
   자르지 않는 집합이라 방향은 안전하다.
5. **13~33% 라는 창 민감도의 정확한 근거.** Keeper 별로 사흘 미호출 집합 중 그
   앞 나흘에 불린 것: analyst 9/72, code-reviewer 6/33, edgar.a.poe 20/81,
   lane-smith 28/85, rondo 17/71, sangsu 15/69. kidsnote-pr-jira-checker 는
   앞선 기록이 없어 0/92 다. 앞선 초안의 edgar.a.poe 18, sangsu 12 는 재현되지
   않아 바꿔 적는다. 여드레보다 긴 창에서 이 비율이 어디로 수렴하는지는 모른다.
6. **레인을 이름의 부재로 갈랐다.** 배열에 `keeper_tool_search` 가 없으면 고정
   레인으로 셌는데, `keeper_tools_agent_core_bundle.ml:612-616` 에는 목록이 없는
   경우가 하나 더 있다 —— 붙임 표면도 없고 유예 대상 내장도 없을 때다. 지금
   `config/tools` 145개 중 55개가 `defer_loading` 을 선언해서 이 조합이 나오지
   않지만, 확인한 것이 아니라 추론이다. 정하는 법: wire capture 행에 레인을
   직접 적는다.
7. **순서만 바뀐 배열이 캐시 접두사를 잃게 하는가.** §5.1 은 아무것도 선언하지
   않은 Keeper 의 배열도 다시 섞는다. §4.3 의 관측 일곱 건은 전부 내용이 바뀐
   경우라 이 물음에 답하지 않는다. 정하는 법: 아래 8번과 같은 실험을 순서만 바꾼
   배열로 한 번 더 한다.
8. **Z.AI·Ollama Cloud 가 캐시 접두사에 도구 배열을 넣는지.** §4.3 의 관찰은
   glm-5.3 에서 "아니오"라고 말하지만 통제 실험이 아니다. 정하는 법: 라이브 설정을
   복사한 스크래치 base 에서 같은 Keeper·같은 히스토리로 배열을 고정한 턴과 스키마
   하나를 더한 턴의 `cache_read_tokens` 를 비교한다.
9. **`Keeper_effective_tool_surface` 가 왜 붙임 도구를 빠뜨리는가.** 빠뜨린다는
   것과 정확히 44개 `github_*` 라는 것만 확인했고, 어느 호출에서 떨어지는지는
   추적하지 않았다. 이 RFC 와 별개로 이슈 하나가 필요하다.

닫은 항목 둘을 적어 둔다.

- **고정 레인 배열 변화율.** 앞선 초안은 잴 수 없다고 적었는데 §2 가 이미 쓰는
  wire capture 로 잴 수 있었다. 값은 §4.3 으로 옮겼다.
- **47 과 94 중 어느 집합인가.** 둘 다 아니다. 항상 실리는 집합은 40이다(§4.5).

## 9. 워크어라운드 기준 대조

masc 의 거부 기준 일곱 항목에 대해:

- 텔레메트리-as-fix 아님: 고침은 §5.1 의 배열 변경이다. §5.4 의 기록은 판정
  전제 조건이고, 그것만 넣는 단계는 없다고 §5.4 에 적었다.
- 문자열 분류기 추가 없음: 정확 이름 일치이고, 접두사 규칙을 명시적으로 거부한다.
- N-of-M 부분 패치 아님: 한 필터가 두 계열 전부에 걸린다.
- catch-all 추가 없음.
- 증상 억제형 상한 없음: 개수·바이트 상한을 두지 않는다(§7).
- 테스트 백도어 없음.
- 같은 오타를 N곳에서 N번 고치는 형태 아님.

이 설계가 스스로 인정하는 위험은 하나다. **#31728 이 지운 축과 모양이 같다.**
답은 §4.4 와 §5.5 다 —— 기전과 선언이 같은 변경에 들어가고, 선언 없는 기전은
이 RFC 의 산출물이 아니다.

### 9.1 이 RFC 가 두 번 인용한 파일이 이 RFC 를 반대한다

`tool_loading_declarations.mli:37-44` 의 마지막 문단이다.

> There is deliberately no "which tools defer" listing here. Such a list reads
> as a roster the moment something takes it as input rather than as a report,
> and a roster of tools loaded together is the group axis again. Loading
> several tools as a unit is already a composition entry
> (`keeper_compose_<name>`) ... and costs no schema bytes at all, because the
> model calls the one composition rather than the tools inside it.

두 가지를 말한다. 하나, **이름 목록은 그 자체로 로스터이고 그것이 #31728 이 지운
축이다.** 둘, **묶어서 싣는 문제의 답은 이미 있고 그것은 composition 이다.**

첫 번째는 인정한다. `tools.deferred_allow` 는 로스터다. 이 RFC 는 그것이 로스터가
아니라고 주장하지 않는다. 구별되는 점 하나만 적는다: #31728 이 지운
`keeper.tools.groups` 는 **그룹이라는 두 번째 이름 층**을 만들어 그룹 멤버십을 따로
맞춰야 했고, 이 필드는 도구가 이미 가진 이름을 그 Keeper 가 정의된 파일 한 곳에
적을 뿐 새 이름 층을 만들지 않는다. 이 구별이 얼마나 버티는지는 이 문서가 보증할
수 없고, 그래서 §5.5 가 선언을 같은 변경에 묶는다 —— 선언 0개인 기전으로 남으면
#31728 과 같은 근거로 지워지는 것이 맞다.

두 번째는 이 문제에 닿지 않는다. composition 은 **함께, 정해진 순서로, 데이터를
주고받으며 불리는** 도구 묶음이다(`compositions.nodes` 가 순서와 데이터 흐름을
적는다). §2.3 의 `github_*` 는 그 모양이 아니다. 다섯 Keeper 가 같은 44개를 받아
각각 23·21·20·19·16개를 쓰고, **쓰는 것들의 구성이 서로 다르다.** 이걸 composition
으로 풀려면 Keeper 마다 자기 부분집합을 담은 composition 을 하나씩 써야 하는데,
그건 로스터에 순서와 데이터 흐름이라는 안 쓰는 구조를 얹은 것이다. 그리고
composition 안의 도구는 모델이 직접 못 부른다. `github_search_code` 는 다섯 중
넷이 매일 직접 부른다.

**그래서 이 축이 더 복잡한 대신 사는 것은 하나다: 함께 불리지 않는 도구들에 대한
Keeper 단위 세밀도.** composition 은 함께 불리는 것을 묶고, 이 필드는 함께 불리지
않는 것 중 이 Keeper 가 안 부르는 것을 뺀다. 두 답이 겹치지 않는다.
