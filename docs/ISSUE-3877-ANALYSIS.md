# Issue #3877 분석: Qwen3.5-9B Tool Calling 품질 개선안

## 문제 요약

현재 10개 활성 keeper가 Qwen3.5-9B를 사용 중이며, `autonomous_tool_turn_count=0`으로 tool calling 성공률이 매우 낮은 상태입니다.

## 현재 상태 분석

### 1. 현재 Cascade 구성

**Primary Configuration** (`config/cascade.json`):
```json
{
  "keeper_unified_models": ["llama:auto", "glm:auto"],
  "keeper_turn_models": ["llama:auto", "glm:auto"],
  "keeper_reply_models": ["glm:auto", "llama:auto"],
  "keeper_autonomy_models": ["llama:auto", "glm:auto"],
  "keeper_proactive_models": ["llama:auto", "glm:auto"],

  "keeper_unified_temperature": 0.4,
  "keeper_unified_max_tokens": 2048,
  "keeper_autonomy_temperature": 0.3,
  "keeper_autonomy_max_tokens": 500
}
```

**Default 3-Tier Cascade** (`data/chains/cascade-default.json`):
- Tier 1: GLM (로컬, cost=0.0, confidence_threshold=0.7)
- Tier 2: Gemini (클라우드, cost=1.0, confidence_threshold=0.7)
- Tier 3: Claude (최종, cost=10.0, confidence_threshold=0.0)

### 2. 현재 모델 인프라

**문서 기준** (`docs/spec/01-system-overview.md:211`):
- llama-server: localhost:8085
- 현재 사용: Qwen3.5-35B-A3B Q4_K_XL (35B 모델)
- 벤치마크 설정: `qwen35-hot` preset, ctx=262144

**실제 사용 예시** (`scripts/harness/local64-model-matrix.example.json`):
```json
{
  "label": "qwen35-a3b-ud-q8-xl",
  "alias": "qwen3.5-35b-a3b-ud-q8-xl",
  "model_path": "/Users/dancer/models/Qwen3.5-35B-A3B-UD-Q8_K_XL-20260305.gguf",
  "target_shards": 2,
  "worker_count": 16
}
```

### 3. Tool Calling 품질 추적 시스템

**메트릭 수집 인프라**:
- `lib/tool_metrics_persist.ml`: JSONL 기반 영속화, 5분 플러시 간격
- `lib/keeper/keeper_tools_oas.ml`: 연속 실패 추적 및 차단
- `lib/trajectory.ml`: 전체 tool call trajectory 로깅
- `lib/tool_unified.ml`: 통합 쿼리 인터페이스 (count, success, p50/p95/p99)
- `lib/eval_harness.ml`: 시나리오 기반 평가 프레임워크

**Dashboard 엔드포인트**:
- `GET /api/v1/tool-metrics`: 통합 레지스트리 통계
- Keeper 상세 패널: tool/text turn 분리 표시

### 4. 문제의 근본 원인

**Issue에서 언급된 Qwen3.5-9B**는:
1. **실제 운영 모델(35B)과 다름**: 문서는 35B-Q4_K_XL을 명시하지만, issue는 9B를 언급
2. **9B 모델의 제약사항** (`docs/design/inventory-gap-analysis-rfc.md:150`):
   - "로컬 모델(qwen3.5-9b)은 강제 없이 [STATE] 포맷을 거의 생성하지 않는다"
   - Tool calling structured output 생성 능력 부족
3. **Memory recall 로직** (`lib/keeper/keeper_memory_recall.ml:289`):
   ```ocaml
   if contains "qwen" || contains "llama" || contains "mistral"
   ```
   - 로컬 소형 모델은 context overflow에 더 취약하다고 명시

## 개선 방안

### Option 1: 즉시 적용 가능 - Cascade 우선순위 조정 ⭐ 추천

**목표**: GLM 우선 시도 후 로컬 모델 폴백

```json
{
  "keeper_unified_models": ["glm:auto", "llama:auto"],
  "keeper_autonomy_models": ["glm:auto", "llama:auto"],
  "keeper_proactive_models": ["glm:auto", "llama:auto"]
}
```

**장점**:
- Zero configuration change (이미 cascade에 포함)
- GLM은 클라우드지만 Z.ai API로 cost-effective
- Tool calling structured output 능력 검증됨
- 즉시 적용 가능

**단점**:
- 약간의 외부 API 비용 증가
- 레이턴시 증가 (로컬 → 클라우드)

### Option 2: 로컬 모델 업그레이드

**2.1. Qwen3.5-35B로 전환 (기존 인프라 활용)**

이미 문서에 35B가 표준으로 명시되어 있으므로, 현재 9B를 사용 중이라면 35B로 교체:

```bash
# llama-server 재시작
LLAMA_PRESET=qwen35-hot ~/me/scripts/llama-server.sh restart
```

**장점**:
- 문서 기준과 일치
- Zero external cost
- 35B는 9B보다 tool calling 능력 우수
- 기존 벤치마크 인프라 그대로 사용

**단점**:
- 메모리 요구사항 증가 (35B Q8: ~40GB)
- 추론 속도 저하

**2.2. 대체 로컬 모델 고려**

현재 인프라가 지원하는 다른 옵션:
- **Llama 3.1/3.2 시리즈**: Meta 공식, tool calling native 지원
- **DeepSeek-V3**: 강력한 tool use 능력, MoE 아키텍처로 효율적
- **Qwen2.5-Coder 시리즈**: 코드 및 structured output 특화

### Option 3: Hybrid Cascade - Tool Call 전용 라우팅

**새로운 cascade 프로필 추가**:

```json
{
  "keeper_tool_calling_models": ["gemini:auto", "glm:auto", "llama:auto"],
  "keeper_tool_calling_temperature": 0.2,
  "keeper_tool_calling_max_tokens": 1024
}
```

**구현 위치**: `lib/keeper/keeper_coordination.ml:23-24` (`effective_model_labels_for_turn`)

**로직**:
```ocaml
let effective_model_labels_for_turn ~has_tool_context ~cascade_name () =
  match has_tool_context, cascade_name with
  | true, "keeper_unified" ->
      Cascade_config.models_of_name "keeper_tool_calling_models"
  | _ ->
      Cascade_config.models_of_name cascade_name
```

**장점**:
- Tool calling이 필요한 턴만 선택적으로 강력한 모델 사용
- 일반 텍스트 응답은 로컬 모델 유지 (cost 절감)
- Fine-grained control

**단점**:
- 코드 수정 필요
- 추가 복잡도

### Option 4: Temperature 및 Inference 파라미터 튜닝

**현재 설정**:
```json
{
  "keeper_unified_temperature": 0.4,
  "keeper_autonomy_temperature": 0.3
}
```

**Tool calling 최적화 제안**:
```json
{
  "keeper_unified_temperature": 0.2,        // 더 deterministic
  "keeper_autonomy_temperature": 0.1,       // Tool call은 creativity 불필요
  "keeper_unified_top_p": 0.9,              // 추가
  "keeper_unified_min_p": 0.05              // 추가
}
```

**근거**: Tool calling은 structured output이므로 낮은 temperature가 성공률 향상

### Option 5: 평가 기반 접근 - A/B 테스트

**기존 Eval Harness 활용** (`lib/eval_harness.ml`):

```bash
# 1. Tool calling 시나리오 정의
cat > test/fixtures/tool_calling_eval.json <<EOF
{
  "scenario_id": "keeper_tool_quality",
  "description": "Keeper autonomous tool calling quality",
  "prompts": [...],
  "tool_expectations": {
    "required_tools": ["keeper_board_read", "keeper_memory_store"],
    "max_calls": 5
  }
}
EOF

# 2. 모델별 평가 실행
./scripts/harness/workload/coding_worker_quickwin.sh
```

**측정 지표**:
- Tool call success rate
- Tool call relevance (deterministic grader)
- Latency (p50, p95, p99)
- Cost per successful tool call

**비교 대상**:
1. Qwen3.5-9B (baseline)
2. Qwen3.5-35B
3. GLM-first cascade
4. Gemini-first cascade

## 즉시 실행 가능한 액션 플랜

### Phase 1: 진단 (1-2시간)

```bash
# 1. 현재 실제 사용 모델 확인
curl http://127.0.0.1:8085/v1/models

# 2. Keeper 상태 확인
curl http://127.0.0.1:8935/api/v1/keeper/list | jq '.[] | {name, autonomous_tool_turn_count, autonomous_text_turn_count, last_model_used}'

# 3. Tool metrics 확인
curl http://127.0.0.1:8935/api/v1/tool-metrics | jq '.top_tools[] | {name, success_rate: (.success_count / .total_count)}'

# 4. Trajectory 로그 분석
find .masc/trajectories -name "*.jsonl" -mtime -1 | xargs cat | jq 'select(.type=="tool_call") | {tool: .tool_name, status: .status}'
```

### Phase 2: 빠른 개선 (즉시 적용)

**권장: Option 1 적용**

```bash
# config/cascade.json 수정
cat > config/cascade.json <<EOF
{
  "keeper_unified_models": ["glm:auto", "llama:auto"],
  "keeper_turn_models": ["glm:auto", "llama:auto"],
  "keeper_autonomy_models": ["glm:auto", "llama:auto"],
  "keeper_proactive_models": ["glm:auto", "llama:auto"],

  "keeper_unified_temperature": 0.2,
  "keeper_unified_max_tokens": 2048,
  "keeper_autonomy_temperature": 0.1,
  "keeper_autonomy_max_tokens": 500
}
EOF

# MASC 재시작
./start-masc-mcp.sh --http
```

### Phase 3: 검증 (1-2일)

```bash
# 24시간 후 재측정
curl http://127.0.0.1:8935/api/v1/keeper/list | \
  jq '[.[] | {tool_turns: .autonomous_tool_turn_count, text_turns: .autonomous_text_turn_count}] |
      {total_tool_turns: (map(.tool_turns) | add), total_text_turns: (map(.text_turns) | add)}'
```

**성공 기준**:
- `autonomous_tool_turn_count > 0` for at least 8/10 keepers
- Tool call success rate > 60%
- No increase in cost per keeper > 10%

## 장기 전략 권고사항

### 1. Model Registry 도입

현재 `llama:auto`, `glm:auto`는 추상화되어 있지만, 실제 모델 선택은 런타임 의존적입니다.

**제안**: `config/model-registry.json` 추가

```json
{
  "llama:auto": {
    "primary": "qwen3.5-35b-a3b-ud-q8-xl",
    "fallback": "qwen3.5-35b-a3b-ud-q4-xl",
    "capabilities": ["tool_calling", "reasoning", "code"],
    "min_tool_call_quality_score": 0.7
  },
  "glm:auto": {
    "provider": "z.ai",
    "capabilities": ["tool_calling", "reasoning"],
    "cost_per_1m_tokens": 1.0
  }
}
```

### 2. Tool Calling Quality Monitoring

**Dashboard 개선 제안**:
- Per-keeper tool success rate 시각화
- Tool call latency histogram
- Model-specific tool quality breakdown
- Alert when `autonomous_tool_turn_count` stagnates

**구현 위치**: `dashboard/src/components/keeper-detail-runtime.ts:113`

### 3. Automatic Model Fallback

**Keeper-level circuit breaker**:

```ocaml
(* lib/keeper/keeper_coordination.ml *)
let select_model_for_turn ~rt ~consecutive_tool_failures =
  if consecutive_tool_failures > 3 then
    (* Escalate to higher-quality model *)
    Cascade_config.models_of_name "keeper_tool_calling_models"
  else
    Cascade_config.models_of_name rt.cascade_name
```

## 참고 문헌

- `docs/BENCHMARK-RUNBOOK.md`: 벤치마크 실행 가이드
- `docs/KEEPER-USER-MANUAL.md`: Keeper 메트릭 정의
- `lib/eval_harness.ml`: 평가 프레임워크
- `lib/keeper/keeper_tools_oas.ml`: Tool execution 로직
- `config/cascade.json`: 현재 cascade 설정
- Issue #3877: https://github.com/jeong-sik/masc-mcp/issues/3877

## 결론 및 권장사항

**즉시 적용 권장**: Option 1 (GLM-first cascade) + Temperature 튜닝

**이유**:
1. **Zero infrastructure change**: 이미 cascade에 포함된 모델 사용
2. **검증된 솔루션**: GLM은 클라우드지만 Z.ai로 cost-effective
3. **점진적 개선**: 실패 시 로컬 모델로 폴백 유지
4. **즉시 측정 가능**: 24시간 내 `autonomous_tool_turn_count` 개선 확인 가능

**중기 계획**: Qwen3.5-35B 로컬 인프라 확인 및 전환 (현재 9B 사용 중이라면)

**장기 전략**: Model registry + automatic fallback + quality monitoring 구축

---

**Next Steps**:
1. 현재 실제 사용 모델 확인 (9B vs 35B)
2. Option 1 적용 및 24시간 관찰
3. 결과에 따라 Option 2 또는 3 선택
4. Eval harness로 정량적 비교 수행
