# Tinker·Inkling 2 Small 256K 서빙 확인, 2026-11-08

keeper-librarian admission 프롬프트는 중앙값이 약 52K 토큰이고, 64K 창을 넘는 것도 있다.
그래서 학습은 256K 학습 ID `thinkingmachines/Inkling-2-Small:peft:262144`로 해야 한다.
Tinker 문서는 이 ID로 학습한 sampler 체크포인트가 OpenAI 호환 endpoint에서 몇 토큰 창으로 서빙되는지 적지 않는다.
MASC는 체크포인트를 그 endpoint로만 부른다. 그래서 endpoint에 직접 물었다.

## 무엇을 확인했나

1. 256K 학습 ID에 rank 8 LoRA를 만들었다.
   학습 전에 한 번(`zero`), 짧은 예시 4건으로 1 step 학습한 뒤에 한 번(`one`) sampler로 저장했다.
2. Inkling 토크나이저로 약 100K, 230K 토큰 프롬프트를 만들었다.
   첫 암호는 맨 앞에, 둘째 암호는 가운데에 두고, 질문은 맨 끝에 두었다.
   앞부분을 잘라 내면 첫 암호를 답할 수 없다.
3. 두 프롬프트를 OpenAI 호환 endpoint로 세 대상에 보냈다.
   `one` 체크포인트, `zero` 체크포인트, 256K 기본 ID를 이름으로 부른 것이다.
   64K 기본 ID에는 100K 프롬프트를 한 번 보냈다. 실패해야 하는 대조군이다.
4. 같은 글의 SDK logprob을 `zero` 체크포인트와 256K 기본 모델에서 비교했다.
   학습 없이 저장한 체크포인트가 기본 모델과 같은지 보려고 했다.

요청 모양은 MASC exact 레인과 같은 `reasoning_effort: "low"`다. `max_tokens`는 2,048로 보냈다.

## 통과선

스크립트 맨 위 설명에 적은 값이다.
2026-11-08 10:36:10Z에 스크립트 sha256을 적어 둔 뒤 유료 호출을 시작했다. 실행 뒤 다시 잰 값도 같았다.

| 통과선 | 결과 |
| --- | --- |
| `one`이 두 긴 프롬프트에 HTTP 200으로 답한다 | 200, 200 |
| 응답의 `prompt_tokens`가 65,536을 넘고, 로컬 개수와 1% 안에서 같다 | 99,996 (로컬 99,981), 230,008 (로컬 229,993) |
| 두 암호를 모두 맞힌다 | 두 프롬프트 모두 맞힘 |

대조군과 logprob 비교는 기록만 하고 판정하지 않는다.

## 환경

| 항목 | 값 |
| --- | --- |
| 호스트 | macOS, 한 대 |
| 클라이언트 | Python 3.12.13 (uv), `tinker` 0.39.0, `tinker-cookbook` 0.6.1, `tml-renderers` 0.4.1, `torch` 2.15.0, `openai` 3.46.0, `transformers` 5.22.2 |
| 학습 | `thinkingmachines/Inkling-2-Small:peft:262144`, LoRA rank 8, `cross_entropy`, Adam lr 2e-4, 1 step(97 토큰), seed 20261108 |
| 렌더러 | `tml_v0`, effort 0.2. 토크나이저와 렌더러는 64K ID 이름으로 골랐다. 두 ID 모두 `get_recommended_renderer_name`이 `tml_v0`을 돌려준다 |
| endpoint | `https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1` (OpenAI 호환 Beta), 요청을 하나씩 보냈다 |
| 인증 | `TINKER_API_KEY` 환경 변수. 어떤 파일에도 키를 쓰지 않았다 |
| MASC 코드 | 쓰지 않는다 |

`ServiceClient.get_server_capabilities`(SDK 0.39.0)는 이 ID를 학습·샘플링 가능, 창 262,144로 알려 준다.
64K ID `thinkingmachines/Inkling-2-Small`은 창 65,536이다.

## 무엇을 돌렸나

| 시각 (UTC) | 명령 | 내용 |
| --- | --- | --- |
| 2026-11-08 10:36:01 | `serving_256k_check.py --out <dir> --dry-run` | 프롬프트 크기와 비용 추정만 찍는다 |
| 2026-11-08 10:36:10 ~ 10:37:50 | `serving_256k_check.py --out <dir>` | 저장 두 번, logprob 비교, endpoint 호출 7번 |

```sh
uv run --quiet --python 3.12 --with 'torch>=2.10' --with tinker==0.39.0 \
  --with tinker-cookbook==0.6.1 --with openai python -I serving_256k_check.py ...
```

## 결과

| 대상 | 프롬프트 | HTTP | `prompt_tokens` | 캐시 토큰 | 두 암호 | completion 토큰 | 지연 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `one` | 100K | 200 | 99,996 | 0 | 맞힘 | 143 | 7.03초 |
| `one` | 230K | 200 | 230,008 | 49,920 | 맞힘 | 141 | 9.94초 |
| `zero` | 100K | 200 | 99,996 | 0 | 맞힘 | 153 | 6.18초 |
| `zero` | 230K | 200 | 230,008 | 49,920 | 맞힘 | 204 | 9.71초 |
| 256K 기본 ID | 100K | 200 | 99,996 | 0 | 맞힘 | 236 | 5.97초 |
| 256K 기본 ID | 230K | 200 | 230,008 | 49,920 | 맞힘 | 216 | 10.51초 |
| 64K 기본 ID (대조군) | 100K | 400 | - | - | - | - | 0.50초 |

- 256K 학습 ID로 학습한 체크포인트는 OpenAI 호환 endpoint에서 256K 창으로 서빙된다. 통과선을 모두 넘었다.
- 서버가 센 `prompt_tokens`는 로컬 개수보다 15개 많다. 채팅 틀이 붙인 토큰이다. 앞부분은 잘리지 않았다.
- 230K 요청의 캐시 토큰 49,920개는 100K 프롬프트와 같은 앞부분이다. 두 프롬프트는 둘째 암호 앞까지 같다.
- 대조군은 400과 `{"detail":"Prompt length plus max_tokens exceeds the model's context window: 99996 prompt tokens + 2048 max_tokens > 65536."}`를 돌려줬다.
  endpoint는 프롬프트 토큰에 `max_tokens`를 더해 창과 비교한다.
- 256K 기본 ID는 이름 그대로 endpoint에 보내도 256K 창으로 답한다.

### 학습 없이 저장한 체크포인트

`zero` 체크포인트와 256K 기본 모델의 logprob을 같은 321 토큰에서 비교했다. 차이의 최댓값은 0.0이다.
학습하지 않은 LoRA를 저장하면 기본 모델과 같은 답을 낸다.

### 비용

공개 단가로 계산하면 약 $0.26이다. 이 금액은 Tinker 청구서와 맞춰 보지 않았다.

| 항목 | 토큰 | 단가 (USD/M) |
| --- | --- | --- |
| 캐시 안 된 prefill | 840,252 | 0.30 |
| 캐시된 prefill | 149,760 | 0.03 |
| 샘플링 | 1,093 | 1.00 |
| 학습 | 97 | 3.00 |

## 체크포인트

두 체크포인트 모두 TTL 3일로 저장했다. 2026-11-11 10:38Z 무렵 만료된다.
이름은 `tinker://<run-id>:train:0/sampler_weights/masc-256k-zero`와 `…/masc-256k-one-step`이다.

## 파일

| 파일 | sha256 | 설명 |
| --- | --- | --- |
| `serving_256k_check.py` | `0f0a84ed…` | 실행한 스크립트. `--out`으로 받은 새 디렉터리에만 쓴다 |
| `config.json` | `ff15499c…` | 설정과 사전 비용 추정. 원본 그대로다 |
| `rows.jsonl` | `c67b8f64…` | endpoint 호출 7행. 원본 그대로다 |
| `summary.json` | `728f1eab…` | 요약. `sampler_paths`의 run ID만 `<run-id>`로 바꿨다. 원본 sha256은 `362d5e0a…`다 |

실행 로그는 넣지 않았다. 내용이 위 파일과 겹치고, run ID가 들어 있다.

## 확인하지 않은 것

- 오래 학습한 체크포인트. 이번 `one`은 1 step뿐이다.
- 256K에 가까운 프롬프트. 가장 긴 요청은 230,008 토큰이었다.
- 반복성과 동시 요청. 요청을 하나씩 한 번만 보냈다.
- 지연의 분포. 대상과 크기마다 한 번씩만 쟀다.
- 청구 금액.
