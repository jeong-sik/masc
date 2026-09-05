---
rfc: "0419"
title: "스트림 반복 감지: 반복은 문단이 아니라 주기다 — 개행 없는 루프도 세 번째 반복에서 멈춘다"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
supersedes: []
superseded_by: null
related: ["0271", "0418"]
---

## 1. 문제

스트림 반복 감지기(`Complete_stream_state.repeating_paragraph`, #32997, 2026-09-04)는
생성이 같은 **문단**을 세 번 쓰면 거기서 스트림을 끝낸다. 문단은 `\n` 으로 나눈
40바이트 이상의 줄이다. 그 규칙이 잡는 붕괴와 못 잡는 붕괴가 오늘 같은 keeper 에서
같은 날 나왔다.

### 1.1 실측 (2026-09-05, `~/me/.masc/keepers/*.decisions.jsonl*`)

| 붕괴 모양 | 끝난 이유 | 턴 | 턴당 중앙값 | 합계 |
|---|---|---|---|---|
| 문단 반복 (polisher) | `sse/repeating_generation`, 3번째 문단에서 | 7 | 15초 | 197초 |
| 문단 반복 (sangsu) | 같음 | 4 | 29초 | 107초 |
| **한 줄 반복 (sangsu)** | **`accept_rejected`, `max_tokens` 까지 달린 뒤** | **12** | **100초** | **1,592초** |

못 잡은 쪽의 모양(sangsu 턴 1293, checkpoint messages[7097]): 31,347바이트가
**개행 없이 한 줄**이고, 82바이트짜리 문장 하나가 379번 이어진다. 안에 `</think>`
마크업이 본문으로 섞여 있다. `\n` 이 없으니 `repeating_paragraph` 에게는 40바이트
이상의 "문단" 이 하나도 없고, 생성은 provider 의 토큰 상한(65,536)까지 달린 뒤
accept 가 `no_usable_progress` 로 거부한다. 같은 붕괴가 문단 모양이면 15~29초에
끝나고, 한 줄 모양이면 100초를 태운다. 하루 한 keeper 에서 26분이다.

거부된 응답이 checkpoint 에 남아 다음 턴을 다시 붕괴시키던 문제는 별건이고
#33281 이 고쳤다. 이 RFC 는 그 앞, 생성이 진행되는 동안 언제 멈추느냐만 다룬다.

### 1.2 왜 문단이었나

#32997 의 근거는 "반복되는 단어나 줄은 보통 산문이다 — 목록, 표, 코드가 짧은
문자열을 반복한다" 였다. 맞는 관찰이지만 결론이 한 발 넘었다. 짧은 반복이 산문인
것과, **긴 단위를 세 번 연달아 쓰는 것이 문단 경계를 지나야 한다**는 것은 다른
말이다. 40바이트와 3번은 이미 정한 기준이고, 그 기준을 개행에 묶은 것이 구멍이다.

## 2. 반복은 어디서 잡을 수 있나

| 층 | 무엇 | 지금 masc | 비고 |
|---|---|---|---|
| **샘플러** | `repetition_penalty` (Keskar 외 2019, CTRL), `no_repeat_ngram_size` (HF), llama.cpp `--repeat-penalty`/DRY | OpenAI-호환 wire 에 `frequency_penalty`/`presence_penalty` 를 **보내지 않는다**. Ollama 네이티브 옵션(`repeat_penalty`)은 `/api` 백엔드에만 실린다 | ollama.com/v1 은 두 penalty 를 받는다 (docs.ollama.com/openai, 2026-09-05 확인) |
| **스트림** | 생성 도중 반복 단위를 보고 끊기 | `repeating_paragraph`: `\n` 단위, ≥40B, 3회 | 이 RFC 의 자리 |
| **accept** | 응답이 끝난 뒤 `max_tokens`/무진전 거부 | 있음 (RFC-0271 §4.5) | 이미 다 태운 뒤다 |
| **lane** | 거부된 응답을 checkpoint 에서 떼기 | #33281 | 다음 턴을 지킨다 |

샘플러 층은 provider 가 갖고 있다. penalty 는 모델의 모든 출력을 바꾸는 손잡이라
붕괴 하나를 막자고 켜면 정상 출력의 어휘 분포까지 바뀐다. 측정 없이 켤 수 없고,
켜도 감지는 아니다. 스트림 층은 우리가 가진 유일한 "도중" 이고, 이미 한 규칙이
있다. 그 규칙의 단위를 고치는 것이 가장 작은 변화다.

## 3. 판단

- 반복의 단위는 **바이트열의 주기**다. 문단은 주기의 한 경우다.
- 기준은 새로 만들지 않는다. 40바이트와 3회는 #32997 이 정했고, 3회는 keeper
  턴 루프의 `repeated_assistant_text_yield_threshold` 와 같은 수다. 이 RFC 는
  그 두 수에 붙어 있던 "개행 경계" 조건만 뺀다.
- 정확 일치만 본다. 유사도, 압축률, n-gram 통계는 새 상수를 만든다.
- thinking 블록은 지금처럼 보지 않는다. 답으로 가는 사고를 중간에 끊는 비용이
  붕괴 비용보다 크다는 #32997 의 판단을 유지한다.

## 4. 설계

### 4.1 규칙

텍스트 블록의 끝에서, 길이 `p ≥ 40` 인 어떤 바이트열이 **연속으로 세 번** 쓰였으면
스트림을 끝낸다. 즉 블록 텍스트 `t` (길이 `n`)에 대해 `40 ≤ p ≤ n/3` 인 `p` 가
있어 `t[n−3p, n−2p) = t[n−2p, n−p) = t[n−p, n)` 이면 반복이다. 세 조각이 `\n` 을
품고 있든 아니든 상관없다. 문단 반복은 `p` 가 문단 길이(+1)인 경우로 그대로
포함된다.

### 4.2 계산

델타마다 블록 텍스트 전체를 다시 훑지 않는다. 블록에 바이트가 붙을 때 다항
롤링 해시의 prefix 배열을 같이 늘리고, 델타 뒤에 `p` 를 `40..n/3` 으로 훑으며 세
구간의 해시를 O(1) 에 비교한다. 해시가 맞으면 바이트를 직접 비교해 확정한다.
31KB 블록에서 `n/3 ≈ 10,000` 후보, 델타당 10⁴ 번 비교다. 지금 규칙은 델타마다
문단 목록을 다시 세니 비용은 같은 차원이다.

### 4.3 타입

```ocaml
| Stream_repeating of { unit : string; occurrences : int; bytes_seen : int }
```

`paragraph` 필드를 `unit` 으로 바꾼다. 필드 이름은 주장이다. 82바이트 문장을
`paragraph` 라 부르면 읽는 쪽이 개행을 찾는다. destructure 하는 자리는 넷이다
(`complete_stream_error.ml`, `complete_stream.ml`, `complete_stream_state.ml`,
`keeper_chat_agent_core_stream_bridge.ml`). 컴파일러가 전부 짚는다. 오류 문구
"generation repeated one paragraph %d times" 는 "repeated one %d-byte unit %d
times" 로 바뀐다. 보이는 곳은 keeper 로그와 TUI 의 turn terminal 줄이다.

### 4.4 오탐

정상 산문이 40바이트 이상의 같은 바이트열을 세 번 **연달아** 쓰는 경우가 오탐이다.
`\n` 규칙에서는 "같은 줄 세 번" 이 그 자리였고 이번엔 "같은 구절 세 번 연속" 이
더해진다. 표에서 같은 셀이 세 줄 이어지는 것은 이미 지금 규칙에 걸린다. 새로
걸릴 수 있는 것은 개행 없이 같은 구절을 세 번 잇는 문장인데, 40바이트 구절을
띄어쓰기까지 똑같이 세 번 붙여 쓰는 정상 답은 실측에서 세지 않았다. §5 가 잰다.

## 5. 판정 기준

1. sangsu 턴 1293 의 31,347바이트 본문을 델타로 흘리면 세 번째 82바이트 단위에서
   `Stream_repeating { occurrences = 3 }` 이 난다. `bytes_seen` 은 300 미만이다.
2. #32997 의 문단 케이스 네 개(`test_stream_accumulator.ml` "repeating" 그룹)는
   그대로 통과한다. 두 번 반복은 끝내지 않고, 짧은 줄 반복은 두고, thinking 은
   보지 않는다.
3. 오늘 하루 캡처된 정상 턴의 assistant 텍스트를 같은 규칙으로 훑어 **거짓 정지
   0건**을 확인한다. 하나라도 있으면 그 텍스트를 테스트로 넣고 규칙을 다시 본다.
   측정은 wire capture 요청 행으로 한다.
4. 배포 뒤 한 주, `accept_rejected` 중 `stop_reason=max_tokens` 이고 본문이 한
   단위의 반복인 턴이 0 이 된다. `sse/repeating_generation` 의 턴당 시간은 지금의
   15~29초 안에 머문다.

## 6. 대안과 비채택

- **`presence_penalty`/`frequency_penalty` 를 wire 에 싣는다.** ollama.com/v1 이
  받는다. 붕괴를 줄일 수는 있지만 모든 출력의 분포를 바꾸는 손잡이고, 감지가 아니라
  예방이다. 켜려면 정상 턴의 품질 변화를 재는 별도 canary 가 필요하다. 이 RFC 에서
  하지 않고, 필요가 보이면 provider binding 단위의 실험으로 따로 낸다.
- **binding 에 `max_tokens` 를 준다.** 손해의 상한을 정하지만 65,536 이 8,000 이
  되는 것뿐이고 언제 붕괴했는지는 모른다. 감지와 겹치지 않으니 별건으로 남긴다.
- **압축률(zlib) 로 저엔트로피를 잡는다.** 비율 임계값이 새 상수가 되고, 표나
  반복 구조가 많은 정상 답이 걸린다.
- **n-gram 통계로 잡는다.** 같은 이유. 그리고 정확 일치 3회는 이미 있는 기준이다.
- **그대로 둔다.** keeper 하나에서 하루 26분, 12턴이 토큰 상한까지 달렸다.

## 7. 구현 범위와 순서

1. `Complete_stream_state`: `repeating_paragraph` 를 주기 검사로 바꾸고, prefix
   해시를 블록 상태에 둔다. `paragraph` → `unit`. 테스트: 오늘 캡처의 한 줄 루프,
   #32997 의 네 케이스, 개행이 단위 안에 있는 문단 반복(회귀), 세 번째 반복이
   델타 경계에 걸쳐 도착하는 경우.
2. 소비자 넷의 문구와 TUI turn terminal 줄.
3. 오탐 측정(§5-3)을 PR 본문에 싣는다. 캡처가 없으면 그날의 turn record 본문으로
   대신하고 그렇게 적는다.

## 8. 건드리지 않는 것

- accept 게이트와 `max_tokens` 분류(RFC-0271).
- thinking/reasoning 블록.
- 샘플러 파라미터. 보내지 않던 것을 이 RFC 로 보내기 시작하지 않는다.
- 40바이트, 3회. 두 수를 바꾸는 근거는 이 실측에 없다.

## 출처

- #32997 `feat(stream): stop a generation that has started repeating itself` (d98e10170b, 2026-09-04) — 지금 규칙과 그 실측(29,788바이트, 문단 234개 중 11개 고유, 3번째 반복이 1,691바이트).
- #33267 — 오늘의 붕괴와 checkpoint 재주입 실측. #33281 — lane 쪽 수정.
- Ollama OpenAI compatibility, 지원 필드 목록: <https://docs.ollama.com/openai> (2026-09-05 확인. `frequency_penalty`, `presence_penalty`, `seed`, `max_tokens` 지원; `logit_bias`, `n`, `tool_choice` 미지원).
- Hugging Face `GenerationConfig`: `repetition_penalty` (1.0 = 없음, Keskar 외 2019 arXiv:1909.05858 참조), `no_repeat_ngram_size` — <https://huggingface.co/docs/transformers/main_classes/text_generation> (v5.15.1, 2026-09-05 확인).
- llama.cpp `common/arg.cpp`: `--repeat-penalty` "penalize repeat sequence of tokens (1.0 = disabled)", `--repeat-last-n`, `--dry-multiplier`/`--dry-base`/`--dry-allowed-length` (2026-09-05 확인, 도움말 문자열만).
