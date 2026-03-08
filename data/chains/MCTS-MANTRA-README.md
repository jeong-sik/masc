# MCTS-MANTRA Code Review Pipeline

Monte Carlo Tree Search 기반 MANTRA 코드 리뷰 체인 시스템.

## 체인 목록

| Chain ID | 모드 | 설명 | 사용 시점 |
|----------|------|------|-----------|
| `mcts-mantra-review` | 끝장 리뷰 | 품질 목표 도달까지 반복 수정 | PR 머지 전, 배포 전 |
| `mcts-mantra-explore` | 문제 발견 | 다관점 이슈 탐색 | 코드 감사, 기술 부채 분석 |
| `mcts-mantra-hybrid` | 하이브리드 | 탐색 → 우선순위 → 순차 수정 | 대규모 리팩토링 |

---

## 1. 끝장 리뷰 (mcts-mantra-review)

```
┌─────────────────────────────────────────────────────────────┐
│  Input → Expansion → Simulation → Selection → Backprop     │
│          (3 LLMs)    (Evaluator)   (Gate)    (GoalDriven)  │
└─────────────────────────────────────────────────────────────┘
```

### MCTS 매핑

| MCTS Phase | MANTRA Role | Chain Node |
|------------|-------------|------------|
| **Expansion** | Developer | `fanout` (Claude, Gemini, Codex) |
| **Simulation** | Reviewer | `evaluator` (anti_fake scoring) |
| **Selection** | Best Pick | `gate` (score >= 0.8?) |
| **Backpropagation** | Repairer | `goal_driven` (until 0.85) |

### 사용법

```bash
# MCP tool call
curl -X POST http://localhost:8932/mcp -d '{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "chain.orchestrate",
    "arguments": {
      "chain_id": "mcts-mantra-review",
      "input": {
        "code": "function add(a, b) { return a + b }",
        "feedback": "Add type annotations and error handling"
      }
    }
  }
}'
```

---

## 2. 문제 발견 (mcts-mantra-explore)

```
┌─────────────────────────────────────────────────────────────┐
│                    5-Way Parallel Analysis                   │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────┐│
│  │ Security │ │  Perf    │ │  Types   │ │  Logic   │ │Mnt ││
│  │ (Claude) │ │(Gemini)  │ │ (Codex)  │ │ (Ollama) │ │(G) ││
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘ └─┬──┘│
│       └────────────┴────────────┴────────────┴─────────┘   │
│                            │                                │
│                            ▼                                │
│                   ┌────────────────┐                        │
│                   │ Merge + Prioritize                      │
│                   │ (Claude)       │                        │
│                   └────────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### 분석 관점

| Analyst | Model | Focus Areas |
|---------|-------|-------------|
| Security | Claude | Injection, Auth, Data exposure |
| Performance | Gemini | O(n²), Memory leaks, N+1 |
| Type Safety | Codex | any, null checks, casts |
| Logic | Ollama | Off-by-one, race conditions |
| Maintainability | Gemini | God functions, nesting, naming |

### 출력 형식

```json
{
  "summary": {
    "total_issues": 12,
    "critical": 1,
    "high": 3,
    "medium": 5,
    "low": 3,
    "health_score": 0.65
  },
  "top_priority": [...],
  "by_category": {...},
  "quick_wins": [...]
}
```

---

## 3. 하이브리드 (mcts-mantra-hybrid)

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: Explore    →    Phase 2: Fix Loop                 │
│  (mcts-mantra-explore)    (GoalDriven until 0.9)           │
│                                                              │
│  ┌─────────────┐         ┌─────────────────────────────┐   │
│  │ 5-Way       │         │  For each top issue:        │   │
│  │ Analysis    │────────▶│    1. Select issue          │   │
│  │             │         │    2. Generate 2 fixes      │   │
│  └─────────────┘         │    3. Evaluate & pick best  │   │
│                          │    4. Apply & re-measure    │   │
│                          └─────────────────────────────┘   │
│                                       │                     │
│                                       ▼                     │
│                          ┌─────────────────────────────┐   │
│                          │  Final Report (Markdown)    │   │
│                          └─────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Fix Loop Strategy

| Health Score | Strategy |
|--------------|----------|
| < 50% | `fix_critical_first` |
| 50-70% | `fix_high_priority` |
| 70-85% | `fix_medium_and_polish` |
| > 85% | `final_polish` |

### 출력 예시

```markdown
# Code Review Report

## Executive Summary
- Original health: 0.45 → Final health: 0.92
- Issues fixed: 8/12
- Iterations: 4

## What Was Fixed
1. [HIGH] SQL injection in user query
2. [HIGH] Missing null check on API response
...

## Remaining Issues
1. [LOW] Magic number on line 42
...

## Recommendations
- Consider adding integration tests
- Enable strict TypeScript mode
```

---

## 아키텍처: MCTS → Chain DSL 매핑

```
┌─────────────────────────────────────────────────────────────┐
│                    MCTS Algorithm                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   Selection ─────────► UCT/UCB1 Score                       │
│       │                     │                                │
│       │                     ▼                                │
│       │             Chain: gate / evaluator                  │
│       │                                                      │
│   Expansion ────────► Generate Children                      │
│       │                     │                                │
│       │                     ▼                                │
│       │             Chain: fanout (multi-LLM)               │
│       │                                                      │
│   Simulation ───────► Evaluate State                         │
│       │                     │                                │
│       │                     ▼                                │
│       │             Chain: evaluator (anti_fake)            │
│       │                                                      │
│   Backpropagation ──► Update Scores                         │
│                             │                                │
│                             ▼                                │
│                     Chain: goal_driven (iterate)            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 실행 예시

```bash
# 1. 끝장 리뷰
chain.orchestrate --chain_id=mcts-mantra-review --input='{"code":"...", "feedback":"..."}'

# 2. 문제 발견
chain.orchestrate --chain_id=mcts-mantra-explore --input='{"code":"..."}'

# 3. 하이브리드
chain.orchestrate --chain_id=mcts-mantra-hybrid --input='{"code":"..."}'
```

---

## 비용 추정

| Chain | LLM Calls | Est. Tokens | Est. Cost |
|-------|-----------|-------------|-----------|
| review | 3-12 | 10K-40K | $0.05-$0.20 |
| explore | 6 | 15K | $0.08 |
| hybrid | 10-30 | 30K-100K | $0.15-$0.50 |

*Costs based on Claude/Gemini API pricing (Jan 2026)*
