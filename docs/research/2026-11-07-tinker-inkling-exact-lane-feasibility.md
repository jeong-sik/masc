# Tinker·Inkling 2 Small: exact 레인 실측과 학습으로 갈 수 있는 범위

2026-11-07 조사. 코드 대조 기준은 `cd3b9cb38c8`(#49616 병합 뒤 main)이다.
§3.1의 보내기 전 검사와 §4.5는 `cc630d4f224`에서 다시 대조했다.
§5.2는 2026-11-08에 돌린 SFT 한 바퀴다. MASC 코드는 쓰지 않았다.
[측정 기록](../evidence/research/2026-11-07-tinker-inkling-exact-lane/README.md)은 요청·답 원문 없이
상태, 응답 모양, 사용량, 채점 결과만 남긴다.

## 요약

- Inkling 2 Small을 effort `low`로 돌리면 librarian 기록 17건이 모두 유효했다.
  지연 p50은 6.6초다. 같은 기록에 남은 2026-09 클라우드 슬롯 지연은 p50 150초였다.
  두 값은 시점과 조건이 다르다.
  MASC exact 레인이 보내는 모양으로 다시 보내도 17/17이었다(§4.4).
- keeper-librarian Lane Add-on의 실제 요청 94건을 같은 모양으로 보냈다(§4.5).
  admission은 미리 정한 유효 0.95에 못 미쳤다. 창 안 62건 중 50건이 유효했다(0.806).
  admission prompt p50이 42,834 토큰이라 86건 중 24건이 창을 넘어 400을 받았다.
  durable은 창 안 4건이 모두 유효했지만, 그중 3건은 새 claim이 0개였다.
- board는 미리 정한 일치율 0.9에 못 미쳤다. 최고가 `low`의 0.80(생산 가중 0.844)이다.
- 기본 ID `thinkingmachines/Inkling-2-Small`의 창은 65,536 토큰이다. 256K는 `:peft:262144` ID만 받는다.
  MASC는 이 행으로 보내기 전에 창을 재지 않는다. 넘친 요청과 잘린 답은 다음 슬롯으로 넘어간다(§3.1).
- Tinker OpenAI 호환 엔드포인트는 `response_format`을 받기만 하고 적용하지 않는다.
  답의 형식은 모델이 프롬프트 속 계약을 지키느냐에 달려 있다.
- effort `none`은 긴 프롬프트에서 생각을 끄지 않는다. 레인 답 예산만 주면 답이 잘린다.
- #49616으로 들어온 add-on과 runner는 배선이다. 그 runner로 학습 효과를 보인 적은 없다.
  가이드와 템플릿에는 측정과 다른 값이 남아 있다(§5).
- cookbook 렌더러로 LoRA rank 8을 25 step 학습했다(§5.2).
  숨긴 규칙 과제의 고정 평가가 0/40에서 39/40으로 올랐다. 학습에 없던 이름·도시는 19/20이다.
  학습 경로가 끝까지 통한다는 근거다. librarian 품질의 근거는 아니다.

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
위치는 #49616의 병합 커밋 `cca5af9f4afc` 기준이다.

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

모델 행에 창을 적어도 이 행에서는 보내기 전에 막지 못한다.
보내기 전 창 검사는 `Prepared_completion_request.admit`에 있다(`prepared_completion_request.ml:364`).
이 검사는 모델 행에 `serving_constraint`가 있을 때만 돈다(`exact_output_flow_admission.ml:207`).
Tinker 행(`packages/agent_core/models.toml:2342`)에는 `serving_constraint`가 없다.
그래서 요청은 `finalize_unmeasured`를 지나 토큰을 세지 않고 나간다(`exact_output_flow_admission.ml:218`, `exact_output_plan.ml:594`).
OpenAI 호환 provider는 요청 때 토큰을 셀 수도 없다(`count_tokens_sync.ml:151`).

창을 넘는 요청은 Tinker까지 가서 400을 받는다. 400은 실행 실패로 남고, 흐름은 다음 슬롯으로 넘어간다(`exact_output.ml:1332`).
창 끝에서 잘린 답(`finish_reason=length`)도 `Output_limit_reached` 실행 실패가 되어 다음 슬롯으로 간다(`exact_output.ml:934`).
스키마를 어긴 답은 `Reject_and_advance`로 다음 슬롯에 간다(`lib/server/server_lane_addon_exact.ml:113`).
슬롯 안의 검사는 스키마만 보지 않는다. 스키마 검사 뒤에 add-on 소비자 검사(`validate_output`)도 부른다(`lib/lane_addon/lane_addon_exact.ml:922`).
keeper-librarian admission이면 `Keeper_memory_admission_judgment.unwrap`이 빠진 후보를 거절한다(`lib/keeper/keeper_memory_admission_judgment.ml:88`).
이 검사에 떨어진 답도 같은 길로 다음 슬롯에 간다.
뒤 슬롯이 답하면 요청은 그대로 답을 받는다.
대가는 시간과 비용이다. §4.5에서 400은 0.34~1.49초가 걸렸다. 잘린 답 7건은 5.4~18.7초와 건마다 prefill 약 $0.019를 썼다.

## 4. exact 레인 재생

2026-09 로컬 벤치 데이터셋을 그대로 다시 썼다
(`~/me/.masc/benchmarks/local-llm-2026-09/`, 읽기만).
채점기도 그 벤치의 `replay_exact.py` 것을 불러 썼다.
요청에는 `json_schema` strict를 실었고, 400이 오면 `json_object`로 다시 보내게 했다.
MASC exact 레인은 이와 다르다. `Json_syntax`를 요청하므로 `json_schema`를 보내지 않는다.
대신 스키마 지시를 마지막 사용자 메시지로 덧붙인다(`exact_output_ready_admission.ml`).
이 재생에는 그 지시가 없었고, Tinker는 `response_format`을 적용하지 않았다.
모델이 본 형식 안내는 librarian 프롬프트에 원래 있던 것뿐이다.
지시를 붙인 재생은 §4.4에 있다.
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
`medium`은 0.70으로 더 낮다. 이 표본(설정마다 1회, 20건)에서는 더 오래 생각해도 일치율이 오르지 않았다.
몰림 지연은 모든 effort에서 통과했다(8건 동시, p50 3.47~8.73초).
2026-09 로컬 배선이 되돌려진 이유가 이 지연이었다.

### 4.3 effort `none`

짧은 질문에서는 reasoning이 0자였다.
실제 librarian 프롬프트에서는 `none`이어도 reasoning p50이 7,238자였다.
그 reasoning이 2026-09 벤치의 레인 답 예산 3,072 토큰을 먼저 쓰는 바람에, 답이 잘리거나 비어 있었다(10/17).
공식 문서는 effort를 "얼마나 생각할지 기울이는 값"으로 설명하고, `none`을 0.0에 대응시킨다.
측정해 보니 `none`은 생각을 끄지 않았다.

### 4.4 MASC 요청 모양으로 다시 재생

이 카탈로그 행은 JSON mode와 native schema를 둘 다 `false`로 둔다.
그래서 MASC exact 레인은 `response_format`을 싣지 않고, 스키마 지시를 마지막 사용자 메시지로 덧붙인다.
같은 데이터셋을 그 모양으로 두 번 더 보냈다(측정 기록의 O와 L). effort는 `low`다.
O는 temperature 0.0과 위 재생의 답 예산을 그대로 두었다.
L은 temperature를 싣지 않고 `max_tokens`를 8,192로 고정했다.
MASC exact 요청은 temperature를 비운다.
`max_tokens` 8,192는 라이브와 다르다(2026-11-08 확인).
keeper-librarian 출력은 레인 답 예산(`max_output_tokens`)을 적지 않는다. 그러면 MASC는 `max_tokens`를 싣지 않는다(`exact_output_resolver.ml:927`).
바인딩의 `max-tokens`는 exact 요청에 쓰이지 않는다. 라이브 Tinker 400 본문에는 `4096 max_tokens`가 찍혔다.
L의 출력 최대 3,172 토큰은 4,096 안에도 들어간다.

| 기록 | librarian 유효 | librarian 지연 p50 | librarian 출력 최대 | board 일치 |
| --- | --- | --- | --- | --- |
| 위 재생 `low` (`json_schema`, 지시 없음) | 17/17 | 6.62초 | 2,602 토큰 | 0.80 |
| O (지시, temperature 0.0) | **17/17** | 6.34초 | 2,879 토큰 | 0.75 |
| L (지시, temperature 없음, `max_tokens` 8,192) | **17/17** | 5.75초 | 3,172 토큰 | — |

54건 모두 답이 JSON 하나였다. 스키마 지시는 librarian prompt를 기록마다 417 토큰 늘렸다.
요청 모양을 바꿔도 librarian은 17/17 그대로였다. board는 여전히 0.9 아래다.
L은 O와 같은 프롬프트를 3분 뒤에 보내 prompt의 99.7%가 캐시였다. 그래서 L의 비용 $0.034는 대표값이 아니다.
O의 librarian 비용은 호출 한 번에 $0.0070이었다.
데이터셋은 여전히 2026-09 것이다. 지금 프롬프트로는 §4.5에서 다시 쟀다.

### 4.5 keeper-librarian Lane Add-on 실제 요청

Tinker는 2026-11-07 16:09Z 재시작부터 keeper-librarian Lane Add-on의 `admission`·`durable` 슬롯에 있다(§6의 1번).
그 add-on이 2026-11-03~07에 남긴 실제 요청 94건을 L과 같은 모양으로 다시 보냈다(측정 기록의 A).
통과선은 보내기 전에 정했다. admission은 창 안 요청 중 유효 0.95 이상이다. durable은 창 안 요청이 모두 유효해야 한다.

| 출력 | 요청 | 창 넘침 400 | 창 안 유효 | 통과선 | 지연 p50 | prompt p50 |
| --- | --- | --- | --- | --- | --- | --- |
| admission | 86 | 24 | 50/62 = **0.806** | 미달 | 9.21초 | 42,834 토큰 |
| durable | 8 | 4 | 4/4 | 통과 | 7.14초 | 48,374 토큰 |

- 가장 큰 원인은 창이다. admission 86건 중 24건은 prompt만으로 65,536 토큰을 넘었다.
  9건은 창 안이었지만 답 예산 8,192 토큰이 들어갈 자리가 없었다. 그중 7건은 답이 창 끝에서 잘렸다.
- 창 영향을 빼도 통과선 아래다. prompt가 57,344 토큰 이하인 52건 중 유효는 48건(0.923)이다.
  이 분해는 결과를 본 뒤에 정했다. 나머지 4건은 답 예산 소진 1건, 후보 빠뜨림 2건, 스키마 위반 1건이다.
- 후보를 빠뜨린 2건은 스키마를 지켰다. 라이브에서는 librarian 검사가 슬롯 안에서 이 답을 거절한다(§3.1).
  그래서 A에서 유효가 아니었던 답은 라이브에서 모두 다음 슬롯으로 넘어간다. 실패한 답이 그대로 받아들여지는 경우는 없다.
- durable 통과는 약한 근거다. 창 안 4건 중 3건이 새 claim 0개였다. 같은 요청의 기록 답(GLM)은 3·1·2·0개였다.
- admission도 기록 답보다 새 claim을 적게 만들었다. 유효 50건의 새 claim은 40개, 같은 요청의 기록 답은 46개다.
  후보별 결정은 스키마를 지킨 답의 후보 73개 중 53개가 기록 답과 같았다.
- 이 요청은 core `librarian_exact` 레인의 입력(p50 12.9KB)과 다른 요청이고, 훨씬 크다.
- A는 `max_tokens`를 8,192로 보냈다. 라이브는 이 필드를 싣지 않아 Tinker 기본값 4,096이 쓰인다(§4.4).
  유효 50건 중 1건(completion 5,039 토큰)은 4,096이면 잘린다. 그러면 admission은 49/62 = 0.790이다. 결과를 본 뒤의 추정이다.
- 94건 재생 비용은 $0.937이었다.

라이브(2026-11-07 16:09Z~11-08 09:06Z)에서 기록이 바뀐 keeper-librarian 요청은 17건이다. 답을 받은 14건은 모두 GLM이 답했다.
Tinker까지 내려온 요청은 admission 2건뿐이었다.
둘 다 매번 창 넘침 400을 받았다. prompt는 251,251 토큰과 280,850 토큰이다.
이 두 요청은 후보를 272개와 515개 싣고 있다. 다른 admission 요청의 후보 수는 중앙값 1개, 최대 77개다.
모든 슬롯이 429, 시간 초과, 400으로 실패해서 11-07부터 같은 요청을 다시 보내고 있다(#49910).

## 5. 학습으로 갈 수 있는 범위

- **Keeper 턴 그대로는 안 들어간다.**
  2026-11-07에 라이브 provider-inputs 7,381턴을 셌다. 요청 본문은 p50 1.16MB, p90 2.82MB였다.
  바이트를 3.6으로 나눠 추정하면 p50이 약 32만 토큰이고, 256K 창을 넘는다.
  이 세는 스크립트는 남기지 않았다. Keeper 턴에 Tinker를 붙일지 정하기 전에 명령을 남기고 다시 잰다.
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

### 5.2 SFT 한 바퀴 (2026-11-08)

§6의 3번 중 SFT 쪽을 돌렸다.
[SFT 측정 기록](../evidence/research/2026-11-08-tinker-inkling-sft-pipeline-check/README.md)에 스크립트, 행, 통과선이 있다.
과제는 숨긴 규칙으로 레코드를 부호로 바꾸는 일이다(`alice 7 seoul` → `ALICE#007#SEO`).
프롬프트에 규칙이 없어서 학습 전 모델은 맞힐 수 없다.

- 데이터는 cookbook 0.6.1의 Inkling 2 렌더러(`tml_v0`)로 만들었다. §2의 바이트 토큰은 쓰지 않았다.
- LoRA rank 8로 160건을 5 epoch(25 step) 학습했다. 학습 데이터의 effort는 부를 때 쓰는 `low`와 같은 0.2다.
- 학습 전후에 같은 평가 40건을 §4.4의 MASC exact 요청 모양으로 보냈다.
  학습 뒤에는 `tinker://` sampler 경로를 모델 이름으로 넣었다.

| | 기본 모델 | 학습 뒤 |
| --- | --- | --- |
| 정확 일치 | 0/40 | 39/40 |
| 학습에 없던 이름·도시 | 0/20 | 19/20 |
| reasoning 글자 p50 | 1,480 | 0 |
| completion 토큰 p50 (최대) | 403 (4,096) | 19 (20) |
| 지연 p50 | 4.86초 | 1.09초 |

미리 고정한 통과선 셋을 모두 넘었다.
기본 모델 0.10 이하, 학습 뒤 0.80 이상, 마지막 step NLL이 첫 step의 절반 이하다.
학습 NLL은 3.54에서 0.00001로 내려갔다.
스크립트가 공개 단가로 계산한 비용은 $0.18이다. 청구서와는 맞춰 보지 않았다.

- **학습 경로는 끝까지 통한다.** 렌더러, LoRA 학습, sampler 저장, OpenAI 호환 샘플링이 이어진다.
- **답만 담아 학습한 모델은 생각을 건너뛰었다.** 학습 데이터의 모델 차례에는 생각 블록이 없었다.
  학습 뒤 모델은 effort `low`로 불러도 40건 모두 생각 없이 바로 답했다.
  librarian SFT 데이터에 교사의 생각을 넣을지 먼저 정해야 한다.
- **Tinker 기본 출력 한도 4,096을 다시 봤다.** 기본 모델 2건은 생각만 하다 4,096 토큰에서 끊겼다.
  두 답 모두 content가 비었다(§4.4).

이 결과는 librarian 품질의 근거가 아니다. 과제가 단순한 문자열 규칙이다.
MASC 레인이 체크포인트를 부른 적도 없다. exact 슬롯은 카탈로그 행에만 붙는다(§6의 1번).
체크포인트를 exact 슬롯에 두려면 적어도 그 경로의 카탈로그 행이 있어야 한다.
체크포인트(sampler, 4.17GB)는 2026-11-11 09:39Z에 만료된다.

## 6. 다음에 해 볼 것

1. **keeper-librarian 슬롯.** 2026-11-07 16:09Z 재시작부터 keeper-librarian Lane Add-on의 `admission`·`durable` 출력에서 GLM 다음 슬롯에 `low`로 있다.
   exact 슬롯은 AGENT_CORE 카탈로그의 provider 행과 모델 행에만 붙는다(`Exact_output_catalog_binding.resolve_exact`).
   runtime.toml에만 적은 행은 부팅 때 exact 레지스트리에서 빠진다.
   그래서 창 65,536과 effort 사다리는 카탈로그 행에 적고, runtime.toml은 그 행을 묶기만 한다.
   카탈로그 행은 측정대로 JSON mode와 native schema를 둘 다 `false`로 둔다.
   MASC exact 레인은 모두 `Json_syntax`라서 이 값으로도 레인에 들어간다.
   설정은 운영자 저장 경로(runtime.toml save channel)로 바꾸고, 모델 행이라 재시작이 필요하다.
   librarian 입력의 15%는 회사 쪽 Keeper 몫이다. 운영자가 2026-11-07에 이것도 Tinker로 보내도 된다고 정했다.
2. **창.** §4.5에서 admission 요청의 28%가 창을 넘었다. `:peft:262144` ID로 긴 요청 35건을 다시 보내 본다.
   35건은 창 넘침 400 28건과 창 끝에서 잘린 7건이다. prompt를 합치면 2,724,410 토큰이고, 기본 ID 단가로 prefill만 약 $0.82다.
   그 ID의 단가와 통과선은 보내기 전에 정한다.
   긴 admission 31건이 모두 유효해도, 창 안 실패 5건이 그대로면 이 표본의 admission은 81/86 = 0.942다.
   라이브에서 Tinker까지 내려온 두 요청(251,251·280,850 토큰)은 256K 창에도 하나가 넘는다. 이 두 요청은 part 크기 문제다(#49910).
3. **학습 파이프라인 확인.** SFT 쪽은 2026-11-08에 통과했다(§5.2).
   남은 것은 RL 쪽이다. cookbook `rl_basic`에 샘플링 logprob을 붙여 한 바퀴 돌린다.
   기준은 같다. 고정한 평가 세트의 점수가 오르는가다.
4. **librarian 처분 규칙 SFT.** 합성 입력, Tinker 교사 답, 결정론 검사로 데이터를 만든다.
   실제 기록은 평가에만 쓴다. 3번의 SFT 쪽이 통과해서 시작할 수 있다.
   데이터에 교사의 생각을 넣을지 먼저 정한다. 답만 넣으면 학습 뒤 모델이 생각을 건너뛸 수 있다(§5.2).

board는 0.9를 넘는 후보가 생기기 전까지 클라우드에 둔다.

## 출처

확인 시각은 따로 적지 않으면 2026-11-07이다.

| 출처 | 쓴 곳 | 신뢰도 |
| --- | --- | --- |
| [Models & Pricing](https://tinker-docs.thinkingmachines.ai/tinker/models/models_and_pricing/) | 창, 구조, 가격, 입력 종류 | High |
| [OpenAI API Compatible Inference (Beta)](https://tinker-docs.thinkingmachines.ai/tinker/compatible-apis/openai/) | effort 대응값, 생략 시 0.9, Beta 용도 | High |
| [Losses](https://tinker-docs.thinkingmachines.ai/tinker/losses/) | RL 손실 입력 | High |
| [Audio (cookbook)](https://tinker-docs.thinkingmachines.ai/cookbook/inkling/audio/) | 오디오 지원 모델 | High |
| [Tinker pricing](https://thinkingmachines.ai/tinker/pricing/) | serverless 단가 "as of October 19, 2026" | High |
| [Inkling 2 Small 발표](https://thinkingmachines.ai/news/inkling-2-small/) | 닫힌 가중치, 공개 계획 | High(문구) · Low(시점) |
| [측정 기록](../evidence/research/2026-11-07-tinker-inkling-exact-lane/README.md) | §3, §4 | High(이 표본) |
| [SFT 측정 기록](../evidence/research/2026-11-08-tinker-inkling-sft-pipeline-check/README.md) (2026-11-08) | §5.2 | High(이 표본) |
| `tinker-cookbook` 0.6.1, `tinker` 0.39.0 PyPI 배포본 소스 (2026-11-08) | §5.2 렌더러, 학습·저장 호출 | High |
| 2026-09 로컬 벤치 `REPORT.md`, `LIVE-WIRING-ROLLBACK.md` | 비교값, 42초 기준 | High |
| 라이브 provider-inputs 집계(스크립트 미보존) | §5 요청 크기, 회사 쪽 몫 | Medium |
