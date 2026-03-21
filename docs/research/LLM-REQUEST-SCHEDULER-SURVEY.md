# LLM Request Priority Scheduler — Survey & OAS Design Notes

조사일: 2026-03-21

## 문제

MASC keeper 5개가 4-slot llama-server를 공유.
Background heartbeat가 슬롯을 전부 점유하면 interactive chat이 무한 대기.
llama-server 자체에는 priority queue가 없음.

## 업계 접근법 (2025-2026)

### 1. AgentRM — OS-Inspired Resource Manager (2026.03)

- 논문: https://arxiv.org/html/2603.13110
- **Multi-Level Feedback Queue (MLFQ)** 스케줄러
- interactive(user-facing) → 높은 큐, background(heartbeat) → 낮은 큐
- zombie reaping + rate-limit-aware admission control
- 3-tier Context Lifecycle Manager (working / archive / evict)
- 핵심 인사이트: agent 리소스를 OS 리소스처럼 취급

### 2. vLLM Priority Scheduling (진행 중)

- RFC: https://github.com/vllm-project/vllm/issues/30256
- SLA tier 파라미터를 요청에 추가
- interactive가 batch를 **preempt**(선점), 완료 후 batch 재개
- KV cache 보존하면서 선점 가능 (swap to CPU)
- Strict Priority 구현: https://github.com/IBM/vllm/pull/48
- 알려진 제약: chunked-prefill 활성 시 preemption 미동작

### 3. Agent.xpu — Heterogeneous SoC Scheduling (2025)

- 논문: https://arxiv.org/html/2506.24045v1/
- reactive(사용자 요청) vs proactive(background) 이분법
- 사용자 → low-latency 경로, background → throughput 경로
- heterogeneous 실행 그래프: CPU/GPU/NPU 매핑

### 4. Autellix — Program-Level Scheduling (2025)

- 논문: https://arxiv.org/html/2502.13965v1
- agentic workflow의 총 실행 시간 기준으로 우선순위
- 짧은 프로그램 우선 완료 → head-of-line blocking 제거
- vLLM 대비 4-15x throughput 개선

### 5. Astraea — Stateful-MLFQ (2025)

- 논문: https://arxiv.org/pdf/2512.14142
- 요청의 과거 행동 + 미래 예측을 통합한 MLFQ
- hierarchical, preemptive scheduling
- 효율성과 공정성 균형

### 6. Semantic Scheduling (2025)

- 논문: https://arxiv.org/html/2506.12204v1
- LLM 기반 classifier로 요청 urgency 태깅
- urgency + estimated output cost → min-heap 스케줄러
- high-priority 요청이 batch formation에 블록되지 않음

## 정량적 효과

- Hexgen-Text2SQL: latency 1.67x 감소, throughput 1.75x 증가
- Autellix: vLLM 대비 4-15x throughput

## OAS 적용 설계 (제안)

### Application-Level MLFQ

llama-server에 priority가 없으므로 OAS cascade 레이어에서 처리.

```
요청 → OAS Request Scheduler (MLFQ)
  ├─ P0: interactive (chat, user message)     → 즉시 dispatch
  ├─ P1: proactive (keeper turn, board reply) → 슬롯 여유 시
  └─ P2: background (heartbeat, status tick)  → 나머지
```

### 구현 방향

1. **Request tagging**: cascade 호출 시 `priority: P0|P1|P2` 필드 추가
2. **Admission control**: P0 요청 도착 시 P2 요청 preempt (cancel + requeue)
3. **Slot monitoring**: llama-server `/slots` 엔드포인트로 slot 상태 주기적 확인
4. **Timeout propagation**: LLM 타임아웃 시 SSE에 RUN_ERROR 이벤트 전파 (현재 silent drop 버그)

### llama-server 대안

| 방법 | 장점 | 단점 |
|------|------|------|
| `--n-parallel 8` | 즉시 적용 | 12+ 슬롯부터 성능 급감 |
| 별도 포트 chat 전용 서버 | 완전 격리 | 모델 2x 메모리 |
| vLLM 전환 | native priority | Apple Silicon 미지원 |
| OAS MLFQ | llama-server 무관 | 구현 필요 |

### 권장 경로

1. **즉시**: `--n-parallel 8` + keeper heartbeat 간격 60초→120초
2. **단기**: OAS cascade에 P0/P1/P2 태깅 + P0 fast-path
3. **중기**: MLFQ 스케줄러 + slot monitoring + preemption
4. **장기**: vLLM Apple Silicon 지원 시 전환 검토

## 관련 이슈

- 대시보드 keeper chat이 heartbeat 경쟁으로 응답 못 받는 문제 발견 (2026-03-21)
- SSE 타임아웃 시 RUN_ERROR 미전파 버그 (silent drop)
