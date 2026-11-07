# Tinker·Inkling 2 Small: exact 레인 실측과 학습으로 갈 수 있는 범위

2026-11-07 조사. 코드 대조 기준은 `cd3b9cb38c8`(#49616 병합 뒤 main)이다.
[측정 기록](../evidence/research/2026-11-07-tinker-inkling-exact-lane/README.md)은 요청·답 원문 없이
상태, 응답 모양, 사용량, 채점 결과만 남긴다.

## 요약

- Inkling 2 Small을 effort `low`로 돌리면 librarian 기록 17건이 모두 유효했다.
  지연 p50은 6.6초다. 같은 기록에서 클라우드 슬롯은 150초가 걸렸다.
- board는 미리 정한 일치율 0.9에 못 미쳤다. 최고가 `low`의 0.80(생산 가중 0.844)이다.
- 기본 ID `thinkingmachines/Inkling-2-Small`의 창은 65,536 토큰이다. 256K는 `:peft:262144` ID만 받는다.
- Tinker OpenAI 호환 엔드포인트는 `response_format`을 받기만 하고 적용하지 않는다.
  답의 형식은 모델이 프롬프트 속 계약을 지키느냐에 달려 있다.
- effort `none`은 긴 프롬프트에서 생각을 끄지 않는다. 레인 답 예산만 주면 답이 잘린다.
- #49616으로 들어온 add-on과 runner는 배선이다. 실제 학습 효과를 보인 적은 없다.
  가이드와 템플릿에는 측정과 다른 값이 남아 있다(§5).

## 1. 무엇을 확인하려 했나

#49616은 MASC가 Tinker로 Keeper 모델을 SFT·DPO·RLVR로 학습시킬 수 있고,
결합 없이 붙는다고 설명했다. 그 세션은 "라이브 학습 한 스텝"과 `promote_ready` 판정을 근거로 들었다.
이 조사는 세 가지를 따로 묻는다.

1. Inkling 2 Small을 지금 MASC 레인에 추론 모델로 붙일 수 있나.
2. MASC 기록으로 학습시킬 수 있나.
3. #49616의 근거는 무엇을 보여 주나.

## 2. #49616의 근거가 보여 주는 것

| 주장 | 코드에 있는 것 | 위치 |
| --- | --- | --- |
| 라이브 학습 한 스텝 | 토큰을 tokenizer가 아니라 UTF-8 바이트 + 256으로 만든다 | `scripts/tinker/tinker_runner.py:164` |
| RL 손실 입력 | 기록된 logprob이 없으면 모든 토큰에 -0.1을 넣는다 | `scripts/tinker/tinker_runner.py:210` |
| 학습 데이터 | `--bundle`이 없으면 합성 datum 1개를 만든다 | `scripts/tinker/tinker_runner.py:583` |
| `promote_ready` | 평가 통과율 기본값 0.88, 기준선 기본값 0.78을 비교한다 | `scripts/tinker/tinker_runner.py:561`, `addons/tinker-trainer/server.py:704` |
| 스냅샷 소스 | 예제가 상대 경로를 쓰는데, 런타임은 절대 경로만 받는다 | `docs/examples/lane-addons/tinker-trainer.toml:21`, `lib/lane_addon/lane_addon_sources.ml:88` |

그 한 스텝은 배선이 끝까지 통한다는 뜻이다.
모델이 나아졌다는 근거는 아니다.
그때 만든 체크포인트는 계정에 하나 남아 있었고(sampler, 16.7GB),
2026-11-07 07:16Z에 TTL 7일을 걸었다(만료 2026-11-14 07:16Z).
가이드의 체크포인트 교체 예제가 이 경로를 쓰므로, 만료 뒤에는 예제 경로가 없어진다.

## 3. 엔드포인트 실측

공식 OpenAI SDK로 직접 쟀다. 값은 측정 기록 W·P에 있다.

| 항목 | 결과 | MASC 설정에 주는 뜻 |
| --- | --- | --- |
| 창 크기 | 기본 ID 65,536. `:peft:262144`는 262,144. prompt + `max_tokens`로 센다 | 기본 ID면 `max-context = 65536` |
| 넘침 오류 | HTTP 400, 본문 `{"detail":"Prompt length plus max_tokens exceeds …"}` | 아래 §3.1 |
| `response_format` | `json_schema` strict와 `json_object` 모두 200이지만 답은 스키마를 무시했다 | 형식 보장은 MASC 쪽 검증뿐이다 |
| effort | `none`~`xhigh`, 실수, `"max"`까지 200. 생략하면 0.9다(공식 문서) | 레인마다 effort를 꼭 보내야 한다 |
| reasoning | `reasoning_content`로 따로 온다. completion 토큰에 포함된다 | 답 예산에 reasoning 몫을 더해야 한다 |
| 되보내기 | reasoning을 실은 assistant 턴을 다시 보내도 200 | 다턴 재전송이 막히지 않는다 |
| 병렬 tool call | `tool_choice="required"`에 2개가 한 응답에 왔다 | — |
| prefix cache | 같은 앞부분 6,329 토큰 중 6,272가 두 번째에 캐시로 보고됐다 | cached 단가 $0.03/M가 적용된다 |
| 동시 8건 | 모두 200, 0.78~1.36초. 429와 한도 헤더 없음 | 한도 숫자는 모른다(Beta) |

### 3.1 MASC가 넘침 400을 받는 방식

`packages/agent_core/lib/llm_provider/retry.ml:357`의 `classify_error`는 본문 문장을 읽지 않는다.
400은 모두 `InvalidRequest { reason = Unknown_invalid_request }`가 된다(`:370`).
그래서 Tinker의 창 넘침은 `ContextOverflow`로 잡히지 않는다.
오류 메시지는 남는다. `Api_common.error_message_of_body`는 `detail` 키를 읽지 않지만,
`extract_error_message`가 본문 전체를 메시지로 쓴다(`retry.ml:318`).

막는 방법은 문장 매칭을 더하는 것이 아니다. 모델 행에 실제 창을 적는 것이다.
그러면 exact 레인은 보내기 전에 `Measured_context_window_exceeded`로 거절한다
(`exact_output_ready_admission.ml:92`).

## 4. exact 레인 재생

2026-09 로컬 벤치 데이터셋을 그대로 다시 썼다
(`~/me/.masc/benchmarks/local-llm-2026-09/`, 읽기만).
채점기도 그 벤치의 `replay_exact.py` 것을 불러 썼다.
요청에는 `json_schema` strict를 실었고, 400이 오면 `json_object`로 다시 보내게 했다.
MASC exact 레인은 이와 다르다. `Json_syntax`를 요청하므로 `json_schema`를 보내지 않는다.
대신 스키마 지시를 마지막 사용자 메시지로 덧붙인다(`exact_output_ready_admission.ml`).
이 재생에는 그 지시가 없었고, Tinker는 `response_format`을 적용하지 않았다.
모델이 본 형식 안내는 librarian 프롬프트에 원래 있던 것뿐이다.
통과선은 보내기 전에 정했다.

| effort | librarian 유효 | librarian 지연 p50 | board 일치 | board 생산 가중 | board 몰림 p50 | 비용 |
| --- | --- | --- | --- | --- | --- | --- |
| none | 7/17 | 11.66초 | 0.55 | 0.660 | 3.85초 | $0.161 |
| **low** | **17/17** | **6.62초** | 0.80 | 0.844 | 3.47초 | $0.141 |
| medium | 17/17 | 17.6초 | 0.70 | 0.744 | 8.73초 | $0.215 |
| 통과선 | 17/17 | — | 0.9 이상 | — | 42초 이하 | — |

생산 가중은 2026-09 보고서와 같은 식이다. relevant 재현율 × 0.28 + not_relevant 재현율 × 0.72이다.
같은 표에서 2026-09 값은 Ornith-1.5-9B 0.972, 27B 0.887, Spark-X2.5-4B 0.843이었다.
비교 대상은 진실이 아니라 2026-09 당시 클라우드 슬롯의 답이다.

### 4.1 librarian

`low`와 `medium`은 17건 모두 계약을 지켰다.
계약은 모든 현재 기억 ID를 retained나 dropped에 정확히 한 번씩 적는 것이다.
2026-09에 10B 이하 모델은 이 계약에서 최고 76%였다.
27B는 17/17이었지만 251초가 걸렸다.

`low`의 retained Jaccard 평균은 0.944, dropped 완전 일치는 9/17이다.
no-op 여부가 클라우드와 같은 것은 11/17이다.
나머지 6건은 형식은 맞지만 결정이 클라우드와 다르다.
어느 쪽이 옳은지는 이 기록으로 판정할 수 없다.

호출 한 번에 `low`로 $0.0068가 들었다(prompt p50 23,741 토큰, 캐시 p50 5,376 토큰).
2026-11-07 라이브 librarian 입력은 p50 12.9KB로, 이 데이터셋(p50 64KB)보다 작다.
지금 프롬프트로 다시 재지는 않았다.

### 4.2 board

`low`의 일치율은 0.80이다. 클래스별로 relevant 7/10, not_relevant 9/10이다.
`medium`은 0.70으로 더 낮다. 이 레인에서는 더 오래 생각해도 일치율이 오르지 않았다.
몰림 지연은 모든 effort에서 통과했다(8건 동시, p50 3.47~8.73초).
2026-09 로컬 배선이 되돌려진 이유가 이 지연이었다.

### 4.3 effort `none`

짧은 질문에서는 reasoning이 0자였다.
실제 librarian 프롬프트에서는 `none`이어도 reasoning p50이 7,238자였다.
그 reasoning이 2026-09 벤치의 레인 답 예산 3,072 토큰을 먼저 쓰는 바람에, 답이 잘리거나 비어 있었다(10/17).
공식 문서는 effort를 "얼마나 생각할지 기울이는 값"으로 설명하고, `none`을 0.0에 대응시킨다.
측정해 보니 `none`은 생각을 끄지 않았다.

## 5. 학습으로 갈 수 있는 범위

- **Keeper 턴 그대로는 안 들어간다.**
  2026-11-07에 라이브 provider-inputs 7,381턴을 셌다. 요청 본문은 p50 1.16MB, p90 2.82MB였다.
  바이트를 3.6으로 나눠 추정하면 p50이 약 32만 토큰이고, 256K 창을 넘는다.
  이 세는 스크립트는 남기지 않았다.
- **과거 기록으로 바로 RL을 할 수 없다.**
  RL 손실(`importance_sampling`, `ppo`, `cispo`, `dro`)은 `target_tokens`·`logprobs`·`advantages`만 받는다.
  `logprobs`는 샘플링한 정책의 값이어야 한다.
  다른 모델이 만든 MASC 기록에는 그 값이 없다.
- **학습 데이터는 합성 입력과 Tinker 출력, 결정론 검사로 만든다.**
  다른 공급자 출력으로 학습하려면 그 약관을 따로 확인해야 해서, 이번 범위에서 뺐다.
  실제 MASC 기록은 평가에만 쓴다.
- **가중치는 아직 닫혀 있다.**
  2026-11-05 발표는 "외부 안전 시험 뒤 다음 주에 Apache 2.0으로 공개할 계획"이라고 적었다.
  공개 전에는 학습한 LoRA도 Tinker 안에서만 샘플링할 수 있다.
  공개 시점은 확인이 필요하다.

### 5.1 main에 남은 측정과 다른 값

`docs/guides/tinker-integration.md`와 `config/runtime.toml`의 주석 템플릿에 아래 값이 들어 있다.
템플릿은 주석이라 라이브 설정에는 영향이 없다.
가이드를 따라 행을 만들면 아래 값이 그대로 들어간다.

| 위치 | 적힌 값 | 측정·공식 값 |
| --- | --- | --- |
| 기본 ID의 `max-context` | 262144 | 65,536 (실측, Models 표 64K) |
| `supports-structured-output` | true | 받기만 하고 적용하지 않음 (실측 P) |
| `supports-audio-input` | true | Inkling 2 Small은 "Hybrid + Vision" (Models 표). 오디오는 Inkling·Inkling-Small |
| 가이드 §6 Inkling | 1T/32B, 262,144, $1.00·$3.00·$3.00 | 975B/41B, 64K, $1.87·$4.68·$5.61 |
| 가이드 §6 GLM-5.3-Flash | 35B/3.6B, $0.22·$0.54·$0.65 | 320B/18B, $0.84·$2.11·$5.58 |
| 가이드 §6 Qwen3.8-27B | 262,144, $0.54·$1.36·$1.63 | 64K, $0.6975·$5.595·$4.103 |
| 기본 effort | `reasoning-effort = "high"` | exact 레인 재생에서는 `low`가 가장 나았다 |
| 가이드의 `tinker-inkling-2-small-none` | "Fast non-thinking profile for exact-output gates" | `none`도 긴 프롬프트에서 reasoning p50 7,238자, librarian 10/17 잘림 (§4.3) |

## 6. 다음에 해 볼 것

1. **librarian 2순위 슬롯.** `low` 기준으로 클라우드 다음 순서에 둔다.
   exact 슬롯은 AGENT_CORE 카탈로그의 provider 행과 모델 행에만 붙는다(`Exact_output_catalog_binding.resolve_exact`).
   runtime.toml에만 적은 행은 부팅 때 exact 레지스트리에서 빠진다.
   그래서 창 65,536과 effort 사다리는 카탈로그 행에 적고, runtime.toml은 그 행을 묶기만 한다.
   카탈로그 행은 측정대로 JSON mode와 native schema를 둘 다 `false`로 둔다.
   MASC exact 레인은 모두 `Json_syntax`라서 이 값으로도 레인에 들어간다.
   설정은 운영자 저장 경로(runtime.toml save channel)로 바꾸고, 모델 행이라 재시작이 필요하다.
   librarian 입력의 15%는 회사 쪽 Keeper 몫이다. 운영자가 2026-11-07에 이것도 Tinker로 보내도 된다고 정했다.
2. **지금 프롬프트와 MASC 경로로 다시 재생.** 라이브 librarian 입력 p50이 12.9KB로 줄었으니,
   최근 기록으로 표본을 새로 뽑는다. 요청은 MASC exact 레인처럼 `response_format` 없이
   스키마 지시를 덧붙여 보내고, 같은 통과선으로 잰다.
3. **학습 파이프라인 확인.** cookbook `sl_basic`·`rl_basic`에 Inkling 2 렌더러와
   샘플링 logprob을 붙여 한 바퀴 돌린다. 기준은 고정한 평가 세트의 점수가 오르는가다.
4. **librarian 처분 규칙 SFT.** 합성 입력, Tinker 교사 답, 결정론 검사로 데이터를 만든다.
   실제 기록은 평가에만 쓴다. 3번이 통과한 뒤에 한다.

board는 0.9를 넘는 후보가 생기기 전까지 클라우드에 둔다.

## 출처

확인 시각은 모두 2026-11-07이다.

| 출처 | 쓴 곳 | 신뢰도 |
| --- | --- | --- |
| [Models & Pricing](https://tinker-docs.thinkingmachines.ai/tinker/models/models_and_pricing/) | 창, 구조, 가격, 입력 종류 | High |
| [OpenAI API Compatible Inference (Beta)](https://tinker-docs.thinkingmachines.ai/tinker/compatible-apis/openai/) | effort 대응값, 생략 시 0.9, Beta 용도 | High |
| [Losses](https://tinker-docs.thinkingmachines.ai/tinker/losses/) | RL 손실 입력 | High |
| [Audio (cookbook)](https://tinker-docs.thinkingmachines.ai/cookbook/inkling/audio/) | 오디오 지원 모델 | High |
| [Tinker pricing](https://thinkingmachines.ai/tinker/pricing/) | serverless 단가 "as of October 19, 2026" | High |
| [Inkling 2 Small 발표](https://thinkingmachines.ai/news/inkling-2-small/) | 닫힌 가중치, 공개 계획 | High(문구) · Low(시점) |
| [측정 기록](../evidence/research/2026-11-07-tinker-inkling-exact-lane/README.md) | §3, §4 | High(이 표본) |
| 2026-09 로컬 벤치 `REPORT.md`, `LIVE-WIRING-ROLLBACK.md` | 비교값, 42초 기준 | High |
| 라이브 provider-inputs 집계(스크립트 미보존) | §5 요청 크기, 회사 쪽 몫 | Medium |
