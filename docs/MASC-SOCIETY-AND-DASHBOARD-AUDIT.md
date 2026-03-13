# MASC Society and Dashboard Audit

Status: active analysis  
Date: 2026-03-12

## Purpose

This document answers two practical questions:

1. How does the MASC "society" actually run?
2. Which dashboard surfaces are core to understanding that society, and which are operator or experimental overlays?

This is an audit, not a UI patch. It does not change contracts. It clarifies what should be treated as social truth versus operational or heuristic layers.

## Short answer

The MASC "cluster" is not the society itself.

- `cluster` is a deployment label.
- `room` is the real collaboration boundary.
- `keepers`, `persistent_agents`, `messages`, `board`, and `sessions` are the closest things to the lived social layer.
- `guardian`, `sentinel`, `gardener`, `operator`, and `swarm_status` are supervisory or derived layers around that society.

If the question is "how does the agent society behave?", the default dashboard should be room-centric, not operator-centric.

## What the society actually is

The most useful mental model is:

1. Agent
   Single executable actor with identity, capabilities, and local workload.
2. Room
   Shared social boundary for tasks, broadcasts, board posts, and persistence.
3. Keeper / persistent actor
   Long-lived agent form that can survive turns, accumulate memory, and keep acting over time.
4. Organization / supervision
   Policy, routing, approvals, health checks, and operator intervention.
5. Swarm / institutional overlays
   Experimental search, team-session orchestration, succession, and memory continuity.

This matches the repo's current architecture framing:

- `docs/HOLONIC-ARCHITECTURE.md` says the real implemented center is `Agent -> Room`, while `Organization`, `Swarm`, and `Institution` are partial or experimental.
- `docs/AGENT-TRUTH-AUDIT.md` says several high-level dashboard surfaces are not canonical judgment owners, but derived or fallback read models.

## The runtime loops in plain language

The internal social system runs through a few separate loops:

### 1. Social truth loop

This is the main society.

- Agents and keepers read shared state from the room.
- They write tasks, messages, board posts, decisions, and session artifacts.
- This is the layer a human usually means by "what is happening in the cluster?"

Primary state carriers:

- room state
- tasks
- recent messages
- board posts and comments
- team sessions
- keeper status and persistent agent state

### 2. Social scheduling loop

This is the Lodge heartbeat side.

- It decides who checks in, when, and with what cadence.
- It affects the rhythm of the society, but it is not the society's truth by itself.

Important distinction:

- `lodge` is a scheduler/runtime summary.
- `board/messages/keepers` are the social artifacts that people actually inspect.

### 3. Safety and hygiene loop

This is where `guardian`, `sentinel`, and `gardener` live.

- `guardian`: cleanup and protection
- `sentinel`: watchdog / patrol / anomaly surfacing
- `gardener`: population shaping and keeper ecology

These are real runtime actors, but they are operational infrastructure, not the first-class social narrative.

### 4. Operator and derived guidance loop

This is where the dashboard becomes easy to over-interpret.

- `operator_control` builds a supervisory snapshot.
- It explicitly labels itself as `fallback_read_model`.
- `swarm_status`, `attention_items`, and `recommended_actions` are useful, but they are not primary truth.

This means:

- these fields are good control-plane aids
- they should not be mistaken for "what the society is"

## Code anchors

These are the main sources of truth for the audit:

| Concern | Source | Why it matters |
| --- | --- | --- |
| Holonic layer framing | `docs/HOLONIC-ARCHITECTURE.md` | Explains that `Room` is implemented and `Swarm/Institution` are extensions |
| Provenance contract | `docs/AGENT-TRUTH-AUDIT.md` | Defines `truth`, `derived`, `fallback`, `narrative` |
| Operator snapshot contract | `lib/operator_control.ml` | Marks operator surfaces as `fallback_read_model` and exposes `swarm_status`, `attention_items`, `recommended_actions` |
| Dashboard shell status | `lib/server_dashboard_http.ml` | Bundles `lodge`, `gardener`, `guardian`, `sentinel`, `cluster`, and build/runtime metadata |
| Dashboard execution snapshot | `lib/dashboard_execution.ml` | Aggregates room, agents, messages, keepers, and execution summaries into one report |

## Dashboard audit matrix

The table below separates "important to understanding the society" from "important to operating the system."

| Surface | Primary role | Provenance class | Society default? | Recommendation |
| --- | --- | --- | --- | --- |
| `room` | Collaboration boundary | `truth` | Yes | Keep in default society view |
| `sessions` | Active coordination state | `truth` | Yes | Keep in default society view |
| `keepers` | Long-lived social actors | `truth` | Yes | Keep in default society view |
| `persistent_agents` | Durable actor identities | `truth` | Yes | Keep in default society view |
| `recent_messages` / `messages` | Social exchange stream | `truth` | Yes | Keep in default society view |
| `board` | Public discourse / memory surface | `truth` | Yes | Keep in default society view |
| `lodge` | Social rhythm / scheduler runtime | `truth` for runtime, not social truth | Maybe | Collapse as secondary diagnostics in society view |
| `command_plane` | Execution substrate | `truth` | No | Move to operations-focused view |
| `pending_confirms` | Operator intervention queue | `truth` | No | Move to operations-focused view |
| `guardian` | Cleanup / safety infrastructure | `truth` for runtime | No | Move to operations-focused view |
| `sentinel` | Patrol / watchdog infrastructure | `truth` for runtime | No | Move to operations-focused view |
| `gardener` | Population management runtime | `truth` for runtime | No | Move to operations-focused view |
| `cluster` | Deployment label | `derived` metadata | No | Demote to header metadata, not social content |
| `swarm_status` | Swarm synthesis | `derived` | No | Move to experimental view |
| `attention_items` | Heuristic attention digest | `derived` | No | Move to experimental view |
| `recommended_actions` | Supervisory guidance | `fallback` | No | Move to experimental or operator view |
| `recommendation_summary` | Summarized guidance | `fallback` | No | Move with recommended actions |
| `mission briefing` / narrative summaries | Human-facing story layer | `narrative` | No | Hide by default, expose on demand |

## What feels unnecessary today

Most of the "unnecessary" feeling comes from mixing layers, not from having too much data.

### Not actually unnecessary

- `guardian`, `sentinel`, `gardener`
  They matter operationally.
- `swarm_status`, `attention_items`, `recommended_actions`
  They matter when supervising experiments or failed runs.
- `command_plane`
  It matters to operators and debugging.

### Actually misplaced for a society-first dashboard

- `cluster`
  Useful as metadata, not as a main explanatory concept.
- operator fallback summaries
  Useful after the reader already understands room and actor state.
- swarm recommendation layers
  Too interpretive to sit next to social truth by default.

## Recommended dashboard split

If the dashboard is later reorganized, use three top-level views instead of one mixed wall.

### 1. Society

Default view for understanding "how the agent society is moving."

Show:

- room
- sessions
- keepers
- persistent agents
- board
- recent messages
- light Lodge rhythm summary

Hide by default:

- guardian
- sentinel
- gardener
- swarm recommendations
- operator pending confirms

### 2. Operations

View for runtime health and intervention.

Show:

- command plane
- guardian
- sentinel
- gardener
- pending confirms
- shell/runtime/build metadata
- cluster label

### 3. Experimental

View for higher-order orchestration and heuristic synthesis.

Show:

- swarm status
- attention items
- recommended actions
- resolution recommendations
- narrative briefings

## Concrete reading of the current system

If someone asks, "What is happening inside the MASC society right now?", the right reading order is:

1. `room`
2. `sessions`
3. `keepers`
4. `persistent_agents`
5. `board` and `messages`
6. `lodge` only as cadence context
7. `guardian/sentinel/gardener` only if social motion seems stalled or distorted
8. `swarm_status` and `recommended_actions` only if investigating experimental orchestration

This is the key conclusion of the audit:

The current dashboard is better understood as a combined control room than as a pure society viewer.

That is acceptable operationally, but confusing conceptually.

## Follow-up implementation direction

No contract change is required for the next UI pass.

The safest next change would be:

1. Keep current JSON fields intact.
2. Add a society-first dashboard mode or tab.
3. Reorder current sections so social truth appears before operational and heuristic overlays.
4. Demote `cluster`, `guardian`, `sentinel`, `gardener`, and `recommended_actions` out of the default reading path.

That would improve conceptual clarity without changing MCP, operator, or dashboard APIs.
