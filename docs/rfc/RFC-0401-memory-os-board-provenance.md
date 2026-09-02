---
rfc: "0401"
title: "Memory OS: an observed fact names the Board post it was read from — RFC-0251 §3 is settled as (a)"
status: Draft
created: 2026-09-02
updated: 2026-09-02
author: vincent
supersedes: []
superseded_by: null
related: ["0247", "0251", "0257", "tui-operator-ia"]
---

## 1. 결정

RFC-0251 §3 가 미결로 남긴 keeper 간 기억 공유는 **(a)** 로 정한다. 공용 저장소 층을 만들지 않는다. keeper 사이의 지식은 Board 로 오가고, 각 keeper 는 Board 에서 읽은 것을 자기 저장소에 자기 판단으로 적는다.

그 대신 저장소가 **어디서 읽었는지** 를 typed 로 남긴다. 지금은 Board 에서 온 사실인지 알 길이 claim 본문에 `p-…` 문자열이 우연히 들어 있는지뿐이다. 2026-09-02 실측(`docs/research/2026-09-02-shared-agent-memory-research-r1.md` §1): 711건 중 Board 를 언급하는 사실 49건, post id 를 적은 사실 12건. 이 수치는 정규식이고, 그래서 신뢰할 수 없다.

## 2. 왜 (a) 인가

1. 역할이 다른 agent 사이의 무차별 공유는 성능을 떨어뜨린다. LLMA-Mem(arXiv 2604.03295) §4.5.1 에서 local 저장소가 shared·hybrid 를 세 지표 모두에서 이겼고, 이유는 다른 역할의 경험을 꺼내 쓰는 간섭이었다. masc 의 keeper 는 역할이 뚜렷하다(리뷰, triage, 사실 확인, 정리).
2. 빈도로 승격할 재료가 없다. 12 저장소에서 keeper 간 동일 claim 이 0건이다. RFC-0247 의 06-16 실측에서도 `_shared` 의 산출 17건이 전부 조정 상투어였다.
3. 공용 층을 두려면 범위 있는 검색, 시간 순 대체, 출처, 정책 통제 전파 넷이 필요하다(Governed Shared Memory, arXiv 2606.24535). 그중 masc 에 없는 둘(범위 검색, 정책 전파)은 Board 가 이미 다른 형태로 갖고 있다. Board 는 hearth 로 범위를 가르고 verifier·judge 판정을 거친다.
4. RFC-0244 는 per-keeper 격리를 sandbox-containment 속성으로 명시 거부했다(RFC-0365:215). (b) 는 그 결정을 뒤집는 일이고, 그 이득을 잴 벤치마크가 문헌에 없다.

(b) 는 닫지 않는다. Board 출처가 typed 로 쌓이면 "어떤 분류의 사실이 실제로 Board 를 타고 다른 keeper 저장소에 도달하는가" 를 잴 수 있고, 그 수치가 (b) 를 다시 열 근거가 된다.

## 3. 무엇을 바꾸나 (이 RFC 의 조각 1, PR 동반)

### 3.1 타입

```ocaml
type board_ref = { post_id : string; comment_id : string option }
type observation = Transcript | Board of board_ref
type basis = Observed of observation | Derived of derivation list
```

`Observed` 가 관측의 출처를 든다. `Transcript` 는 keeper 자신의 턴 기록이고, 지금까지의 모든 observed 사실이 이것이다. `Board` 는 글과, 있으면 댓글을 가리킨다.

### 3.2 wire

- `{"kind":"observed"}` 는 그대로 `Transcript` 다. 디스크의 모든 스냅샷이 그대로 읽힌다. 호환 reader 가 아니라 이 스키마의 정의다.
- `{"kind":"observed","board":{"post_id":"p-…"}}` 와 `{"kind":"observed","board":{"post_id":"p-…","comment_id":"c-…"}}` 가 추가된다. 필드 집합은 정확히 이 셋 중 하나여야 한다.
- id 는 `Board_types.Post_id.of_string` / `Comment_id.of_string` 으로 검사한다. Memory OS 가 문법을 따로 적지 않는다.
- 존재 여부는 쓰기 시점에 검사하지 않는다. 참조는 "무엇을 인용했는가" 이고, 글이 아직 있는지는 읽는 쪽의 질문이다. source-bound 사실이 recall 때 파일 바이트로 재검증되는 것과 같은 자리다. 이 재검증은 조각 2 다.
- `memory_id` 는 여전히 claim 바이트만의 digest 다. 출처가 다른 같은 문장은 같은 사실이고, 두 번째 관측은 reinforcement 로 센다.

### 3.3 생산자

- librarian: `new_claims[]` 에 선택 필드 `board_post_id`, `board_comment_id`. 문법에 맞지 않는 id 는 다른 잘못된 claim 필드와 같이 그 claim 을 거부한다. 프롬프트(`config/prompts/librarian.md`) 출력 스키마에 두 필드를 적었다.
- `keeper_memory_write`: 파라미터 `board_post_id`, `board_comment_id`. derivation(`rule_id`/`premise_ids`)이나 `source_path` 와는 같이 쓸 수 없다. 오류 종류 넷을 닫힌 타입으로 추가했다: `board_ref_invalid`, `board_comment_without_post`, `board_ref_with_derivation_unsupported`, `board_ref_with_source_path_unsupported`.

### 3.4 소비자

- recall 렌더: `basis=observed board=p-… comment=c-…`. 모델이 Board 도구로 열 수 있는 id 그대로이고 문장은 없다.
- 같은 claim 의 재관측(merge): 관측은 파생보다 앞서고, Board 참조는 transcript 보다 앞선다. Board 참조 둘은 먼저 것을 지킨다.
- 대시보드 TS 디코더는 `board` 를 받는다. health 집계의 observed 수는 둘을 합친다.

## 4. 판정 기준

1. 배포 일주일 뒤 `basis.board` 가 있는 사실 수. 지금 정규식 추정 12건보다 커야 하고, 그 수는 jq 로 센다.
   `jq '[.facts[] | select(.basis.board)] | length' <base-path>/.masc/config/keepers/<k>.memory-current.json`
2. `basis.board.post_id` 가 Board 에 없는 글을 가리키는 비율. 이것이 조각 2(recall 재검증)의 입력이다.
3. librarian 이 `board_post_id` 를 잘못 적어 claim 이 거부된 횟수. 로그의 librarian parse 실패에서 센다. 이 수가 크면 프롬프트 문장을 고친다.

## 5. 조각 2 이후 (이 RFC 범위 밖)

- recall 때 Board 참조 재검증: 글이 삭제·만료됐으면 source-bound 처럼 typed 무효화 표시를 넣는다.
- Board 글을 읽은 턴에서 librarian 입력에 그 글의 id 목록을 typed 로 넘겨, 모델이 id 를 베끼지 않고 고르게 한다.
- 도구 사용법 lesson(오늘 191/324)이 Board 를 타고 다른 keeper 에 도달하는 비율. (b) 를 다시 열지의 근거.

## 6. 비목표

- 공용 저장소 층. 빈도·점수·verifier 점수에 의한 승격. RFC-0251 의 "record well, do not value" 를 지킨다.
- 기존 스냅샷 변환. 스키마가 이전 wire 를 포함하므로 필요 없다.
