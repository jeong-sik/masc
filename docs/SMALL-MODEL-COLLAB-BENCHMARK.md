# Small Model Collaboration Benchmark

9B x 4 team session vs 35B x 1 단독 — repo_synthesis 질문셋 기반.

## 목적

"소형 모델 N개가 협업하면 대형 모델 1개보다 나은가?"에 대한 정량 근거 생성.

## 실험 설계

| 조건 | 모델 | 에이전트 수 | 실행 방식 |
|------|------|:---------:|----------|
| Baseline | Qwen3.5-35B-A3B Q4_K_XL | 1 | 단독 repo_synthesis |
| Collab | Qwen3.5-9B Q4_K_XL | 4 | team_session + swarm |

- 반복: 각 조건 5회 (동일 질문셋 3개)
- 질문셋: `benchmark/repo_synthesis_question_set.json`
- llama-server: 모델별 순차 실행 (9B 서빙 → 35B 서빙)

## 측정 지표

### 기존 (repo_synthesis)

| 지표 | 설명 |
|------|------|
| evidence_precision | cited_paths 중 gold_paths 비율 |
| claim_coverage | required_claims 중 답변 포함 비율 |
| unsupported_claim_penalty | gold_paths에 없는 인용 패널티 |
| avg_latency_ms | 질문당 평균 응답 시간 |
| composite_score | 위 4개 가중 합산 |

### 협업 특화 (신규)

| 지표 | 설명 |
|------|------|
| total_tokens | 전체 실험 토큰 소비량 |
| convergence_rate | team session converged 비율 |
| agent_contribution_balance | 에이전트별 기여도 stddev (낮을수록 균등) |

## 실행 방법

```bash
# Phase 1: Baseline (35B 단독)
LLAMA_PRESET=qwen35 scripts/harness_small_model_collab_benchmark.sh --phase baseline

# Phase 2: Collaboration (9B x 4)
LLAMA_PRESET=qwen35-9b scripts/harness_small_model_collab_benchmark.sh --phase collab

# Phase 3: 비교 리포트
scripts/harness_small_model_collab_benchmark.sh --phase report
```

## 결과 저장 경로

```
.masc/benchmarks/small-model-collab/
  {run_id}/
    config.json          # 실험 조건 (모델, 에이전트 수, 반복)
    baseline/
      run-{n}/score.json # 각 반복의 스코어
    collab/
      run-{n}/score.json
      run-{n}/events.jsonl   # team session 이벤트 로그
    report.md            # 비교 리포트
    report.json          # 원시 데이터
```

## 해석 기준

- composite_score: collab > baseline이면 협업이 효과적
- total_tokens: collab/baseline 비율 = 토큰 효율
- latency: collab이 느릴 수 있지만 품질이 보상하면 유의미
- convergence_rate < 80%면 협업 프로토콜 자체에 문제

## 한계

- 질문 3개는 통계적으로 약함 (질문셋 확장 권장)
- llama-server 동시 모델 서빙 불가로 순차 실행
- 9B 모델의 tool calling 능력이 35B보다 떨어질 수 있음 (실험으로 확인 필요)
