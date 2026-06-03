# Keeper Social Experiment Design

Date: 2026-02-14  
Scope: MASC keeper autonomy, handoff/compaction stability, small-society behavior

## 1) Goal

지속 실행되는 Keeper 집단(작은 사회)이 아래를 동시에 만족하는지 검증한다.

- 안정성: timeout/latency/regression 없이 장시간 turn 지속
- 기억 연속성: compaction/handoff 이후에도 핵심 맥락 보존
- 사회성: 역할 분화가 실제로 의견 다양성과 실행 품질을 높임

## 2) Research Anchors

- ReAct (Yao et al., 2022): https://arxiv.org/abs/2210.03629
- Reflexion (Shinn et al., 2023): https://arxiv.org/abs/2303.11366
- CRITIC (Gou et al., 2023): https://arxiv.org/abs/2305.11738
- Lost in the Middle (Liu et al., 2023): https://arxiv.org/abs/2307.03172
- MemGPT (Packer et al., 2023): https://arxiv.org/abs/2310.08560
- Generative Agents (Park et al., 2023): https://arxiv.org/abs/2304.03442
- Voyager (Wang et al., 2023): https://arxiv.org/abs/2305.16291
- AgentBench (Liu et al., 2023): https://arxiv.org/abs/2308.03688

## 3) Hypotheses

- H1. `keeper_status` fast-path + `keeper_msg` post-pass budget는 timeout rate를 낮추되 recall 지표를 유지한다.
- H2. 역할 분화된 Keeper cohort(archivist/skeptic/builder/dreamer/moderator)는 단일 스타일 cohort 대비 답변 다양성이 높다.
- H3. 사회적 프로토콜(제안/반박/실행)의 강제는 실행 가능한 action item 비율을 높인다.

## 4) Arms (A/B)

- Arm A `baseline`:
  - 자유 서술형 라운드 토론
  - 최소 구조화
- Arm B `protocol`:
  - 각 turn에서 `proposal + critique + action` 강제
  - moderator가 라운드 합의/이견/다음 행동 요약

## 5) Metrics

하네스가 자동 산출하는 핵심 지표:

- `success_rate`: tool call 성공률
- `avg_latency_ms`, `p95_latency_ms`
- `handoff_events`, `compaction_events`
- `avg_context_ratio`
- `reply_diversity_ratio`:
  - 고유 reply preview 수 / 전체 turn 수
- `dissent_mentions`:
  - 반대/이견/disagree/however/but 패턴 출현 count
- Dashboard 보조 지표:
  - `/api/v1/dashboard`의 `status.tool_call_health.*`

## 6) Experiment Flow

1. Cohort 기동 (`masc_keeper_up`)
2. 라운드 반복
   - worker keepers에게 동일 주제 + 직전 라운드 요약 전달
   - moderator keeper가 라운드 결과 요약
3. 각 turn JSONL 기록
4. arm별 summary 계산
5. A/B delta 계산
6. 선택적으로 keeper 정리 (`masc_keeper_down`)

## 7) Dev Test Plan

### 7.1 Harness smoke (no server)

`DRY_RUN=1` 모드로 하네스 로직/집계/파일출력만 검증한다.

```bash
cd ~/me/workspace/yousleepwhen/masc
DRY_RUN=1 ROUNDS=2 ARMS=baseline ./scripts/run_keeper_social_experiment.sh
```

검증 포인트:

- `logs/social_experiment/<run_id>/summary_baseline.json` 생성
- `manifest.json` 및 `arm_*.jsonl` 정상 기록

### 7.2 Integration smoke (local server)

```bash
cd ~/me/workspace/yousleepwhen/masc
./start-masc.sh
ROUNDS=2 ARMS=baseline ./scripts/run_keeper_social_experiment.sh
```

검증 포인트:

- `tool_call_health.timeouts` 증가 없이 완료
- `success_rate >= 0.95`

### 7.3 Regression gate (before merge)

- Build:
  - `dune build --display=short`
- Related coverage tests:
  - `_build/default/test/test_mcp_server_eio_coverage.exe`
  - `_build/default/test/test_web_dashboard_coverage.exe`
  - `_build/default/test/test_tool_audit_coverage.exe`

## 8) Failure Criteria

아래 중 하나면 실패로 간주:

- `success_rate < 0.90`
- `timeouts > 0` (smoke 기준)
- `p95_latency_ms`가 baseline 대비 2배 이상 증가
- summary 파일 미생성 또는 JSON 파싱 실패

## 9) Operational Notes

- 현재 하네스는 정량화 가능성(재현/비교)에 우선순위를 둔다.
- 품질 판단은 반드시 arm 간 delta로 비교한다. 절대값만으로 결론 내리지 않는다.
- 장기 실험(수시간~수일)은 `ARMS=baseline,protocol` + `ROUNDS` 증대 후 수행한다.

