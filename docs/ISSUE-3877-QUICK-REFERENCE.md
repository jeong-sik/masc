# Issue #3877 빠른 참조 가이드

## 문제 요약
Qwen3.5-9B 사용 중인 keeper들의 `autonomous_tool_turn_count=0`, tool calling 실패

## 즉시 적용된 해결책

### 1. Cascade 우선순위 변경 (✓ 적용됨)

**변경 사항** (`config/cascade.json`):
```diff
- "keeper_unified_models": ["llama:auto", "glm:auto"]
+ "keeper_unified_models": ["glm:auto", "llama:auto"]

- "keeper_autonomy_models": ["llama:auto", "glm:auto"]
+ "keeper_autonomy_models": ["glm:auto", "llama:auto"]

- "keeper_proactive_models": ["llama:auto", "glm:auto"]
+ "keeper_proactive_models": ["glm:auto", "llm:auto"]
```

**효과**: GLM (Z.ai 클라우드 모델)을 먼저 시도, tool calling 품질 향상

### 2. Temperature 최적화 (✓ 적용됨)

```diff
- "keeper_unified_temperature": 0.4
+ "keeper_unified_temperature": 0.2

- "keeper_autonomy_temperature": 0.3
+ "keeper_autonomy_temperature": 0.1
```

**효과**: Tool calling은 structured output이므로 낮은 temperature가 성공률 향상

## 검증 방법

### 즉시 검증
```bash
# 설정 변경 후 MASC 재시작
./start-masc-mcp.sh --http

# 검증 스크립트 실행
./scripts/verify-keeper-tool-quality.sh
```

### 24시간 후 검증
```bash
# Keeper 상태 확인
curl http://127.0.0.1:8935/api/v1/keeper/list | \
  jq '[.[] | {
    name,
    tool_turns: .autonomous_tool_turn_count,
    text_turns: .autonomous_text_turn_count,
    model: .last_model_used
  }]'

# 성공 기준:
# - autonomous_tool_turn_count > 0 for 8/10 keepers
# - GLM 모델 사용 확인
```

## 추가 개선 옵션

### Option A: Qwen3.5-35B로 로컬 모델 업그레이드
```bash
# 현재 사용 모델 확인
curl http://127.0.0.1:8085/v1/models

# 35B로 전환 (문서 표준)
LLAMA_PRESET=qwen35-hot ~/me/scripts/llama-server.sh restart
```

### Option B: Hybrid cascade (tool call 전용 라우팅)
`docs/ISSUE-3877-ANALYSIS.md` 참조 - Option 3

## 모니터링 지표

### Dashboard 확인 사항
1. Keeper 상세 페널: "도구 턴" 수치 증가 확인
2. Tool Metrics: Success rate > 60%
3. Model 사용: GLM 비율 증가

### CLI 확인
```bash
# Tool success rate
curl http://127.0.0.1:8935/api/v1/tool-metrics | \
  jq '.top_tools[] | {
    name,
    success_rate: ((.success_count * 100.0 / .total_count) | floor)
  }'

# Recent trajectory
find .masc/trajectories -name "*.jsonl" -mtime -1 | \
  xargs cat | \
  jq 'select(.type=="tool_call") | {tool: .tool_name, status}' | \
  head -20
```

## 롤백 방법

문제 발생 시 이전 설정으로 복원:
```bash
cd config
git checkout HEAD~1 cascade.json
./start-masc-mcp.sh --http
```

## 관련 문서
- `docs/ISSUE-3877-ANALYSIS.md`: 상세 분석 및 대안
- `docs/KEEPER-USER-MANUAL.md`: Keeper 메트릭 설명
- `docs/BENCHMARK-RUNBOOK.md`: 평가 프레임워크

## 문의
Issue: https://github.com/jeong-sik/masc-mcp/issues/3877
