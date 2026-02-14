(** MASC Web Dashboard - Real-time Agent Coordination Visualization

    HTTP endpoint: /dashboard
    SSE events: /sse (existing)

    Shows:
    - Active agents with status indicators
    - Task board (Kanban style)
    - Recent broadcasts
    - File locks
    - Tempo status

    @author MASC-MCP
    @since 2026-01
*)

(** ETag for dashboard HTML - based on build version.
    Changes only when server is rebuilt, enabling 304 responses. *)
let etag () =
  let v = Version.version in
  let hash = Digest.string v |> Digest.to_hex in
  String.sub hash 0 12

(** Cached dashboard HTML - computed once per process lifetime *)
let cached_html = lazy ({|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>MASC Dashboard</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', 'Segoe UI', sans-serif;
      background: linear-gradient(135deg, #0f0c29 0%, #1a1a2e 50%, #16213e 100%);
      color: #e0e0e0;
      min-height: 100vh;
      padding: 20px;
    }
    .container { max-width: 1400px; margin: 0 auto; }

    /* Header */
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 15px 0;
      border-bottom: 1px solid #333;
      margin-bottom: 20px;
    }
    h1 {
      font-size: 24px;
      background: linear-gradient(90deg, #4ade80, #22d3ee);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      display: flex;
      align-items: center;
      gap: 10px;
    }
    .version-badge {
      font-size: 11px;
      background: rgba(74,222,128,0.2);
      color: #4ade80;
      padding: 2px 8px;
      border-radius: 10px;
      font-weight: 500;
      -webkit-text-fill-color: #4ade80;
    }
    .status-dot {
      width: 12px; height: 12px;
      border-radius: 50%;
      background: #666;
      animation: pulse 2s infinite;
    }
    .status-dot.connected { background: #4ade80; }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }

    /* Stats Grid */
    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 15px;
      margin-bottom: 20px;
    }
    .stat-card {
      background: rgba(255,255,255,0.05);
      border-radius: 12px;
      padding: 20px;
      border: 1px solid rgba(255,255,255,0.1);
    }
    .stat-label { font-size: 12px; color: #888; text-transform: uppercase; }
    .stat-value { font-size: 32px; font-weight: bold; color: #4ade80; }

    /* Sections */
    .grid-2col {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
      margin-bottom: 20px;
    }
    @media (max-width: 900px) { .grid-2col { grid-template-columns: 1fr; } }

    .section {
      background: rgba(255,255,255,0.03);
      border-radius: 12px;
      padding: 20px;
      border: 1px solid rgba(255,255,255,0.08);
    }
    .section h2 {
      font-size: 14px;
      color: #4ade80;
      text-transform: uppercase;
      letter-spacing: 1px;
      margin-bottom: 15px;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    /* Agents */
    .agent-list { display: flex; flex-direction: column; gap: 10px; }
    .agent {
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 12px;
      background: rgba(255,255,255,0.05);
      border-radius: 8px;
    }
    .agent-status {
      width: 10px; height: 10px;
      border-radius: 50%;
    }
    .agent-status.active { background: #4ade80; box-shadow: 0 0 10px #4ade80; }
    .agent-status.busy { background: #fbbf24; box-shadow: 0 0 10px #fbbf24; }
    .agent-status.inactive { background: #666; }
    .agent-name { font-weight: 600; flex: 1; }
    .agent-task { font-size: 12px; color: #888; max-width: 200px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

    /* Live Agents (Keepers / Perpetual) */
    .live-agent-list { display: flex; flex-direction: column; gap: 10px; }
    .live-agent {
      display: flex;
      align-items: flex-start;
      gap: 12px;
      padding: 12px;
      background: rgba(255,255,255,0.05);
      border-radius: 8px;
    }
    .live-agent-main { flex: 1; min-width: 0; }
    .live-agent-title { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
    .live-agent-name { font-weight: 600; }
    .live-agent-sub { font-size: 11px; color: #888; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .pill {
      font-size: 10px;
      padding: 2px 8px;
      border-radius: 999px;
      background: rgba(34,211,238,0.15);
      color: #22d3ee;
      border: 1px solid rgba(34,211,238,0.2);
    }
    .pill.warn {
      background: rgba(251,191,36,0.12);
      color: #fbbf24;
      border-color: rgba(251,191,36,0.25);
    }
    .pill.bad {
      background: rgba(248,113,113,0.12);
      color: #f87171;
      border-color: rgba(248,113,113,0.25);
    }
    .live-agent-meta { font-size: 12px; color: #aaa; display: flex; flex-wrap: wrap; gap: 10px; }
    .live-agent-meta .warn-metric { color: #fbbf24; font-weight: 700; }
    .live-agent-meta .bad-metric { color: #f87171; font-weight: 700; }
    .ctx-bar { height: 6px; background: rgba(255,255,255,0.08); border-radius: 999px; overflow: hidden; margin-top: 8px; }
    .ctx-fill { height: 100%; width: 0%; background: linear-gradient(90deg, #4ade80, #22d3ee); transition: width 0.3s ease; }
    .ctx-fill.warn { background: linear-gradient(90deg, #fbbf24, #f97316); }
    .ctx-fill.bad { background: linear-gradient(90deg, #f87171, #ef4444); }
    .ctx-spark { margin-top: 10px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .sparkline {
      width: 180px;
      height: 40px;
      padding: 4px 6px;
      border-radius: 8px;
      background: rgba(0,0,0,0.22);
      border: 1px solid rgba(255,255,255,0.08);
      box-sizing: border-box;
    }
    .spark-svg { width: 100%; height: 100%; display: block; }
    .spark-empty { font-size: 11px; color: #777; padding: 8px 0; }
    .spark-meta { font-size: 11px; color: #888; display: flex; gap: 10px; flex-wrap: wrap; }
    .spark-meta b { color: #cbd5e1; font-weight: 600; }
    .live-agent.keeper-card {
      cursor: pointer;
      transition: border-color 0.2s ease, transform 0.2s ease;
      border: 1px solid rgba(255,255,255,0.08);
    }
    .live-agent.keeper-card:hover {
      border-color: rgba(34,211,238,0.35);
      transform: translateY(-1px);
    }
    .live-agent.keeper-card.selected {
      border-color: rgba(74,222,128,0.55);
      box-shadow: 0 0 0 1px rgba(74,222,128,0.35) inset;
    }

    /* Keeper detail modal */
    .keeper-detail-modal {
      position: fixed;
      inset: 0;
      background: rgba(2,6,23,0.72);
      backdrop-filter: blur(2px);
      z-index: 1200;
      display: none;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .keeper-detail-modal.active { display: flex; }
    .keeper-detail-panel {
      width: min(1100px, 96vw);
      max-height: 88vh;
      overflow-y: auto;
      background: linear-gradient(180deg, rgba(15,23,42,0.98), rgba(2,6,23,0.98));
      border: 1px solid rgba(148,163,184,0.24);
      border-radius: 14px;
      box-shadow: 0 28px 70px rgba(0,0,0,0.5);
      padding: 18px;
    }
    .keeper-detail-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      margin-bottom: 14px;
      padding-bottom: 10px;
      border-bottom: 1px solid rgba(148,163,184,0.16);
    }
    .keeper-detail-title {
      font-size: 16px;
      font-weight: 700;
      color: #e2e8f0;
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }
    .keeper-detail-sub {
      font-size: 12px;
      color: #94a3b8;
      font-weight: 500;
    }
    .keeper-eta-pill {
      font-size: 11px;
      padding: 2px 8px;
      border-radius: 999px;
      background: rgba(34,211,238,0.18);
      color: #22d3ee;
      border: 1px solid rgba(34,211,238,0.3);
      font-weight: 700;
      letter-spacing: 0.2px;
    }
    .keeper-eta-pill.warn {
      background: rgba(251,191,36,0.2);
      color: #fbbf24;
      border-color: rgba(251,191,36,0.38);
    }
    .keeper-eta-pill.now {
      background: rgba(248,113,113,0.2);
      color: #f87171;
      border-color: rgba(248,113,113,0.4);
    }
    .keeper-close-btn {
      border: 1px solid rgba(148,163,184,0.28);
      background: rgba(148,163,184,0.12);
      color: #e2e8f0;
      border-radius: 8px;
      font-size: 12px;
      padding: 6px 10px;
      cursor: pointer;
    }
    .keeper-close-btn:hover { background: rgba(148,163,184,0.2); }
    .keeper-detail-toolbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
      margin-bottom: 12px;
      padding: 8px 10px;
      border-radius: 10px;
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.16);
    }
    .keeper-toolbar-group {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
    }
    .keeper-toolbar-label {
      font-size: 11px;
      color: #94a3b8;
      text-transform: uppercase;
      letter-spacing: 0.4px;
      font-weight: 700;
    }
    .keeper-zoom-btn {
      border: 1px solid rgba(148,163,184,0.26);
      background: rgba(148,163,184,0.1);
      color: #cbd5e1;
      border-radius: 999px;
      padding: 4px 9px;
      font-size: 11px;
      cursor: pointer;
      font-weight: 600;
    }
    .keeper-zoom-btn:hover {
      border-color: rgba(34,211,238,0.5);
      color: #e2e8f0;
    }
    .keeper-zoom-btn.active {
      border-color: rgba(34,211,238,0.55);
      background: rgba(34,211,238,0.2);
      color: #22d3ee;
    }
    .keeper-select {
      background: rgba(255,255,255,0.08);
      border: 1px solid rgba(148,163,184,0.28);
      border-radius: 8px;
      padding: 6px 10px;
      color: #e2e8f0;
      font-size: 12px;
      min-width: 170px;
    }
    .keeper-select:focus { outline: none; border-color: rgba(34,211,238,0.55); }
    .keeper-toolbar-btn {
      border: 1px solid rgba(148,163,184,0.26);
      background: rgba(148,163,184,0.1);
      color: #e2e8f0;
      border-radius: 8px;
      padding: 6px 10px;
      font-size: 12px;
      cursor: pointer;
      font-weight: 600;
    }
    .keeper-toolbar-btn:hover {
      border-color: rgba(34,211,238,0.5);
      color: #22d3ee;
    }
    .keeper-detail-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
      margin-bottom: 14px;
    }
    @media (max-width: 980px) {
      .keeper-detail-grid { grid-template-columns: 1fr; }
    }
    .keeper-kpis {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 8px;
      margin-bottom: 12px;
    }
    @media (max-width: 980px) {
      .keeper-kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    }
    .keeper-kpi {
      background: rgba(255,255,255,0.04);
      border: 1px solid rgba(148,163,184,0.18);
      border-radius: 10px;
      padding: 10px;
    }
    .keeper-kpi-label {
      color: #94a3b8;
      font-size: 11px;
      margin-bottom: 4px;
      text-transform: uppercase;
      letter-spacing: 0.4px;
    }
    .keeper-kpi-value {
      color: #e2e8f0;
      font-size: 15px;
      font-weight: 700;
      word-break: break-all;
    }
    .keeper-kpi-value.warn { color: #fbbf24; }
    .keeper-kpi-value.bad { color: #f87171; }
    .keeper-chart-card {
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.16);
      border-radius: 10px;
      padding: 10px;
    }
    .keeper-chart-title {
      font-size: 12px;
      color: #cbd5e1;
      margin-bottom: 8px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .keeper-chart {
      width: 100%;
      height: 180px;
      background: rgba(2,6,23,0.35);
      border-radius: 8px;
      border: 1px solid rgba(148,163,184,0.14);
      padding: 8px;
    }
    .keeper-chart svg { width: 100%; height: 100%; display: block; }
    .keeper-chart-meta {
      margin-top: 8px;
      font-size: 11px;
      color: #94a3b8;
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
    }
    .keeper-chart-meta b { color: #e2e8f0; font-weight: 600; }
    .keeper-chart-meta .warn-metric { color: #fbbf24; font-weight: 700; }
    .keeper-chart-meta .bad-metric { color: #f87171; font-weight: 700; }
    .keeper-handoff-timeline { margin-bottom: 12px; }
    .keeper-handoff-list {
      margin-top: 8px;
      max-height: 220px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .keeper-handoff-controls {
      margin-top: 8px;
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }
    .keeper-handoff-row {
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.18);
      border-left: 3px solid rgba(251,191,36,0.8);
      border-radius: 8px;
      padding: 0;
      overflow: hidden;
    }
    .keeper-handoff-row[open] {
      border-color: rgba(251,191,36,0.45);
      background: rgba(251,191,36,0.05);
    }
    .keeper-handoff-summary {
      list-style: none;
      cursor: pointer;
      padding: 8px 9px;
      display: flex;
      flex-direction: column;
      gap: 5px;
    }
    .keeper-handoff-summary::-webkit-details-marker { display: none; }
    .keeper-handoff-summary::marker { content: ''; }
    .keeper-handoff-extra {
      border-top: 1px solid rgba(148,163,184,0.18);
      padding: 8px 9px;
      background: rgba(2,6,23,0.25);
    }
    .keeper-handoff-extra-grid {
      display: flex;
      flex-wrap: wrap;
      gap: 6px 10px;
      color: #cbd5e1;
      font-size: 11px;
      margin-bottom: 6px;
    }
    .keeper-handoff-extra-grid b { color: #e2e8f0; font-weight: 600; }
    .keeper-handoff-tools {
      color: #94a3b8;
      font-size: 11px;
      line-height: 1.35;
      word-break: break-word;
    }
    .keeper-handoff-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      flex-wrap: wrap;
    }
    .keeper-handoff-gen {
      color: #fbbf24;
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.25px;
      text-transform: uppercase;
    }
    .keeper-handoff-time {
      color: #94a3b8;
      font-size: 11px;
    }
    .keeper-handoff-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 8px 12px;
      color: #cbd5e1;
      font-size: 11px;
    }
    .keeper-handoff-meta b { color: #e2e8f0; font-weight: 600; }
    .keeper-handoff-trace {
      font-size: 11px;
      color: #94a3b8;
      line-height: 1.3;
      word-break: break-all;
    }
    .keeper-events {
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.16);
      border-radius: 10px;
      padding: 10px;
      margin-top: 2px;
    }
    .keeper-compare-block { margin-bottom: 12px; }
    .keeper-events-list {
      max-height: 180px;
      overflow-y: auto;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .keeper-event {
      font-size: 12px;
      color: #cbd5e1;
      background: rgba(255,255,255,0.03);
      border-left: 3px solid rgba(34,211,238,0.65);
      padding: 7px 8px;
      border-radius: 6px;
    }
    .keeper-event.handoff { border-left-color: rgba(251,191,36,0.85); }
    .keeper-event.compaction { border-left-color: rgba(74,222,128,0.85); }
    .keeper-event-time { color: #94a3b8; font-size: 11px; margin-right: 8px; }
    .keeper-equipment-wrap {
      margin-top: 10px;
      border-top: 1px solid rgba(148,163,184,0.16);
      padding-top: 10px;
    }
    .keeper-equipment-list {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 180px;
      overflow-y: auto;
    }
    .keeper-equipment-row {
      display: flex;
      flex-wrap: wrap;
      gap: 8px 12px;
      font-size: 11px;
      color: #cbd5e1;
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.16);
      border-radius: 8px;
      padding: 7px 8px;
    }
    .keeper-equipment-gen {
      color: #22d3ee;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.3px;
      min-width: 26px;
    }
    .keeper-memory-wrap {
      margin-top: 10px;
      border-top: 1px solid rgba(148,163,184,0.16);
      padding-top: 10px;
    }
    .keeper-memory-list {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 180px;
      overflow-y: auto;
    }
    .keeper-memory-item {
      display: flex;
      flex-direction: column;
      gap: 4px;
      font-size: 11px;
      color: #cbd5e1;
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.16);
      border-radius: 8px;
      padding: 7px 8px;
    }
    .keeper-memory-kind {
      color: #22d3ee;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.25px;
      font-size: 10px;
    }
    .keeper-memory-text {
      color: #e2e8f0;
      line-height: 1.35;
      word-break: break-word;
    }
    .keeper-memory-meta {
      color: #94a3b8;
      font-size: 10px;
    }
    .keeper-conversation-wrap,
    .keeper-k2k-wrap {
      margin-top: 10px;
      border-top: 1px solid rgba(148,163,184,0.16);
      padding-top: 10px;
    }
    .keeper-conversation-list,
    .keeper-k2k-list {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 220px;
      overflow-y: auto;
    }
    .keeper-conversation-item,
    .keeper-k2k-item {
      display: flex;
      flex-direction: column;
      gap: 4px;
      font-size: 11px;
      color: #cbd5e1;
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.16);
      border-radius: 8px;
      padding: 7px 8px;
    }
    .keeper-conversation-head {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
    }
    .keeper-role-chip {
      border: 1px solid rgba(148,163,184,0.32);
      border-radius: 999px;
      padding: 1px 7px;
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.2px;
      text-transform: uppercase;
      color: #e2e8f0;
      background: rgba(148,163,184,0.16);
    }
    .keeper-role-chip.user {
      border-color: rgba(34,211,238,0.45);
      background: rgba(34,211,238,0.16);
      color: #a5f3fc;
    }
    .keeper-role-chip.assistant {
      border-color: rgba(167,139,250,0.45);
      background: rgba(167,139,250,0.16);
      color: #ddd6fe;
    }
    .keeper-role-chip.warn {
      border-color: rgba(251,191,36,0.45);
      background: rgba(251,191,36,0.16);
      color: #fde68a;
    }
    .keeper-role-chip.bad {
      border-color: rgba(248,113,113,0.45);
      background: rgba(248,113,113,0.16);
      color: #fecaca;
    }
    .keeper-k2k-chip {
      border: 1px solid rgba(251,191,36,0.45);
      border-radius: 999px;
      padding: 1px 7px;
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.2px;
      text-transform: uppercase;
      color: #fde68a;
      background: rgba(251,191,36,0.16);
    }
    .keeper-mentions {
      display: flex;
      flex-wrap: wrap;
      gap: 5px;
    }
    .keeper-mention-chip {
      border: 1px solid rgba(74,222,128,0.38);
      border-radius: 999px;
      padding: 1px 7px;
      font-size: 10px;
      color: #bbf7d0;
      background: rgba(74,222,128,0.14);
    }
    .keeper-conversation-text,
    .keeper-k2k-text {
      line-height: 1.4;
      color: #cbd5e1;
      word-break: break-word;
    }
    .keeper-conversation-item.fragment {
      border-color: rgba(251,191,36,0.35);
      background: rgba(251,191,36,0.07);
    }
    .keeper-k2k-route {
      color: #fbbf24;
      font-weight: 700;
      font-size: 11px;
      letter-spacing: 0.2px;
    }

    /* Tasks (Kanban) */
    .task-board {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 15px;
    }
    .task-column h3 {
      font-size: 12px;
      color: #888;
      margin-bottom: 10px;
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .task-column h3 .count {
      background: rgba(255,255,255,0.1);
      padding: 2px 8px;
      border-radius: 10px;
      font-size: 10px;
    }
    .task-list { display: flex; flex-direction: column; gap: 8px; min-height: 100px; }
    .task {
      padding: 10px;
      background: rgba(255,255,255,0.05);
      border-radius: 6px;
      border-left: 3px solid #666;
      font-size: 13px;
    }
    .task.todo { border-left-color: #888; }
    .task.in-progress { border-left-color: #fbbf24; }
    .task.done { border-left-color: #4ade80; opacity: 0.7; }
    .task-title { font-weight: 500; margin-bottom: 4px; }
    .task-meta { font-size: 11px; color: #666; }

    /* Messages */
    .message-list { display: flex; flex-direction: column; gap: 8px; max-height: 300px; overflow-y: auto; }
    .message {
      padding: 10px;
      background: rgba(255,255,255,0.03);
      border-radius: 6px;
      font-size: 13px;
    }
    .message-header { display: flex; justify-content: space-between; margin-bottom: 4px; }
    .message-from { color: #22d3ee; font-weight: 500; }
    .message-time { color: #666; font-size: 11px; }
    .message-content { color: #ccc; }

    /* Tempo */
    .tempo-badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 6px 12px;
      border-radius: 20px;
      font-size: 12px;
      font-weight: 600;
    }
    .tempo-badge.normal { background: rgba(74,222,128,0.2); color: #4ade80; }
    .tempo-badge.slow { background: rgba(251,191,36,0.2); color: #fbbf24; }
    .tempo-badge.fast { background: rgba(34,211,238,0.2); color: #22d3ee; }
    .tempo-badge.paused { background: rgba(248,113,113,0.2); color: #f87171; }

    /* Board - Compact Cards with Avatars */
    .board-list { display: flex; flex-direction: column; gap: 8px; max-height: 500px; overflow-y: auto; }
    .board-post {
      display: flex; gap: 10px;
      padding: 10px 12px;
      background: rgba(255,255,255,0.04);
      border-radius: 8px;
      cursor: pointer;
      transition: all 0.15s ease;
      border: 1px solid transparent;
    }
    .board-post:hover { background: rgba(255,255,255,0.07); border-color: rgba(34,211,238,0.3); }
    .author-avatar {
      flex-shrink: 0;
      width: 32px; height: 32px;
      border-radius: 50%;
      display: flex; align-items: center; justify-content: center;
      font-size: 14px;
      font-weight: 600;
      color: white;
      text-shadow: 0 1px 2px rgba(0,0,0,0.3);
    }
    .avatar-blue { background: linear-gradient(135deg, #3b82f6, #1d4ed8); }
    .avatar-purple { background: linear-gradient(135deg, #8b5cf6, #6d28d9); }
    .avatar-green { background: linear-gradient(135deg, #10b981, #059669); }
    .avatar-orange { background: linear-gradient(135deg, #f59e0b, #d97706); }
    .avatar-pink { background: linear-gradient(135deg, #ec4899, #db2777); }
    .avatar-cyan { background: linear-gradient(135deg, #22d3ee, #0891b2); }
    .board-post-body { flex: 1; min-width: 0; }
    .board-post-header { display: flex; align-items: center; gap: 8px; margin-bottom: 4px; }
    .board-post-author { color: #e0e0e0; font-weight: 600; font-size: 12px; }
    .board-post-time { color: #666; font-size: 10px; }
    .board-post-content { color: #aaa; font-size: 12px; line-height: 1.5; margin-bottom: 6px;
      white-space: pre-wrap; word-break: break-word; }
    .board-post-footer { display: flex; gap: 10px; font-size: 10px; color: #666; }
    .board-post-footer span { display: flex; align-items: center; gap: 3px; cursor: pointer; padding: 2px 4px; border-radius: 4px; transition: all 0.15s; }
    .board-post-footer span:hover { background: rgba(255,255,255,0.1); }
    .vote-up:hover { color: #f43f5e; }
    .vote-up.liked { color: #f43f5e; }
    .vote-up.liked::before { content: '❤️'; }
    .vote-down:hover { color: #f87171; }
    .bookmark-btn:hover { color: #fbbf24; }
    .bookmark-btn.saved { color: #fbbf24; }
    .share-btn:hover { color: #22d3ee; }

    /* Reddit-style vertical votes */
    .vote-column {
      display: flex; flex-direction: column; align-items: center; gap: 2px;
      padding: 4px; margin-right: 8px;
    }
    .vote-btn {
      width: 24px; height: 24px; display: flex; align-items: center; justify-content: center;
      background: transparent; border: none; cursor: pointer; border-radius: 4px;
      font-size: 14px; color: #666; transition: all 0.15s;
    }
    .vote-btn:hover { background: rgba(255,255,255,0.1); }
    .vote-btn.upvote:hover, .vote-btn.upvote.active { color: #ff4500; }
    .vote-btn.downvote:hover, .vote-btn.downvote.active { color: #7193ff; }
    .vote-score {
      font-size: 12px; font-weight: 600; color: #888; min-width: 20px; text-align: center;
    }
    .vote-score.positive { color: #ff4500; }
    .vote-score.negative { color: #7193ff; }

    /* Karma badge */
    .karma-badge {
      font-size: 10px; color: #888; background: rgba(255,255,255,0.05);
      padding: 1px 5px; border-radius: 8px; margin-left: 4px;
    }

    /* Flair badge */
    .flair-badge {
      font-size: 10px; padding: 2px 6px; border-radius: 4px;
      background: rgba(34,211,238,0.15); color: #22d3ee; margin-left: 6px;
    }
    .flair-badge.insight { background: rgba(251,191,36,0.15); color: #fbbf24; }
    .flair-badge.question { background: rgba(168,85,247,0.15); color: #a855f7; }
    .flair-badge.announcement { background: rgba(239,68,68,0.15); color: #ef4444; }
    .flair-badge.bug { background: rgba(239,68,68,0.15); color: #ef4444; }
    .flair-badge.idea { background: rgba(74,222,128,0.15); color: #4ade80; }
    .flair-badge.meta { background: rgba(107,114,128,0.15); color: #6b7280; }

    /* Vote animation */
    @keyframes votePop {
      0% { transform: scale(1); }
      50% { transform: scale(1.4); }
      100% { transform: scale(1); }
    }
    .vote-btn.pop { animation: votePop 0.2s ease; }
    .vote-score.pop { animation: votePop 0.3s ease; }

    /* Legacy heart animation */
    @keyframes heartPop {
      0% { transform: scale(1); }
      50% { transform: scale(1.3); }
      100% { transform: scale(1); }
    }
    .vote-up.pop { animation: heartPop 0.3s ease; }

    /* Verified badge */
    .verified-badge {
      display: inline-flex; align-items: center; justify-content: center;
      width: 14px; height: 14px; background: #3b82f6; border-radius: 50%;
      font-size: 8px; color: white; margin-left: 4px;
    }

    /* Trending sidebar */
    .board-layout { display: flex; gap: 20px; }
    .board-main { flex: 1; min-width: 0; }
    .board-sidebar { width: 200px; flex-shrink: 0; }
    @media (max-width: 800px) {
      .board-layout { flex-direction: column; }
      .board-sidebar { width: 100%; order: -1; }
    }
    .trending-section {
      background: rgba(255,255,255,0.03); border-radius: 10px;
      padding: 12px; border: 1px solid rgba(255,255,255,0.08);
    }
    .trending-title { font-size: 13px; font-weight: 600; color: #e0e0e0; margin-bottom: 10px; }
    .trending-tag {
      display: block; padding: 6px 8px; margin-bottom: 4px; border-radius: 6px;
      font-size: 12px; color: #22d3ee; cursor: pointer; transition: all 0.15s;
    }
    .trending-tag:hover { background: rgba(34,211,238,0.1); }
    .trending-count { color: #666; font-size: 10px; margin-left: 4px; }

    .board-comment {
      display: flex; gap: 8px;
      padding: 10px 12px;
      margin-left: 40px;
      margin-top: 8px;
      background: rgba(255,255,255,0.02);
      border-radius: 6px;
      font-size: 12px;
      color: #aaa;
    }
    .board-comment-author { color: #4ade80; font-weight: 500; font-size: 11px; }
    .board-detail { display: none; }
    .board-detail.active { display: block; }
    .board-back { color: #22d3ee; cursor: pointer; font-size: 12px; margin-bottom: 10px; }
    .board-back:hover { text-decoration: underline; }

    /* Main Navigation Tabs */
    .main-tab-bar {
      display: flex; gap: 8px; margin-bottom: 20px; padding: 10px;
      background: rgba(255,255,255,0.03); border-radius: 12px;
    }
    .main-tab-btn {
      padding: 10px 20px; border-radius: 8px; font-size: 14px; cursor: pointer;
      background: transparent; color: #888; border: none; transition: all 0.2s;
      font-weight: 500;
    }
    .main-tab-btn:hover { background: rgba(255,255,255,0.05); color: #ccc; }
    .main-tab-btn.active { background: rgba(74,222,128,0.15); color: #4ade80; }
    .main-tab-content { display: block; }

    /* Server Health */
    .server-health {
      display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 15px;
    }
    .health-item {
      display: flex; justify-content: space-between; padding: 12px;
      background: rgba(255,255,255,0.03); border-radius: 8px;
    }
    .health-label { color: #888; font-size: 12px; }
    .health-item span:last-child { color: #4ade80; font-weight: 600; }

    /* Legacy Tabs (kept for compatibility) */
    .tab-bar { display: flex; gap: 4px; margin-bottom: 15px; }
    .tab-btn {
      padding: 6px 14px; border-radius: 6px; font-size: 12px; cursor: pointer;
      background: rgba(255,255,255,0.05); color: #888; border: none; transition: all 0.2s;
    }
    .tab-btn.active { background: rgba(74,222,128,0.2); color: #4ade80; }

    /* Journal */
    .journal-list { display: flex; flex-direction: column; gap: 6px; max-height: 400px; overflow-y: auto; }
    .journal-entry {
      display: flex; gap: 10px; padding: 8px 12px;
      background: rgba(255,255,255,0.02); border-radius: 6px; font-size: 12px;
    }
    .journal-time { color: #666; white-space: nowrap; min-width: 60px; }
    .journal-agent { color: #22d3ee; min-width: 80px; font-weight: 500; }
    .journal-action { color: #ccc; flex: 1; }

    /* Agents Tab */
    .agents-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 12px; }
    .agent-card { padding: 16px; background: rgba(255,255,255,0.04); border-radius: 10px; border: 1px solid rgba(255,255,255,0.06); transition: border-color 0.2s; }
    .agent-card:hover { border-color: rgba(74,222,128,0.3); }
    .agent-card-header { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
    .agent-card-emoji { font-size: 28px; }
    .agent-card-name { font-weight: 600; font-size: 15px; }
    .agent-card-korean { color: #888; font-size: 12px; }
    .agent-card-status { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 10px; font-weight: 600; margin-left: auto; }
    .agent-card-status.active { background: rgba(74,222,128,0.2); color: #4ade80; }
    .agent-card-status.inactive { background: rgba(255,255,255,0.1); color: #888; }
    .agent-card-traits { display: flex; flex-wrap: wrap; gap: 4px; margin-bottom: 8px; }
    .agent-trait { padding: 2px 8px; border-radius: 4px; font-size: 11px; background: rgba(34,211,238,0.15); color: #22d3ee; }
    .agent-card-meta { font-size: 11px; color: #666; display: flex; flex-wrap: wrap; gap: 8px; }
    .agent-card-meta span { white-space: nowrap; }
    .admin-gate { text-align: center; padding: 40px 20px; }
    .admin-gate input { background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.15); color: #e0e0e0; padding: 10px 16px; border-radius: 8px; font-size: 14px; width: 280px; }
    .admin-gate input::placeholder { color: #666; }
    .admin-gate button { background: rgba(74,222,128,0.2); color: #4ade80; border: none; padding: 10px 20px; border-radius: 8px; cursor: pointer; font-size: 14px; margin-left: 8px; }
    .admin-gate button:hover { background: rgba(74,222,128,0.3); }
    .create-agent-form { background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.08); border-radius: 12px; padding: 20px; margin-bottom: 20px; }
    .create-agent-form h3 { color: #4ade80; margin-bottom: 16px; font-size: 15px; }
    .form-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .form-group { display: flex; flex-direction: column; gap: 4px; }
    .form-group.full-width { grid-column: 1 / -1; }
    .form-group label { font-size: 12px; color: #888; font-weight: 500; }
    .form-group input, .form-group select, .form-group textarea { background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.12); color: #e0e0e0; padding: 8px 12px; border-radius: 6px; font-size: 13px; }
    .form-group textarea { resize: vertical; min-height: 60px; font-family: inherit; }
    .form-group input:focus, .form-group select:focus, .form-group textarea:focus { outline: none; border-color: rgba(74,222,128,0.5); }
    .hours-grid { display: flex; flex-wrap: wrap; gap: 4px; }
    .hour-btn { width: 32px; height: 28px; border-radius: 4px; font-size: 11px; cursor: pointer; background: rgba(255,255,255,0.06); color: #888; border: 1px solid rgba(255,255,255,0.1); transition: all 0.15s; }
    .hour-btn.selected { background: rgba(74,222,128,0.25); color: #4ade80; border-color: rgba(74,222,128,0.4); }
    .hour-btn:hover { background: rgba(255,255,255,0.12); }
    .range-row { display: flex; align-items: center; gap: 10px; }
    .range-row input[type=range] { flex: 1; accent-color: #4ade80; }
    .range-val { font-size: 13px; color: #4ade80; font-weight: 600; min-width: 30px; }
    .create-btn { background: linear-gradient(135deg, rgba(74,222,128,0.3), rgba(34,211,238,0.3)); color: #fff; border: none; padding: 12px 28px; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; margin-top: 16px; transition: opacity 0.2s; }
    .create-btn:hover { opacity: 0.85; }
    .create-btn:disabled { opacity: 0.4; cursor: not-allowed; }
    .toast { position: fixed; bottom: 20px; right: 20px; padding: 12px 20px; border-radius: 8px; font-size: 13px; z-index: 1000; animation: fadeInUp 0.3s; max-width: 400px; }
    .toast.success { background: rgba(74,222,128,0.9); color: #000; }
    .toast.error { background: rgba(248,113,113,0.9); color: #fff; }
    @keyframes fadeInUp { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }

    /* Empty state */
    .empty { color: #666; font-style: italic; padding: 20px; text-align: center; }

    /* Think tag - collapsible */
    .think-block {
      background: rgba(147, 51, 234, 0.1);
      border: 1px solid rgba(147, 51, 234, 0.3);
      border-radius: 6px;
      margin: 8px 0;
      overflow: hidden;
    }
    .think-toggle {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 6px 10px;
      background: rgba(147, 51, 234, 0.15);
      color: #a78bfa;
      font-size: 11px;
      cursor: pointer;
      user-select: none;
    }
    .think-toggle:hover { background: rgba(147, 51, 234, 0.25); }
    .think-toggle::before { content: '▶'; font-size: 8px; transition: transform 0.2s; }
    .think-block.expanded .think-toggle::before { transform: rotate(90deg); }
    .think-content {
      display: none;
      padding: 10px;
      font-size: 12px;
      color: #9ca3af;
      white-space: pre-wrap;
      max-height: 200px;
      overflow-y: auto;
    }
    .think-block.expanded .think-content { display: block; }

    /* Markdown styling */
    .md-bold { font-weight: 600; color: #e0e0e0; }
    .md-code {
      background: rgba(255,255,255,0.1);
      padding: 1px 5px;
      border-radius: 3px;
      font-family: 'SF Mono', Monaco, monospace;
      font-size: 12px;
      color: #4ade80;
    }
    .md-link { color: #22d3ee; text-decoration: none; }
    .md-link:hover { text-decoration: underline; }

    /* Expandable content */
    .content-collapsed {
      position: relative;
      max-height: 120px;
      overflow: hidden;
    }
    .content-collapsed::after {
      content: '';
      position: absolute;
      bottom: 0;
      left: 0;
      right: 0;
      height: 40px;
      background: linear-gradient(transparent, rgba(15,12,41,0.95));
    }
    .expand-btn {
      display: block;
      margin-top: 8px;
      padding: 4px 10px;
      background: rgba(34,211,238,0.15);
      color: #22d3ee;
      border: none;
      border-radius: 4px;
      font-size: 11px;
      cursor: pointer;
    }
    .expand-btn:hover { background: rgba(34,211,238,0.25); }

    /* Hashtag styling */
    .hashtag {
      color: #22d3ee;
      background: rgba(34,211,238,0.15);
      padding: 1px 6px;
      border-radius: 3px;
      font-size: 12px;
      cursor: pointer;
      transition: background 0.2s;
    }
    .hashtag:hover { background: rgba(34,211,238,0.3); }

    /* SSE Connection status */
    .connection-status {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 12px;
      color: #888;
    }
    .connection-status.connected { color: #4ade80; }
    .connection-status.disconnected { color: #f87171; }
    .event-counter {
      background: rgba(255,255,255,0.1);
      padding: 2px 8px;
      border-radius: 10px;
      font-size: 11px;
    }

    /* Toast notifications */
    .toast-container {
      position: fixed;
      top: 20px;
      right: 20px;
      z-index: 1000;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .toast {
      padding: 12px 16px;
      background: rgba(34,211,238,0.9);
      color: #000;
      border-radius: 8px;
      font-size: 13px;
      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
      animation: slideIn 0.3s ease-out;
      max-width: 300px;
    }
    .toast.success { background: rgba(74,222,128,0.9); }
    .toast.warning { background: rgba(251,191,36,0.9); }
    .toast.error { background: rgba(248,113,113,0.9); color: #fff; }
    @keyframes slideIn {
      from { transform: translateX(100%); opacity: 0; }
      to { transform: translateX(0); opacity: 1; }
    }

    /* Auto-scroll toggle */
    .auto-scroll-toggle {
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 11px;
      color: #888;
      cursor: pointer;
      user-select: none;
    }
    .auto-scroll-toggle input { cursor: pointer; }

    /* Tag filter indicator */
    .tag-filter-bar {
      display: none;
      padding: 8px 12px;
      background: rgba(34,211,238,0.1);
      border-radius: 6px;
      margin-bottom: 12px;
      font-size: 12px;
      justify-content: space-between;
      align-items: center;
    }
    .tag-filter-bar.active { display: flex; }
    .tag-filter-bar .clear-filter {
      color: #f87171;
      cursor: pointer;
      font-size: 11px;
    }

    /* Sort & Filter controls */
    .board-controls {
      display: flex;
      gap: 12px;
      margin-bottom: 12px;
      align-items: center;
      flex-wrap: wrap;
    }
    .sort-select {
      background: rgba(255,255,255,0.08);
      border: 1px solid rgba(255,255,255,0.15);
      border-radius: 6px;
      padding: 6px 10px;
      color: #e0e0e0;
      font-size: 12px;
      cursor: pointer;
    }
    .sort-select:focus { outline: none; border-color: #22d3ee; }
    .board-controls label {
      font-size: 11px;
      color: #888;
    }
    /* Activity tab styles */
    .activity-agents {
      display: flex;
      flex-direction: column;
      gap: 6px;
      margin-top: 8px;
    }
    .activity-line {
      background: rgba(34, 211, 238, 0.08);
      padding: 8px 12px;
      border-radius: 6px;
      font-size: 13px;
      font-family: 'SF Mono', 'Menlo', monospace;
      color: #e2e8f0;
      border-left: 3px solid #22d3ee;
    }
    .board-title {
      font-weight: 600;
      color: #f8fafc;
      margin-bottom: 4px;
    }
  </style>
</head>
<body>
  <div class="container">
    <!-- Toast container -->
    <div class="toast-container" id="toast-container"></div>

    <header>
      <h1><span class="status-dot" id="status-dot"></span> MASC Dashboard <span id="version-badge" class="version-badge">v...</span></h1>
      <div style="display:flex;align-items:center;gap:16px;">
        <div class="connection-status" id="connection-status">
          <span id="conn-text">Connecting...</span>
          <span class="event-counter" id="event-counter">0 events</span>
        </div>
        <div class="tempo-badge normal" id="tempo-badge">Normal</div>
      </div>
    </header>

    <!-- Main Navigation Tabs -->
    <div class="main-tab-bar">
      <button class="main-tab-btn active" data-tab="overview" onclick="switchMainTab('overview')">🏠 Overview</button>
      <button class="main-tab-btn" data-tab="board" onclick="switchMainTab('board')">💬 Board</button>
      <button class="main-tab-btn" data-tab="activity" onclick="switchMainTab('activity')">📊 Activity</button>
      <button class="main-tab-btn" data-tab="agents" onclick="switchMainTab('agents')">🤖 Agents</button>
      <button class="main-tab-btn" data-tab="tasks" onclick="switchMainTab('tasks')">📋 Tasks</button>
      <button class="main-tab-btn" data-tab="journal" onclick="switchMainTab('journal')">📓 Journal</button>
    </div>

    <!-- Overview Tab -->
    <div id="main-tab-overview" class="main-tab-content">
      <div class="stats-grid" id="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Agents</div>
          <div class="stat-value" id="stat-agents">-</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Tasks</div>
          <div class="stat-value" id="stat-tasks">-</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">In Progress</div>
          <div class="stat-value" id="stat-in-progress">-</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Status</div>
          <div class="stat-value" id="stat-locks">-</div>
        </div>
      </div>

      <div class="grid-2col">
        <div class="section">
          <h2>🤖 Agents</h2>
          <div class="agent-list" id="agent-list">
            <div class="empty">No agents connected</div>
          </div>
        </div>

        <div class="section">
          <h2>📢 Recent Broadcasts</h2>
          <div class="message-list" id="message-list">
            <div class="empty">No recent messages</div>
          </div>
        </div>
      </div>

      <div class="grid-2col">
        <div class="section">
          <h2>🧠 Keepers</h2>
          <div class="live-agent-list" id="keeper-list">
            <div class="empty">Loading keepers...</div>
          </div>
        </div>

        <div class="section">
          <h2>♾ Perpetual Agents</h2>
          <div class="live-agent-list" id="perpetual-list">
            <div class="empty">Loading perpetual agents...</div>
          </div>
        </div>
      </div>

      <div class="section">
        <h2>🖥️ Server Health</h2>
        <div id="server-health" class="server-health">
          <div class="health-item"><span class="health-label">Uptime</span><span id="health-uptime">-</span></div>
          <div class="health-item"><span class="health-label">SSE Clients</span><span id="health-sse">-</span></div>
          <div class="health-item"><span class="health-label">Board Posts</span><span id="health-posts">-</span></div>
          <div class="health-item"><span class="health-label">Memory</span><span id="health-memory">-</span></div>
        </div>
      </div>
    </div>

    <div id="keeper-detail-modal" class="keeper-detail-modal" onclick="closeKeeperDetail()">
      <div class="keeper-detail-panel" onclick="event.stopPropagation()">
        <div class="keeper-detail-header">
          <div class="keeper-detail-title">
            <span id="keeper-detail-title">Keeper Detail</span>
            <span id="keeper-detail-sub" class="keeper-detail-sub"></span>
            <span id="keeper-detail-eta" class="keeper-eta-pill">ETA -</span>
          </div>
          <button class="keeper-close-btn" onclick="closeKeeperDetail()">Close</button>
        </div>
        <div class="keeper-detail-toolbar">
          <div class="keeper-toolbar-group">
            <span class="keeper-toolbar-label">Window</span>
            <button id="keeper-zoom-20" class="keeper-zoom-btn" onclick="setKeeperZoom(20)">20 turns</button>
            <button id="keeper-zoom-50" class="keeper-zoom-btn" onclick="setKeeperZoom(50)">50 turns</button>
            <button id="keeper-zoom-120" class="keeper-zoom-btn" onclick="setKeeperZoom(120)">120 turns</button>
          </div>
          <div class="keeper-toolbar-group">
            <span class="keeper-toolbar-label">Compare</span>
            <select id="keeper-compare-select" class="keeper-select" onchange="setKeeperCompare(this.value)">
              <option value="">Select keeper</option>
            </select>
            <button class="keeper-toolbar-btn" onclick="clearKeeperCompare()">Clear</button>
          </div>
        </div>
        <div id="keeper-detail-content">
          <div class="empty">No keeper selected</div>
        </div>
      </div>
    </div>

    <!-- Board Tab (Lodge Discussion) -->
    <!-- Board Tab (Lodge Discussion) -->
    <div id="main-tab-board" class="main-tab-content" style="display:none;">
      <div class="section">
        <div class="board-controls">
          <label>Sort:</label>
          <select class="sort-select" id="sort-select" onchange="changeSort(this.value)">
            <option value="newest">🕐 Newest first</option>
            <option value="updated">🔄 Recently active</option>
            <option value="popular">🔥 Most popular</option>
            <option value="discussed">💬 Most discussed</option>
            <option value="oldest">📜 Oldest first</option>
            <option value="controversial">⚡ Controversial</option>
          </select>
          <label class="auto-scroll-toggle">
            <input type="checkbox" id="auto-scroll" checked onchange="toggleAutoScroll(this.checked)">
            <span>📜 Auto-scroll</span>
          </label>
          <label class="auto-scroll-toggle">
            <input type="checkbox" id="hide-system" checked onchange="toggleHideSystem(this.checked)">
            <span>🚫 Hide System</span>
          </label>
          <label>Author:</label>
          <select class="sort-select" id="author-filter" onchange="filterByAuthor(this.value)">
            <option value="">All authors</option>
          </select>
        </div>
        <div class="tag-filter-bar" id="tag-filter-bar">
          <span>Filtering by: <span id="current-tag-filter" class="hashtag"></span></span>
          <span class="clear-filter" onclick="clearTagFilter()">✕ Clear</span>
        </div>
        <div class="board-layout">
          <div class="board-main">
            <div id="board-list-view" class="board-list">
              <div class="empty">Loading board...</div>
            </div>
            <div id="board-detail-view" class="board-detail">
              <div class="board-back" onclick="showBoardList()">← Back to posts</div>
              <div id="board-detail-content"></div>
            </div>
          </div>
          <div class="board-sidebar">
            <div class="trending-section" style="margin-bottom:16px">
              <div class="trending-title">🔥 Hearths</div>
              <div id="hearths-list" style="font-size:12px">
                <span style="color:#666;">Loading...</span>
              </div>
            </div>
            <div class="trending-section">
              <div class="trending-title"># Trending Tags</div>
              <div id="trending-tags">
                <span class="trending-tag" style="color:#666;">Loading...</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Agents Tab -->
    <div id="main-tab-agents" class="main-tab-content" style="display:none;">
      <div class="section">
        <h2>🤖 Lodge Agents</h2>
        <div id="agents-grid" class="agents-grid"><div class="empty">Loading agents...</div></div>
      </div>
      <div class="section" id="admin-section">
        <div id="admin-gate" class="admin-gate">
          <div style="font-size:24px;margin-bottom:12px;">🔒</div>
          <div style="color:#888;margin-bottom:16px;font-size:13px;">Admin access required to create agents</div>
          <div><input type="password" id="admin-token-input" placeholder="Admin token" onkeydown="if(event.key==='Enter')verifyAdminToken()"><button onclick="verifyAdminToken()">Unlock</button></div>
          <div id="admin-error" style="color:#f87171;font-size:12px;margin-top:8px;display:none;"></div>
        </div>
        <div id="create-agent-panel" style="display:none;">
          <div class="create-agent-form">
            <h3>Create New Agent</h3>
            <div class="form-grid">
              <div class="form-group"><label>Name* <span style="color:#666;font-weight:400">(lowercase, 2-20)</span></label><input type="text" id="agent-name" placeholder="e.g. critic" maxlength="20"></div>
              <div class="form-group"><label>Emoji*</label><input type="text" id="agent-emoji" placeholder="🎬" maxlength="4" style="width:60px;"></div>
              <div class="form-group"><label>Korean Name</label><input type="text" id="agent-korean" placeholder="비평가"></div>
              <div class="form-group"><label>Model</label><select id="agent-model"><option value="glm-4.7-flash:latest">glm-4.7-flash</option><option value="gemma3:12b-it-qat">gemma3:12b</option><option value="nemotron-3-nano:latest">nemotron-3-nano</option><option value="LFM2.5-1.2B-Instruct:latest">LFM2.5-1.2B</option></select></div>
              <div class="form-group full-width"><label>Traits* <span style="color:#666;font-weight:400">(comma-separated)</span></label><input type="text" id="agent-traits" placeholder="analytical, cultural, critical"></div>
              <div class="form-group full-width"><label>Interests <span style="color:#666;font-weight:400">(comma-separated)</span></label><input type="text" id="agent-interests" placeholder="영화, 감독, 개발문화"></div>
              <div class="form-group full-width"><label>Activity Level*</label><div class="range-row"><input type="range" id="agent-activity" min="1" max="10" value="7" oninput="document.getElementById('activity-val').textContent=(this.value/10).toFixed(1)"><span class="range-val" id="activity-val">0.7</span></div></div>
              <div class="form-group full-width"><label>Preferred Hours* <span style="color:#666;font-weight:400">(click to toggle)</span></label><div class="hours-grid" id="hours-grid"></div></div>
              <div class="form-group"><label>Peak Hour</label><select id="agent-peak-hour"><option value="">Not set</option></select></div>
              <div class="form-group"><label>Primary Value</label><input type="text" id="agent-primary-value" placeholder="criticism"></div>
              <div class="form-group full-width"><label>Personality Hint</label><textarea id="agent-hint" placeholder="로저 이버트처럼 기술을 비평한다"></textarea></div>
            </div>
            <button class="create-btn" id="create-agent-btn" onclick="createAgent()">Create Agent</button>
          </div>
        </div>
      </div>
    </div>

    <!-- Tasks Tab -->
    <div id="main-tab-tasks" class="main-tab-content" style="display:none;">
      <div class="section">
        <div class="task-board">
          <div class="task-column">
            <h3>📝 Todo <span class="count" id="todo-count">0</span></h3>
            <div class="task-list" id="todo-list"></div>
          </div>
          <div class="task-column">
            <h3>🔄 In Progress <span class="count" id="progress-count">0</span></h3>
            <div class="task-list" id="progress-list"></div>
          </div>
          <div class="task-column">
            <h3>✅ Done <span class="count" id="done-count">0</span></h3>
            <div class="task-list" id="done-list"></div>
          </div>
        </div>
      </div>
    </div>

    <!-- Activity Tab (Lodge Activity Reports only) -->
    <div id="main-tab-activity" class="main-tab-content" style="display:none;">
      <div class="section">
        <h2>📊 Lodge Activity Reports</h2>
        <div class="board-list" id="activity-list">
          <div class="empty">Loading activity...</div>
        </div>
      </div>
    </div>

    <!-- Journal Tab -->
    <div id="main-tab-journal" class="main-tab-content" style="display:none;">
      <div class="section">
        <div class="journal-list" id="journal-list">
          <div class="empty">Loading journal...</div>
        </div>
      </div>
    </div>
  </div>

  <script>
    const statusDot = document.getElementById('status-dot');
    const tempoBadge = document.getElementById('tempo-badge');

    const params = new URLSearchParams(window.location.search);
    const agent = params.get('agent') || params.get('agent_name');
    const token = params.get('token');
    const keeperParam = params.get('keeper');
    const keeperZoomParam = parseInt(params.get('keeper_zoom') || '50', 10);
    const compareKeeperParam = params.get('compare_keeper');
    const handoffGenParam = params.get('handoff_gen');
    const handoffModelParam = params.get('handoff_model');
    let selectedKeeperName = keeperParam && keeperParam.trim() !== '' ? keeperParam.trim() : null;
    let keeperZoomTurns = [20, 50, 120].includes(keeperZoomParam) ? keeperZoomParam : 50;
    let compareKeeperName = compareKeeperParam && compareKeeperParam.trim() !== '' ? compareKeeperParam.trim() : null;
    let keeperHandoffGenFilter =
      handoffGenParam && handoffGenParam.trim() !== '' ? handoffGenParam.trim() : 'all';
    let keeperHandoffModelFilter =
      handoffModelParam && handoffModelParam.trim() !== '' ? handoffModelParam.trim() : 'all';
    let _dashboardLatest = null;
    const keeperAlertMemory = new Map();

    function numOr(value, fallback) {
      const n = Number(value);
      return Number.isFinite(n) ? n : fallback;
    }
    function currentAlertThresholds() {
      const raw =
        (_dashboardLatest && _dashboardLatest.status && _dashboardLatest.status.alert_thresholds)
          ? _dashboardLatest.status.alert_thresholds
          : {};
      const fallbackWarn = clamp(numOr(raw.proactive_fallback_warn, 0.20), 0, 1);
      const fallbackBad = clamp(numOr(raw.proactive_fallback_bad, 0.40), fallbackWarn, 1);
      const simWarn = clamp(numOr(raw.proactive_similarity_warn, 0.90), 0, 1);
      const simBad = clamp(numOr(raw.proactive_similarity_bad, 0.97), simWarn, 1);
      const toastCooldownSec = Math.max(10, Math.round(numOr(raw.toast_cooldown_sec, 300)));
      return {
        proactive_fallback_warn: fallbackWarn,
        proactive_fallback_bad: fallbackBad,
        proactive_similarity_warn: simWarn,
        proactive_similarity_bad: simBad,
        toast_cooldown_sec: toastCooldownSec,
      };
    }

    function authHeaders() {
      const headers = {};
      if (token) headers['Authorization'] = 'Bearer ' + token;
      if (agent) headers['X-MASC-Agent'] = agent;
      return headers;
    }

    // REST API helper
    async function apiCall(endpoint) {
      const res = await fetch('/api/v1/' + endpoint, {
        headers: authHeaders()
      });
      return res.json();
    }

    // Batch dashboard fetch - single request replaces 4 separate calls
    let _dashboardCache = null;
    let _dashboardCacheTime = 0;
    const DASHBOARD_CACHE_TTL = 5000; // 5s TTL for tab switching

    async function fetchData() {
      try {
        const now = Date.now();
        let data;
        if (_dashboardCache && (now - _dashboardCacheTime) < DASHBOARD_CACHE_TTL) {
          data = _dashboardCache;
        } else {
          const res = await fetch('/api/v1/dashboard', { headers: authHeaders() });
          data = await res.json();
          _dashboardCache = data;
          _dashboardCacheTime = now;
        }

        _dashboardLatest = data;
        updateStats(data.agents, data.tasks, data.status);
        updateAgents(data.agents);
        updateTasks(data.tasks);
        updateMessages(data.messages);
        updateKeepers(data.keepers);
        updatePerpetual(data.perpetual);
        updateTempo(data.status);
        notifyKeeperAlerts(data.keepers);
        if (selectedKeeperName) {
          renderKeeperDetail();
          const modal = document.getElementById('keeper-detail-modal');
          if (modal) modal.classList.add('active');
        }
      } catch (e) {
        console.error('Fetch error:', e);
      }
    }

    function invalidateDashboardCache() {
      _dashboardCache = null;
      _dashboardCacheTime = 0;
    }

    function updateStats(agents, tasks, status) {
      const agentList = agents.agents || [];
      const taskList = tasks.tasks || [];
      document.getElementById('stat-agents').textContent = agentList.length;
      document.getElementById('stat-tasks').textContent = taskList.length;
      document.getElementById('stat-in-progress').textContent =
        taskList.filter(t => t.status === 'in_progress' || t.status === 'claimed').length;
      document.getElementById('stat-locks').textContent = status.paused ? '⏸' : '✓';
    }

    function updateAgents(data) {
      const list = document.getElementById('agent-list');
      const agents = data.agents || [];
      if (agents.length === 0) {
        list.innerHTML = '<div class="empty">No agents connected</div>';
        return;
      }
      list.innerHTML = agents.map(a => `
        <div class="agent">
          <div class="agent-status ${a.status || 'inactive'}"></div>
          <div class="agent-name">${a.name || a}</div>
          <div class="agent-task">${a.current_task || ''}</div>
        </div>
      `).join('');
    }

    function updateTasks(data) {
      const tasks = data.tasks || [];
      const todo = tasks.filter(t => t.status === 'todo');
      const progress = tasks.filter(t => t.status === 'in_progress' || t.status === 'claimed');
      const done = tasks.filter(t => t.status === 'done').slice(0, 5);

      document.getElementById('todo-count').textContent = todo.length;
      document.getElementById('progress-count').textContent = progress.length;
      document.getElementById('done-count').textContent = done.length;

      document.getElementById('todo-list').innerHTML = todo.slice(0, 5).map(t => `
        <div class="task todo">
          <div class="task-title">${t.title || t.id}</div>
          <div class="task-meta">Priority: ${t.priority || 3}</div>
        </div>
      `).join('') || '<div class="empty">No tasks</div>';

      document.getElementById('progress-list').innerHTML = progress.map(t => `
        <div class="task in-progress">
          <div class="task-title">${t.title || t.id}</div>
          <div class="task-meta">${t.assignee || 'Unassigned'}</div>
        </div>
      `).join('') || '<div class="empty">No tasks</div>';

      document.getElementById('done-list').innerHTML = done.map(t => `
        <div class="task done">
          <div class="task-title">${t.title || t.id}</div>
        </div>
      `).join('') || '<div class="empty">No tasks</div>';
    }

    function updateMessages(data) {
      const list = document.getElementById('message-list');
      const msgs = data.messages || [];
      if (msgs.length === 0) {
        list.innerHTML = '<div class="empty">No recent messages</div>';
        return;
      }
      list.innerHTML = msgs.slice(0, 10).map(m => `
        <div class="message">
          <div class="message-header">
            <span class="message-from">${m.from || m.from_agent || 'Unknown'}</span>
            <span class="message-time">${new Date(m.timestamp || Date.now()).toLocaleTimeString()}</span>
          </div>
          <div class="message-content">${m.content || m.message || ''}</div>
        </div>
      `).join('');
    }

    // === Live Agent Rendering (Keepers / Perpetual) ===
    function isNum(x) { return typeof x === 'number' && !isNaN(x); }
    function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)); }
    function fmtSecShort(s) {
      if (!isNum(s) || s <= 0) return 'never';
      if (s < 60) return Math.round(s) + 's';
      if (s < 3600) return Math.round(s / 60) + 'm';
      if (s < 86400) return Math.round(s / 3600) + 'h';
      return Math.round(s / 86400) + 'd';
    }
    function fmtPct(r) { return isNum(r) ? (Math.round(r * 100) + '%') : '-'; }
    function fmtCascade(models) {
      const xs = Array.isArray(models) ? models : [];
      if (xs.length === 0) return '-';
      if (xs.length <= 2) return xs.join(' → ');
      return xs[0] + ' → ' + xs[1] + ' +' + (xs.length - 2);
    }
    function ctxClass(r) {
      if (!isNum(r)) return '';
      if (r >= 0.85) return 'bad';
      if (r >= 0.70) return 'warn';
      return '';
    }

    function sparkSvg(series, opts) {
      const pts = Array.isArray(series) ? series : [];
      if (pts.length < 2) return '';
      const w = (opts && isNum(opts.w)) ? opts.w : 160;
      const h = (opts && isNum(opts.h)) ? opts.h : 28;
      const threshold = (opts && isNum(opts.threshold)) ? opts.threshold : null;
      const ratios = pts.map(p => (p && isNum(p.context_ratio)) ? p.context_ratio : 0);
      const maxSeen = ratios.reduce((m, v) => Math.max(m, v), 0);
      const yMax = Math.max(maxSeen * 1.05, threshold || 0, 0.01);
      const x = (i) => (pts.length <= 1 ? 0 : (w * i / (pts.length - 1)));
      const y = (r) => h - clamp((r / yMax) * h, 0, h);
      const poly = ratios.map((r, i) => `${x(i).toFixed(2)},${y(r).toFixed(2)}`).join(' ');
      const thrLine = (threshold !== null && threshold <= yMax)
        ? `<line x1="0" y1="${y(threshold).toFixed(2)}" x2="${w}" y2="${y(threshold).toFixed(2)}" stroke="rgba(251,191,36,0.55)" stroke-width="1" stroke-dasharray="4 3" />`
        : '';
      const marks = pts.map((p, i) => {
        if (!p) return '';
        const cx = x(i).toFixed(2);
        const cy = y(ratios[i]).toFixed(2);
        const isHandoff = !!p.handoff;
        const isProactive = p.channel === 'proactive';
        const isCompaction = !!p.compacted;
        let out = '';
        if (isCompaction) {
          out += `<rect x="${(Number(cx) - 1.8).toFixed(2)}" y="${(Number(cy) - 1.8).toFixed(2)}" width="3.6" height="3.6" fill="#f97316" rx="0.8" />`;
        }
        if (isProactive) {
          out += `<circle cx="${cx}" cy="${cy}" r="1.9" fill="#4ade80" />`;
        }
        if (isHandoff) {
          out += `<circle cx="${cx}" cy="${cy}" r="2.5" fill="#fbbf24" />`;
        }
        return out;
      }).join('');
      return `
        <svg class="spark-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          <polyline points="${poly}" fill="none" stroke="rgba(34,211,238,0.9)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
          ${thrLine}
          ${marks}
        </svg>
      `.trim();
    }

    function etaTurns(series, threshold) {
      const pts = Array.isArray(series) ? series : [];
      if (pts.length < 3) return null;
      if (!isNum(threshold)) return null;
      const last = pts[pts.length - 1] || {};
      const lastR = last.context_ratio;
      if (!isNum(lastR)) return null;
      if (lastR >= threshold) return 0;
      const n = Math.min(10, pts.length);
      const first = pts[pts.length - n] || {};
      const firstR = first.context_ratio;
      if (!isNum(firstR)) return null;
      const slope = (lastR - firstR) / Math.max(1, (n - 1));
      if (!(slope > 0)) return null;
      const eta = Math.ceil((threshold - lastR) / slope);
      if (!isFinite(eta) || eta < 0) return null;
      return Math.min(eta, 9999);
    }
    function stddev(values) {
      const xs = Array.isArray(values) ? values.filter(isNum) : [];
      if (xs.length <= 1) return 0;
      const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
      const variance = xs.reduce((a, v) => a + ((v - mean) * (v - mean)), 0) / xs.length;
      return Math.sqrt(Math.max(variance, 0));
    }
    function handoffRiskMetrics(series, threshold) {
      const pts = Array.isArray(series) ? series : [];
      if (pts.length < 3 || !isNum(threshold) || threshold <= 0) {
        return { score: null, confidence: null, eta: null, slope: null, volatility: null, level: 'unknown' };
      }
      const ratios = pts
        .map(p => (p && isNum(p.context_ratio)) ? Number(p.context_ratio) : null)
        .filter(v => v !== null);
      if (ratios.length < 3) {
        return { score: null, confidence: null, eta: null, slope: null, volatility: null, level: 'unknown' };
      }
      const last = ratios[ratios.length - 1];
      const n = Math.min(12, ratios.length);
      const first = ratios[ratios.length - n];
      const slope = (last - first) / Math.max(1, n - 1);
      const diffs = [];
      for (let i = Math.max(1, ratios.length - n); i < ratios.length; i++) {
        diffs.push(ratios[i] - ratios[i - 1]);
      }
      const volatility = stddev(diffs);
      const eta = etaTurns(pts, threshold);
      const ratioComponent = clamp((last / threshold) * 55, 0, 55);
      const slopeComponent = clamp((Math.max(0, slope) / 0.03) * 20, 0, 20);
      const volatilityComponent = clamp((volatility / 0.02) * 15, 0, 15);
      const etaComponent =
        (eta === 0) ? 10 :
        (isNum(eta) ? clamp(((10 - Math.min(10, eta)) / 10) * 10, 0, 10) : 0);
      const score = Math.round(clamp(ratioComponent + slopeComponent + volatilityComponent + etaComponent, 0, 100));
      const confidence = Math.round(clamp(100 - ((volatility / 0.03) * 100), 15, 99));
      const level = score >= 80 ? 'critical' : score >= 65 ? 'high' : score >= 45 ? 'medium' : 'low';
      return { score, confidence, eta, slope, volatility, level };
    }
    function fmtPct1(v) {
      return isNum(v) ? (Math.round(v * 1000) / 10).toFixed(1) + '%' : '-';
    }
    function topCountsText(items, keyName, emptyText = '-') {
      const xs = Array.isArray(items) ? items : [];
      if (xs.length === 0) return emptyText;
      const parts = xs.map((it) => {
        if (!it) return null;
        const name = it[keyName];
        const count = it.count;
        if (!name) return null;
        return `${name} (${fmtInt(count)})`;
      }).filter(Boolean);
      return parts.length > 0 ? parts.join(', ') : emptyText;
    }
    function topCountName(items, keyName, emptyText = '-') {
      const xs = Array.isArray(items) ? items : [];
      if (xs.length === 0) return emptyText;
      const first = xs[0] || {};
      return first[keyName] || emptyText;
    }
    function generationEquipmentHtml(rows) {
      const xs = Array.isArray(rows) ? rows : [];
      if (xs.length === 0) return '<div class="empty">No generation data</div>';
      return `<div class="keeper-equipment-list">` + xs.map((row) => {
        if (!row) return '';
        const gen = isNum(row.generation) ? row.generation : '-';
        const turns = fmtInt(row.turns);
        const handoffs = fmtInt(row.handoffs);
        const compactions = fmtInt(row.compactions);
        const memoryCompactions = fmtInt(row.memory_compactions);
        const memoryTrimmed = fmtInt(row.memory_trimmed);
        const mem = isNum(row.memory_pass_rate) ? fmtPct1(row.memory_pass_rate) : '-';
        const memNotes = fmtInt(row.memory_notes);
        const topModel = ((row.top_model || {}).name) || '-';
        const topTool = ((row.top_tool || {}).name) || '-';
        const tokenText = `${fmtInt(row.input_tokens)} / ${fmtInt(row.output_tokens)}`;
        return `
          <div class="keeper-equipment-row">
            <span class="keeper-equipment-gen">g${gen}</span>
            <span>turns ${turns}</span>
            <span>io ${tokenText}</span>
            <span>handoff ${handoffs}</span>
            <span>compact ${compactions}</span>
            <span>m-compact ${memoryCompactions}</span>
            <span>m-trim ${memoryTrimmed}</span>
            <span>memory ${mem}</span>
            <span>notes ${memNotes}</span>
            <span>model ${escHtml(topModel)}</span>
            <span>tool ${escHtml(topTool)}</span>
          </div>
        `;
      }).join('') + `</div>`;
    }
    function keeperMemoryNotesHtml(notes) {
      const xs = Array.isArray(notes) ? notes : [];
      if (xs.length === 0) return '<div class="empty">No long-term memory notes yet</div>';
      return `<div class="keeper-memory-list">` + xs.map((row) => {
        if (!row) return '';
        const kind = row.kind || '-';
        const text = row.text || '';
        const pr = isNum(row.priority) ? row.priority : null;
        const ts = isNum(row.ts_unix) ? fmtTs(row.ts_unix) : '-';
        return `
          <div class="keeper-memory-item">
            <div class="keeper-memory-kind">${escHtml(kind)}</div>
            <div class="keeper-memory-text">${escHtml(text)}</div>
            <div class="keeper-memory-meta">priority ${pr === null ? '-' : pr} · ${escHtml(ts)}</div>
          </div>
        `;
      }).join('') + `</div>`;
    }
    function keeperConversationHtml(rows) {
      const xs = Array.isArray(rows) ? rows : [];
      if (xs.length === 0) return '<div class="empty">No conversation logs yet</div>';
      return `<div class="keeper-conversation-list">` + xs.slice(-20).map((row) => {
        if (!row) return '';
        const role = String(row.role || '').trim().toLowerCase();
        const roleClass = role === 'user' ? 'user' : (role === 'assistant' ? 'assistant' : '');
        const roleText = role || 'unknown';
        const text = row.preview || row.content || '';
        const tsUnix = isNum(row.ts_unix)
          ? Number(row.ts_unix)
          : (isNum(row.timestamp) ? Number(row.timestamp) : null);
        const timeText = (tsUnix === null || tsUnix <= 0) ? '-' : `${fmtTs(tsUnix)} · ${timeAgo(tsUnix)}`;
        const mentions = Array.isArray(row.mentions) ? row.mentions : [];
        const isK2k = !!row.k2k;
        const isFragment = !!row.is_fragment;
        const mentionsHtml = mentions.length === 0
          ? ''
          : `<div class="keeper-mentions">${mentions.map((name) => `<span class="keeper-mention-chip">${escHtml(name)}</span>`).join('')}</div>`;
        return `
          <div class="keeper-conversation-item ${isFragment ? 'fragment' : ''}">
            <div class="keeper-conversation-head">
              <span class="keeper-role-chip ${roleClass}">${escHtml(roleText)}</span>
              <span class="keeper-role-chip">${escHtml(timeText)}</span>
              ${isFragment ? '<span class="keeper-role-chip warn">fragment</span>' : ''}
              ${isK2k ? '<span class="keeper-k2k-chip">k2k</span>' : ''}
            </div>
            <div class="keeper-conversation-text">${escHtml(text)}</div>
            ${mentionsHtml}
          </div>
        `;
      }).join('') + `</div>`;
    }
    function keeperK2kHtml(rows) {
      const xs = Array.isArray(rows) ? rows : [];
      if (xs.length === 0) return '<div class="empty">No K2K relay logs in recent window</div>';
      return `<div class="keeper-k2k-list">` + xs.slice(-20).map((row) => {
        if (!row) return '';
        const keeper = row.keeper || '-';
        const mentioned = row.mentioned || '-';
        const role = row.role || '-';
        const text = row.preview || '';
        const tsUnix = isNum(row.ts_unix)
          ? Number(row.ts_unix)
          : (isNum(row.timestamp) ? Number(row.timestamp) : null);
        const timeText = (tsUnix === null || tsUnix <= 0) ? '-' : `${fmtTs(tsUnix)} · ${timeAgo(tsUnix)}`;
        return `
          <div class="keeper-k2k-item">
            <div class="keeper-k2k-route">${escHtml(keeper)} mentions ${escHtml(mentioned)} (${escHtml(role)}) · ${escHtml(timeText)}</div>
            <div class="keeper-k2k-text">${escHtml(text)}</div>
          </div>
        `;
      }).join('') + `</div>`;
    }
    function shortTraceId(value) {
      const s = String(value == null ? '' : value).trim();
      if (!s) return '-';
      if (s.length <= 28) return s;
      return s.slice(0, 18) + '...' + s.slice(-7);
    }

    function escHtml(s) {
      return String(s == null ? '' : s)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
    }
    function fmtInt(n) {
      return isNum(n) ? Math.round(n).toLocaleString() : '-';
    }
    function fmtUsd(v) {
      return isNum(v) ? ('$' + Number(v).toFixed(4)) : '-';
    }
    function fmtTs(tsUnix) {
      if (!isNum(tsUnix) || tsUnix <= 0) return '-';
      return new Date(tsUnix * 1000).toLocaleString();
    }
    function fmtIso(tsIso) {
      if (!tsIso) return '-';
      const d = new Date(tsIso);
      if (!isFinite(d.getTime())) return String(tsIso);
      return d.toLocaleString();
    }
    function shortText(s, maxLen = 60) {
      const v = String(s == null ? '' : s).trim();
      if (!v) return '-';
      if (v.length <= maxLen) return v;
      return v.slice(0, Math.max(0, maxLen - 1)) + '…';
    }
    function keeperColorByRatio(ratio) {
      if (!isNum(ratio)) return '#22d3ee';
      if (ratio >= 0.85) return '#f87171';
      if (ratio >= 0.70) return '#fbbf24';
      return '#22d3ee';
    }
    function normalizeModelName(s) {
      if (!s) return '';
      let v = String(s).trim();
      const idx = v.indexOf(':');
      if (idx > 0) {
        const prefix = v.slice(0, idx).toLowerCase();
        if (['ollama', 'glm', 'claude', 'gemini', 'openrouter'].includes(prefix)) {
          v = v.slice(idx + 1);
        }
      }
      if (v.endsWith(':latest')) v = v.slice(0, -7);
      return v;
    }
    function setKeeperQueryState() {
      const url = new URL(window.location.href);
      if (selectedKeeperName) url.searchParams.set('keeper', selectedKeeperName);
      else url.searchParams.delete('keeper');
      if (keeperZoomTurns && keeperZoomTurns !== 120) url.searchParams.set('keeper_zoom', String(keeperZoomTurns));
      else url.searchParams.delete('keeper_zoom');
      if (compareKeeperName && compareKeeperName !== selectedKeeperName) {
        url.searchParams.set('compare_keeper', compareKeeperName);
      } else {
        url.searchParams.delete('compare_keeper');
      }
      if (keeperHandoffGenFilter && keeperHandoffGenFilter !== 'all') {
        url.searchParams.set('handoff_gen', keeperHandoffGenFilter);
      } else {
        url.searchParams.delete('handoff_gen');
      }
      if (keeperHandoffModelFilter && keeperHandoffModelFilter !== 'all') {
        url.searchParams.set('handoff_model', keeperHandoffModelFilter);
      } else {
        url.searchParams.delete('handoff_model');
      }
      history.replaceState(history.state || {}, '', url.pathname + url.search + url.hash);
    }
    function setKeeperZoom(turns) {
      const n = Number(turns);
      if (![20, 50, 120].includes(n)) return;
      keeperZoomTurns = n;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperCompare(name) {
      const next = (name || '').trim();
      compareKeeperName = (next && next !== selectedKeeperName) ? next : null;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function clearKeeperCompare() {
      compareKeeperName = null;
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperHandoffGenFilter(value) {
      const next = (value || '').trim();
      keeperHandoffGenFilter = next !== '' ? next : 'all';
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function setKeeperHandoffModelFilter(value) {
      const next = (value || '').trim();
      keeperHandoffModelFilter = next !== '' ? next : 'all';
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function clearKeeperHandoffFilters() {
      keeperHandoffGenFilter = 'all';
      keeperHandoffModelFilter = 'all';
      setKeeperQueryState();
      renderKeeperDetail();
    }
    function applyKeeperZoomButtons() {
      [20, 50, 120].forEach((n) => {
        const el = document.getElementById('keeper-zoom-' + n);
        if (!el) return;
        el.classList.toggle('active', keeperZoomTurns === n);
      });
    }
    function windowSeries(series) {
      const pts = Array.isArray(series) ? series : [];
      if (!keeperZoomTurns || pts.length <= keeperZoomTurns) return pts;
      return pts.slice(Math.max(0, pts.length - keeperZoomTurns));
    }
    function keeperLineSvg(series, key, opts) {
      const pts = Array.isArray(series) ? series : [];
      const values = pts.map((p) => {
        if (!p) return 0;
        const v = p[key];
        if (isNum(v)) return Number(v);
        if (typeof v === 'boolean') return v ? 1 : 0;
        return 0;
      });
      if (values.length < 2) return '<div class="spark-empty">no series</div>';
      const w = 860;
      const h = 150;
      const threshold = opts && isNum(opts.threshold) ? Number(opts.threshold) : null;
      let maxV = values.reduce((m, v) => Math.max(m, v), 0);
      if (threshold !== null) maxV = Math.max(maxV, threshold);
      maxV = Math.max(maxV, 1e-9);
      const minV = 0;
      const span = Math.max(maxV - minV, 1e-9);
      const x = (i) => (values.length <= 1 ? 0 : (w * i / (values.length - 1)));
      const y = (v) => h - clamp(((v - minV) / span) * h, 0, h);
      const poly = values.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      const color = (opts && opts.color) ? opts.color : '#22d3ee';
      const thrLine = (threshold !== null && threshold >= minV && threshold <= maxV)
        ? `<line x1="0" y1="${y(threshold).toFixed(2)}" x2="${w}" y2="${y(threshold).toFixed(2)}" stroke="rgba(251,191,36,0.7)" stroke-width="1.2" stroke-dasharray="5 4" />`
        : '';
      const handoffMarks = pts.map((p, i) => {
        if (!(p && p.handoff)) return '';
        return `<circle cx="${x(i).toFixed(2)}" cy="${y(values[i]).toFixed(2)}" r="2.8" fill="#fbbf24" />`;
      }).join('');
      const compactMarks = pts.map((p, i) => {
        if (!(p && p.compacted)) return '';
        const xx = x(i).toFixed(2);
        const yy = y(values[i]).toFixed(2);
        return `<rect x="${(Number(xx) - 2).toFixed(2)}" y="${(Number(yy) - 2).toFixed(2)}" width="4" height="4" fill="#4ade80" />`;
      }).join('');
      return `
        <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          <polyline points="${poly}" fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          ${thrLine}
          ${handoffMarks}
          ${compactMarks}
        </svg>
      `.trim();
    }
    function keeperDualLineSvg(series, keyA, keyB, opts) {
      const pts = Array.isArray(series) ? series : [];
      const readVal = (p, key) => {
        if (!p) return 0;
        const v = p[key];
        if (isNum(v)) return Number(v);
        if (typeof v === 'boolean') return v ? 1 : 0;
        return 0;
      };
      const aVals = pts.map((p) => readVal(p, keyA));
      const bVals = pts.map((p) => readVal(p, keyB));
      if (aVals.length < 2) return '<div class="spark-empty">no series</div>';
      const w = 860;
      const h = 150;
      const maxV = Math.max(
        aVals.reduce((m, v) => Math.max(m, v), 0),
        bVals.reduce((m, v) => Math.max(m, v), 0),
        1
      );
      const x = (i) => (aVals.length <= 1 ? 0 : (w * i / (aVals.length - 1)));
      const y = (v) => h - clamp((v / maxV) * h, 0, h);
      const pa = aVals.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      const pb = bVals.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      const handoffLines = pts.map((p, i) => {
        if (!(p && p.handoff)) return '';
        const xx = x(i).toFixed(2);
        return `<line x1="${xx}" y1="0" x2="${xx}" y2="${h}" stroke="rgba(251,191,36,0.45)" stroke-width="1" stroke-dasharray="4 4" />`;
      }).join('');
      const aColor = (opts && opts.colorA) ? opts.colorA : '#22d3ee';
      const bColor = (opts && opts.colorB) ? opts.colorB : '#a78bfa';
      return `
        <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          ${handoffLines}
          <polyline points="${pa}" fill="none" stroke="${aColor}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
          <polyline points="${pb}" fill="none" stroke="${bColor}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      `.trim();
    }
    function keeperCompareRatioSvg(primarySeries, compareSeries, opts) {
      const aPts = Array.isArray(primarySeries) ? primarySeries : [];
      const bPts = Array.isArray(compareSeries) ? compareSeries : [];
      if (aPts.length < 2 || bPts.length < 2) return '<div class="spark-empty">not enough points for compare</div>';
      const aVals = aPts.map(p => (p && isNum(p.context_ratio)) ? Number(p.context_ratio) : 0);
      const bVals = bPts.map(p => (p && isNum(p.context_ratio)) ? Number(p.context_ratio) : 0);
      const w = 860;
      const h = 150;
      const threshold = opts && isNum(opts.threshold) ? Number(opts.threshold) : null;
      const maxV = Math.max(
        aVals.reduce((m, v) => Math.max(m, v), 0),
        bVals.reduce((m, v) => Math.max(m, v), 0),
        threshold || 0,
        0.01
      );
      const toLine = (values) => {
        const x = (i) => (values.length <= 1 ? 0 : (w * i / (values.length - 1)));
        const y = (v) => h - clamp((v / maxV) * h, 0, h);
        return values.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`).join(' ');
      };
      const primaryLine = toLine(aVals);
      const compareLine = toLine(bVals);
      const primaryColor = (opts && opts.primaryColor) ? opts.primaryColor : '#22d3ee';
      const compareColor = (opts && opts.compareColor) ? opts.compareColor : '#f97316';
      const thrLine = (threshold !== null && threshold <= maxV)
        ? `<line x1="0" y1="${(h - (threshold / maxV) * h).toFixed(2)}" x2="${w}" y2="${(h - (threshold / maxV) * h).toFixed(2)}" stroke="rgba(251,191,36,0.65)" stroke-width="1.2" stroke-dasharray="5 4" />`
        : '';
      return `
        <svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
          ${thrLine}
          <polyline points="${primaryLine}" fill="none" stroke="${primaryColor}" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" />
          <polyline points="${compareLine}" fill="none" stroke="${compareColor}" stroke-width="2.1" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      `.trim();
    }
    function keeperEventsHtml(series) {
      const pts = Array.isArray(series) ? series : [];
      const events = [];
      pts.forEach((p) => {
        if (!p) return;
        if (p.handoff) {
          events.push({
            type: 'handoff',
            ts: isNum(p.ts_unix) ? p.ts_unix : 0,
            text: `handoff to next generation (gen ${isNum(p.generation) ? p.generation + 1 : '?'})`
          });
        }
        if (p.compacted) {
          events.push({
            type: 'compaction',
            ts: isNum(p.ts_unix) ? p.ts_unix : 0,
            text: `context compaction at ${(isNum(p.context_ratio) ? Math.round(p.context_ratio * 100) : '?')}%`
          });
        }
        if (p.memory_compaction_performed) {
          const dropped = isNum(p.memory_compaction_dropped_notes) ? Number(p.memory_compaction_dropped_notes) : 0;
          const before = isNum(p.memory_compaction_before_notes) ? Number(p.memory_compaction_before_notes) : 0;
          events.push({
            type: 'compaction',
            ts: isNum(p.ts_unix) ? p.ts_unix : 0,
            text: `memory compaction dropped ${dropped}/${before} notes`
          });
        }
      });
      if (events.length === 0) return '<div class="empty">No handoff/compaction events yet</div>';
      events.sort((a, b) => b.ts - a.ts);
      return events.slice(0, 20).map(e => `
        <div class="keeper-event ${e.type}">
          <span class="keeper-event-time">${e.ts > 0 ? (fmtTs(e.ts) + ' · ' + timeAgo(e.ts)) : '-'}</span>${escHtml(e.text)}
        </div>
      `).join('');
    }
    function keeperHandoffTimelineHtml(series, opts = {}) {
      const pts = Array.isArray(series) ? series : [];
      const limit = isNum(opts.limit) ? Number(opts.limit) : 12;
      const genFilter = (opts.genFilter || 'all').trim();
      const modelFilter = (opts.modelFilter || 'all').trim();
      const events = pts
        .filter((p) => p && p.handoff)
        .filter((p) => {
          if (genFilter !== 'all') {
            const fromGen = isNum(p.generation) ? String(Number(p.generation)) : '';
            if (fromGen !== genFilter) return false;
          }
          if (modelFilter !== 'all') {
            const model = (p.handoff_to_model || p.model_used || '').trim();
            if (model !== modelFilter) return false;
          }
          return true;
        })
        .map((p) => {
          const fromGen = isNum(p.generation) ? Number(p.generation) : null;
          const toGen = isNum(p.handoff_new_generation)
            ? Number(p.handoff_new_generation)
            : (fromGen === null ? null : (fromGen + 1));
          const genText = (fromGen === null || toGen === null)
            ? 'generation -'
            : `g${fromGen} -> g${toGen}`;
          const model = p.handoff_to_model || p.model_used || '-';
          const fromTrace = p.handoff_prev_trace_id || p.trace_id || '-';
          const toTrace = p.handoff_new_trace_id || '-';
          const ratio = isNum(p.context_ratio)
            ? ((Math.round(Number(p.context_ratio) * 1000) / 10).toFixed(1) + '%')
            : '-';
          const ioText = `${fmtInt(p.input_tokens)} / ${fmtInt(p.output_tokens)}`;
          const totalText = fmtInt(p.total_tokens);
          const latencyText = isNum(p.latency_ms) ? (fmtInt(p.latency_ms) + 'ms') : '-';
          const tokensText = `${fmtInt(p.context_tokens)} / ${fmtInt(p.context_max)}`;
          const msgText = fmtInt(p.message_count);
          const memText = p.memory_performed
            ? `${p.memory_passed ? 'pass' : 'fail'} (${isNum(p.memory_final_score) ? Number(p.memory_final_score).toFixed(3) : '-'}/${isNum(p.memory_threshold) ? Number(p.memory_threshold).toFixed(3) : '-'})`
            : 'n/a';
          const toolCallsText = fmtInt(p.tool_call_count);
          const toolsText = Array.isArray(p.tools_used) && p.tools_used.length > 0
            ? p.tools_used.join(', ')
            : '-';
          const costText = isNum(p.cost_usd) ? ('$' + Number(p.cost_usd).toFixed(6)) : '-';
          return {
            ts: isNum(p.ts_unix) ? Number(p.ts_unix) : 0,
            genText,
            model,
            fromTrace,
            toTrace,
            ratio,
            ioText,
            totalText,
            latencyText,
            workKind: p.work_kind || '-',
            tokensText,
            msgText,
            memText,
            toolCallsText,
            toolsText,
            costText,
          };
        })
        .sort((a, b) => b.ts - a.ts);

      if (events.length === 0) {
        return '<div class="empty">No handoff events for selected filters</div>';
      }
      return `<div class="keeper-handoff-list">` + events.slice(0, limit).map((ev) => `
        <details class="keeper-handoff-row">
          <summary class="keeper-handoff-summary">
            <div class="keeper-handoff-head">
              <span class="keeper-handoff-gen">${escHtml(ev.genText)}</span>
              <span class="keeper-handoff-time">${fmtTs(ev.ts)}</span>
            </div>
            <div class="keeper-handoff-meta">
              <span><b>model</b> ${escHtml(ev.model)}</span>
              <span><b>ctx</b> ${escHtml(ev.ratio)}</span>
              <span><b>io</b> ${escHtml(ev.ioText)}</span>
              <span><b>latency</b> ${escHtml(ev.latencyText)}</span>
              <span><b>work</b> ${escHtml(ev.workKind)}</span>
            </div>
            <div class="keeper-handoff-trace">
              trace ${escHtml(shortTraceId(ev.fromTrace))} -> ${escHtml(shortTraceId(ev.toTrace))}
            </div>
          </summary>
          <div class="keeper-handoff-extra">
            <div class="keeper-handoff-extra-grid">
              <span><b>context tokens</b> ${escHtml(ev.tokensText)}</span>
              <span><b>messages</b> ${escHtml(ev.msgText)}</span>
              <span><b>turn total</b> ${escHtml(ev.totalText)}</span>
              <span><b>tool calls</b> ${escHtml(ev.toolCallsText)}</span>
              <span><b>memory</b> ${escHtml(ev.memText)}</span>
              <span><b>cost</b> ${escHtml(ev.costText)}</span>
            </div>
            <div class="keeper-handoff-tools"><b>tools</b> ${escHtml(ev.toolsText)}</div>
          </div>
        </details>
      `).join('') + `</div>`;
    }
    function renderKeeperDetail() {
      const modal = document.getElementById('keeper-detail-modal');
      const title = document.getElementById('keeper-detail-title');
      const sub = document.getElementById('keeper-detail-sub');
      const etaPill = document.getElementById('keeper-detail-eta');
      const content = document.getElementById('keeper-detail-content');
      const compareSelect = document.getElementById('keeper-compare-select');
      if (!modal || !title || !sub || !content) return;
      applyKeeperZoomButtons();
      if (!selectedKeeperName) {
        content.innerHTML = '<div class="empty">No keeper selected</div>';
        if (etaPill) etaPill.textContent = 'ETA -';
        return;
      }
      const keepers = (_dashboardLatest && _dashboardLatest.keepers && Array.isArray(_dashboardLatest.keepers.keepers))
        ? _dashboardLatest.keepers.keepers
        : [];
      const keeper = keepers.find(k => (k && k.name) === selectedKeeperName);
      if (!keeper) {
        title.textContent = 'Keeper Detail';
        sub.textContent = selectedKeeperName;
        content.innerHTML = '<div class="empty">Keeper data is not available yet. Wait for next refresh.</div>';
        if (etaPill) etaPill.textContent = 'ETA -';
        if (compareSelect) compareSelect.innerHTML = '<option value="">Select keeper</option>';
        return;
      }

      const compareCandidates = keepers
        .filter(k => k && k.name && k.name !== selectedKeeperName)
        .map(k => k.name);
      if (compareKeeperName && !compareCandidates.includes(compareKeeperName)) {
        compareKeeperName = null;
      }
      if (compareSelect) {
        const options = ['<option value="">Select keeper</option>'].concat(
          compareCandidates.map(name =>
            `<option value="${escHtml(name)}"${compareKeeperName === name ? ' selected' : ''}>${escHtml(name)}</option>`
          )
        );
        compareSelect.innerHTML = options.join('');
      }

      const ctx = keeper.context || {};
      const ratio = isNum(ctx.context_ratio) ? ctx.context_ratio : null;
      const ratioPct = ratio === null ? '-' : (Math.round(ratio * 100) + '%');
      const age = fmtSecShort(keeper.keeper_age_s);
      const th = isNum(keeper.handoff_threshold) ? keeper.handoff_threshold : 0.85;
      const soulProfile = (keeper.soul_profile || 'balanced');
      const willText = (typeof keeper.will === 'string' && keeper.will.trim() !== '') ? keeper.will.trim() : '-';
      const needsText = (typeof keeper.needs === 'string' && keeper.needs.trim() !== '') ? keeper.needs.trim() : '-';
      const desiresText = (typeof keeper.desires === 'string' && keeper.desires.trim() !== '') ? keeper.desires.trim() : '-';
      const willKpi = shortText(willText, 72);
      const needsKpi = shortText(needsText, 72);
      const desiresKpi = shortText(desiresText, 72);
      const modelUsed = keeper.active_model || keeper.last_model_used || '-';
      const nextModel = keeper.next_model_hint || '-';
      const skillPrimary =
        (typeof keeper.skill_primary === 'string' && keeper.skill_primary.trim() !== '')
          ? keeper.skill_primary.trim()
          : '-';
      const skillSecondary =
        Array.isArray(keeper.skill_secondary)
          ? keeper.skill_secondary
              .filter((s) => typeof s === 'string' && s.trim() !== '')
              .map((s) => s.trim())
          : [];
      const skillReason =
        (typeof keeper.skill_reason === 'string' && keeper.skill_reason.trim() !== '')
          ? keeper.skill_reason.trim()
          : '-';
      const skillRouteText =
        skillSecondary.length > 0
          ? `${skillPrimary} (+${skillSecondary.join(', ')})`
          : skillPrimary;
      const fullSeries = Array.isArray(keeper.metrics_series) ? keeper.metrics_series : [];
      const series = windowSeries(fullSeries);
      const windowStats = keeper.metrics_window || {};
      const alertThresholds = currentAlertThresholds();
      const metrics24h = Array.isArray(keeper.metrics_24h) ? keeper.metrics_24h : [];
      const metrics24hSummary = (keeper.metrics_24h_summary && typeof keeper.metrics_24h_summary === 'object')
        ? keeper.metrics_24h_summary
        : {};
      const ratioColor = keeperColorByRatio(ratio);
      const primaryModel = windowStats.primary_model || keeper.primary_model || ((Array.isArray(keeper.models) && keeper.models[0]) ? keeper.models[0] : '-');

      let modelFallbackCount = isNum(windowStats.model_fallback_count)
        ? Number(windowStats.model_fallback_count)
        : (isNum(windowStats.fallback_count) ? Number(windowStats.fallback_count) : null);
      if (modelFallbackCount === null) {
        const normPrimary = normalizeModelName(primaryModel);
        modelFallbackCount = series.reduce((acc, p) => {
          const used = normalizeModelName(p && p.model_used ? p.model_used : '');
          if (!normPrimary || !used) return acc;
          return used === normPrimary ? acc : (acc + 1);
        }, 0);
      }

      const compactionEvents = isNum(windowStats.compaction_events) ? Number(windowStats.compaction_events) : 0;
      const compactionSavedTokens = isNum(windowStats.compaction_saved_tokens) ? Number(windowStats.compaction_saved_tokens) : 0;
      const compactionBeforeTokens = isNum(windowStats.compaction_before_tokens) ? Number(windowStats.compaction_before_tokens) : 0;
      const compactionSavedRatio = isNum(windowStats.compaction_saved_ratio)
        ? Number(windowStats.compaction_saved_ratio)
        : (compactionBeforeTokens > 0 ? (compactionSavedTokens / compactionBeforeTokens) : null);
      const avgCompactionSaved = isNum(windowStats.avg_compaction_saved_tokens)
        ? Number(windowStats.avg_compaction_saved_tokens)
        : (compactionEvents > 0 ? (compactionSavedTokens / compactionEvents) : null);
      const memoryChecks = isNum(windowStats.memory_checks)
        ? Number(windowStats.memory_checks)
        : series.filter(p => p && p.memory_performed).length;
      const memoryPassed = isNum(windowStats.memory_passed)
        ? Number(windowStats.memory_passed)
        : series.filter(p => p && p.memory_performed && p.memory_passed).length;
      const memoryFailed = isNum(windowStats.memory_failed)
        ? Number(windowStats.memory_failed)
        : Math.max(0, memoryChecks - memoryPassed);
      const memoryPassRate = isNum(windowStats.memory_pass_rate)
        ? Number(windowStats.memory_pass_rate)
        : (memoryChecks > 0 ? (memoryPassed / memoryChecks) : null);
      const memoryAvgScore = isNum(windowStats.memory_avg_score)
        ? Number(windowStats.memory_avg_score)
        : (() => {
            const vals = series
              .filter(p => p && p.memory_performed && isNum(p.memory_final_score))
              .map(p => Number(p.memory_final_score));
            if (vals.length === 0) return null;
            return vals.reduce((a, b) => a + b, 0) / vals.length;
          })();
      const memoryThreshold = isNum(windowStats.memory_threshold)
        ? Number(windowStats.memory_threshold)
        : 0.18;
      const memoryCorrections = isNum(windowStats.memory_corrections)
        ? Number(windowStats.memory_corrections)
        : series.filter(p => p && p.memory_correction_applied).length;
      const memoryCorrectionSuccess = isNum(windowStats.memory_correction_success)
        ? Number(windowStats.memory_correction_success)
        : series.filter(p => p && p.memory_correction_success).length;
      const memoryWeatherChecks = isNum(windowStats.memory_weather_checks)
        ? Number(windowStats.memory_weather_checks)
        : series.filter(p => p && p.memory_performed && p.memory_expected_topic === 'weather').length;
      const memoryWeatherPassed = isNum(windowStats.memory_weather_passed)
        ? Number(windowStats.memory_weather_passed)
        : series.filter(p => p && p.memory_performed && p.memory_expected_topic === 'weather' && p.memory_passed).length;
      const memoryWeatherPassRate = isNum(windowStats.memory_weather_pass_rate)
        ? Number(windowStats.memory_weather_pass_rate)
        : (memoryWeatherChecks > 0 ? (memoryWeatherPassed / memoryWeatherChecks) : null);
      const memoryBank = keeper.memory_bank || {};
      const memoryNoteCount = isNum(keeper.memory_note_count)
        ? Number(keeper.memory_note_count)
        : (isNum(memoryBank.total_notes) ? Number(memoryBank.total_notes) : 0);
      const memoryTopKind = keeper.memory_top_kind || memoryBank.top_kind || '-';
      const memoryRecentNotes = Array.isArray(memoryBank.recent_notes)
        ? memoryBank.recent_notes
        : [];
      const memoryRecentNote =
        keeper.memory_recent_note
        || ((memoryRecentNotes[0] && memoryRecentNotes[0].text) ? memoryRecentNotes[0].text : '-');
      const memoryKindCounts = Array.isArray(memoryBank.kind_counts)
        ? memoryBank.kind_counts
        : [];
      const topWorkKinds = Array.isArray(windowStats.top_work_kinds) ? windowStats.top_work_kinds : [];
      const topModels = Array.isArray(windowStats.top_models) ? windowStats.top_models : [];
      const topTools = Array.isArray(windowStats.top_tools) ? windowStats.top_tools : [];
      const topMemoryKindsWindow = Array.isArray(windowStats.top_memory_kinds)
        ? windowStats.top_memory_kinds
        : [];
      const generationEquipment = Array.isArray(windowStats.generation_equipment)
        ? windowStats.generation_equipment : [];
      const topWorkText = topCountsText(topWorkKinds, 'kind');
      const topWorkName = topCountName(topWorkKinds, 'kind');
      const topModelText = topCountsText(topModels, 'model');
      const topModelName = topCountName(topModels, 'model');
      const topToolText = topCountsText(topTools, 'tool');
      const topToolName = topCountName(topTools, 'tool');
      const topMemoryKindsText = topCountsText(topMemoryKindsWindow, 'kind');
      const memoryBankKindsText = topCountsText(memoryKindCounts, 'kind');
      const toolCallCount = isNum(windowStats.tool_call_count) ? Number(windowStats.tool_call_count) : 0;
      const memoryNotesAddedWindow = isNum(windowStats.memory_notes_added)
        ? Number(windowStats.memory_notes_added)
        : 0;
      const memoryCompactionEvents = isNum(windowStats.memory_compaction_events)
        ? Number(windowStats.memory_compaction_events)
        : series.filter(p => p && p.memory_compaction_performed).length;
      const memoryCompactionBeforeNotes = isNum(windowStats.memory_compaction_before_notes)
        ? Number(windowStats.memory_compaction_before_notes)
        : series.reduce((acc, p) => {
            if (!p || !p.memory_compaction_performed || !isNum(p.memory_compaction_before_notes)) return acc;
            return acc + Number(p.memory_compaction_before_notes);
          }, 0);
      const memoryCompactionDroppedNotes = isNum(windowStats.memory_compaction_dropped_notes)
        ? Number(windowStats.memory_compaction_dropped_notes)
        : series.reduce((acc, p) => {
            if (!p || !p.memory_compaction_performed || !isNum(p.memory_compaction_dropped_notes)) return acc;
            return acc + Number(p.memory_compaction_dropped_notes);
          }, 0);
      const memoryCompactionInvalidDropped = isNum(windowStats.memory_compaction_invalid_dropped)
        ? Number(windowStats.memory_compaction_invalid_dropped)
        : series.reduce((acc, p) => {
            if (!p || !p.memory_compaction_performed || !isNum(p.memory_compaction_invalid_dropped)) return acc;
            return acc + Number(p.memory_compaction_invalid_dropped);
          }, 0);
      const memoryCompactionDropRatio = isNum(windowStats.memory_compaction_drop_ratio)
        ? Number(windowStats.memory_compaction_drop_ratio)
        : (memoryCompactionBeforeNotes > 0 ? (memoryCompactionDroppedNotes / memoryCompactionBeforeNotes) : null);
      const memoryCompactionDropAvg = isNum(windowStats.memory_compaction_drop_avg)
        ? Number(windowStats.memory_compaction_drop_avg)
        : (memoryCompactionEvents > 0 ? (memoryCompactionDroppedNotes / memoryCompactionEvents) : null);
      const turnPoints = isNum(windowStats.turn_points)
        ? Number(windowStats.turn_points)
        : series.filter(p => p && p.channel === 'turn').length;
      const heartbeatPoints = isNum(windowStats.heartbeat_points)
        ? Number(windowStats.heartbeat_points)
        : series.filter(p => p && p.channel === 'heartbeat').length;
      const proactivePoints = isNum(windowStats.proactive_points)
        ? Number(windowStats.proactive_points)
        : series.filter(p => p && p.channel === 'proactive').length;
      const driftAppliedCount = isNum(windowStats.drift_applied_count)
        ? Number(windowStats.drift_applied_count)
        : series.filter(p => p && p.drift_applied).length;
      const interactionPoints = turnPoints + proactivePoints;
      const modelFallbackRate = isNum(windowStats.model_fallback_rate)
        ? Number(windowStats.model_fallback_rate)
        : (isNum(windowStats.fallback_rate)
            ? Number(windowStats.fallback_rate)
            : (interactionPoints > 0 ? (modelFallbackCount / interactionPoints) : null));
      const driftAppliedRate = isNum(windowStats.drift_applied_rate)
        ? Number(windowStats.drift_applied_rate)
        : (interactionPoints > 0 ? (driftAppliedCount / interactionPoints) : null);
      const interventionShare = isNum(windowStats.intervention_share)
        ? Number(windowStats.intervention_share)
        : (interactionPoints > 0 ? (proactivePoints / interactionPoints) : null);
      const interventionPerTurn = isNum(windowStats.intervention_per_turn)
        ? Number(windowStats.intervention_per_turn)
        : (turnPoints > 0 ? (proactivePoints / turnPoints) : null);
      const topDriftReasons = Array.isArray(windowStats.top_drift_reasons)
        ? windowStats.top_drift_reasons
        : [];
      const topDriftReason = topCountName(topDriftReasons, 'reason');
      const driftReasonText = topCountsText(topDriftReasons, 'reason');
      const topCompactionTriggers = Array.isArray(windowStats.top_compaction_triggers)
        ? windowStats.top_compaction_triggers
        : [];
      const topCompactionTrigger = topCountName(topCompactionTriggers, 'reason');
      const compactionTriggerText = topCountsText(topCompactionTriggers, 'reason');
      const proactiveTemplateFallbackCount = isNum(windowStats.proactive_template_fallback_count)
        ? Number(windowStats.proactive_template_fallback_count)
        : (isNum(windowStats.proactive_fallback_count)
            ? Number(windowStats.proactive_fallback_count)
            : series.filter(p => p && p.channel === 'proactive' && p.proactive_fallback_applied).length);
      const proactiveTemplateFallbackRate = isNum(windowStats.proactive_template_fallback_rate)
        ? Number(windowStats.proactive_template_fallback_rate)
        : (isNum(windowStats.proactive_fallback_rate)
            ? Number(windowStats.proactive_fallback_rate)
            : (proactivePoints > 0 ? (proactiveTemplateFallbackCount / proactivePoints) : null));
      const proactivePreviewSampleCount = isNum(windowStats.proactive_preview_sample_count)
        ? Number(windowStats.proactive_preview_sample_count)
        : 0;
      const proactivePreviewPairCount = isNum(windowStats.proactive_preview_pair_count)
        ? Number(windowStats.proactive_preview_pair_count)
        : 0;
      const proactivePreviewSimilarityAvg = isNum(windowStats.proactive_preview_similarity_avg)
        ? Number(windowStats.proactive_preview_similarity_avg)
        : null;
      const proactivePreviewSimilarityMax = isNum(windowStats.proactive_preview_similarity_max)
        ? Number(windowStats.proactive_preview_similarity_max)
        : null;
      const proactivePreviewSimilarityWarn =
        !!windowStats.proactive_preview_similarity_warn
        || (isNum(proactivePreviewSimilarityMax) && proactivePreviewSimilarityMax >= alertThresholds.proactive_similarity_warn);
      const compactionRatioGate = isNum(keeper.compaction_ratio_gate)
        ? Number(keeper.compaction_ratio_gate)
        : 0.5;
      const compactionMessageGate = isNum(keeper.compaction_message_gate)
        ? Number(keeper.compaction_message_gate)
        : 240;
      const compactionTokenGate = isNum(keeper.compaction_token_gate)
        ? Number(keeper.compaction_token_gate)
        : 0;
      const proactiveSimilarityText =
        proactivePreviewPairCount > 0
          ? `avg ${fmtPct1(proactivePreviewSimilarityAvg)} / max ${fmtPct1(proactivePreviewSimilarityMax)}`
          : '-';
      const proactiveSimilarityState =
        (isNum(proactivePreviewSimilarityMax) && proactivePreviewSimilarityMax >= alertThresholds.proactive_similarity_bad)
          ? 'bad'
          : (proactivePreviewSimilarityWarn ? 'warn' : 'ok');
      const proactiveFallbackState =
        (isNum(proactiveTemplateFallbackRate) && proactiveTemplateFallbackRate >= alertThresholds.proactive_fallback_bad)
          ? 'bad'
          : ((isNum(proactiveTemplateFallbackRate) && proactiveTemplateFallbackRate >= alertThresholds.proactive_fallback_warn) ? 'warn' : 'ok');
      const proactiveFallbackKpiClass =
        proactiveFallbackState === 'ok' ? 'keeper-kpi-value' : `keeper-kpi-value ${proactiveFallbackState}`;
      const proactiveSimilarityKpiClass =
        proactiveSimilarityState === 'ok' ? 'keeper-kpi-value' : `keeper-kpi-value ${proactiveSimilarityState}`;
      const proactiveFallbackBadge =
        proactiveFallbackState === 'ok'
          ? '<span class="keeper-role-chip">ok</span>'
          : `<span class="keeper-role-chip ${proactiveFallbackState}">${proactiveFallbackState}</span>`;
      const proactiveSimilarityBadge =
        proactiveSimilarityState === 'ok'
          ? '<span class="keeper-role-chip">ok</span>'
          : `<span class="keeper-role-chip ${proactiveSimilarityState}">${proactiveSimilarityState}</span>`;
      const conversationTail = Array.isArray(keeper.conversation_tail)
        ? keeper.conversation_tail
        : [];
      const conversationTailCount = isNum(keeper.conversation_tail_count)
        ? Number(keeper.conversation_tail_count)
        : conversationTail.length;
      const conversationRawCount = isNum(keeper.conversation_raw_count)
        ? Number(keeper.conversation_raw_count)
        : conversationTailCount;
      const conversationFragmentCount = isNum(keeper.conversation_fragment_count)
        ? Number(keeper.conversation_fragment_count)
        : conversationTail.filter((row) => !!(row && row.is_fragment)).length;
      const conversationFragmentFilteredCount = isNum(keeper.conversation_fragment_filtered_count)
        ? Number(keeper.conversation_fragment_filtered_count)
        : 0;
      const conversationFragmentFilterEnabled = !!keeper.conversation_fragment_filter_enabled;
      const fragmentBadgeText =
        conversationFragmentCount > 0
          ? `frag ${fmtInt(conversationFragmentCount)}`
          : '-';
      const k2kRecent = Array.isArray(keeper.k2k_recent)
        ? keeper.k2k_recent
        : [];
      const k2kCount = isNum(keeper.k2k_count)
        ? Number(keeper.k2k_count)
        : k2kRecent.length;
      const k2kMentions = Array.isArray(keeper.k2k_mentions)
        ? keeper.k2k_mentions
        : [];
      const k2kMentionsText = topCountsText(k2kMentions, 'keeper');
      const bornAtText = fmtIso(keeper.created_at);
      const updatedAtText = fmtIso(keeper.updated_at);
      const proactiveLastAgoText = isNum(keeper.last_proactive_ago_s)
        ? (fmtSecShort(keeper.last_proactive_ago_s) + ' ago')
        : '-';
      const proactiveReasonText =
        (typeof keeper.last_proactive_reason === 'string' && keeper.last_proactive_reason.trim() !== '')
          ? keeper.last_proactive_reason.trim()
          : '-';
      const proactivePreviewText =
        (typeof keeper.last_proactive_preview === 'string' && keeper.last_proactive_preview.trim() !== '')
          ? keeper.last_proactive_preview.trim()
          : '-';
      const metrics24hBuckets = isNum(metrics24hSummary.buckets)
        ? Number(metrics24hSummary.buckets)
        : metrics24h.length;
      const metrics24hPoints = isNum(metrics24hSummary.points)
        ? Number(metrics24hSummary.points)
        : metrics24h.reduce((acc, row) => {
            if (!row || !isNum(row.sample_points)) return acc;
            return acc + Number(row.sample_points);
          }, 0);
      const metrics24hCoverage = isNum(metrics24hSummary.coverage_ratio)
        ? Number(metrics24hSummary.coverage_ratio)
        : null;
      const metrics24hProactivePoints = isNum(metrics24hSummary.proactive_points)
        ? Number(metrics24hSummary.proactive_points)
        : metrics24h.reduce((acc, row) => {
            if (!row || !isNum(row.proactive_points)) return acc;
            return acc + Number(row.proactive_points);
          }, 0);
      const metrics24hFallbackCount = isNum(metrics24hSummary.proactive_template_fallback_count)
        ? Number(metrics24hSummary.proactive_template_fallback_count)
        : (isNum(metrics24hSummary.proactive_fallback_count)
            ? Number(metrics24hSummary.proactive_fallback_count)
            : metrics24h.reduce((acc, row) => {
                const v = isNum(row && row.proactive_template_fallback_count)
                  ? Number(row.proactive_template_fallback_count)
                  : (isNum(row && row.proactive_fallback_count) ? Number(row.proactive_fallback_count) : 0);
                return acc + v;
              }, 0));
      const metrics24hFallbackRate = isNum(metrics24hSummary.proactive_template_fallback_rate)
        ? Number(metrics24hSummary.proactive_template_fallback_rate)
        : (isNum(metrics24hSummary.proactive_fallback_rate)
            ? Number(metrics24hSummary.proactive_fallback_rate)
            : (metrics24hProactivePoints > 0 ? (metrics24hFallbackCount / metrics24hProactivePoints) : null));
      const metrics24hStartTs =
        metrics24h.length > 0 && isNum(metrics24h[0].bucket_ts_unix)
          ? Number(metrics24h[0].bucket_ts_unix)
          : null;
      const metrics24hEndTs =
        metrics24h.length > 0 && isNum(metrics24h[metrics24h.length - 1].bucket_ts_unix)
          ? Number(metrics24h[metrics24h.length - 1].bucket_ts_unix)
          : null;
      const metrics24hFallbackState =
        (isNum(metrics24hFallbackRate) && metrics24hFallbackRate >= alertThresholds.proactive_fallback_bad)
          ? 'bad'
          : ((isNum(metrics24hFallbackRate) && metrics24hFallbackRate >= alertThresholds.proactive_fallback_warn) ? 'warn' : 'ok');
      const metrics24hFallbackClass =
        metrics24hFallbackState === 'bad'
          ? 'bad-metric'
          : (metrics24hFallbackState === 'warn' ? 'warn-metric' : '');

      const contextRatioChart = keeperLineSvg(series, 'context_ratio', { threshold: th, color: ratioColor });
      const contextTokenChart = keeperLineSvg(series, 'context_tokens', { color: '#4ade80' });
      const ioChart = keeperDualLineSvg(series, 'input_tokens', 'output_tokens', { colorA: '#22d3ee', colorB: '#a78bfa' });
      const memoryChart = keeperLineSvg(series, 'memory_final_score', { threshold: memoryThreshold, color: '#f59e0b' });
      const driftChart = keeperLineSvg(series, 'drift_applied', { color: '#fb7185' });
      const interventionChart = keeperDualLineSvg(series, 'proactive_fallback_applied', 'drift_applied', { colorA: '#22c55e', colorB: '#fb7185' });
      const compactionEventChart = keeperLineSvg(series, 'compacted', { color: '#f97316' });
      const compactionSavedChart = keeperLineSvg(series, 'compaction_saved_tokens', { color: '#f59e0b' });
      const metrics24hRatioChart = keeperLineSvg(metrics24h, 'context_ratio_avg', { threshold: th, color: '#14b8a6' });
      const metrics24hFallbackChart = keeperLineSvg(metrics24h, 'proactive_template_fallback_rate', {
        threshold: alertThresholds.proactive_fallback_warn,
        color: '#f97316',
      });
      const eventsHtml = keeperEventsHtml(series);
      const memoryNotesHtml = keeperMemoryNotesHtml(memoryRecentNotes);
      const conversationHtml = keeperConversationHtml(conversationTail);
      const k2kHtml = keeperK2kHtml(k2kRecent);
      const handoffEventsAll = fullSeries.filter((p) => p && p.handoff);
      const handoffFromGenerations = Array.from(new Set(
        handoffEventsAll
          .map((p) => (isNum(p.generation) ? String(Number(p.generation)) : ''))
          .filter((v) => v !== '')
      )).sort((a, b) => Number(a) - Number(b));
      const handoffModels = Array.from(new Set(
        handoffEventsAll
          .map((p) => (p.handoff_to_model || p.model_used || '').trim())
          .filter((v) => v !== '')
      )).sort((a, b) => a.localeCompare(b));
      let handoffFilterAdjusted = false;
      if (keeperHandoffGenFilter !== 'all' && !handoffFromGenerations.includes(keeperHandoffGenFilter)) {
        keeperHandoffGenFilter = 'all';
        handoffFilterAdjusted = true;
      }
      if (keeperHandoffModelFilter !== 'all' && !handoffModels.includes(keeperHandoffModelFilter)) {
        keeperHandoffModelFilter = 'all';
        handoffFilterAdjusted = true;
      }
      if (handoffFilterAdjusted) setKeeperQueryState();
      const handoffTimelineHtml = keeperHandoffTimelineHtml(fullSeries, {
        limit: 12,
        genFilter: keeperHandoffGenFilter,
        modelFilter: keeperHandoffModelFilter,
      });
      const handoffTimelineCount = handoffEventsAll.length;
      const handoffTimelineFilteredCount = handoffEventsAll.filter((p) => {
        const genOk =
          keeperHandoffGenFilter === 'all'
            || (isNum(p.generation) && String(Number(p.generation)) === keeperHandoffGenFilter);
        const modelValue = (p.handoff_to_model || p.model_used || '').trim();
        const modelOk =
          keeperHandoffModelFilter === 'all'
            || modelValue === keeperHandoffModelFilter;
        return genOk && modelOk;
      }).length;
      const handoffGenOptionsHtml = ['<option value="all">All generations</option>']
        .concat(handoffFromGenerations.map((fromGen) => {
          const row =
            handoffEventsAll.find((p) => isNum(p.generation) && String(Number(p.generation)) === fromGen)
            || null;
          const toGen =
            row && isNum(row.handoff_new_generation)
              ? Number(row.handoff_new_generation)
              : (Number(fromGen) + 1);
          const label = `g${fromGen} -> g${toGen}`;
          const selected = keeperHandoffGenFilter === fromGen ? ' selected' : '';
          return `<option value="${escHtml(fromGen)}"${selected}>${escHtml(label)}</option>`;
        }))
        .join('');
      const handoffModelOptionsHtml = ['<option value="all">All models</option>']
        .concat(handoffModels.map((model) => {
          const selected = keeperHandoffModelFilter === model ? ' selected' : '';
          return `<option value="${escHtml(model)}"${selected}>${escHtml(model)}</option>`;
        }))
        .join('');
      const handoffLatestTs = (() => {
        const xs = fullSeries.filter((p) => p && p.handoff && isNum(p.ts_unix));
        if (xs.length === 0) return null;
        return Number(xs[xs.length - 1].ts_unix);
      })();
      const risk = handoffRiskMetrics(series, th);
      const eta = risk.eta;
      let etaText = 'ETA n/a';
      let etaClass = 'keeper-eta-pill';
      if (eta === 0) {
        etaText = 'ETA now';
        etaClass += ' now';
      } else if (isNum(eta)) {
        etaText = `ETA ~${eta} turns`;
        if (eta <= 3) etaClass += ' warn';
      }
      const riskText = (risk.score === null) ? 'Risk -/100' : `Risk ${risk.score}/100`;
      const riskLevelText = (risk.level || 'unknown').toUpperCase();
      const confidenceText = (risk.confidence === null) ? '-' : (risk.confidence + '%');
      if (risk.score !== null && risk.score >= 80) etaClass += ' now';
      else if (risk.score !== null && risk.score >= 65) etaClass += ' warn';
      if (etaPill) {
        etaPill.className = etaClass;
        etaPill.textContent = `${etaText} · ${riskText}`;
      }

      title.textContent = keeper.name || selectedKeeperName;
      sub.textContent = `${keeper.agent_name || ''} · gen ${isNum(keeper.generation) ? keeper.generation : 0} · age ${age} · window ${keeperZoomTurns}`;

      let compareHtml = `
        <div class="keeper-chart-card keeper-compare-block">
          <div class="keeper-chart-title">Compare (Context Ratio)</div>
          <div class="empty">Select another keeper from the compare dropdown.</div>
        </div>
      `;
      if (compareKeeperName) {
        const compareKeeper = keepers.find(k => k && k.name === compareKeeperName);
        if (compareKeeper) {
          const compareSeries = windowSeries(Array.isArray(compareKeeper.metrics_series) ? compareKeeper.metrics_series : []);
          const compareChart = keeperCompareRatioSvg(series, compareSeries, {
            threshold: th,
            primaryColor: ratioColor,
            compareColor: '#f97316',
          });
          const compareRisk = handoffRiskMetrics(compareSeries, th);
          const lastPrimary = (series.length > 0 && isNum(series[series.length - 1].context_ratio))
            ? series[series.length - 1].context_ratio : null;
          const lastCompare = (compareSeries.length > 0 && isNum(compareSeries[compareSeries.length - 1].context_ratio))
            ? compareSeries[compareSeries.length - 1].context_ratio : null;
          const deltaPct = (lastPrimary !== null && lastCompare !== null)
            ? Math.round((lastPrimary - lastCompare) * 100) : null;
          const deltaText = (deltaPct === null)
            ? '-'
            : (deltaPct === 0 ? '0pp' : (deltaPct > 0 ? `+${deltaPct}pp` : `${deltaPct}pp`));
          compareHtml = `
            <div class="keeper-chart-card keeper-compare-block">
              <div class="keeper-chart-title">Compare (Context Ratio): ${escHtml(keeper.name || selectedKeeperName)} vs ${escHtml(compareKeeperName)}</div>
              <div class="keeper-chart">${compareChart}</div>
              <div class="keeper-chart-meta">
                <span><b>${escHtml(keeper.name || selectedKeeperName)}</b> ${lastPrimary === null ? '-' : (Math.round(lastPrimary * 100) + '%')}</span>
                <span><b>${escHtml(compareKeeperName)}</b> ${lastCompare === null ? '-' : (Math.round(lastCompare * 100) + '%')}</span>
                <span><b>delta</b> ${deltaText}</span>
                <span><b>risk</b> ${risk.score === null ? '-' : risk.score} vs ${compareRisk.score === null ? '-' : compareRisk.score}</span>
                <span><b>window</b> ${keeperZoomTurns} turns</span>
              </div>
            </div>
          `;
        }
      }

      content.innerHTML = `
        <div class="keeper-kpis">
          <div class="keeper-kpi"><div class="keeper-kpi-label">SOUL Profile</div><div class="keeper-kpi-value">${escHtml(soulProfile)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Will (의지)</div><div class="keeper-kpi-value">${escHtml(willKpi)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Needs (니즈)</div><div class="keeper-kpi-value">${escHtml(needsKpi)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Desires (욕구)</div><div class="keeper-kpi-value">${escHtml(desiresKpi)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Active Model</div><div class="keeper-kpi-value">${escHtml(modelUsed)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Next Model</div><div class="keeper-kpi-value">${escHtml(nextModel)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Primary Model</div><div class="keeper-kpi-value">${escHtml(primaryModel || '-')}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Skill Route</div><div class="keeper-kpi-value">${escHtml(skillRouteText)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Context</div><div class="keeper-kpi-value">${escHtml(ratioPct)} (${fmtInt(ctx.context_tokens)}/${fmtInt(ctx.context_max)})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Handoff Threshold</div><div class="keeper-kpi-value">${Math.round(th * 100)}%</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Handoff Risk</div><div class="keeper-kpi-value">${riskText} (${riskLevelText})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Risk Confidence</div><div class="keeper-kpi-value">${escHtml(confidenceText)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Total Turns</div><div class="keeper-kpi-value">${fmtInt(keeper.total_turns)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Input / Output</div><div class="keeper-kpi-value">${fmtInt(keeper.total_input_tokens)} / ${fmtInt(keeper.total_output_tokens)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Total Tokens</div><div class="keeper-kpi-value">${fmtInt(keeper.total_tokens)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Total Cost</div><div class="keeper-kpi-value">${fmtUsd(keeper.total_cost_usd)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Born At</div><div class="keeper-kpi-value">${escHtml(bornAtText)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Updated At</div><div class="keeper-kpi-value">${escHtml(updatedAtText)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Handoffs (Total)</div><div class="keeper-kpi-value">${fmtInt(keeper.handoff_count_total)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Compactions (Total)</div><div class="keeper-kpi-value">${fmtInt(keeper.compaction_count)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Compaction Profile</div><div class="keeper-kpi-value">${escHtml(keeper.compaction_profile || 'custom')}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Proactive (Total)</div><div class="keeper-kpi-value">${fmtInt(keeper.proactive_count_total)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Drift (Total)</div><div class="keeper-kpi-value">${fmtInt(keeper.drift_count_total)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Last Proactive</div><div class="keeper-kpi-value">${escHtml(proactiveLastAgoText)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Last Drift</div><div class="keeper-kpi-value">${fmtInt(keeper.last_drift_turn)} / ${escHtml(shortText(keeper.last_drift_reason || '-', 36))}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Proactive Template Fallback</div><div class="${proactiveFallbackKpiClass}" title="formula: proactive_template_fallback_count / proactive_points">${fmtInt(proactiveTemplateFallbackCount)} / ${fmtInt(proactivePoints)} (${proactiveTemplateFallbackRate === null ? '-' : fmtPct1(proactiveTemplateFallbackRate)}) ${proactiveFallbackBadge}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Proactive Similarity</div><div class="${proactiveSimilarityKpiClass}" title="formula: Jaccard(adjacent proactive previews), window<=8">${escHtml(proactiveSimilarityText)} (${proactiveSimilarityState}; pairs ${fmtInt(proactivePreviewPairCount)}) ${proactiveSimilarityBadge}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Drift Window</div><div class="keeper-kpi-value">${fmtInt(driftAppliedCount)} / ${fmtInt(interactionPoints)} (${driftAppliedRate === null ? '-' : fmtPct1(driftAppliedRate)})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Intervention Share</div><div class="keeper-kpi-value">${interventionShare === null ? '-' : fmtPct1(interventionShare)} (per-turn ${interventionPerTurn === null ? '-' : interventionPerTurn.toFixed(2)})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Top Drift Reason</div><div class="keeper-kpi-value">${escHtml(topDriftReason)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Top Compact Trigger</div><div class="keeper-kpi-value">${escHtml(topCompactionTrigger)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Window H/C</div><div class="keeper-kpi-value">${fmtInt(windowStats.handoff_count)}/${fmtInt(windowStats.compaction_events)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Window Saved</div><div class="keeper-kpi-value">${fmtInt(windowStats.compaction_saved_tokens)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Compaction Efficiency</div><div class="keeper-kpi-value">${compactionSavedRatio === null ? '-' : fmtPct1(compactionSavedRatio)} (${avgCompactionSaved === null ? '-' : fmtInt(avgCompactionSaved) + '/event'})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Model Fallback Rate</div><div class="keeper-kpi-value" title="formula: model_fallback_count / (turn_points + proactive_points)">${modelFallbackRate === null ? '-' : fmtPct1(modelFallbackRate)} (${fmtInt(modelFallbackCount)}/${fmtInt(interactionPoints)})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Memory Pass</div><div class="keeper-kpi-value">${memoryPassRate === null ? '-' : fmtPct1(memoryPassRate)} (${fmtInt(memoryPassed)}/${fmtInt(memoryChecks)})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Memory Score</div><div class="keeper-kpi-value">${memoryAvgScore === null ? '-' : (Math.round(memoryAvgScore * 1000) / 1000).toFixed(3)} / ${memoryThreshold.toFixed(2)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Weather Recall</div><div class="keeper-kpi-value">${memoryWeatherPassRate === null ? '-' : fmtPct1(memoryWeatherPassRate)} (${fmtInt(memoryWeatherPassed)}/${fmtInt(memoryWeatherChecks)})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Corrections</div><div class="keeper-kpi-value">${fmtInt(memoryCorrections)} / ${fmtInt(memoryCorrectionSuccess)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Memory Notes</div><div class="keeper-kpi-value">${fmtInt(memoryNoteCount)} (+${fmtInt(memoryNotesAddedWindow)} window)</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Memory Compact</div><div class="keeper-kpi-value">${fmtInt(memoryCompactionEvents)} events / ${fmtInt(memoryCompactionDroppedNotes)} dropped</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Memory Trim Rate</div><div class="keeper-kpi-value">${memoryCompactionDropRatio === null ? '-' : fmtPct1(memoryCompactionDropRatio)} (${memoryCompactionDropAvg === null ? '-' : fmtInt(memoryCompactionDropAvg) + '/event'})</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Memory Focus</div><div class="keeper-kpi-value">${escHtml(memoryTopKind)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Most Work</div><div class="keeper-kpi-value">${escHtml(topWorkName)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Most Model</div><div class="keeper-kpi-value">${escHtml(topModelName)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Most Tool</div><div class="keeper-kpi-value">${escHtml(topToolName)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Tool Calls</div><div class="keeper-kpi-value">${fmtInt(toolCallCount)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Window Points</div><div class="keeper-kpi-value">${fmtInt(turnPoints)}t / ${fmtInt(proactivePoints)}p / ${fmtInt(heartbeatPoints)}h</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Conversation Rows</div><div class="keeper-kpi-value">${fmtInt(conversationTailCount)} / raw ${fmtInt(conversationRawCount)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Conversation Fragments</div><div class="keeper-kpi-value">${escHtml(fragmentBadgeText)}${conversationFragmentFilterEnabled ? ` (filtered ${fmtInt(conversationFragmentFilteredCount)})` : ''}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">K2K Edges</div><div class="keeper-kpi-value">${fmtInt(k2kCount)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">K2K Mentions</div><div class="keeper-kpi-value">${escHtml(k2kMentionsText)}</div></div>
          <div class="keeper-kpi"><div class="keeper-kpi-label">Handoff ETA</div><div class="keeper-kpi-value">${escHtml(etaText)}</div></div>
        </div>
        ${compareHtml}
        <div class="keeper-chart-card keeper-handoff-timeline">
          <div class="keeper-chart-title">Handoff Timeline</div>
          <div class="keeper-chart-meta">
            <span><b>events</b> ${fmtInt(handoffTimelineCount)}</span>
            <span><b>filtered</b> ${fmtInt(handoffTimelineFilteredCount)}</span>
            <span><b>latest</b> ${handoffLatestTs === null ? '-' : fmtTs(handoffLatestTs)}</span>
            <span><b>last model</b> ${escHtml((keeper.last_handoff_event || {}).to_model || '-')}</span>
            <span><b>threshold</b> ${Math.round(th * 100)}%</span>
            <span><b>window</b> ${keeperZoomTurns} turns</span>
          </div>
          <div class="keeper-handoff-controls">
            <span class="keeper-toolbar-label">From Gen</span>
            <select class="keeper-select" onchange="setKeeperHandoffGenFilter(this.value)">${handoffGenOptionsHtml}</select>
            <span class="keeper-toolbar-label">Model</span>
            <select class="keeper-select" onchange="setKeeperHandoffModelFilter(this.value)">${handoffModelOptionsHtml}</select>
            <button class="keeper-toolbar-btn" onclick="clearKeeperHandoffFilters()">Clear</button>
          </div>
          ${handoffTimelineHtml}
        </div>
        <div class="keeper-detail-grid">
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Context Ratio (with handoff threshold)</div>
            <div class="keeper-chart">${contextRatioChart}</div>
            <div class="keeper-chart-meta">
              <span><b>threshold</b> ${Math.round(th * 100)}%</span>
              <span><b>latest</b> ${escHtml(ratioPct)}</span>
              <span><b>points</b> ${fmtInt(turnPoints)}t / ${fmtInt(proactivePoints)}p / ${fmtInt(heartbeatPoints)}h</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Context Tokens</div>
            <div class="keeper-chart">${contextTokenChart}</div>
            <div class="keeper-chart-meta">
              <span><b>current</b> ${fmtInt(ctx.context_tokens)}</span>
              <span><b>max</b> ${fmtInt(ctx.context_max)}</span>
              <span><b>source</b> ${escHtml(keeper.context_source || ctx.source || '-')}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Turn I/O Tokens (input vs output)</div>
            <div class="keeper-chart">${ioChart}</div>
            <div class="keeper-chart-meta">
              <span><b>input total</b> ${fmtInt(keeper.total_input_tokens)}</span>
              <span><b>output total</b> ${fmtInt(keeper.total_output_tokens)}</span>
              <span><b>last turn</b> ${fmtInt((keeper.last_usage || {}).input_tokens)} / ${fmtInt((keeper.last_usage || {}).output_tokens)}</span>
              <span title="formula: model_fallback_count / (turn_points + proactive_points)"><b>model fallback</b> ${modelFallbackRate === null ? '-' : fmtPct1(modelFallbackRate)}</span>
              <span><b>memory pass</b> ${memoryPassRate === null ? '-' : fmtPct1(memoryPassRate)}</span>
              <span><b>weather</b> ${memoryWeatherPassRate === null ? '-' : fmtPct1(memoryWeatherPassRate)}</span>
              <span><b>work</b> ${escHtml(topWorkName)}</span>
              <span><b>tool calls</b> ${fmtInt(toolCallCount)}</span>
              <span><b>primary</b> ${escHtml(primaryModel || '-')}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Memory Recall Score</div>
            <div class="keeper-chart">${memoryChart}</div>
            <div class="keeper-chart-meta">
              <span><b>threshold</b> ${(Math.round(memoryThreshold * 1000) / 1000).toFixed(3)}</span>
              <span><b>avg</b> ${memoryAvgScore === null ? '-' : (Math.round(memoryAvgScore * 1000) / 1000).toFixed(3)}</span>
              <span><b>pass</b> ${memoryPassRate === null ? '-' : fmtPct1(memoryPassRate)}</span>
              <span><b>fail</b> ${fmtInt(memoryFailed)}</span>
              <span><b>correct</b> ${fmtInt(memoryCorrections)} / ${fmtInt(memoryCorrectionSuccess)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Drift Applied (0/1)</div>
            <div class="keeper-chart">${driftChart}</div>
            <div class="keeper-chart-meta">
              <span><b>window drift</b> ${fmtInt(driftAppliedCount)} / ${fmtInt(interactionPoints)}</span>
              <span><b>rate</b> ${driftAppliedRate === null ? '-' : fmtPct1(driftAppliedRate)}</span>
              <span><b>enabled</b> ${keeper.drift_enabled ? 'on' : 'off'}</span>
              <span><b>gap</b> ${fmtInt(keeper.drift_min_turn_gap)} turns</span>
              <span><b>top reason</b> ${escHtml(topDriftReason)}</span>
              <span><b>reasons</b> ${escHtml(shortText(driftReasonText, 72))}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Intervention vs Drift (0/1)</div>
            <div class="keeper-chart">${interventionChart}</div>
            <div class="keeper-chart-meta">
              <span><b>proactive points</b> ${fmtInt(proactivePoints)}</span>
              <span><b>intervention share</b> ${interventionShare === null ? '-' : fmtPct1(interventionShare)}</span>
              <span><b>per-turn</b> ${interventionPerTurn === null ? '-' : interventionPerTurn.toFixed(2)}</span>
              <span><b>drift points</b> ${fmtInt(driftAppliedCount)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Compaction Timeline (Events + Saved Tokens)</div>
            <div class="keeper-chart">${compactionEventChart}</div>
            <div class="keeper-chart-meta">
              <span><b>events</b> ${fmtInt(windowStats.compaction_events)}</span>
              <span><b>saved</b> ${fmtInt(windowStats.compaction_saved_tokens)}</span>
              <span><b>avg/event</b> ${avgCompactionSaved === null ? '-' : fmtInt(avgCompactionSaved)}</span>
              <span><b>top trigger</b> ${escHtml(topCompactionTrigger)}</span>
              <span><b>spread</b> ${escHtml(shortText(compactionTriggerText, 72))}</span>
            </div>
            <div class="keeper-chart" style="margin-top:8px">${compactionSavedChart}</div>
            <div class="keeper-chart-meta">
              <span><b>profile</b> ${escHtml(keeper.compaction_profile || 'custom')}</span>
              <span><b>gate</b> ratio ${fmtPct1(compactionRatioGate)} / msg ${fmtInt(compactionMessageGate)} / tok ${compactionTokenGate > 0 ? fmtInt(compactionTokenGate) : 'off'}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">24h Trend (Hourly)</div>
            <div class="keeper-chart">${metrics24hRatioChart}</div>
            <div class="keeper-chart-meta">
              <span><b>buckets</b> ${fmtInt(metrics24hBuckets)}</span>
              <span><b>points</b> ${fmtInt(metrics24hPoints)}</span>
              <span><b>coverage</b> ${metrics24hCoverage === null ? '-' : fmtPct1(metrics24hCoverage)}</span>
              <span><b>range</b> ${metrics24hStartTs === null ? '-' : fmtTs(metrics24hStartTs)} ~ ${metrics24hEndTs === null ? '-' : fmtTs(metrics24hEndTs)}</span>
              <span><b>threshold</b> ${Math.round(th * 100)}%</span>
            </div>
            <div class="keeper-chart" style="margin-top:8px">${metrics24hFallbackChart}</div>
            <div class="keeper-chart-meta">
              <span title="formula: proactive_template_fallback_count / proactive_points (24h buckets)"><b>proactive template fallback</b> <span class="${metrics24hFallbackClass}">${fmtInt(metrics24hFallbackCount)} / ${fmtInt(metrics24hProactivePoints)} (${metrics24hFallbackRate === null ? '-' : fmtPct1(metrics24hFallbackRate)})</span></span>
              <span><b>state</b> ${metrics24hFallbackState}</span>
              <span><b>warn/bad</b> ${fmtPct1(alertThresholds.proactive_fallback_warn)} / ${fmtPct1(alertThresholds.proactive_fallback_bad)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Lifecycle</div>
            <div class="keeper-chart-meta">
              <span><b>trace</b> ${escHtml(keeper.trace_id || '-')}</span>
              <span><b>keepalive</b> ${(keeper.keepalive_running ? 'on' : 'off')}</span>
              <span><b>born</b> ${escHtml(bornAtText)}</span>
              <span><b>updated</b> ${escHtml(updatedAtText)}</span>
              <span><b>age</b> ${escHtml(age)}</span>
              <span><b>last turn</b> ${escHtml(isNum(keeper.last_turn_ago_s) ? (fmtSecShort(keeper.last_turn_ago_s) + ' ago') : 'never')}</span>
              <span><b>last handoff</b> ${escHtml(isNum(keeper.last_handoff_ago_s) ? (fmtSecShort(keeper.last_handoff_ago_s) + ' ago') : '-')}</span>
              <span><b>last compaction</b> ${escHtml(isNum(keeper.last_compaction_ago_s) ? (fmtSecShort(keeper.last_compaction_ago_s) + ' ago') : '-')}</span>
              <span><b>proactive</b> ${(keeper.proactive_enabled ? 'on' : 'off')} (idle ${fmtInt(keeper.proactive_idle_sec)}s / cd ${fmtInt(keeper.proactive_cooldown_sec)}s)</span>
              <span><b>last proactive</b> ${escHtml(proactiveLastAgoText)}</span>
              <span><b>proactive reason</b> ${escHtml(proactiveReasonText)}</span>
              <span><b>proactive preview</b> ${escHtml(proactivePreviewText)}</span>
              <span><b>drift</b> ${(keeper.drift_enabled ? 'on' : 'off')} (gap ${fmtInt(keeper.drift_min_turn_gap)} turns)</span>
              <span><b>drift total</b> ${fmtInt(keeper.drift_count_total)}</span>
              <span><b>last drift reason</b> ${escHtml(shortText(keeper.last_drift_reason || '-', 60))}</span>
              <span><b>skill route</b> ${escHtml(skillRouteText)}</span>
              <span><b>skill reason</b> ${escHtml(skillReason)}</span>
              <span title="formula: proactive_template_fallback_count / proactive_points"><b>proactive template fallback</b> <span class="${proactiveFallbackState === 'bad' ? 'bad-metric' : (proactiveFallbackState === 'warn' ? 'warn-metric' : '')}">${fmtInt(proactiveTemplateFallbackCount)} / ${fmtInt(proactivePoints)} (${proactiveTemplateFallbackRate === null ? '-' : fmtPct1(proactiveTemplateFallbackRate)})</span></span>
              <span title="formula: Jaccard(adjacent proactive previews), window<=8"><b>proactive similarity</b> <span class="${proactiveSimilarityState === 'bad' ? 'bad-metric' : (proactiveSimilarityState === 'warn' ? 'warn-metric' : '')}">${escHtml(proactiveSimilarityText)} (${proactiveSimilarityState}; samples ${fmtInt(proactivePreviewSampleCount)})</span></span>
              <span><b>last handoff model</b> ${escHtml((keeper.last_handoff_event || {}).to_model || '-')}</span>
              <span><b>last compaction saved</b> ${fmtInt(keeper.last_compaction_saved_tokens)}</span>
              <span><b>compaction efficiency</b> ${compactionSavedRatio === null ? '-' : fmtPct1(compactionSavedRatio)}</span>
              <span><b>compaction gate</b> ratio ${fmtPct1(compactionRatioGate)} / msg ${fmtInt(compactionMessageGate)} / tok ${compactionTokenGate > 0 ? fmtInt(compactionTokenGate) : 'off'}</span>
              <span><b>top compaction trigger</b> ${escHtml(topCompactionTrigger)}</span>
              <span><b>trigger spread</b> ${escHtml(shortText(compactionTriggerText, 72))}</span>
              <span><b>risk confidence</b> ${escHtml(confidenceText)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Metric Formula</div>
            <div class="keeper-chart-meta">
              <span><b>model fallback</b> ${modelFallbackRate === null ? '-' : fmtPct1(modelFallbackRate)} = ${fmtInt(modelFallbackCount)} / ${fmtInt(interactionPoints)} (turn+proactive)</span>
              <span><b>template fallback</b> ${proactiveTemplateFallbackRate === null ? '-' : fmtPct1(proactiveTemplateFallbackRate)} = ${fmtInt(proactiveTemplateFallbackCount)} / ${fmtInt(proactivePoints)} (proactive only)</span>
              <span><b>similarity avg/max</b> ${proactiveSimilarityText}</span>
              <span><b>similarity pairs</b> ${fmtInt(proactivePreviewPairCount)} from ${fmtInt(proactivePreviewSampleCount)} samples (window <= 8)</span>
              <span><b>similarity method</b> Jaccard(adjacent proactive preview text)</span>
              <span><b>warn/bad threshold</b> template ${fmtPct1(alertThresholds.proactive_fallback_warn)}/${fmtPct1(alertThresholds.proactive_fallback_bad)}, similarity ${fmtPct1(alertThresholds.proactive_similarity_warn)}/${fmtPct1(alertThresholds.proactive_similarity_bad)}</span>
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Work & Equipment</div>
            <div class="keeper-chart-meta">
              <span><b>top work</b> ${escHtml(topWorkText)}</span>
              <span><b>top model</b> ${escHtml(topModelText)}</span>
              <span><b>top tool</b> ${escHtml(topToolText)}</span>
              <span><b>memory window</b> ${escHtml(topMemoryKindsText)}</span>
              <span><b>memory bank</b> ${escHtml(memoryBankKindsText)}</span>
              <span><b>tool calls</b> ${fmtInt(toolCallCount)}</span>
              <span><b>points</b> ${fmtInt(turnPoints)}t / ${fmtInt(proactivePoints)}p / ${fmtInt(heartbeatPoints)}h</span>
            </div>
            <div class="keeper-equipment-wrap">
              ${generationEquipmentHtml(generationEquipment)}
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Long-term Memory Bank</div>
            <div class="keeper-chart-meta">
              <span><b>notes</b> ${fmtInt(memoryNoteCount)}</span>
              <span><b>top kind</b> ${escHtml(memoryTopKind)}</span>
              <span><b>window kinds</b> ${escHtml(topMemoryKindsText)}</span>
              <span><b>auto compact</b> ${fmtInt(memoryCompactionEvents)} events</span>
              <span><b>trimmed</b> ${fmtInt(memoryCompactionDroppedNotes)} (+invalid ${fmtInt(memoryCompactionInvalidDropped)})</span>
              <span><b>latest</b> ${escHtml(memoryRecentNote)}</span>
            </div>
            <div class="keeper-memory-wrap">
              ${memoryNotesHtml}
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">Recent Conversation (User/Assistant)</div>
            <div class="keeper-chart-meta">
              <span><b>rows</b> ${fmtInt(conversationTailCount)}</span>
              <span><b>raw</b> ${fmtInt(conversationRawCount)}</span>
              <span><b>fragments</b> ${fmtInt(conversationFragmentCount)}</span>
              <span><b>filtered</b> ${conversationFragmentFilterEnabled ? fmtInt(conversationFragmentFilteredCount) : '-'}</span>
              <span><b>k2k edges</b> ${fmtInt(k2kCount)}</span>
              <span><b>mentions</b> ${escHtml(k2kMentionsText)}</span>
            </div>
            <div class="keeper-conversation-wrap">
              ${conversationHtml}
            </div>
          </div>
          <div class="keeper-chart-card">
            <div class="keeper-chart-title">K2K Relay Trail</div>
            <div class="keeper-chart-meta">
              <span><b>edges</b> ${fmtInt(k2kCount)}</span>
              <span><b>window</b> recent history tail</span>
            </div>
            <div class="keeper-k2k-wrap">
              ${k2kHtml}
            </div>
          </div>
        </div>
        <div class="keeper-events">
          <div class="keeper-chart-title">Recent Lifecycle Events</div>
          <div class="keeper-events-list">${eventsHtml}</div>
        </div>
      `;
    }
    function openKeeperDetail(name) {
      if (!name) return;
      selectedKeeperName = String(name);
      if (compareKeeperName === selectedKeeperName) compareKeeperName = null;
      setKeeperQueryState();
      renderKeeperDetail();
      const modal = document.getElementById('keeper-detail-modal');
      if (modal) modal.classList.add('active');
    }
    function closeKeeperDetail() {
      selectedKeeperName = null;
      compareKeeperName = null;
      setKeeperQueryState();
      const modal = document.getElementById('keeper-detail-modal');
      if (modal) modal.classList.remove('active');
    }

    function updateKeepers(data) {
      const list = document.getElementById('keeper-list');
      if (!list) return;
      const keepers = (data && data.keepers) ? data.keepers : [];
      if (keepers.length === 0) {
        list.innerHTML = '<div class="empty">No keepers</div>';
        return;
      }
      const alertThresholds = currentAlertThresholds();
      list.innerHTML = keepers.map(k => {
        const agent = k.agent || {};
        const exists = !!agent.exists;
        const zombie = !!agent.is_zombie;
        const statusClass = (exists && !zombie) ? 'active' : 'inactive';

        const ctx = k.context || {};
        const ratio = ctx.context_ratio;
        const tokens = ctx.context_tokens;
        const max = ctx.context_max;
        const pct = fmtPct(ratio);
        const fillPct = isNum(ratio) ? clamp(ratio * 100, 0, 100) : 0;
        const fillClass = ctxClass(ratio);

        const keepalive = !!k.keepalive_running;
        const keepalivePill = keepalive
          ? '<span class="pill">keepalive</span>'
          : '<span class="pill bad">no-keepalive</span>';
        const zombiePill = zombie ? '<span class="pill bad">zombie</span>' : '';
        const handoffTh = isNum(k.handoff_threshold) ? k.handoff_threshold : 0.85;
        const handoffSoon = (isNum(ratio) && isNum(handoffTh) && ratio >= handoffTh * 0.95)
          ? '<span class="pill warn">handoff-soon</span>' : '';

        const modelUsed = k.active_model || k.last_model_used || '-';
        const nextModel = k.next_model_hint || '-';
        const skillPrimaryQuick =
          (typeof k.skill_primary === 'string' && k.skill_primary.trim() !== '')
            ? k.skill_primary.trim()
            : '-';
        const skillSecondaryQuick =
          Array.isArray(k.skill_secondary)
            ? k.skill_secondary
                .filter((s) => typeof s === 'string' && s.trim() !== '')
                .map((s) => s.trim())
            : [];
        const skillQuick =
          skillSecondaryQuick.length > 0
            ? `${skillPrimaryQuick} (+${skillSecondaryQuick.join(', ')})`
            : skillPrimaryQuick;
        const soulProfile = (k.soul_profile || 'balanced');
        const willQuick = shortText(k.will, 36);
        const needsQuick = shortText(k.needs, 36);
        const desiresQuick = shortText(k.desires, 36);
        const cascade = fmtCascade(k.models);
        const gen = isNum(k.generation) ? k.generation : 0;
        const genPill = `<span class="pill">gen ${gen}</span>`;
        const contextSource = k.context_source || ctx.source || '-';

        const usage = k.last_usage || {};
        const io = (isNum(usage.input_tokens) && isNum(usage.output_tokens))
          ? `io ${usage.input_tokens}/${usage.output_tokens}`
          : '';

        const age = fmtSecShort(k.keeper_age_s);
        const last = isNum(k.last_turn_ago_s) ? (fmtSecShort(k.last_turn_ago_s) + ' ago') : 'never';
        const lastHandoffAgo = isNum(k.last_handoff_ago_s) ? (fmtSecShort(k.last_handoff_ago_s) + ' ago') : '-';
        const lastCompactionAgo = isNum(k.last_compaction_ago_s) ? (fmtSecShort(k.last_compaction_ago_s) + ' ago') : '-';
        const ctxText = (isNum(tokens) && isNum(max) && max > 0) ? `${pct} (${tokens}/${max})` : pct;
        const handoffTotal = isNum(k.handoff_count_total) ? k.handoff_count_total : 0;
        const compactionSavedLast = isNum(k.last_compaction_saved_tokens) ? k.last_compaction_saved_tokens : 0;

        const series = Array.isArray(k.metrics_series) ? k.metrics_series : [];
        const spark = sparkSvg(series, { threshold: handoffTh });
        const eta = etaTurns(series, handoffTh);
        const etaText = (eta === 0) ? 'now'
          : (isNum(eta) ? (`~${eta} turns`) : '-');
        const seriesText = series.length > 0 ? `${series.length} pts` : 'no metrics';
        const handoffPct = isNum(handoffTh) ? (Math.round(handoffTh * 100) + '%') : '-';
        const windowStats = k.metrics_window || {};
        const handoffWindow = isNum(windowStats.handoff_count) ? windowStats.handoff_count : 0;
        const compactionWindow = isNum(windowStats.compaction_events) ? windowStats.compaction_events : 0;
        const savedWindow = isNum(windowStats.compaction_saved_tokens) ? windowStats.compaction_saved_tokens : 0;
        const fallbackWindowRate = isNum(windowStats.model_fallback_rate)
          ? windowStats.model_fallback_rate
          : (isNum(windowStats.fallback_rate) ? windowStats.fallback_rate : null);
        const fallbackWindowText = fallbackWindowRate === null ? '-' : fmtPct1(fallbackWindowRate);
        const compactionEffWindow = isNum(windowStats.compaction_saved_ratio) ? windowStats.compaction_saved_ratio : null;
        const compactionEffText = compactionEffWindow === null ? '-' : fmtPct1(compactionEffWindow);
        const memoryPassWindow = isNum(windowStats.memory_pass_rate) ? windowStats.memory_pass_rate : null;
        const memoryPassText = memoryPassWindow === null ? '-' : fmtPct1(memoryPassWindow);
        const weatherPassWindow = isNum(windowStats.memory_weather_pass_rate) ? windowStats.memory_weather_pass_rate : null;
        const weatherPassText = weatherPassWindow === null ? '-' : fmtPct1(weatherPassWindow);
        const topWorkQuick = topCountName(windowStats.top_work_kinds, 'kind');
        const topToolQuick = topCountName(windowStats.top_tools, 'tool');
        const topMemoryQuick =
          k.memory_top_kind
          || topCountName(windowStats.top_memory_kinds, 'kind');
        const memoryNoteCountQuick = isNum(k.memory_note_count) ? k.memory_note_count : 0;
        const memoryCompactEventsQuick = isNum(windowStats.memory_compaction_events)
          ? windowStats.memory_compaction_events : 0;
        const memoryTrimQuick = isNum(windowStats.memory_compaction_dropped_notes)
          ? windowStats.memory_compaction_dropped_notes : 0;
        const memoryTrimRateQuick = isNum(windowStats.memory_compaction_drop_ratio)
          ? fmtPct1(windowStats.memory_compaction_drop_ratio)
          : '-';
        const turnPointsQuick = isNum(windowStats.turn_points) ? windowStats.turn_points : null;
        const proactivePointsQuick = isNum(windowStats.proactive_points) ? windowStats.proactive_points : null;
        const heartbeatPointsQuick = isNum(windowStats.heartbeat_points) ? windowStats.heartbeat_points : null;
        const proactiveFallbackQuick = isNum(windowStats.proactive_template_fallback_count)
          ? windowStats.proactive_template_fallback_count
          : (isNum(windowStats.proactive_fallback_count)
              ? windowStats.proactive_fallback_count
              : 0);
        const proactiveFallbackQuickRate = isNum(windowStats.proactive_template_fallback_rate)
          ? windowStats.proactive_template_fallback_rate
          : (isNum(windowStats.proactive_fallback_rate)
              ? windowStats.proactive_fallback_rate
              : (isNum(proactivePointsQuick) && proactivePointsQuick > 0
                  ? (proactiveFallbackQuick / proactivePointsQuick)
                  : null));
        const proactiveFallbackQuickState =
          (isNum(proactiveFallbackQuickRate) && proactiveFallbackQuickRate >= alertThresholds.proactive_fallback_bad)
            ? 'bad'
            : ((isNum(proactiveFallbackQuickRate) && proactiveFallbackQuickRate >= alertThresholds.proactive_fallback_warn) ? 'warn' : 'ok');
        const proactiveFallbackQuickClass =
          proactiveFallbackQuickState === 'bad' ? 'bad-metric'
          : (proactiveFallbackQuickState === 'warn' ? 'warn-metric' : '');
        const proactiveSimMaxQuick = isNum(windowStats.proactive_preview_similarity_max)
          ? windowStats.proactive_preview_similarity_max
          : null;
        const proactiveSimWarnQuick =
          !!windowStats.proactive_preview_similarity_warn
          || (isNum(proactiveSimMaxQuick) && proactiveSimMaxQuick >= alertThresholds.proactive_similarity_warn);
        const proactiveSimQuickState =
          (isNum(proactiveSimMaxQuick) && proactiveSimMaxQuick >= alertThresholds.proactive_similarity_bad)
            ? 'bad'
            : (proactiveSimWarnQuick ? 'warn' : 'ok');
        const proactiveSimQuickClass =
          proactiveSimQuickState === 'bad' ? 'bad-metric'
          : (proactiveSimQuickState === 'warn' ? 'warn-metric' : '');
        const proactiveSimQuickText =
          proactiveSimMaxQuick === null
            ? '-'
            : `${fmtPct1(proactiveSimMaxQuick)}${proactiveSimWarnQuick ? ' !' : ''}`;
        const pointMixText =
          (turnPointsQuick === null && proactivePointsQuick === null && heartbeatPointsQuick === null)
            ? '-'
            : `${fmtInt(turnPointsQuick)}t/${fmtInt(proactivePointsQuick)}p/${fmtInt(heartbeatPointsQuick)}h`;
        const riskQuick = handoffRiskMetrics(series, handoffTh);
        const riskQuickText = riskQuick.score === null ? '-' : (riskQuick.score + '/100');
        const lastHandoffEvent = k.last_handoff_event || {};
        const handoffTo = lastHandoffEvent.to_model || '-';
        const bornQuick = fmtIso(k.created_at);
        const k2kCountQuick = isNum(k.k2k_count) ? k.k2k_count : 0;
        const convoCountQuick = isNum(k.conversation_tail_count) ? k.conversation_tail_count : 0;
        const convoRawQuick = isNum(k.conversation_raw_count) ? k.conversation_raw_count : convoCountQuick;
        const convoFragQuick = isNum(k.conversation_fragment_count) ? k.conversation_fragment_count : 0;
        const convoFragFilteredQuick = isNum(k.conversation_fragment_filtered_count)
          ? k.conversation_fragment_filtered_count : 0;
        const convoFragFilterOnQuick = !!k.conversation_fragment_filter_enabled;
        const convoFragQuickText =
          convoFragQuick > 0
            ? `${fmtInt(convoFragQuick)}${convoFragFilterOnQuick ? ` (f${fmtInt(convoFragFilteredQuick)})` : ''}`
            : '-';
        const proactiveTotalQuick = isNum(k.proactive_count_total) ? k.proactive_count_total : 0;
        const proactiveAgoQuick = isNum(k.last_proactive_ago_s)
          ? (fmtSecShort(k.last_proactive_ago_s) + ' ago')
          : '-';
        const driftTotalQuick = isNum(k.drift_count_total) ? k.drift_count_total : 0;
        const driftWindowQuick = isNum(windowStats.drift_applied_count)
          ? windowStats.drift_applied_count
          : series.filter((p) => p && p.drift_applied).length;
        const interactionPointsQuick = (isNum(turnPointsQuick) ? turnPointsQuick : 0)
          + (isNum(proactivePointsQuick) ? proactivePointsQuick : 0);
        const driftWindowRateQuick = isNum(windowStats.drift_applied_rate)
          ? windowStats.drift_applied_rate
          : (interactionPointsQuick > 0 ? (driftWindowQuick / interactionPointsQuick) : null);
        const interventionShareQuick = isNum(windowStats.intervention_share)
          ? windowStats.intervention_share
          : (interactionPointsQuick > 0 && isNum(proactivePointsQuick)
              ? (proactivePointsQuick / interactionPointsQuick)
              : null);

        const selectedClass = (selectedKeeperName && selectedKeeperName === k.name) ? 'selected' : '';
        return `
          <div class="live-agent keeper-card ${selectedClass}" onclick="openKeeperDetail('${k.name || ''}')">
            <div class="agent-status ${statusClass}"></div>
            <div class="live-agent-main">
              <div class="live-agent-title">
                <span class="live-agent-name">${k.name || 'keeper'}</span>
                <span class="live-agent-sub">${k.agent_name || ''}</span>
                ${genPill}
                ${keepalivePill}
                ${zombiePill}
                ${handoffSoon}
              </div>
              <div class="live-agent-meta">
                <span>model ${modelUsed}</span>
                <span>next ${nextModel}</span>
                <span>skill ${escHtml(shortText(skillQuick, 44))}</span>
                <span>soul ${escHtml(soulProfile)}</span>
                <span>will ${escHtml(willQuick)}</span>
                <span>needs ${escHtml(needsQuick)}</span>
                <span>desire ${escHtml(desiresQuick)}</span>
                <span>cascade ${cascade}</span>
                <span>ctx ${ctxText}</span>
                <span>src ${contextSource}</span>
                <span>${io}</span>
                <span>last ${last}</span>
                <span>age ${age}</span>
                <span>born ${escHtml(bornQuick)}</span>
                <span>handoffs ${handoffTotal}</span>
                <span>compactions ${k.compaction_count || 0}</span>
                <span>save ${compactionSavedLast}</span>
                <span>eff ${compactionEffText}</span>
                <span>mfb ${fallbackWindowText}</span>
                <span>mem ${memoryPassText}</span>
                <span>weather ${weatherPassText}</span>
                <span>notes ${fmtInt(memoryNoteCountQuick)}</span>
                <span>m-compact ${fmtInt(memoryCompactEventsQuick)}</span>
                <span>m-trim ${fmtInt(memoryTrimQuick)} (${memoryTrimRateQuick})</span>
                <span>focus ${escHtml(topMemoryQuick)}</span>
                <span>work ${escHtml(topWorkQuick)}</span>
                <span>tool ${escHtml(topToolQuick)}</span>
                <span>pts ${pointMixText}</span>
                <span${proactiveFallbackQuickClass ? ` class="${proactiveFallbackQuickClass}"` : ''}>ptfb ${fmtInt(proactiveFallbackQuick)}</span>
                <span${proactiveSimQuickClass ? ` class="${proactiveSimQuickClass}"` : ''}>psim ${proactiveSimQuickText}</span>
                <span>logs ${fmtInt(convoCountQuick)}</span>
                <span>raw ${fmtInt(convoRawQuick)}</span>
                <span>frag ${convoFragQuickText}</span>
                <span>k2k ${fmtInt(k2kCountQuick)}</span>
                <span>proactive ${fmtInt(proactiveTotalQuick)}</span>
                <span>p-last ${escHtml(proactiveAgoQuick)}</span>
                <span>drift ${fmtInt(driftTotalQuick)}</span>
                <span>d-win ${fmtInt(driftWindowQuick)} (${driftWindowRateQuick === null ? '-' : fmtPct1(driftWindowRateQuick)})</span>
                <span>intervene ${interventionShareQuick === null ? '-' : fmtPct1(interventionShareQuick)}</span>
                <span>risk ${riskQuickText}</span>
                <span>handoff ${lastHandoffAgo}</span>
                <span>compact ${lastCompactionAgo}</span>
              </div>
              <div class="ctx-bar"><div class="ctx-fill ${fillClass}" style="width:${fillPct}%"></div></div>
              <div class="ctx-spark">
                <div class="sparkline">${spark || '<div class=\"spark-empty\">no series</div>'}</div>
                <div class="spark-meta">
                  <span><b>handoff</b> ${handoffPct}</span>
                  <span><b>eta</b> ${etaText}</span>
                  <span><b>window</b> h${handoffWindow}/c${compactionWindow}/p${fmtInt(proactivePointsQuick)}</span>
                  <span><b>saved</b> ${savedWindow}</span>
                  <span><b>to</b> ${handoffTo}</span>
                  <span><b>marks</b> P/C/H</span>
                  <span>${seriesText}</span>
                </div>
              </div>
            </div>
          </div>
        `;
      }).join('');
    }

    function updatePerpetual(data) {
      const list = document.getElementById('perpetual-list');
      if (!list) return;
      const agents = (data && data.agents) ? data.agents : [];
      if (agents.length === 0) {
        list.innerHTML = '<div class="empty">No perpetual agents</div>';
        return;
      }
      list.innerHTML = agents.map(a => {
        const running = !!a.running;
        const statusClass = running ? 'active' : 'inactive';

        const ratio = a.context_ratio;
        const tokens = a.context_tokens;
        const max = a.context_max;
        const pct = fmtPct(ratio);
        const fillPct = isNum(ratio) ? clamp(ratio * 100, 0, 100) : 0;
        const fillClass = ctxClass(ratio);
        const ctxText = (isNum(tokens) && isNum(max) && max > 0) ? `${pct} (${tokens}/${max})` : pct;

        const age = fmtSecShort(a.age_s);
        const last = isNum(a.last_turn_ago_s) ? (fmtSecShort(a.last_turn_ago_s) + ' ago') : 'never';

        const usage = a.last_usage || {};
        const io = (isNum(usage.input_tokens) && isNum(usage.output_tokens))
          ? `io ${usage.input_tokens}/${usage.output_tokens}`
          : '';

        const cascade = Array.isArray(a.model_cascade)
          ? fmtCascade(a.model_cascade.map(m => (m.provider ? (m.provider + ':' + m.model_id) : m.model_id)))
          : '-';

        const gen = isNum(a.generation) ? a.generation : 0;
        const genPill = gen > 0 ? `<span class="pill warn">gen ${gen}</span>` : `<span class="pill">gen 0</span>`;

        return `
          <div class="live-agent">
            <div class="agent-status ${statusClass}"></div>
            <div class="live-agent-main">
              <div class="live-agent-title">
                <span class="live-agent-name">${(a.trace_id || 'trace').slice(0, 24)}</span>
                <span class="live-agent-sub">${a.last_model_used || ''}</span>
                ${genPill}
              </div>
              <div class="live-agent-meta">
                <span>running ${running ? 'yes' : 'no'}</span>
                <span>turns ${a.turn_count || 0}</span>
                <span>ctx ${ctxText}</span>
                <span>${io}</span>
                <span>last ${last}</span>
                <span>age ${age}</span>
                <span>cost $${isNum(a.total_cost_usd) ? a.total_cost_usd.toFixed(4) : '0.0000'}</span>
                <span>cascade ${cascade}</span>
              </div>
              <div class="ctx-bar"><div class="ctx-fill ${fillClass}" style="width:${fillPct}%"></div></div>
            </div>
          </div>
        `;
      }).join('');
    }

    function updateTempo(status) {
      // Convert tempo_interval_s to mode: <120s=fast, <400s=normal, else=slow
      const interval = status.tempo_interval_s || 300;
      let mode = 'normal';
      if (status.paused) mode = 'paused';
      else if (interval < 120) mode = 'fast';
      else if (interval > 400) mode = 'slow';
      tempoBadge.className = 'tempo-badge ' + mode;
      tempoBadge.textContent = mode.charAt(0).toUpperCase() + mode.slice(1) + ' (' + Math.round(interval) + 's)';
    }

    // === Toast notifications ===
    function showToast(message, type = 'info') {
      const container = document.getElementById('toast-container');
      const toast = document.createElement('div');
      toast.className = 'toast ' + type;
      toast.textContent = message;
      container.appendChild(toast);
      setTimeout(() => toast.remove(), 4000);
    }

    function keeperAlertState(keeper, thresholds) {
      const ws = (keeper && keeper.metrics_window) ? keeper.metrics_window : {};
      const reasons = [];
      let level = 'ok';
      const fallbackRate = isNum(ws.proactive_template_fallback_rate)
        ? Number(ws.proactive_template_fallback_rate)
        : (isNum(ws.proactive_fallback_rate) ? Number(ws.proactive_fallback_rate) : null);
      const similarityMax = isNum(ws.proactive_preview_similarity_max)
        ? Number(ws.proactive_preview_similarity_max)
        : null;
      const similarityWarn = !!ws.proactive_preview_similarity_warn;

      if (isNum(fallbackRate)) {
        if (fallbackRate >= thresholds.proactive_fallback_bad) {
          level = 'bad';
          reasons.push(`template-fallback ${fmtPct1(fallbackRate)}`);
        } else if (fallbackRate >= thresholds.proactive_fallback_warn) {
          if (level !== 'bad') level = 'warn';
          reasons.push(`template-fallback ${fmtPct1(fallbackRate)}`);
        }
      }
      if (isNum(similarityMax)) {
        if (similarityMax >= thresholds.proactive_similarity_bad) {
          level = 'bad';
          reasons.push(`similarity ${fmtPct1(similarityMax)}`);
        } else if (similarityMax >= thresholds.proactive_similarity_warn || similarityWarn) {
          if (level !== 'bad') level = 'warn';
          reasons.push(`similarity ${fmtPct1(similarityMax)}`);
        }
      } else if (similarityWarn) {
        if (level !== 'bad') level = 'warn';
        reasons.push('similarity warn');
      }
      return { level, reasons, fallbackRate, similarityMax };
    }

    function notifyKeeperAlerts(keepersPayload) {
      const keepers = (keepersPayload && Array.isArray(keepersPayload.keepers))
        ? keepersPayload.keepers
        : [];
      const thresholds = currentAlertThresholds();
      const cooldownMs = thresholds.toast_cooldown_sec * 1000;
      const now = Date.now();
      const activeNames = new Set();

      keepers.forEach((keeper) => {
        if (!keeper || !keeper.name) return;
        const name = String(keeper.name);
        activeNames.add(name);
        const st = keeperAlertState(keeper, thresholds);
        const signature = `${st.level}|${st.reasons.join('|')}`;
        const prev = keeperAlertMemory.get(name) || { level: 'ok', signature: '', lastToastMs: 0 };
        let nextLastToastMs = prev.lastToastMs || 0;

        if (st.level === 'ok') {
          if (prev.level !== 'ok') {
            showToast(`[OK] ${name} recovered (fallback/similarity normalized)`, 'success');
          }
        } else {
          const shouldToast =
            prev.level !== st.level
            || prev.signature !== signature
            || ((now - (prev.lastToastMs || 0)) >= cooldownMs);
          if (shouldToast) {
            const reasonText = st.reasons.length > 0 ? st.reasons.join(', ') : 'risk detected';
            const prefix = st.level === 'bad' ? '[BAD]' : '[WARN]';
            showToast(`${prefix} ${name}: ${reasonText}`, st.level === 'bad' ? 'error' : 'warning');
            nextLastToastMs = now;
          }
        }
        keeperAlertMemory.set(name, {
          level: st.level,
          signature,
          lastToastMs: nextLastToastMs,
        });
      });

      Array.from(keeperAlertMemory.keys()).forEach((name) => {
        if (!activeNames.has(name)) keeperAlertMemory.delete(name);
      });
    }

    // === Connection status ===
    let eventCount = 0;
    let sseConnected = false;
    let fetchDataTimer = null;
    let fetchBoardTimer = null;
    let periodicRefreshId = null;
    let sseSource = null;
    let sseReconnectTimer = null;
    let sseReconnectAttempts = 0;
    const sseReconnectBaseMs = 1000;
    const sseReconnectMaxMs = 15000;
    const sseSessionStorageKey = 'masc_dashboard_sse_session_id';
    const connStatus = document.getElementById('connection-status');
    const connText = document.getElementById('conn-text');
    const eventCounter = document.getElementById('event-counter');

    function createSseSessionId() {
      if (window.crypto && typeof window.crypto.randomUUID === 'function') {
        return 'dash_' + window.crypto.randomUUID();
      }
      return 'dash_' + Date.now().toString(36) + '_' + Math.random().toString(36).slice(2, 10);
    }

    function getOrCreateSseSessionId() {
      let sid = sessionStorage.getItem(sseSessionStorageKey);
      if (!sid) {
        sid = createSseSessionId();
        sessionStorage.setItem(sseSessionStorageKey, sid);
      }
      return sid;
    }

    function clearSseReconnectTimer() {
      if (sseReconnectTimer) {
        clearTimeout(sseReconnectTimer);
        sseReconnectTimer = null;
      }
    }

    function scheduleSseReconnect() {
      if (sseReconnectTimer) return;
      sseReconnectAttempts++;
      const exp = Math.min(sseReconnectAttempts, 5);
      const delay = Math.min(sseReconnectMaxMs, sseReconnectBaseMs * Math.pow(2, exp));
      sseReconnectTimer = setTimeout(() => {
        sseReconnectTimer = null;
        connectSSE();
      }, delay);
    }

    function startPeriodicRefresh() {
      if (periodicRefreshId) return;
      // Keepers/perpetual presence heartbeats don't emit SSE events.
      // Polling keeps the live-agent panels accurate even when the room is quiet.
      periodicRefreshId = setInterval(() => {
        invalidateDashboardCache();
        fetchData();
      }, 10000);
    }

    function updateConnectionStatus(connected) {
      sseConnected = connected;
      statusDot.classList.toggle('connected', connected);
      connStatus.classList.toggle('connected', connected);
      connStatus.classList.toggle('disconnected', !connected);
      connText.textContent = connected ? 'Connected' : 'Disconnected';
      startPeriodicRefresh();
    }

    function incrementEventCount() {
      eventCount++;
      eventCounter.textContent = eventCount + ' events';
    }

    // Debounced fetch to prevent CPU spike from cascading API calls
    function debouncedFetchData() {
      if (fetchDataTimer) return;
      fetchDataTimer = setTimeout(() => { fetchData(); fetchDataTimer = null; }, 500);
    }
    function debouncedFetchBoard() {
      if (fetchBoardTimer) return;
      fetchBoardTimer = setTimeout(() => { fetchBoard(); fetchBoardTimer = null; }, 500);
    }

    // SSE for real-time updates
    function connectSSE() {
      clearSseReconnectTimer();
      if (sseSource) {
        sseSource.close();
        sseSource = null;
      }

      const sseParams = new URLSearchParams();
      if (agent) sseParams.set('agent', agent);
      if (token) sseParams.set('token', token);
      sseParams.set('session_id', getOrCreateSseSessionId());
      const sseUrl = sseParams.toString() ? ('/sse?' + sseParams.toString()) : '/sse';
      const es = new EventSource(sseUrl);
      sseSource = es;
      es.onopen = () => {
        if (sseSource !== es) return;
        sseReconnectAttempts = 0;
        updateConnectionStatus(true);
        console.log('SSE connected');
      };
      es.onerror = () => {
        if (sseSource !== es) return;
        updateConnectionStatus(false);
        showToast('Connection lost. Reconnecting...', 'warning');
        es.close();
        sseSource = null;
        scheduleSseReconnect();
      };
      es.onmessage = (e) => {
        try {
          const event = JSON.parse(e.data);
          incrementEventCount();
          handleEvent(event);
        } catch (err) {
          console.log('SSE:', e.data);
        }
      };
    }

    function handleEvent(event) {
      const type = event.type || event.event;
      if (type) {
        invalidateDashboardCache();
        debouncedFetchData(); // Debounced to prevent CPU spike
        // Journal logging
        const agent = event.agent || event.from || event.from_agent || '';
        if (type === 'agent_joined') {
          addJournalEntry(agent, '🟢 Joined');
          showToast(`${agent} joined the room`, 'success');
        }
        else if (type === 'agent_left') {
          addJournalEntry(agent, '🔴 Left');
        }
        else if (type === 'broadcast') {
          addJournalEntry(agent, '📢 ' + (event.message || event.content || '').slice(0,80));
        }
        else if (type === 'task_update') {
          addJournalEntry(agent, '📋 Task: ' + (event.task_id || '') + ' → ' + (event.status || ''));
        }
        else if (type === 'board_post') {
          addJournalEntry(agent, '📝 New post');
          showToast(`📝 New post from ${agent}`, 'info');
          debouncedFetchBoard();
          setTimeout(scrollToNewPost, 500); // scroll after render
        }
        else if (type === 'board_comment') {
          addJournalEntry(agent, '💬 New comment');
          showToast(`💬 New comment from ${agent}`, 'info');
          debouncedFetchBoard();
        }
        else addJournalEntry(agent, type);
        // Skip fetchJournal - addJournalEntry already updates UI
      }
    }

    // === Hash Router ===
    const VALID_TABS = ['overview', 'board', 'activity', 'agents', 'tasks', 'journal'];

    const Router = {
      parse(hash) {
        // Parse: #board?sort=popular&author=claude or #board/post/abc123
        const h = (hash || '').replace(/^#/, '');
        if (!h) return { tab: 'overview', params: {}, postId: null };

        const [pathPart, queryPart] = h.split('?');
        const segments = pathPart.split('/');
        const tab = VALID_TABS.includes(segments[0]) ? segments[0] : 'overview';

        // Check for post detail: #board/post/{id}
        let postId = null;
        if (segments[0] === 'board' && segments[1] === 'post' && segments[2]) {
          postId = segments[2];
        }

        // Parse query params
        const params = {};
        if (queryPart) {
          new URLSearchParams(queryPart).forEach((v, k) => { params[k] = v; });
        }
        return { tab, params, postId };
      },

      serialize(state) {
        let hash = '#' + (state.tab || 'overview');

        // Add post path if viewing detail
        if (state.postId) {
          hash += '/post/' + state.postId;
        }

        // Add query params (sort, author, tag, hearth)
        const params = new URLSearchParams();
        if (state.sort && state.sort !== 'newest') params.set('sort', state.sort);
        if (state.author) params.set('author', state.author);
        if (state.tag) params.set('tag', state.tag);
        if (state.hearth) params.set('hearth', state.hearth);

        const qs = params.toString();
        if (qs) hash += '?' + qs;
        return hash;
      },

      navigate(state, replace = false) {
        const hash = this.serialize(state);
        if (replace) {
          history.replaceState(state, '', hash);
        } else {
          history.pushState(state, '', hash);
        }
        window.dispatchEvent(new CustomEvent('routechange', { detail: state }));
      },

      init() {
        // Handle hash changes (browser back/forward or direct URL)
        const handleRoute = () => {
          const state = this.parse(location.hash);
          // Merge with localStorage preferences
          state.sort = state.params.sort || localStorage.getItem('boardSort') || 'newest';
          state.author = state.params.author || '';
          state.tag = state.params.tag || null;
          state.hearth = state.params.hearth || null;
          window.dispatchEvent(new CustomEvent('routechange', { detail: state }));
        };

        window.addEventListener('hashchange', handleRoute);
        window.addEventListener('popstate', handleRoute);

        // Initial route on page load
        handleRoute();
      }
    };

    // === App State ===
    let currentMainTab = 'overview';
    let hideSystemPosts = true;

    const AppState = {
      tab: 'overview',
      postId: null,
      sort: 'newest',
      author: '',
      tag: null,
      hearth: null,

      update(changes) {
        Object.assign(this, changes);
        currentMainTab = this.tab;
        currentSort = this.sort;
        currentAuthorFilter = this.author;
        currentTagFilter = this.tag;
        currentHearthFilter = this.hearth;
      }
    };

    // === UI Adapter ===
    const UI = {
      apply(state) {
        AppState.update(state);
        this.switchTab(state.tab);

        if (state.tab === 'board') {
          this.applyBoardState(state);
        }
      },

      switchTab(tab) {
        // Update button active states
        document.querySelectorAll('.main-tab-btn').forEach(btn => {
          btn.classList.toggle('active', btn.dataset.tab === tab);
        });

        // Show/hide content panels
        document.querySelectorAll('.main-tab-content').forEach(c => c.style.display = 'none');
        const panel = document.getElementById('main-tab-' + tab);
        if (panel) panel.style.display = 'block';

        // Fetch data for tab
        if (tab === 'journal') fetchJournal();
        if (tab === 'board') fetchBoard();
        if (tab === 'activity') fetchActivity();
        if (tab === 'overview') fetchServerHealth();
        if (tab === 'agents') fetchLodgeAgents();
      },

      applyBoardState(state) {
        // Update sort dropdown
        const sortSelect = document.getElementById('sort-select');
        if (sortSelect && state.sort) sortSelect.value = state.sort;

        // Update author filter dropdown
        const authorSelect = document.getElementById('author-filter');
        if (authorSelect && state.author !== undefined) authorSelect.value = state.author;

        // Show post detail if postId present
        if (state.postId) {
          showPostDirect(state.postId);
        } else {
          showBoardListDirect();
        }
      }
    };

    // Listen for route changes
    window.addEventListener('routechange', (e) => {
      UI.apply(e.detail);
    });

    // === Main Tab switching (now uses Router) ===
    function switchMainTab(tab, opts = {}) {
      const state = {
        tab,
        postId: null,
        sort: currentSort,
        author: currentAuthorFilter,
        tag: currentTagFilter,
        hearth: currentHearthFilter
      };
      Router.navigate(state, opts.replace);
    }

    function toggleHideSystem(checked) {
      hideSystemPosts = checked;
      renderFromCache();
    }

    // Legacy tab function (kept for compatibility)
    function switchTab(tab) {
      switchMainTab(tab);
    }

    // === Board ===
    function timeAgo(ts) {
      if (!isNum(ts) || ts <= 0) return '-';
      const s = Math.floor((Date.now()/1000) - ts);
      if (s < 60) return s + 's ago';
      if (s < 3600) return Math.floor(s/60) + 'm ago';
      if (s < 86400) return Math.floor(s/3600) + 'h ago';
      return Math.floor(s/86400) + 'd ago';
    }

    // Avatar helpers
    function getAuthorEmoji(author) {
      const name = (author || '').toLowerCase();
      if (name.includes('claude')) return '🤖';
      if (name.includes('gemini')) return '💎';
      if (name.includes('codex')) return '🧠';
      if (name.includes('gpt') || name.includes('openai')) return '⚡';
      if (name.includes('vincent') || name.includes('정식')) return '👤';
      if (name.includes('lodge')) return '🏠';
      if (name.includes('patrol')) return '🛡️';
      if (name.includes('skeptic')) return '🔍';
      if (name.includes('pragmatist')) return '🔧';
      return (author || '?')[0].toUpperCase();
    }
    function getAvatarClass(author) {
      const name = (author || '').toLowerCase();
      if (name.includes('claude')) return 'avatar-purple';
      if (name.includes('gemini')) return 'avatar-blue';
      if (name.includes('codex')) return 'avatar-green';
      if (name.includes('gpt') || name.includes('openai')) return 'avatar-cyan';
      if (name.includes('lodge')) return 'avatar-orange';
      if (name.includes('patrol') || name.includes('skeptic')) return 'avatar-pink';
      const hash = (author || '').split('').reduce((a, c) => a + c.charCodeAt(0), 0);
      const colors = ['avatar-blue', 'avatar-purple', 'avatar-green', 'avatar-orange', 'avatar-pink', 'avatar-cyan'];
      return colors[hash % colors.length];
    }

    // SNS features: verified, likes, bookmarks
    const VERIFIED_AGENTS = ['claude', 'gemini', 'codex', 'lodge', 'patrol', 'skeptic', 'pragmatist', 'historian', 'dreamer'];
    function isVerifiedAgent(author) {
      const name = (author || '').toLowerCase();
      return VERIFIED_AGENTS.some(a => name.includes(a));
    }

    const likedPosts = new Set(JSON.parse(localStorage.getItem('likedPosts') || '[]'));
    const bookmarkedPosts = new Set(JSON.parse(localStorage.getItem('bookmarkedPosts') || '[]'));

    function isLiked(postId) { return likedPosts.has(postId); }
    function isBookmarked(postId) { return bookmarkedPosts.has(postId); }

    async function likePost(postId) {
      const btn = event.target.closest('.vote-up');
      if (likedPosts.has(postId)) {
        likedPosts.delete(postId);
        await fetch('/api/v1/board/' + postId + '/vote', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ direction: 'down' })
        });
      } else {
        likedPosts.add(postId);
        btn?.classList.add('pop');
        setTimeout(() => btn?.classList.remove('pop'), 300);
        await fetch('/api/v1/board/' + postId + '/vote', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ direction: 'up' })
        });
      }
      localStorage.setItem('likedPosts', JSON.stringify([...likedPosts]));
      fetchBoard();
    }

    function toggleBookmark(postId) {
      if (bookmarkedPosts.has(postId)) {
        bookmarkedPosts.delete(postId);
      } else {
        bookmarkedPosts.add(postId);
      }
      localStorage.setItem('bookmarkedPosts', JSON.stringify([...bookmarkedPosts]));
      fetchBoard();
    }

    function sharePost(postId) {
      const url = window.location.origin + '/dashboard?post=' + postId;
      navigator.clipboard.writeText(url).then(() => {
        alert('Link copied! 📋');
      }).catch(() => {
        prompt('Copy this link:', url);
      });
    }

    function updateTrendingTags(posts) {
      const tagCounts = {};
      posts.forEach(p => {
        const tags = (p.content || '').match(/#(\w+)/g) || [];
        tags.forEach(t => {
          const tag = t.toLowerCase();
          tagCounts[tag] = (tagCounts[tag] || 0) + 1;
        });
      });
      const sorted = Object.entries(tagCounts)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 5);
      const el = document.getElementById('trending-tags');
      if (!sorted.length) {
        el.innerHTML = '<span class="trending-tag" style="color:#666;">No tags yet</span>';
        return;
      }
      el.innerHTML = sorted.map(([tag, count]) =>
        `<span class="trending-tag" onclick="filterByTag('${tag.slice(1)}')">${tag}<span class="trending-count">${count}</span></span>`
      ).join('');
    }

    // === Server Health ===
    async function fetchServerHealth() {
      try {
        const health = await fetch('/health', { headers: authHeaders() }).then(r => r.json());
        document.getElementById('health-uptime').textContent = health.uptime || 'N/A';
        document.getElementById('health-sse').textContent = health.sse_clients || '0';
        document.getElementById('health-posts').textContent = health.board_posts || '0';
        document.getElementById('health-memory').textContent = health.memory || 'N/A';
        const badge = document.getElementById('version-badge');
        if (badge && health.version) badge.textContent = 'v' + health.version;
      } catch(e) { console.error('Health fetch error:', e); }
    }

    // === Author Filter ===
    let currentAuthorFilter = '';
    function filterByAuthor(author) {
      currentAuthorFilter = author;
      // Update URL with author filter (replace)
      const state = {
        tab: 'board',
        postId: null, // Clear post detail when filtering
        sort: currentSort,
        author: author,
        tag: currentTagFilter,
        hearth: currentHearthFilter
      };
      Router.navigate(state, true);
      renderFromCache();
    }

    function populateAuthorFilter(posts) {
      const authors = [...new Set(posts.map(p => p.author))].sort();
      const select = document.getElementById('author-filter');
      if (!select) return;
      select.innerHTML = '<option value="">All authors</option>' +
        authors.map(a => `<option value="${a}" ${a === currentAuthorFilter ? 'selected' : ''}>${a}</option>`).join('');
    }

    let _cachedPosts = [];

    async function fetchBoard() {
      const el = document.getElementById('board-list-view');
      if (el) el.style.opacity = '0.5';
      try {
        let url = '/api/v1/board';
        if (currentHearthFilter) url += '?hearth=' + encodeURIComponent(currentHearthFilter);
        const res = await fetch(url);
        const data = await res.json();
        _cachedPosts = data.posts || [];
        populateAuthorFilter(_cachedPosts);
        renderFromCache();
      } catch(e) { console.error('Board fetch error:', e); }
      finally { if (el) el.style.opacity = '1'; }
    }

    function renderFromCache() {
      let posts = _cachedPosts;
      if (currentAuthorFilter) {
        posts = posts.filter(p => p.author === currentAuthorFilter);
      }
      if (hideSystemPosts) {
        posts = posts.filter(p => p.author !== 'lodge-system');
      }
      renderBoardList(posts);
    }

    async function fetchActivity() {
      try {
        const res = await fetch('/api/v1/board');
        const data = await res.json();
        const systemPosts = (data.posts || []).filter(p => p.author === 'lodge-system');
        renderActivityList(systemPosts);
      } catch(e) { console.error('Activity fetch error:', e); }
    }

    function renderActivityList(posts) {
      const el = document.getElementById('activity-list');
      if (!posts.length) {
        el.innerHTML = '<div class="empty">No activity reports yet</div>';
        return;
      }
      el.innerHTML = posts.map(p => {
        const time = timeAgo(p.created_at);
        // Parse activity report into individual agent lines
        const lines = p.content.split('\n').filter(l => l.trim());
        const title = lines[0] || '';
        const agentLines = lines.slice(1).filter(l => l.match(/^\[/));
        const agentHtml = agentLines.length > 0
          ? '<div class="activity-agents">' + agentLines.map(l =>
              '<div class="activity-line">' + escapeHtml(l) + '</div>'
            ).join('') + '</div>'
          : '<div class="board-content">' + escapeHtml(p.content).replace(/\n/g, '<br>') + '</div>';
        return '<div class="board-item">' +
          '<div class="board-meta">' + time + '</div>' +
          '<div class="board-title">' + escapeHtml(title) + '</div>' +
          agentHtml +
        '</div>';
      }).join('');
    }

    async function fetchHearths() {
      try {
        const res = await fetch('/api/v1/board/hearths');
        const data = await res.json();
        const hearths = data.hearths || [];
        const sidebar = document.getElementById('hearths-list');
        if (sidebar) {
          sidebar.innerHTML = hearths.length
            ? hearths.map(h => {
                const safeName = escapeHtml(h.name);
                const isActive = currentHearthFilter === h.name;
                const el = document.createElement('div');
                el.className = 'hearth-item';
                el.style.cssText = 'cursor:pointer;padding:4px 8px;border-radius:4px;margin:2px 0;display:flex;justify-content:space-between;' + (isActive ? 'background:var(--accent-blue);color:white' : '');
                el.innerHTML = `<span>🔥 ${safeName}</span><span style="opacity:0.6">${h.count}</span>`;
                el.addEventListener('click', () => filterByHearth(h.name));
                return el.outerHTML;
              }).join('')
            : '<div style="opacity:0.5;font-size:12px">No hearths yet</div>';
          // Re-bind click listeners after innerHTML replacement
          sidebar.querySelectorAll('.hearth-item').forEach((el, i) => {
            el.onclick = () => filterByHearth(hearths[i].name);
          });
        }
      } catch(e) { console.error('Hearth fetch error:', e); }
    }

    function filterByHearth(name) {
      currentHearthFilter = (currentHearthFilter === name) ? null : name;
      // Update URL with hearth filter (replace)
      const state = {
        tab: 'board',
        postId: null,
        sort: currentSort,
        author: currentAuthorFilter,
        tag: currentTagFilter,
        hearth: currentHearthFilter
      };
      Router.navigate(state, true);
      fetchBoard();
      fetchHearths();
    }

    async function votePost(postId, direction) {
      try {
        await fetch('/api/v1/board/' + postId + '/vote', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ direction })
        });
        fetchBoard();
      } catch(e) { console.error('Vote error:', e); }
    }

    async function voteWithAnim(postId, direction, btn) {
      btn.classList.add('pop');
      const scoreEl = document.getElementById('score-' + postId);
      if (scoreEl) {
        const currentScore = parseInt(scoreEl.textContent) || 0;
        const newScore = direction === 'up' ? currentScore + 1 : currentScore - 1;
        scoreEl.textContent = newScore;
        scoreEl.classList.remove('positive', 'negative');
        if (newScore > 0) scoreEl.classList.add('positive');
        else if (newScore < 0) scoreEl.classList.add('negative');
        scoreEl.classList.add('pop');
      }
      setTimeout(() => {
        btn.classList.remove('pop');
        if (scoreEl) scoreEl.classList.remove('pop');
      }, 300);
      await votePost(postId, direction);
    }

    function renderBoardList(posts) {
      const el = document.getElementById('board-list-view');

      // Apply client-side sort
      let sorted = sortPosts(posts);

      // Apply tag filter
      let filtered = sorted;
      if (currentTagFilter) {
        const tagRegex = new RegExp('#' + currentTagFilter + '\\b', 'i');
        filtered = sorted.filter(p => tagRegex.test(p.content));
      }
      if (!filtered.length) {
        el.innerHTML = currentTagFilter
          ? `<div class="empty">No posts with #${currentTagFilter}</div>`
          : '<div class="empty">No posts yet</div>';
        return;
      }
      el.innerHTML = filtered.map(p => {
        const score = p.votes_up - p.votes_down;
        const scoreClass = score > 0 ? 'positive' : score < 0 ? 'negative' : '';
        const flairHtml = p.flair ? `<span class="flair-badge ${p.flair.name}">${p.flair.emoji} ${p.flair.label}</span>` : '';
        const karmaHtml = p.author_karma ? `<span class="karma-badge">⭐ ${p.author_karma}</span>` : '';
        const hearthHtml = p.hearth ? `<span style="background:#ff6b3520;color:#ff6b35;padding:1px 6px;border-radius:8px;font-size:10px;margin-left:4px">🔥 ${escapeHtml(p.hearth)}</span>` : '';
        const threadHtml = p.thread_id ? `<span style="color:var(--accent-blue);font-size:11px;cursor:pointer" onclick="event.stopPropagation()">→ Discussion</span>` : '';
        return `
        <div class="board-post" onclick="showPost('${p.id}')">
          <div class="vote-column" onclick="event.stopPropagation()">
            <button class="vote-btn upvote" onclick="voteWithAnim('${p.id}','up',this)">▲</button>
            <span class="vote-score ${scoreClass}" id="score-${p.id}">${score}</span>
            <button class="vote-btn downvote" onclick="voteWithAnim('${p.id}','down',this)">▼</button>
          </div>
          <div class="author-avatar ${getAvatarClass(p.author)}">${getAuthorEmoji(p.author)}</div>
          <div class="board-post-body">
            <div class="board-post-header">
              <span class="board-post-author">${p.author}</span>${karmaHtml}${isVerifiedAgent(p.author) ? '<span class="verified-badge">✓</span>' : ''}${flairHtml}${hearthHtml}
              <span class="board-post-time">${timeAgo(p.created_at)}</span>
            </div>
            <div class="board-post-content">${formatContent(p.content, {collapsed: true, postId: p.id})}</div>
            <div class="board-post-footer">
              <span>💬 ${p.reply_count}</span>${threadHtml}
              <span class="bookmark-btn ${isBookmarked(p.id) ? 'saved' : ''}" onclick="event.stopPropagation();toggleBookmark('${p.id}')">
                ${isBookmarked(p.id) ? '🔖' : '📑'}
              </span>
              <span class="share-btn" onclick="event.stopPropagation();sharePost('${p.id}')">↗️</span>
              <span style="margin-left:auto;opacity:0.4;font-size:9px">${p.visibility === 'public' ? '🌐' : '🔒'}</span>
            </div>
          </div>
        </div>
      `}).join('');
      updateTrendingTags(posts);
    }

    function escapeHtml(s) {
      return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    // Format content with markdown, think tags, and hashtags
    function formatContent(s, opts = {}) {
      const { collapsed = false, postId = '' } = opts;

      // Step 1: Extract <think> blocks BEFORE escaping (handles unclosed tags too)
      let thinkCounter = 0;
      const thinkBlocks = [];

      // Match both closed <think>...</think> and unclosed <think>... (rest of content)
      let processed = s.replace(/<think>([\s\S]*?)(<\/think>|$)/gi, (match, content, closing) => {
        thinkCounter++;
        const blockId = postId ? `think-${postId}-${thinkCounter}` : `think-${Date.now()}-${thinkCounter}`;
        thinkBlocks.push({ id: blockId, content: escapeHtml(content.trim()) });
        return `__THINK_${thinkCounter}__`;
      });

      // Step 2: Escape remaining HTML
      let html = escapeHtml(processed);

      // Step 3: Restore think blocks as collapsible divs
      thinkBlocks.forEach((block, i) => {
        html = html.replace(`__THINK_${i+1}__`, `<div class="think-block" id="${block.id}">
          <div class="think-toggle" onclick="toggleThink('${block.id}')">🧠 Thinking (click to expand)</div>
          <div class="think-content">${block.content}</div>
        </div>`);
      });

      // Step 4: Basic markdown - **bold**, `code`, [text](url)
      html = html.replace(/\*\*([^*]+)\*\*/g, '<span class="md-bold">$1</span>');
      html = html.replace(/`([^`]+)`/g, '<span class="md-code">$1</span>');
      html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a class="md-link" href="$2" target="_blank" rel="noopener">$1</a>');

      // Step 5: Hashtags - #tag (word characters, but not inside think blocks)
      html = html.replace(/#(\w+)/g, '<span class="hashtag" onclick="filterByTag(\'$1\')">#$1</span>');

      // Step 6: Wrap in collapsible container if needed (based on visible text length)
      const visibleLength = s.replace(/<think>[\s\S]*?(<\/think>|$)/gi, '').length;
      if (collapsed && visibleLength > 300) {
        const contentId = postId ? `content-${postId}` : `content-${Date.now()}`;
        return `<div id="${contentId}" class="content-collapsed">${html}</div>
          <button class="expand-btn" onclick="toggleContent('${contentId}')">Show more</button>`;
      }
      return html;
    }

    function toggleThink(blockId) {
      const block = document.getElementById(blockId);
      if (block) block.classList.toggle('expanded');
    }

    function toggleContent(contentId) {
      const content = document.getElementById(contentId);
      const btn = content?.nextElementSibling;
      if (content) {
        const isCollapsed = content.classList.toggle('content-collapsed');
        if (btn) btn.textContent = isCollapsed ? 'Show more' : 'Show less';
      }
    }

    let currentTagFilter = null;
    let currentHearthFilter = null;
    let currentSort = localStorage.getItem('boardSort') || 'newest';
    let autoScrollEnabled = localStorage.getItem('autoScroll') !== 'false';

    // Initialize router and UI state
    document.addEventListener('DOMContentLoaded', () => {
      // Initialize sort dropdown
      const sortSelect = document.getElementById('sort-select');
      if (sortSelect) sortSelect.value = currentSort;

      // Initialize auto-scroll checkbox
      const autoScrollCheck = document.getElementById('auto-scroll');
      if (autoScrollCheck) autoScrollCheck.checked = autoScrollEnabled;

      // Initialize hide system checkbox
      const hideSystemCheck = document.getElementById('hide-system');
      if (hideSystemCheck) hideSystemCheck.checked = hideSystemPosts;

      // Initialize Router (handles URL hash and triggers initial routechange)
      Router.init();

      // Fetch hearths sidebar
      fetchHearths();
    });

    function toggleAutoScroll(enabled) {
      autoScrollEnabled = enabled;
      localStorage.setItem('autoScroll', enabled ? 'true' : 'false');
    }

    function scrollToNewPost() {
      if (!autoScrollEnabled) return;
      const boardList = document.getElementById('board-list');
      if (boardList && boardList.firstElementChild) {
        boardList.firstElementChild.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      }
    }

    function changeSort(sortBy) {
      currentSort = sortBy;
      localStorage.setItem('boardSort', sortBy);
      // Update URL with new sort (replace to avoid history spam)
      const state = {
        tab: 'board',
        postId: AppState.postId,
        sort: sortBy,
        author: currentAuthorFilter,
        tag: currentTagFilter,
        hearth: currentHearthFilter
      };
      Router.navigate(state, true); // replace = true
      renderFromCache();
    }

    function sortPosts(posts) {
      return [...posts].sort((a, b) => {
        switch (currentSort) {
          case 'newest':
            return b.created_at - a.created_at;
          case 'updated':
            return (b.updated_at || b.created_at) - (a.updated_at || a.created_at);
          case 'oldest':
            return a.created_at - b.created_at;
          case 'popular':
            return (b.votes_up - b.votes_down) - (a.votes_up - a.votes_down);
          case 'discussed':
            return (b.reply_count || 0) - (a.reply_count || 0);
          case 'controversial': {
            // High total engagement with mixed up/down ratio
            const totalA = a.votes_up + a.votes_down;
            const totalB = b.votes_up + b.votes_down;
            // Controversy = high votes + ratio close to 0.5
            const ratioA = totalA > 0 ? Math.min(a.votes_up, a.votes_down) / totalA : 0;
            const ratioB = totalB > 0 ? Math.min(b.votes_up, b.votes_down) / totalB : 0;
            return (totalB * ratioB) - (totalA * ratioA);
          }
          default:
            return b.created_at - a.created_at;
        }
      });
    }

    function filterByTag(tag) {
      currentTagFilter = currentTagFilter === tag ? null : tag;
      // Update URL with tag filter (replace)
      const state = {
        tab: 'board',
        postId: null,
        sort: currentSort,
        author: currentAuthorFilter,
        tag: currentTagFilter,
        hearth: currentHearthFilter
      };
      Router.navigate(state, true);
      updateTagFilterBar();
      renderFromCache();
    }

    function clearTagFilter() {
      currentTagFilter = null;
      updateTagFilterBar();
      renderFromCache();
    }

    function updateTagFilterBar() {
      const bar = document.getElementById('tag-filter-bar');
      const tagSpan = document.getElementById('current-tag-filter');
      if (currentTagFilter) {
        bar.classList.add('active');
        tagSpan.textContent = '#' + currentTagFilter;
      } else {
        bar.classList.remove('active');
      }
    }

    // Show post via URL navigation (pushes history)
    async function showPost(postId) {
      const state = {
        tab: 'board',
        postId: postId,
        sort: currentSort,
        author: currentAuthorFilter,
        tag: currentTagFilter,
        hearth: currentHearthFilter
      };
      Router.navigate(state);
    }

    // Direct post display (called from router, no history push)
    async function showPostDirect(postId) {
      try {
        const res = await fetch('/api/v1/board/' + postId);
        const data = await res.json();
        const p = data.post;
        const comments = data.comments || [];
        const el = document.getElementById('board-detail-content');
        el.innerHTML = `
          <div class="board-post" style="cursor:default;">
            <div class="author-avatar ${getAvatarClass(p.author)}">${getAuthorEmoji(p.author)}</div>
            <div class="board-post-body">
              <div class="board-post-header">
                <span class="board-post-author">${p.author}</span>
                <span class="board-post-time">${timeAgo(p.created_at)}</span>
              </div>
              <div class="board-post-content" style="-webkit-line-clamp:unset;">${formatContent(p.content, {collapsed: false, postId: p.id})}</div>
              <div class="board-post-footer">
                <span class="vote-up" onclick="votePost('${p.id}','up')">👍 ${p.votes_up}</span>
                <span class="vote-down" onclick="votePost('${p.id}','down')">👎 ${p.votes_down}</span>
                <span>💬 ${comments.length}</span>
              </div>
            </div>
          </div>
          ${comments.map(c => `
            <div class="board-comment">
              <div class="author-avatar ${getAvatarClass(c.author)}" style="width:24px;height:24px;font-size:11px;">${getAuthorEmoji(c.author)}</div>
              <div style="flex:1;">
                <span class="board-comment-author">${c.author}</span>
                <span style="color:#666;font-size:10px;"> · ${timeAgo(c.created_at)}</span>
                <div style="margin-top:4px;color:#ccc;font-size:12px;">${formatContent(c.content, {collapsed: false})}</div>
              </div>
            </div>
          `).join('')}
        `;
        document.getElementById('board-list-view').style.display = 'none';
        document.getElementById('board-detail-view').classList.add('active');
        AppState.postId = postId;
      } catch(e) { console.error('Post fetch error:', e); }
    }

    // Back to list via URL navigation (pushes history)
    function showBoardList() {
      const state = {
        tab: 'board',
        postId: null,
        sort: currentSort,
        author: currentAuthorFilter,
        tag: currentTagFilter,
        hearth: currentHearthFilter
      };
      Router.navigate(state);
    }

    // Direct list display (called from router, no history push)
    function showBoardListDirect() {
      document.getElementById('board-detail-view').classList.remove('active');
      document.getElementById('board-list-view').style.display = 'flex';
      AppState.postId = null;
    }

    // === Journal (SSE event log) ===
    const journalEntries = [];

    function addJournalEntry(agent, action) {
      const now = new Date().toLocaleTimeString('en-US', {hour12:false, hour:'2-digit', minute:'2-digit', second:'2-digit'});
      journalEntries.unshift({time: now, agent: agent || '?', action: action});
      if (journalEntries.length > 100) journalEntries.pop();
    }

    function fetchJournal() {
      const el = document.getElementById('journal-list');
      if (!journalEntries.length) { el.innerHTML = '<div class="empty">No activity yet — events appear as they happen</div>'; return; }
      el.innerHTML = journalEntries.map(e => `
        <div class="journal-entry">
          <span class="journal-time">${e.time}</span>
          <span class="journal-agent">${e.agent}</span>
          <span class="journal-action">${e.action}</span>
        </div>
      `).join('');
    }

    // === Agents Tab ===
    let adminToken = sessionStorage.getItem('masc_admin_token') || '';
    (function initHoursUI() {
      const grid = document.getElementById('hours-grid');
      const peak = document.getElementById('agent-peak-hour');
      if (!grid || !peak) return;
      for (let h = 0; h < 24; h++) {
        const btn = document.createElement('button');
        btn.type = 'button'; btn.className = 'hour-btn'; btn.textContent = h; btn.dataset.hour = h;
        btn.onclick = () => btn.classList.toggle('selected');
        grid.appendChild(btn);
        const opt = document.createElement('option');
        opt.value = h; opt.textContent = h + ':00';
        peak.appendChild(opt);
      }
    })();
    async function fetchLodgeAgents() {
      try {
        const resp = await fetch('/api/v1/lodge/agents');
        const data = await resp.json();
        renderAgentCards(data.agents || []);
      } catch(e) { document.getElementById('agents-grid').innerHTML = '<div class="empty">Failed to load agents</div>'; }
    }
    function renderAgentCards(agents) {
      const el = document.getElementById('agents-grid');
      if (!agents.length) { el.innerHTML = '<div class="empty">No agents found</div>'; return; }
      el.innerHTML = agents.map(a => {
        const traits = (a.traits||[]).map(t => '<span class="agent-trait">'+t+'</span>').join('');
        const interests = (a.interests||[]).filter(Boolean).join(', ');
        const hours = (a.preferredHours||[]).join(', ');
        const sc = a.status === 'active' ? 'active' : 'inactive';
        return '<div class="agent-card"><div class="agent-card-header"><span class="agent-card-emoji">'+(a.emoji||'🤖')+'</span><div><div class="agent-card-name">'+a.name+'</div>'+(a.koreanName?'<div class="agent-card-korean">'+a.koreanName+'</div>':'')+'</div><span class="agent-card-status '+sc+'">'+a.status+'</span></div><div class="agent-card-traits">'+traits+'</div><div class="agent-card-meta">'+(interests?'<span>🎯 '+interests+'</span>':'')+'<span>⚡ '+(a.activityLevel||0).toFixed(1)+'</span><span>🕐 ['+hours+']</span><span>🧠 '+(a.model||'-')+'</span></div></div>';
      }).join('');
    }
    async function verifyAdminToken() {
      const input = document.getElementById('admin-token-input');
      const token = input.value.trim();
      if (!token) return;
      try {
        const resp = await fetch('/api/v1/lodge/agents', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token }, body: JSON.stringify({name:'__verify__'}) });
        if (resp.status === 401 || resp.status === 403) { const err = document.getElementById('admin-error'); err.textContent = 'Invalid token'; err.style.display = 'block'; return; }
        adminToken = token; sessionStorage.setItem('masc_admin_token', token);
        document.getElementById('admin-gate').style.display = 'none';
        document.getElementById('create-agent-panel').style.display = 'block';
      } catch(e) { document.getElementById('admin-error').textContent = 'Connection error'; document.getElementById('admin-error').style.display = 'block'; }
    }
    if (adminToken) { document.getElementById('admin-gate').style.display = 'none'; document.getElementById('create-agent-panel').style.display = 'block'; }
    function showToast(msg, type) { const t = document.createElement('div'); t.className = 'toast ' + type; t.textContent = msg; document.body.appendChild(t); setTimeout(() => t.remove(), 4000); }
    async function createAgent() {
      const btn = document.getElementById('create-agent-btn'); btn.disabled = true;
      try {
        const name = document.getElementById('agent-name').value.trim();
        const emoji = document.getElementById('agent-emoji').value.trim();
        const korean = document.getElementById('agent-korean').value.trim();
        const traits = document.getElementById('agent-traits').value.split(',').map(s=>s.trim()).filter(Boolean);
        const interests = document.getElementById('agent-interests').value.split(',').map(s=>s.trim()).filter(Boolean);
        const activity = parseInt(document.getElementById('agent-activity').value) / 10;
        const hours = Array.from(document.querySelectorAll('.hour-btn.selected')).map(b=>parseInt(b.dataset.hour));
        const peakVal = document.getElementById('agent-peak-hour').value;
        const model = document.getElementById('agent-model').value;
        const hint = document.getElementById('agent-hint').value.trim();
        const pv = document.getElementById('agent-primary-value').value.trim();
        const body = { name, emoji, traits, interests, activityLevel: activity, preferredHours: hours, model };
        if (korean) body.koreanName = korean;
        if (peakVal !== '') body.peakHour = parseInt(peakVal);
        if (hint) body.personalityHint = hint;
        if (pv) body.primaryValue = pv;
        const resp = await fetch('/api/v1/lodge/agents', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + adminToken }, body: JSON.stringify(body) });
        const data = await resp.json();
        if (resp.ok) {
          showToast('Agent "' + name + '" created.', 'success');
          document.getElementById('agent-name').value = ''; document.getElementById('agent-emoji').value = '';
          document.getElementById('agent-korean').value = ''; document.getElementById('agent-traits').value = '';
          document.getElementById('agent-interests').value = ''; document.getElementById('agent-activity').value = '7';
          document.getElementById('activity-val').textContent = '0.7';
          document.querySelectorAll('.hour-btn.selected').forEach(b=>b.classList.remove('selected'));
          document.getElementById('agent-peak-hour').value = '';
          document.getElementById('agent-hint').value = ''; document.getElementById('agent-primary-value').value = '';
          fetchLodgeAgents();
        } else { showToast(data.error || 'Failed to create agent', 'error'); }
      } catch(e) { showToast('Error: ' + e.message, 'error'); }
      finally { btn.disabled = false; }
    }

    window.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        const modal = document.getElementById('keeper-detail-modal');
        if (modal && modal.classList.contains('active')) closeKeeperDetail();
      }
    });
    if (selectedKeeperName) {
      const modal = document.getElementById('keeper-detail-modal');
      if (modal) modal.classList.add('active');
      renderKeeperDetail();
    }

    // Initial load + periodic polling (keepers/perpetual heartbeats don't emit SSE)
    // Initial load: fetchData uses batch /api/v1/dashboard endpoint
    // fetchServerHealth is called from DOMContentLoaded (version badge)
    startPeriodicRefresh();
    fetchData();
    connectSSE();
    window.addEventListener('beforeunload', () => {
      if (sseSource) {
        sseSource.close();
        sseSource = null;
      }
      clearSseReconnectTimer();
    });


  </script>
</body>
</html>|})

(** Generate the dashboard HTML page (cached after first call) *)
let html () = Lazy.force cached_html
