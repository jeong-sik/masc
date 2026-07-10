# Fusion Judge-of-Judges(JoJ) 운영 가이드

38버그 캠페인 #35("JoJ 기능이 동작하게 할 설정이 없고 동작도 안 합니다")의 응답 문서.

라이브 실측(2026-07-10): fusion run 11건 전부 `trio` preset — JoJ run 0건. 코드 스택(RFC-0283:
`fusion_policy` judge_spec/검증, `fusion_orchestrator` staged JOJ, 대시보드 `isJoj` topology 렌더,
`fusion_config.ml:112` TOML 파싱)은 전부 구현·랜딩돼 있으나, **JoJ를 켜는 TOML 문법이 어떤 문서에도
운영자 언어로 없어서** 기본 preset(`trio`, 단일 judge = simple 위상)만 쓰이고 있었다. 이 문서가 그
갭을 닫는다.

## JoJ가 켜지는 조건 (둘 다 필요)

1. preset에 `[[fusion.presets.<이름>.judges]]` sub-table이 **2개 이상** 정의돼 있다
   (1차 심판들. 런타임이 `>= 2`를 요구 — RFC-0283 §2.3).
2. fusion 실행이 `judge_of_judges`(또는 `staged_judge_of_judges`) 위상으로 요청된다.
   `simple`/`refine`/`conditional`은 `judges`를 **무시**하고 기존 단일 `judge`만 쓴다
   (하위 위상 동작 불변 — byte-identical).

기존 preset의 `judge`/`judge_system_prompt`는 JoJ에서 **meta-judge(reducer)** 역할로 재사용된다.

## runtime.toml 예시

`.masc/config/runtime.toml`의 기존 `[fusion.presets.trio]` 옆에 추가:

```toml
[fusion.presets.trio-joj]
# panels(패널 그룹)는 trio와 동일하게 구성 — 생략 부분은 기존 trio 참조.
# 단일 judge = JoJ의 meta-judge (1차 심판 종합의 reconciler).
judge = "ollama_cloud.deepseek-v4-pro"
judge_system_prompt = """
You are the meta judge. You are given the verdicts of several first-stage
judges over the same panel of answers. Reconcile them into one final verdict,
attributing which first-stage judge supported what.
"""
judge_timeout_s = 120.0

# JoJ 1차 심판들 — 2개 이상이어야 JoJ 위상이 성립한다.
# system_prompt는 필수(코드 default 없음): 비면 Judge_panel_prompt_missing으로 부팅 거부.
# 두 심판이 같은 정체성(label 없으면 model)이면 Duplicate_judge로 거부.
[[fusion.presets.trio-joj.judges]]
model = "ollama_cloud.deepseek-v4-pro"
label = "correctness"
system_prompt = """
Judge the panel answers strictly on factual correctness and logical validity.
"""
timeout_s = 120.0

[[fusion.presets.trio-joj.judges]]
model = "ollama_cloud.minimax-m3"
label = "completeness"
system_prompt = """
Judge the panel answers on coverage: what did each answer miss?
"""
timeout_s = 120.0
```

`judges` sub-table이 받는 전체 키(`fusion_config.ml parse_judge_spec`):
`model`, `label`(정체성 — 비면 model이 정체성), `system_prompt`(필수),
`web_tools`(기본 false), `max_tool_calls`(기본 0, `max_tool_calls_ceiling` 범위 검사),
`max_output_tokens`, `timeout_s`(기본 `default_timeout_s`), `max_timeout_s`.

staged JoJ는 같은 `judges` 목록을 `[fusion].staged_judge_group_size` 단위로 나눠
stage별 meta → final meta로 reconcile한다 (RFC-0283).

## 검증 방법

1. 설정 후 서버 재기동 — preset 검증은 부팅 시 fail-fast (`Judge_panel_prompt_missing`,
   `Duplicate_judge`, 크기/타임아웃 범위 위반이면 어느 preset인지와 함께 거부).
2. `judge_of_judges` 위상으로 fusion 실행 후 `GET /api/v1/dashboard/fusion-runs`에서
   해당 run 확인 — 대시보드 detail은 judges 배열 관측에서 shape를 파생해
   `1차 심판 N · judge-of-judges` topology를 렌더한다 (하드코딩 분기 없음).
3. 대시보드 fusion 설정 패널은 preset의 `judgeGroupCount > 0`이면
   "Judge-of-judges runtime" 라벨로 전환된다.

## 비용 주의

1차 심판 N명 = 심판 LLM 호출이 기존 1회에서 N+1회(1차 N + meta 1)로 는다.
`judge_wave_budget_s`(1차 wave 전체 wall-clock 예산)와 심판별 `timeout_s`로 상한을 걸 것.

## 왜 예시를 라이브 runtime.toml에 직접 넣지 않았나

모델 조합·비용은 운영 결정이고 runtime.toml은 git 추적 해제된 라이브 설정(#1226)이라,
이 가이드는 문법과 검증 경로만 제공한다. 위 예시의 모델 id는 현재 카탈로그 기준이며
적용 시점의 `[fusion.presets.trio]`와 카탈로그를 따라 조정할 것.
