---
rfc: "0424"
title: "디스크에 있고 메모리에 없는 것에 이름을 준다 — 후보 원장의 286MB 를 안 들고 있기 위해"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
supersedes: null
superseded_by: null
related: ["0423"]
---

## 1. 문제

`keeper_board_attention_candidate` 의 원장 캐시가 살아있는 힙의 **220~269MB** 를
차지한다. 2026-09-05 측정, RFC-0423 이 다룬 실행 기록 다음으로 크다.

무엇이 그 안에 있는지는 파일이 답한다. `~/.masc/board_attention_candidates/`,
19파일 13,049행, 합계 337MB:

| 필드 | 크기 | 비중 |
|---|---|---|
| **`judgment_request`** | **286MB** | **85%** |
| `signal` | 34.6MB | 10% |
| `status` | 15.0MB | 4% |
| 나머지 | <1MB | |

### 목록은 그것을 읽지 않는다

이 원장을 목록으로 읽는 곳은 둘이다.

```
lib/keeper/keeper_board_attention_worker.ml               judgment_request 참조 0회
lib/keeper/keeper_board_attention_quarantine_command.ml   judgment_request 참조 0회
```

읽는 곳은 판정 경로 하나이고, 그것도 **판정할 후보 하나**에 대해서다
(`singleton_judgment_request`, `keeper_board_attention_exact_flow.ml`).

즉 RFC-0423 이 다룬 것과 구조가 같다. 목록이 안 읽는 것을 목록을 위해 들고 있다.

## 2. 왜 RFC-0423 의 방법이 그대로 안 되는가

시도했고 되돌렸다. 2026-09-05, 커밋하지 않음.

캐시가 채워질 때 `judgment_request` 를 `` `Null `` 로 두었더니 이렇게 됐다.

```
FAIL worker callback integration: judgment request must be an object
```

| 스위트 | main | 시도 |
|---|---|---|
| `test_keeper_board_attention_candidate` | 20/20 | **10건 실패** |
| `test_keeper_board_attention_worker` | 38/38 | **27건 실패** |

원인은 타입이다.

```ocaml
judgment_request : Yojson.Safe.t
```

타입은 임의 JSON 을 허용하지만 **코드는 객체임을 가정한다.** 검증
(`canonicalize ~context:"keeper_context"`, `validate_finite_json`)과 소비자가
`` `Assoc `` 를 기대한다. `` `Null `` 은 타입이 허용하는 값이면서 불변식을 깨는 값이다.

RFC-0423 이 통했던 이유는 그쪽 타입이 다르기 때문이다.
`Exact_input of Yojson.Safe.t` 는 `` `Null `` 을 **정상값으로 이미 다루고 있었다** —
`projected_run_of_entry` 가 그렇게 쓰고, 목록이 그 상태로 렌더된다. 여기는 아니다.

**두 필드가 같은 모양처럼 보였지만 불변식이 달랐다.** 그 차이를 확인하지 않고
시작한 것이 실패의 원인이다.

## 3. 제안

"안 실렸다"를 **표현 가능한 상태**로 만든다.

```ocaml
type judgment_request =
  | Loaded of Yojson.Safe.t
      (** 이 값이 곧 요청이다. 지금까지의 모든 값이 여기 해당한다. *)
  | Not_loaded
      (** 저장소의 행에는 있고 이 복사본에는 없다. 목록이 읽지 않는 값을
          목록을 위해 들고 있지 않기 위해서다. *)
```

그러면 컴파일러가 60군데의 참조를 전부 짚어 주고, 각 자리에서 어느 쪽인지
결정하게 만든다. `` `Null `` 로 두는 것과 다른 점이 여기다 — 그때는 잘못된 값이
검증까지 조용히 흘러갔고, 지금은 컴파일이 멈춘다.

### 3.1 어디가 어느 쪽인가

| 자리 | 무엇 |
|---|---|
| 디코드(`candidate_of_json`) | 항상 `Loaded` — 행에는 늘 있다 |
| 캐시(`apply_decoded_rows`) | `Not_loaded` 로 바꿔 담는다 |
| 직접 읽기(`latest_candidates`) | `Loaded` 그대로 — 판정이 여기서 읽는다 |
| 검증(`validate_finite_json` 등) | `Loaded` 에만 적용. `Not_loaded` 는 검증할 대상이 아니다 |
| 직렬화(`candidate_to_json`) | `Not_loaded` 를 쓰려 하면 **에러** — 아래 3.3 |
| 판정(`singleton_judgment_request`) | `Loaded` 를 요구한다 |

### 3.2 판정 경로가 읽는 법

`load_judgment_request ~base_path ~keeper_name ~candidate_id` 가 저장소를 읽어
그 후보의 `Loaded` 를 돌려준다. 판정은 한 번에 하나이므로 전체 읽기 한 번이다.

프롬프트와 실행 기록(`Exact_input`)이 **같은 읽기의 값**을 쓴다. 두 번 읽으면
기록이 프롬프트와 다른 것을 말할 수 있다.

### 3.3 쓰기가 안 실린 값을 쓰면

`Not_loaded` 를 직렬화하려는 것은 **저장소에 있는 값을 없는 값으로 덮어쓰는
일**이다. 조용히 `` `Null `` 을 쓰면 그 후보는 다시는 판정될 수 없다.

그러므로 직렬화는 `Not_loaded` 에 대해 에러를 돌려주고, 쓰기 경로는 항상
`Loaded` 를 들고 온다. 컴파일러가 이것을 강제하지는 못하지만 — 두 생성자 모두
같은 타입이므로 — 런타임에서 조용히 넘어가지는 않는다.

더 강하게 하려면 쓰기용 타입과 읽기용 타입을 나눌 수 있다. 3절의 범위를 넘으므로
대안으로만 적는다(7절 (c)).

## 4. 무엇을 하지 않는가

- **파일 형식을 바꾸지 않는다.** 행은 지금 그대로이고, 기존 파일이 그대로 읽힌다.
- **보유 정책을 바꾸지 않는다.**
- **`signal`(34.6MB)과 `status`(15MB)는 건드리지 않는다.** 목록이 읽는다.
- **다른 원장에 적용하지 않는다.** 이 타입은 이 필드의 것이다.

## 5. 검증

| 무엇 | 어떻게 |
|---|---|
| 목록이 안 바뀐다 | `load_candidates` 결과의 다른 필드가 변경 전후 동일 |
| 판정이 요청을 받는다 | 후보를 쓰고 → 판정 경로 → 프롬프트에 요청 내용이 있다 |
| 안 실린 값을 못 쓴다 | `Not_loaded` 로 직렬화 시도가 에러 |
| 메모리가 준다 | `Obj.reachable_words` 로 캐시를 저울에 단다 |
| 기존 계약 | `test_keeper_board_attention_{candidate,worker}` 가 그대로 통과 |

마지막 것이 이 RFC 의 성패다. 실패한 시도에서 37건이 깨졌으므로, 그 37건이
초록인 것이 "타입으로 하면 된다"의 증거다.

메모리는 숫자로 기록한다. 목표는 **캐시가 붙드는 것이 원장 바이트의 20% 이하**다.

## 6. 위험

**판정 경로에 I/O 가 는다.** 지금은 메모리 조회다. 판정은 한 번에 하나이고
저장소가 최대 27MB 이므로 수십 밀리초일 수 있다. RFC-0423 의 `get` 보다 무겁다 —
거기는 한 행이었고 여기는 전체 읽기다. 측정하지 않았다.

줄이려면 오프셋을 기억하는 방법이 있으나, 이 원장은 압축과 재작성이 잦아
오프셋 무효화가 RFC-0423 보다 자주 일어난다. 먼저 단순한 쪽으로 하고 측정한다.

**60군데를 건드린다.** 그중 34곳이 테스트다. 컴파일러가 짚어 주므로 누락은
없으나, 리뷰 부담이 있다.

## 7. 대안

**(a) 그냥 둔다.** RFC-0423 이 493MB 를 없애면 live 가 2.2GB 가 된다. 269MB 는
12%다. 다음 축(`checkpoint_codec` 160MB, `dated_jsonl` 155+147MB)을 먼저 보고
판단할 수도 있다.

**(b) 원장을 나눈다.** `judgment_request` 를 별도 파일에 두고 후보 행은 참조만
갖는다. 타입 변경이 없고 목록이 자연히 가벼워진다. 다만 두 파일의 일관성을
지켜야 하고, 원장의 원자적 쓰기 계약이 깨진다.

**(c) 읽기 타입과 쓰기 타입을 나눈다.** `Not_loaded` 를 쓰기 경로가 아예 표현할
수 없게 된다. 가장 안전하지만 타입이 둘로 늘고 변환이 생긴다.

## 8. 측정 근거

전부 2026-09-05, 이 워크스페이스.

```
live 힙                                    2.71GB
keeper_board_attention_candidate.ml:1467   220~269MB  (2위)
board_attention_candidates/                337MB / 13,049행 / 19파일
  judgment_request                         286MB  (85%)
  signal                                    34.6MB (10%)
  status                                    15.0MB (4%)
목록 소비자의 judgment_request 참조         0회 (worker, quarantine_command)
```

실패한 시도의 결과:

```
test_keeper_board_attention_candidate   main 20/20 → 시도 10건 실패
test_keeper_board_attention_worker      main 38/38 → 시도 27건 실패
실패 문구: "judgment request must be an object"
```
