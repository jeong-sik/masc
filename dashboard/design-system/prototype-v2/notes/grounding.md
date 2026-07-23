# Grounding notes — jeong-sik/masc@main (2026-06)

## Cockpit (components/cockpit/cockpit.ts)
- Title: "MASC Cockpit" / h1 "Command Map". Layout: scrollable command map.
- 5 planes (PLANE_ORDER): work, comms, observe, cognition, ide
  - Work: "Goals, tasks, and accountability routes" (icon git-branch)
  - Comms: "Board, message, and composer routes" (message-square)
  - Observe: "Runtime, safety, audit, and cost routes" (activity)
  - Cognition: "Keeper, decision, memory, and research routes" (brain)
  - IDE: "Source, review, diff, graph, and search routes" (code2)
- Route entry card: label (alias title-cased), caption `#tab / section / view / focus`, coverage chip: `covered` (ok green) | `backend-blocked` (muted).
- Header chip: "10 routes across 5 planes". Per-plane count chips "N covered / N blocked".
- CognitiveDisclosure block "Progressive Disclosure" with levels: perceive ("Route coverage"), comprehend ("Plane grouping"), project ("Route gaps").
- Cognitive modes: cockpit(situational/all-panels), code(focused/editor-first), split(comparative/side-by-side), explode(exploratory/graph-map).
- Main entrypoints (aliases → target):
  - work: goal-horizon → workspace/planning/goal-tree; task-board → workspace/planning/default
  - comms: board-feed → workspace/board; composer → command/operations/ops
  - observe: runtime → monitoring/runtime; audit → monitoring/runtime/audit; safety → command/operations/safety; cost → monitoring/runtime/cost
  - cognition: keeper-cognition → monitoring/cognition/keeper
  - ide: source → code/ide-shell/source
- Legacy subtabs incl.: accountability-ledger/matrix, board-thread, mention-inbox, composer-broadcast/mention, audit-by-actor/summary, safe-auto-*, cost-per-agent/matrix/latency, tool-access/token-stats, decisions-stream, memory-entries, episodes-cards/learnings, ide: edit/review(pr-thread)/merge(split-diff)/search(find).

## Board (components/board/*)
Comms board, NOT task kanban: board-surface (feed), sub-board-surface, post-detail (threads),
reaction-bar, board-karma-panel, board-curation-panel, board-moderation-surface (+moderation-badge),
mention-inbox, composer-v2, message-workspace-timeline.

## IDE (components/ide/*, api/ide.ts)
- api: annotations (kind, file_path, line_start/end, keeper_id, linked goal/task/board_post/pr/git_ref), regions, presence, cursors, events.
- Cursors: keeper_id, file_path, line/col, selection_end, focus_mode: reading|editing|reviewing|planning, tool_name, turn.
- Events: tool (tool_name, outcome, latency_ms, summary, file_path), turn (phase, model_used, tools_used, stop_reason, duration_ms), pr (pr_number, pr_title, pr_state, repo, comment_count, review_status).
- Components: file-tree-store, ide-editor-* (blame, cursor, find, language, ownership, annotation-ui), ide-diff-view, ide-breadcrumb, ide-activity-panel, ide-conversation-rail, ide-context-lens, execute-output-drawer, audit-replay-slider, anchored-thread-rail, code-document-store.
- Views: source | unified | split-diff; terminal: open param; find: open.
- Real PR reference in comments: "#7732" (SchemaDriftError landed).

## Connectors (api/schemas/gate-connectors.ts)
- GET /api/v1/gate/connectors → { connectors[], total, active_count, generated_at }
- Connector: connector_id, display_name, channel, capabilities[], status, available, connected, stale, stale_after_sec, error, updated_at, reply_mode, self_chat_guid (iMessage), last_ready_at, bot_user_name/id, guild_count, gate_base_url, gate_healthy, pid.
- configured_bindings: [{channel_id, keeper_name}]; recent_audit: [{timestamp, action, guild_id, channel_id, keeper_name, actor_id, actor_name, previous_keeper}]
- binding_summary {binding_source, runtime_bindings_count, configured_bindings_count}; names {guild_names, channel_names}.

## Repo stack
dashboard = Preact + htm + lucide-preact + Tailwind tokens (--color-bg-page/surface/elevated, --color-border-default/strong, --color-fg-*, text-ok). Tests everywhere (vitest).
