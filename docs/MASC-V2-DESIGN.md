# MASC v2: Git-Native Multi-Agent Workspace

> "Git for AI Agents" - 다중 MODEL 에이전트의 협업을 Git 워크플로우로 조율

## Executive Summary

MASC v2는 Git Worktree를 활용한 에이전트 격리와 `gh` CLI 기반 PR 워크플로우를 통해
다중 AI 에이전트가 동일 코드베이스에서 충돌 없이 협업할 수 있게 합니다.

**Current runtime status (2026-05):** mainline server bootstrap is filesystem-only by construction. There is no runtime storage selector; retired Redis/PostgreSQL storage modes are not operator targets.

### Design Principles (MAGI 삼두 합의)

| Principle | Origin | Rationale |
|-----------|--------|-----------|
| **Worktree Isolation** | CASPER | 에이전트별 완전 격리, 락 불필요 |
| **Use `gh` CLI** | CASPER | PR 시스템 재발명 금지, 기존 도구 활용 |
| **Capability-based** | BALTHASAR | 역할 기반보다 능력 기반 라우팅 |
| **Layered History** | BALTHASAR | 불변/압축/휘발 계층 분리 |
| **Git as Event Log** | CASPER | git log가 곧 이벤트 로그 |

---

## Architecture

```
project-root/
├── .git/                          # Git repository
├── .masc/                         # MASC workspace collaboration layer
│   ├── state.json                 # Workspace state (agents, tasks)
│   ├── agents/                    # Agent metadata
│   │   ├── agent-llm-a.json            # {capabilities, status, current_worktree}
│   │   ├── provider-f.json
│   │   └── agent-code.json
│   ├── events/                    # Immutable event log (compact layer)
│   │   └── YYYY-MM/
│   │       └── DD.jsonl           # Append-only daily events
│   └── backlog.json               # Task queue
│
├── .worktrees/                    # Git worktrees (agent isolation)
│   ├── agent-llm-a-feature-x/          # Agent-LLM-A's isolated workspace
│   ├── provider-f-fix-y/              # Provider-F's isolated workspace
│   └── agent-code-refactor-z/          # Agent-Code's isolated workspace
│
└── src/                           # Main codebase
```

### Storage Mode

Current MASC runtime supports one storage mode: local filesystem under `.masc/`.

```
Machine A:
┌───────────────┐
│ Agent-LLM-A ─┐     │
│ Provider-F ─┼ .masc/
│ Agent-Code ──┘     │
└───────────────┘
```

**Environment Variables**:

| Variable | Purpose |
|----------|---------|
| `MASC_BASE_PATH` | Base path (determines `.masc/` location) |
| `MASC_CLUSTER_NAME` | Cluster name override |

**Use Cases**:
- **Filesystem Mode**: CLI-Tool-A + terminal Provider-F/Agent-Code on the same machine. This is the only supported runtime storage lane.

---

## Cluster vs Workspace: 개념 정리

MASC에서 가장 혼동하기 쉬운 개념이 **Cluster**와 **Workspace**입니다.

```
┌─────────────────────────────────────────────────────────────────────┐
│  Cluster: "me"                                                       │
│  (MASC_CLUSTER_NAME 또는 기본 label)                                  │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Workspace: "default"                                             │    │
│  │  (협업 공간 - 같은 .masc/ filesystem state)                │    │
│  │                                                               │    │
│  │   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │    │
│  │   │ agent-llm-a-rare- │  │ provider-f-      │  │ agent-code-swift- │      │    │
│  │   │ koala        │  │ fierce-zebra │  │ falcon       │      │    │
│  │   │ (Agent)      │  │ (Agent)      │  │ (Agent)      │      │    │
│  │   └──────────────┘  └──────────────┘  └──────────────┘      │    │
│  │                                                               │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │  Workspace: "frontend-team" (Future: 여러 Workspace 지원 예정)         │    │
│  │   ┌──────────────┐  ┌──────────────┐                        │    │
│  │   │ agent-llm-a-web   │  │ agent-code-ui     │                        │    │
│  │   └──────────────┘  └──────────────┘                        │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 용어 정의

| 용어 | 설명 | 예시 |
|------|------|------|
| **Cluster** | 서버/인스턴스 식별자. `MASC_CLUSTER_NAME` 또는 기본 label | `"default"` |
| **Workspace** | 실제 협업 공간. 같은 Workspace = 같은 Task Board, Messages, Agents | `"default"` (기본 Workspace) |
| **Agent** | Workspace 내에서 작업하는 개별 MODEL 인스턴스 | `agent-llm-a-rare-koala`, `provider-f-fierce-zebra` |

### 협업 조건

에이전트들이 협업하려면:

1. **같은 Cluster**: 동일한 `MASC_CLUSTER_NAME` 값
2. **같은 Workspace**: 동일한 Workspace ID (현재는 "default" 고정)
3. **같은 Storage**: 동일 `.masc/` 폴더 접근

### `masc_status` 출력 예시

```
Cluster: me
Workspace: default
Path: <MASC_BASE_PATH>/.masc

Active Agents (2)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• agent-llm-a-rare-koala (working on task-027)
• provider-f-fierce-zebra (idle)
```

---

## Core Concepts

### 1. Agent Isolation via Git Worktree

**Why Worktree > File Lock**:
- 락: 순차적 접근, 병렬 불가, 데드락 위험
- Worktree: 완전 격리, 병렬 작업, Git이 충돌 해결

**Workflow**:
```bash
# Agent joins and creates worktree
masc_bind --agent agent-llm-a --capabilities "typescript,review"
git worktree add .worktrees/claude-PK-12345 -b agent-llm-a/PK-12345 origin/develop

# Agent works in isolated worktree
cd .worktrees/claude-PK-12345
# ... make changes ...

# Agent publishes work through the repository's normal remote review workflow.
# MASC records workspace collaboration state; it does not wrap remote repository lifecycle actions.
masc_broadcast "work ready for external review"
```

### 2. Capability-based Routing (not Role-based)

**BALTHASAR 경고**: "Commander/Worker 역할 구분은 인간중심적 함정"

**Instead**:
```json
{
  "agent": "agent-llm-a",
  "capabilities": ["typescript", "code-review", "architecture"],
  "availability": 0.8,
  "current_load": 2
}
```

**Task Matching**:
```
Task: "Review TypeScript PR"
Required: ["typescript", "code-review"]

Match: agent-llm-a (2/2 capabilities) > provider-f (1/2) > agent-code (1/2)
```

### 3. Layered History (BALTHASAR 제안)

| Layer | Retention | Content | Storage |
|-------|-----------|---------|---------|
| **Immutable** | Forever | Major decisions, merges | `.masc/events/` |
| **Compactable** | 90 days | Daily summaries | Git commits |
| **Ephemeral** | Session | Real-time messages | Memory only |

**Immutable Events** (`.masc/events/YYYY-MM/DD.jsonl`):
```jsonl
{"seq":1,"type":"agent_join","agent":"agent-llm-a","ts":"2025-01-02T10:00:00Z"}
{"seq":2,"type":"task_claim","agent":"agent-llm-a","task":"PK-12345","ts":"2025-01-02T10:01:00Z"}
{"seq":3,"type":"work_published","agent":"agent-llm-a","ref":"agent-llm-a/PK-12345","ts":"2025-01-02T11:00:00Z"}
{"seq":4,"type":"work_reviewed","agent":"provider-f","ref":"agent-llm-a/PK-12345","ts":"2025-01-02T12:00:00Z"}
```

### 4. Remote Repository Workflow Boundary

**CASPER 핵심 조언**: "PR 시스템 재발명 금지."

**MASC의 역할**:
- worktree/task 상태와 외부 리뷰 준비 신호를 이벤트 로그에 기록
- 에이전트 간 알림 브로드캐스트
- Worktree 생성/정리 자동화

---

## MVP Scope (Phase 1)

CASPER의 실용적 조언에 따라 최소 기능부터 시작:

### Must Have
- [x] `masc_init` - 룸 초기화
- [x] `masc_bind` - 에이전트 참여 (capabilities 포함)
- [x] `masc_broadcast` - 메시지 브로드캐스트
- [x] `masc_status` - 상태 조회

### Should Have
- [ ] Capability matching 알고리즘

### Won't Have (v2.1+)
- Custom PR system (`.masc/pulls/` - 취소)
- Commander/Worker role hierarchy
- Auto-merge 정책

---

## Self-Organization Bounds (BALTHASAR)

**경고**: "AI가 AI를 리뷰하면 '거짓 신뢰 극장' 발생 가능"

**Guardrails**:
1. **Human-in-the-loop**: 최종 main 브랜치 머지는 인간 승인 필수
2. **Audit Trail**: 모든 결정은 이벤트 로그에 불변 기록
3. **Capability Honesty (목표)**: 능력 과장 방지를 목표로 함 (실적 기반 검증 가정)
4. **Escalation Path**: 합의 실패 시 인간에게 에스컬레이션

---

## Implementation Notes

### Git Worktree Commands

```bash
# Create worktree for agent
git worktree add .worktrees/${agent}-${task} -b ${agent}/${task} origin/develop

# List worktrees
git worktree list

# Remove worktree after merge
git worktree remove .worktrees/${agent}-${task}
git branch -d ${agent}/${task}

# Prune stale worktrees
git worktree prune
```

### Event Log Format

```jsonl
// Agent lifecycle
{"seq":1,"type":"agent_join","agent":"agent-llm-a","capabilities":["ts","review"],"ts":"..."}
{"seq":2,"type":"agent_unbind","agent":"agent-llm-a","reason":"session_end","ts":"..."}

// Worktree lifecycle
{"seq":3,"type":"worktree_prepared","agent":"agent-llm-a","branch":"agent-llm-a/PK-123","ts":"..."}
{"seq":4,"type":"worktree_cleaned","agent":"agent-llm-a","branch":"agent-llm-a/PK-123","ts":"..."}

// Task lifecycle
{"seq":5,"type":"task_claim","agent":"agent-llm-a","task":"PK-123","ts":"..."}
{"seq":6,"type":"task_done","agent":"agent-llm-a","task":"PK-123","ts":"..."}
```

---

## Research References

| Source | Key Insight | Applied |
|--------|-------------|---------|
| [ccswarm](https://github.com/nwiizo/ccswarm) | 파일 락킹 패턴 | v1 File Lock 참고 |
| [Agent-MCP](https://github.com/rinadelph/Agent-MCP) | Agentic loops | Task lifecycle |
| [A2A Protocol](https://a2aproject.github.io/A2A/) | Agent Cards | Capability-based |
| Model Workspace (Eric AI Lab) | 협력 패턴 | Self-organization |

---

## Migration from v1

v1 → v2 마이그레이션:

```bash
# v1 file locks → v2 worktrees
# 기존 락은 무시, worktree로 전환

# v1 portal → v2 broadcast + PR
# Portal은 유지하되 PR 워크플로우와 통합

# v1 backlog → v2 backlog (동일)
# 태스크 관리는 그대로 유지
```

---

## Version History

- **v2.0.0** (2025-01-02): Git Worktree 기반 아키텍처, Capability 라우팅, Layered History
- **v1.0.0** (2024-12): File Lock 기반, Role-based, Portal A2A

---

## Related Documents

### Current References

- **[PRODUCT-OPERATING-PLAN.md](./PRODUCT-OPERATING-PLAN.md)** - current product promise and cleanup posture
- **[OAS-MASC-BOUNDARY.md](./OAS-MASC-BOUNDARY.md)** - current OAS/MASC ownership split
- **[spec/SPEC-INDEX.md](./spec/SPEC-INDEX.md)** - maintained specification index
