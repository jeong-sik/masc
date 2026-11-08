# Tinker·Inkling 2 Small SFT 한 바퀴 기록, 2026-11-08

[연구 문서](../../../research/2026-11-07-tinker-inkling-exact-lane-feasibility.md) §5.2가 이 기록을 해석한다.
입력과 답은 모두 스크립트가 만든 합성 값이다. 그래서 답은 앞 200자까지 남겼다.
reasoning 원문은 남기지 않고 글자 수만 셌다.

## 무엇을 확인했나

학습 경로가 끝까지 이어지는지 본다.
cookbook 렌더러로 데이터를 만들고, LoRA를 학습하고, sampler로 저장한다.
그 sampler를 OpenAI 호환 엔드포인트로 부른다.
학습 전후에 같은 평가 세트를 같은 요청 모양으로 보내 점수가 오르는지 잰다.

과제는 숨긴 규칙으로 레코드를 부호로 바꾸는 일이다. 프롬프트에는 규칙이 없다.

| 항목 | 값 |
| --- | --- |
| 규칙 | 이름 대문자, `#`, 나이 세 자리, `#`, 도시 앞 세 글자 대문자. `alice 7 seoul` → `ALICE#007#SEO` |
| 학습 | 160건. 이름 40개와 도시 24개에서 뽑았다 |
| 평가 `seen_pool` | 20건. 학습에 쓴 이름·도시의 새 조합이다 |
| 평가 `unseen_pool` | 20건. 학습에 없던 이름 10개·도시 8개에서 뽑았다 |
| 요청 모양 | 연구 문서 §4.4의 MASC exact 요청 모양이다. 스키마 지시를 마지막 user 메시지로 붙이고 `reasoning_effort: "low"`를 보낸다. temperature와 `max_tokens`는 보내지 않는다 |
| 채점 | 답 전체가 JSON이고 `code`가 규칙 값과 같으면 맞다 |

## 통과선

스크립트의 `PASS` 값이다.
2026-11-08 09:31:26Z에 스크립트 sha256을 적어 둔 뒤 유료 호출을 시작했다.
실행 뒤 다시 잰 값도 같았다. 이 묶음의 `sft_pipeline_check.py`도 같은 값이다.

| 통과선 | 기준 | 결과 |
| --- | --- | --- |
| 기본 모델 정확도 | 0.10 이하 | 0.0 (0/40), 통과 |
| 학습 뒤 정확도 | 0.80 이상 | 0.975 (39/40), 통과 |
| 마지막 step NLL ÷ 첫 step NLL | 0.5 이하 | 1e-05 ÷ 3.54281, 통과 |

## 환경

| 항목 | 값 |
| --- | --- |
| 호스트 | macOS, 한 대 |
| 클라이언트 | Python 3.12.13 (uv), `tinker` 0.39.0, `tinker-cookbook` 0.6.1, `tml-renderers` 0.4.1, `torch` 2.15.0, `openai` 3.46.0, `transformers` 5.22.2 |
| 렌더러 | `model_info.get_recommended_renderer_name`이 고른 `tml_v0`. effort 0.2로 렌더링했다. 엔드포인트 문서에서 `low`가 0.2다 |
| 학습 | `thinkingmachines/Inkling-2-Small`, LoRA rank 8, `cross_entropy`, Adam lr 2e-4 (β1 0.9, β2 0.95, eps 1e-8), batch 32, 5 epoch(25 step), seed 20261108 |
| 평가 엔드포인트 | `https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1` (OpenAI 호환 Beta), 동시 8건 |
| 학습 뒤 모델 이름 | `tinker://<run-id>:train:0/sampler_weights/masc-sft-pipeline-check` |
| 인증 | `TINKER_API_KEY` 환경 변수. 어떤 파일에도 키를 쓰지 않았다 |
| MASC 코드 | 쓰지 않는다 |

## 무엇을 돌렸나

| 시각 (UTC) | 명령 | 내용 |
| --- | --- | --- |
| 2026-11-08 09:30:41 | `sft_pipeline_check.py --out <dir> --dry-run` | 네트워크 호출 없이 설정, 비용 추정, 렌더링 예시만 찍는다 |
| 2026-11-08 09:31:59 ~ 09:39:49 | `sft_pipeline_check.py --out <dir> --budget 1.0` | 기본 모델 평가, 학습, 저장, 학습 뒤 평가 |

두 명령 모두 아래처럼 띄웠다.

```sh
uv run --quiet --python 3.12 --with 'torch>=2.10' --with tinker==0.39.0 \
  --with tinker-cookbook==0.6.1 --with openai python -I sft_pipeline_check.py ...
```

`--budget`는 스크립트 안의 지출 상한이다.
학습 step마다 학습 뒤 평가 몫을 남겨 두고 확인한다. 이번 실행은 상한에 닿지 않았다.

## 결과

| 단계 | 정확 일치 | `seen_pool` | `unseen_pool` | 답 전체가 JSON | finish | reasoning 글자 p50 (최대) | completion 토큰 p50 (최대) | 지연 p50 (최대) | 비용 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 기본 | 0/40 | 0/20 | 0/20 | 38 | stop 38, length 2 | 1,480 (9,651) | 403 (4,096) | 4.86초 (34.05초) | $0.0331 |
| 학습 뒤 | 39/40 | 20/20 | 19/20 | 40 | stop 40 | 0 (0) | 19 (20) | 1.09초 (4.13초) | $0.0020 |

- 기본 모델은 규칙을 몰라 추측했다.
  base64 6건, 원문의 구분자나 대소문자만 바꾼 값 30건, 짧은 약어 2건이다.
- 기본 모델 2건(`rows.jsonl`의 `index` 11, 22)은 생각만 하다 completion 4,096 토큰에서 끊겼다.
  content는 비었다. `max_tokens`를 보내지 않았으니 4,096은 Tinker 기본값이다.
- 학습 뒤 틀린 1건은 `odette 20 hanoi`다. 도시를 네 글자 써서 `ODETTE#020#HANO`로 답했다.
  같은 도시의 `odette 61 hanoi`는 맞혔다.
- 학습 뒤 모델은 40건 모두 reasoning 없이 바로 답했다.
  학습 데이터의 모델 차례는 생각 블록 없이 `<|content_text|>{"code":…}`로 시작한다.

학습 NLL은 아래처럼 내려갔다. step 하나는 p50 12.25초, 25 step 합계는 316.4초였다.

| step | 0 | 1 | 2 | 3 | 5 | 10 | 24 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 평균 NLL | 3.54281 | 1.9852 | 0.79362 | 0.14484 | 0.01511 | 0.00061 | 0.00001 |

학습 토큰은 96,665개다. 스크립트가 공개 단가 $1.50/M로 계산한 학습 비용은 $0.145다.
평가까지 합치면 $0.1801이다. 이 금액은 Tinker 청구서와 맞춰 보지 않았다.

## 체크포인트

실행 직후(2026-11-08 09:40Z ~ 09:43Z) `RestClient.get_training_run_by_tinker_path`로 확인했다.

| 항목 | 값 |
| --- | --- |
| 종류 | sampler, 비공개 |
| 크기 | 4,172,883,144 바이트 |
| 저장 | 2026-11-08 09:39:40Z |
| 만료 | 2026-11-11 09:39:40Z (TTL 3일) |

## 파일

| 파일 | sha256 | 설명 |
| --- | --- | --- |
| `sft_pipeline_check.py` | `c8d4bd53…` | 실행한 스크립트. `--out`으로 받은 새 디렉터리에만 쓴다 |
| `config.json` | `fa777c98…` | 설정과 사전 비용 추정. 원본 그대로다 |
| `rows.jsonl` | `32b5f567…` | 평가 80행. 원본 그대로다 |
| `steps.jsonl` | `e18f6708…` | 학습 25행. 원본 그대로다 |
| `summary.json` | `3926307a…` | 요약. `sampler_path`의 run ID만 `<run-id>`로 바꿨다. 원본 sha256은 `298218db…`다 |

실행 로그는 넣지 않았다. 내용이 위 파일과 겹치고, run ID가 들어 있다.

## 확인하지 않은 것

- librarian 품질. 과제는 단순한 문자열 규칙이다.
- MASC 레인이 `tinker://` 체크포인트를 부르는 경로. 이번에는 스크립트가 직접 불렀다.
- 반복성. seed 하나로 한 번 돌렸다. 샘플링 temperature는 서버 기본값이다.
- 생각을 건너뛰는 버릇이 다른 프롬프트에도 번지는지.
- 청구 금액.
- RL 쪽. cookbook `rl_basic`과 샘플링 logprob은 아직 돌리지 않았다.
