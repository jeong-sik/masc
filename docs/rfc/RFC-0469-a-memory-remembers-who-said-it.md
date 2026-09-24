---
rfc: "0469"
title: "기억은 누구에게서 들었는지 남긴다 — 발화자를 문장이 아니라 출처 칸에"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0468-a-librarian-sees-the-world-through-its-own-keeper", "0456-librarian-output-contract", "0402"]
implementation_prs: []
---

# RFC-0469 — 기억은 누구에게서 들었는지 남긴다

## 1. 원칙

RFC-0468 로 Librarian 은 자기 Keeper 가 누구인지, 들은 말이 각각 누구의 말인지 입력에서 안다.
기억은 여전히 주관적이다. 이 RFC 가 남기려는 것은 "그 말이 맞는가"가 아니라 "나는 이걸
누구에게서 들었나"다. 그 Keeper 의 관점에서 본 출처다. 무엇이 맞는지는 월드가 판단한다.

## 2. 문제

### 2.1 발화자는 문장에만 남는다

기억의 출처는 `Keeper_memory_os_types.observation` 이다(`keeper_memory_os_types.mli:236`).

```ocaml
type observation =
  | Transcript
  | Board of board_ref
```

보드에서 읽은 기억은 글·댓글 id 가 구조로 남는다. 대화나 메시지에서 온 기억은 `Transcript`
하나뿐이다. 누가 말했는지는 Librarian 이 claim 문장에 적어 줄 때만 남는다. 문장에서 빠지면
아무 데도 남지 않는다.

### 2.2 실측 (2026-09-24, RFC-0468 배포 뒤)

Keeper 가 보낸 메시지 10건 × 받은 Keeper = 70쌍을 원문으로 판정했다(#38548 댓글).

| 판정 | 수 |
|---|---|
| 보낸 Keeper 의 말로 적음 | 23 |
| 잘못된 사람의 말로 적음 | 2 |
| 누구 말인지 없이 적음 | 3 |
| 기억에 안 넣음 | 42 |

기억에 들어간 28개 중 5개(18%)에서 발화자가 사라지거나 바뀌었다.

- glossary-maniac: 리더가 전한 운영자 결정을 "릴리스 오너 결정"으로 적었다.
- code-reviewer: 전한 리더를 빼고 "운영자 규칙"으로 적었다. 보드 글에서도 읽어서 `basis.board` 에는
  리더 글이 남았지만, 메시지에서 온 부분에는 구조로 남은 게 없다.
- pr-updater, code-reviewer: 다른 Keeper 의 진단과 규칙을 출처 없이 자기 교훈처럼 적었다.

문장이 틀려도 되돌릴 근거가 없다. 나중에 Keeper 가 "이걸 누가 말했지?"를 확인하려 해도, 볼 곳이
문장뿐이다.

## 3. 결정

**Librarian 은 claim 을 어느 발화에서 읽었는지 입력의 참조로만 적는다. 발화자는 호스트가 그
참조로 찾아 붙인다.**

### 3.1 입력: 발화마다 참조

- Librarian 이 받는 대화의 사람 쪽 말(RFC-0468 §3.2 의 `speaker=` 머리가 붙은 줄)과
  `counterpart_observations` 의 각 항목에 짧은 참조를 붙인다. 예: `u1`, `u2`, `o1`.
- 기억 id 를 `m1` 처럼 보여 주는 방식(`keeper_librarian.ml:194` `surrogate_id_of_index`)과 같다.
  모델은 긴 id 를 옮겨 적지 않는다.

### 3.2 출력: 참조 하나

- `new_claims` 의 각 claim 에 `heard_in` 을 더한다. 값은 `u…`/`o…` 참조 하나나 `null` 이다.
- 파서는 참조를 호스트가 붙인 발화자로 바꾼다. 입력에 없는 참조는 답 전체를 거절한다. `m…` 도
  그렇다(`keeper_librarian.ml:191` 주석, `Supersedes_unknown_memory_id`·`Claim_schema_mismatch`).
  `fact_of_json` 은 입력 맥락이 없으므로 `by_surrogate` 같은 번역 단계가 따로 필요하다.
- 모델은 발화자 이름을 쓰지 않는다. 그래서 발화자를 지어낼 수 없다.

### 3.3 저장: 들은 곳

```ocaml
type observation =
  | Transcript                    (* 자기 턴 기록. 누구에게서 들은 게 아니다 *)
  | Heard of Keeper_input_speaker.t   (* 이 발화자에게서 들었다 *)
  | Board of board_ref
```

- `Heard` 는 직접 들은 사람만 담는다. 리더가 "운영자 결정"을 전했으면 `Heard (Keeper leader)`다.
  "운영자가 정했다"는 내용은 문장에 남는다. 그래서 전달 사슬의 첫 고리가 구조로 남는다.
- 호스트 문구(자율 턴 깨우기)에서 읽은 claim 은 `Heard (Host_prompt …)`다.
- 이 RFC 이전의 기억은 `Transcript` 로 남는다. `Transcript` 는 계속 유효한 생성자라 호환 reader 가
  아니다.

### 3.4 recall

- recall 이 기억을 보여 줄 때 `heard_from=keeper:e-masc-the-leader` 처럼 출처를 같이 보인다.
  지금 `basis=observed board=p-… comment=…` 를 보이는 자리(`keeper_memory_os_render.ml:9-15`)다.
- Keeper 는 그 기억을 누구에게서 들었는지 문장을 믿지 않고도 안다.

## 4. 바꾸지 않는 것

| 그대로 | 왜 |
|---|---|
| 문장에 행위자를 적으라는 프롬프트 규칙 | 문장은 사슬 전체("리더가 전한 운영자 결정")를 담는다. 구조 칸은 첫 고리만 담는다 |
| 기억할지 말지 | Librarian 의 판단이다. 들은 말을 모두 기억하게 하지 않는다 |
| 월드 | 별개다 |
| 흡수 관문 | 흡수는 출처가 다른 claim 을 묶을 수 있다. 묶인 claim 의 출처를 어떻게 합칠지는 §6 |

## 5. 대안

- **모델이 발화자 이름을 직접 적는다.** 지어낼 수 있다. 호스트가 아는 사실을 모델이 다시 쓰게 된다.
- **claim 문장에서 발화자를 뽑는다.** 문자열 분류다.
- **프롬프트만 고쳐 "항상 발화자를 적으라"고 한다.** 지금도 그렇게 적혀 있고 18% 가 빠졌다.
  구조로 남지 않으면 빠진 것을 알 수도 없다.
- **`basis` 에 발화 전체(메시지 id)를 남긴다.** 네이티브 레인 메시지에는 안정된 id 가 없고,
  발화자만으로 "누구에게서 들었나"는 답이 된다.

## 6. 열린 항목

- **흡수·교정 때의 출처.** 흡수된 claim 들의 `Heard` 가 서로 다를 때 새 claim 의 출처를 어떻게
  할지. 후보: 새 claim 이 자기 `heard_in` 을 따로 적는다. 흡수가 출처를 물려주지 않는다는 지금 규칙
  (`librarian.md` "묶는다는 이유만으로 출처를 물려주지 마세요")과 같은 방향이다.
- **여러 발화에서 읽은 claim.** 참조를 하나만 받을지, 목록을 받을지. 목록이면 "여러 사람이 말했다"를
  확신의 근거로 세는 문제(RFC-0468 조사에서 본 7벌 복사)를 다시 봐야 한다.
- **공식 클라이언트 레인.** 대화에 사람 쪽 줄이 없어서 `o…` 참조만 쓸 수 있다(#38548 항목 1).
- **Codex 같은 에이전트 세션.** 지금 `Owner` 로 들어온다(#38548 항목 2). `Heard Owner` 로 남으면
  운영자에게서 들은 것처럼 보인다.

## 7. 검증

단위 테스트(구조만):
- 입력의 사람 쪽 발화와 counterpart 항목마다 참조가 한 번씩 붙는다.
- `heard_in` 이 입력 참조를 가리키면 그 발화자가 `Heard` 로 저장된다.
- 없는 참조는 답 전체를 거절한다. `null` 의 저장값은 §8 조건 1 에 따른다.
- recall 렌더에 `heard_from` 이 나온다.

라이브:
- RFC-0468 §9 와 같은 방법으로 Keeper 발화자 메시지와 새 기억을 짝지어 원문으로 판정한다.
  메시지에서 온 기억 중 `Heard` 가 붙은 비율과, `Heard` 와 문장의 행위자가 어긋나는 수를 센다.

## 8. 적대적 리뷰 뒤 조건 (2026-09-24)

이 RFC 는 아래를 풀기 전까지 구현하지 않는다.

1. **누락이 보여야 한다.** `heard_in: null` 을 `Transcript` 로 저장하면 "자기 턴"과 "발화자를
   빠뜨림"이 같은 값이 된다. 2.2 의 누락 3건이 그대로 가려진다. `heard_in` 을 필수로 하고 자기 턴을
   뜻하는 값을 따로 두거나, `null` 을 `Transcript` 와 다른 값으로 저장해야 한다.
2. **발화자 모델이 둘이다.** `Keeper_counterpart_observation.authority`(`user_id` 가 없는 `Keeper`
   허용)와 `Keeper_input_speaker.t` 가 다르다. `o…` 를 저장 타입으로 바꾸는 규칙이 필요하다. 같은
   발화가 대화와 counterpart 에 둘 다 있으면 참조도 둘이 된다.
3. **참조가 가리키는 발화자가 없을 수 있다.** `speaker=unknown`·`invalid`·`duplicate` 줄과, Ask 답을
   여럿 담은 깨우기 메시지다. 깨우기 메시지를 `Heard (Host_prompt …)` 로 두면 실제로 말한 사람(Ask
   답한 사람)을 가린다. 문장보다 구조가 더 틀리게 된다.
4. **저장 타입.** `Keeper_input_speaker.t` 는 메시지 metadata 용이고 `Keeper_ask`·`Agent_core` 에
   기댄다. 영구 기억에 넣으면 그 변형이 바뀔 때마다 기억을 hard cut 해야 한다(#38548 항목 2 가 바로
   그런 변경이다). `External.user_name` 같은 자유 글도 recall 로 들어간다. Memory OS 가 가진 좁은
   타입이 낫다.
5. **병합 규칙.** `merge_observation`(`keeper_memory_os_current.ml:1172`)은 출처 하나만 남긴다.
   여러 Keeper 에게서 들은 claim 은 처음 출처만 남는다. 이걸 의도로 적을지 정한다. 반복을 확신으로
   세지 않는다는 장점이 있다.
6. **어느 회차가 참조를 싣나.** counterpart 는 기억 회차만 받는다. continuity·working_context 회차와
   `previous_working_state`(문장)에서 온 claim 은 참조가 없다.
7. **먼저 확인할 것.** 커밋 저널 항목은 trace 를 갖고(`keeper_librarian.ml:461-464` 의
   `origin.trace_id` 주석), 메시지 metadata 에는 발화자가 있다. 새 칸 없이 나중에 발화자를 복원할 수
   있으면 이 RFC 는 필요 없다. durable truth 가 망가진다고 말하기 전에 이 길을 배제해야 한다.
8. **근거가 작다.** 메시지 10건, 기억 28개다. 일주일 뒤 같은 방법으로 다시 판정해 누락률을 본다.
