---
rfc: "0468"
title: "Librarian 은 자기 Keeper 의 눈으로 본다 — 나는 누구이고, 각 말은 누가 했는가"
status: Draft
created: 2026-09-23
updated: 2026-09-23
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0223-typed-connector-surfaces-presence-pull-speaker", "0456-librarian-output-contract", "librarian-lifecycle"]
implementation_prs: []
---

# RFC-0468 — Librarian 은 자기 Keeper 의 눈으로 본다

## 1. 원칙

Keeper 하나에 Librarian 하나다. Keeper 는 자기 Librarian 이 정리한 기억을 믿고, Librarian 은
자기 Keeper 의 편에서 정리한다. 누가 말했든 Librarian 은 자기 Keeper 를 기준으로 세계를 본다.
그래서 이 기억은 주관적이어도 된다.

모든 Keeper 를 바깥에서 보고 무엇이 맞는지 판단하는 일은 월드의 몫이다. 이 RFC 는 월드를
다루지 않는다. Librarian 에게 객관성이나 Keeper 사이의 일관성을 요구하지 않는다.

주관적으로 정리하려면 두 가지를 알아야 한다.

- 나(자기 Keeper)는 누구인가.
- 내가 겪은 말은 각각 누가 했는가. 운영자인가, 다른 Keeper 인가, 외부 사람인가, 호스트가
  넣은 문구인가.

지금 Librarian 은 이 두 가지를 입력에서 읽지 못하고 문맥으로 짐작한다.

## 2. 문제

### 2.1 Librarian 은 자기 Keeper 의 이름을 받지 않는다

`Keeper_librarian.input`(`lib/keeper/keeper_librarian.mli:40`)에 Keeper 의 정체를 담는 칸이 없다.
프롬프트 변수 9개(`config/prompts/librarian.md` 의 `template_variables`)에도 없다.

정체에 가장 가까운 것은 `keeper_instructions` 다. 이건 Keeper 의 시스템 프롬프트에 들어가는
글을 그대로 넘긴 것이라 Keeper 에게 말하는 2인칭("너는 …keeper 다")으로 쓰여 있다.
프롬프트는 이 글이 Librarian 에게 하는 지시가 아니라고 따로 막는다(`librarian.md` 12~17행).

2026-09-23 최근 Librarian 입력 60건(`<base-path>/.masc/exact-lane-run-payloads/librarian-exact-*/input-*.json`)
실측.

| 확인 | 결과 |
|---|---|
| Keeper 정체를 담는 입력 칸 | 없음 |
| `keeper_instructions` 가 2인칭("너는"·"당신은") | 60/60 |
| `keeper_instructions` 에 Keeper 이름이 하나라도 나옴 | 18/60. 자기 이름인지 남의 이름인지는 가릴 수 없다 |

대화에는 여러 Keeper 이름이 섞여 나온다(표본 하나에 `polisher` 33번, `code-reviewer` 7번,
`lane-smith` 5번). "@pr-updater 이거 해 주세요"가 보여도 pr-updater 의 Librarian 은 그게 자기
Keeper 인지 이름으로 알 수 없다.

### 2.2 대화 속 사람 쪽 말에 발화자가 없다

Librarian 은 대화를 AGENT_CORE 표준 메시지(`Agent_core.Types.message`)로 받고,
`message_to_text`(`lib/keeper/keeper_librarian.ml:152`)가 `[turn=N role=R]` 머리만 붙인다.
표준 메시지에는 발화자가 없다.

같은 60건에서 `role=user` 메시지 8개를 열어 보았다.

| 내용 | 개수 | 실제 발화자 |
|---|---|---|
| "지금은 자율 턴입니다. 이번 턴의 World State 와 …" | 7 | 호스트(`config/prompts/keeper.autonomous.wake.txt`) |
| "… 태그를 찍을 때까지 main 병합을 멈춰 주세요. 운영자 요청이에요." | 1 | 운영자 |

호스트가 넣은 문구와 운영자의 요청이 똑같이 `role=user` 로 보인다.

### 2.3 발화자는 저장돼 있지만 Librarian 에게 가는 길에서 빠진다

RFC-0223 P1 로 `Keeper_chat_store.chat_message` 에 `speaker`(`speaker_id`·`speaker_name`·
`speaker_authority`)가 생겼다(`lib/keeper/keeper_chat_store.ml:230`). 이 정보는
`counterpart_observations` 로만 Librarian 에게 간다(`keeper_librarian_input_sources.ml`,
`Keeper_counterpart_observation.t`).

`counterpart_observations` 에는 발화자가 있지만 대화 속 어느 메시지인지 가리키는 값이 없다.
프롬프트는 "같은 메시지가 대화와 observation 에 각각 보이면 증거 한 건"이라고 적어,
둘을 내용으로 짝지으라고 맡긴다. 호스트가 이미 아는 사실을 모델이 다시 맞추는 셈이다.
Keeper 가 직접 본 것은 60건 중 24건에만 `counterpart_observations` 가 있었다.

### 2.4 이 빈틈과 같이 보인 일

- 다른 Keeper 의 broadcast 한 건이 Keeper 7명의 기억으로 들어가면서, 누구는 "외부 화자의 주장,
  독립 확인 없음"으로, 누구는 자기 `constraint` 로 적었다. 같은 말을 누구의 말로 적을지가
  Librarian 마다 달랐다.
- masc-pro-builder 의 Librarian 은 wkbl 기억 11개를 "역할 무관"으로 지웠다. 그때 Keeper 는 wkbl
  일을 하고 있었다. Librarian 은 Keeper 의 역할 설명을 기준으로 삼았고, Keeper 가 실제로 겪는 일은
  기준이 되지 못했다.

두 일 모두 이 RFC 만으로 사라진다고 주장하지 않는다. 다만 "나는 누구이고 누가 말했나"를
짐작하는 상태에서는 Keeper 관점의 판단이 설 자리가 없다.

## 3. 결정

**호스트가 이미 아는 두 사실을 Librarian 입력에 붙인다. 모델이 문맥으로 되찾게 하지 않는다.**

### 3.1 자기 Keeper 의 정체

- `Keeper_librarian.input` 에 대상 Keeper 의 식별자(`Keeper_identity.Keeper_id.t`)를 담는 칸을
  더한다. 값은 Librarian 을 부른 레인이 이미 가진 Keeper 식별자다.
- 프롬프트에 그 식별자를 호스트가 붙인 자료로 보인다. 문장은 프롬프트 PR 에서 정한다.
- 값은 `Keeper_id` 라 소문자로 정규화돼 있다. 대화 속 `@Name` 과 대소문자가 다를 수 있다.
- `keeper_instructions` 는 그대로 넘긴다. 2인칭 글을 3인칭으로 고쳐 쓰지 않는다. 그 글이 누구에게
  한 말인지는 정체 칸이 알려 준다.

### 3.2 대화 속 사람 쪽 말의 발화자

- Librarian 이 받는 대화의 사람 쪽 말마다 발화자를 호스트가 붙인다. 단위는 메시지가 아니라
  **말 한 덩어리**다. 자율 턴의 user 메시지는 깨우기 문구와 답이 온 Ask 인용을 한 메시지로 붙여
  만든다(`keeper_unified_prompt.ml:2147-2149`). 한 메시지에 발화자가 둘이다. 넣는 자리에서 덩어리마다
  발화자를 싣거나 메시지를 나눈다. 둘 중 무엇으로 할지는 2단계 구현에서 정한다.

```ocaml
type speaker =
  | Host_prompt of host_prompt   (* 호스트가 넣은 문구: 자율 턴 깨우기 등 *)
  | Owner                        (* 커넥터를 거치지 않은 대시보드·로컬 요청 *)
  | Keeper of Keeper_identity.Keeper_id.t   (* 등록된 다른 Keeper *)
  | External of { channel : string; user_id : string option; user_name : string option }
  | Unknown                      (* 넣는 자리에서 발화자를 몰랐다 *)
```

  - `host_prompt` 는 호스트가 넣는 문구 종류를 닫힌 합타입으로 나열한다. 깨우기 문구는 운영자가
    바꿀 수 있으므로(`autonomous.wake_prompt`) 문구 내용으로 종류를 가르지 않는다. 넣는 자리에서
    정한다. `keeper_unified_prompt.ml:25-33` 도 같은 규칙을 적고 있다.
  - `Owner` 는 인증 사실이 아니다. 지금 `chat_speaker_of_request`
    (`server_routes_http_keeper_stream.ml:235-245`)는 커넥터 발화자가 없는 요청을 모두 `Owner` 로 둔다.
    이 RFC 는 그 뜻을 넓히지 않는다.
  - `Keeper` 는 `Keeper_id.t` 모양만으로 증명되지 않는다. 사람과 외부 봇도 같은 `Keeper_id.t` 를
    만들 수 있다(`keeper_identity.mli:20-24`). 넣는 자리에서 Keeper 등록부와 정확히 맞을 때만
    `Keeper` 다(`server_bootstrap_loops.ml:391-396` 이 같은 이유로 등록부 대조로 바꿨다). 지금은
    다른 Keeper 의 말이 `External` 로 들어온다(`server_bootstrap_loops.ml:205-208`, `384-388`).
  - `Unknown` 은 이 RFC 이전에 저장된 대화와, 넣는 자리가 발화자를 모르는 경우다. 다른 종류로
    채워 넣지 않는다.
- 발화자는 메시지를 넣는 자리에서 정해진다. 깨우기 문구는 호스트가 넣으므로 넣을 때 안다. 사람의
  말은 `chat_message.speaker` 가 이미 안다.
- 렌더러는 머리에 발화자를 적는다. 예: `[turn=3 role=user speaker=owner]`,
  `[turn=5 role=user speaker=host:autonomous_wake]`. 표기는 구현 PR 에서 정한다.
- 발화자를 모르는 메시지는 모른다고 적는다. 운영자나 호스트로 채워 넣지 않는다.

### 3.3 판단은 그대로 Librarian 에게

이 RFC 는 입력만 바꾼다. 누구의 말을 어떻게 기억할지, 무엇이 자기 Keeper 에게 중요한지는
Librarian 이 자기 Keeper 의 관점으로 판단한다. 새 Gate 나 검사를 더하지 않는다.

## 4. 바꾸지 않는 것

| 그대로 | 왜 |
|---|---|
| 월드의 판단 | 별개다. 이 RFC 는 Keeper 한 명의 Librarian 만 다룬다 |
| 출력 계약(RFC-0456) | 입력만 바꾼다 |
| `counterpart_observations` | 대화 밖의 외부 수신도 담는다. 3.2 가 생겨도 필요하다 |
| 흡수 관문 | 판정 대상과 방식이 같다 |

## 5. 대안

- **프롬프트에 "문맥으로 발화자를 추정하라"고 적는다.** 호스트가 아는 사실을 모델의 짐작으로
  바꾼다. 지금 상태가 이것이다.
- **메시지 본문 앞에 "[운영자]" 같은 글을 덧붙인다.** 본문과 출처가 섞여, 사람이 같은 글을 치면
  위조할 수 있다. 출처는 본문 밖 머리에 둔다.
- **`keeper_instructions` 앞에 이름을 문장으로 넣는다.** 역할 글과 정체가 섞인다. 정체는 따로 둔다.
- **대화를 `chat_message` 에서 다시 만든다.** AGENT_CORE 표준 메시지는 도구 호출과 결과를 담고,
  Librarian 은 그 범위를 atom 단위로 읽는다. 원천을 바꾸는 일은 이 RFC 보다 크다.

## 6. 열린 항목

- **발화자를 싣는 자리.** Librarian 이 읽는 AGENT_CORE 메시지에는 어느 `chat_message` 에서 왔는지
  가리키는 값이 없다. `chat_message.id` 로 나중에 잇기보다, 메시지를 넣는 자리에서 발화자를 같이
  싣는 쪽이 단순하다. `Agent_core.Types.message` 에는 이미 `name : string option` 과
  `metadata`(문자열 키 목록)가 있다. 둘 다 문자열이라 그대로 쓰면 발화자를 문자열로 다시 읽게 된다.
  쓰려면 한 곳에서 typed 로 쓰고 읽는 codec 이 있어야 한다. 이 선택은 producer → checkpoint →
  Librarian 경로를 확인한 뒤 2단계에서 정한다. 메시지 동등성·해시가 `metadata` 를 포함하는지도 본다.
- **공식 클라이언트 레인.** Claude Code·Codex·Antigravity 레인의 대화가 같은 경로로 오는지
  확인해야 한다.
- **다른 Keeper 의 메시지가 `Keeper` 로 구분되는가.** 지금 `speaker_authority` 는
  `Owner | External` 둘뿐이라 다른 Keeper 가 `External` 로 들어온다(예: `e-masc-the-leader`
  broadcast 가 `authority=external`). `Keeper` 를 따로 둘지는 발화자를 만드는 자리에서 정한다.

## 7. 검증

단위 테스트(구조만 본다. 프롬프트 문장을 고정하지 않는다):
- Librarian 입력을 렌더하면 자기 Keeper 식별자가 호스트 자료 칸에 한 번 나온다.
- 깨우기 문구와 운영자 메시지가 서로 다른 발화자 머리로 렌더된다.
- 발화자를 모르는 메시지는 모른다는 머리를 갖고, 운영자나 호스트로 렌더되지 않는다.

라이브:
- exact-lane 입력 payload 에서 정체 칸과 `role=user` 머리의 발화자를 센다.
  이 RFC 의 60건 표본과 같은 방법으로 잰다.
