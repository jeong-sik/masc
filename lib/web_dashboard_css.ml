(** Dashboard CSS styles — extracted from web_dashboard.ml for maintainability *)

let content = {|  <style>
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
    .agent-status.warn { background: #f97316; box-shadow: 0 0 10px #f97316; }
    .agent-status.dead { background: #ef4444; box-shadow: 0 0 10px #ef4444; }
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
      cursor: pointer;
      transition: border-color 0.15s ease, background 0.15s ease;
    }
    .keeper-kpi:hover {
      border-color: rgba(34,211,238,0.45);
      background: rgba(34,211,238,0.08);
    }
    .keeper-kpi.selected {
      border-color: rgba(74,222,128,0.55);
      background: rgba(74,222,128,0.12);
    }
    .keeper-kpi-label {
      color: #94a3b8;
      font-size: 11px;
      margin-bottom: 4px;
      text-transform: uppercase;
      letter-spacing: 0.4px;
    }
    .keeper-hint {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      width: 14px;
      height: 14px;
      margin-left: 4px;
      border-radius: 999px;
      border: 1px solid rgba(34,211,238,0.45);
      background: rgba(34,211,238,0.14);
      color: #67e8f9;
      font-size: 10px;
      font-weight: 700;
      vertical-align: middle;
      cursor: help;
      text-transform: none;
      letter-spacing: 0;
    }
    .keeper-hint:hover {
      border-color: rgba(74,222,128,0.6);
      color: #bbf7d0;
      background: rgba(74,222,128,0.16);
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
    .keeper-field-dictionary {
      display: flex;
      flex-direction: column;
      gap: 8px;
      max-height: 460px;
      overflow-y: auto;
      padding-right: 2px;
    }
    .keeper-field-search {
      margin-bottom: 8px;
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }
    .keeper-field-search input {
      flex: 1 1 220px;
      min-width: 180px;
      background: rgba(255,255,255,0.08);
      border: 1px solid rgba(148,163,184,0.28);
      border-radius: 8px;
      padding: 6px 10px;
      color: #e2e8f0;
      font-size: 12px;
    }
    .keeper-field-search input:focus {
      outline: none;
      border-color: rgba(34,211,238,0.55);
    }
    .keeper-field-search-count {
      color: #94a3b8;
      font-size: 11px;
      white-space: nowrap;
    }
    .keeper-kpi-detail-grid {
      margin-top: 8px;
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px 12px;
    }
    .keeper-kpi-detail-item {
      background: rgba(2,6,23,0.35);
      border: 1px solid rgba(148,163,184,0.18);
      border-radius: 8px;
      padding: 8px;
    }
    .keeper-kpi-detail-label {
      color: #94a3b8;
      font-size: 10px;
      text-transform: uppercase;
      letter-spacing: 0.35px;
      margin-bottom: 4px;
      font-weight: 600;
    }
    .keeper-kpi-detail-value {
      color: #e2e8f0;
      font-size: 12px;
      line-height: 1.35;
      word-break: break-word;
    }
    @media (max-width: 760px) {
      .keeper-kpi-detail-grid { grid-template-columns: 1fr; }
    }
    .keeper-field-row {
      background: rgba(2,6,23,0.38);
      border: 1px solid rgba(148,163,184,0.18);
      border-radius: 8px;
      padding: 8px;
    }
    .keeper-field-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-bottom: 6px;
    }
    .keeper-field-title {
      color: #e2e8f0;
      font-size: 12px;
      font-weight: 700;
    }
    .keeper-field-key {
      font-family: 'SF Mono', Monaco, monospace;
      font-size: 10px;
      color: #67e8f9;
      border: 1px solid rgba(34,211,238,0.28);
      border-radius: 999px;
      background: rgba(34,211,238,0.14);
      padding: 2px 6px;
    }
    .keeper-field-item {
      display: grid;
      grid-template-columns: 90px minmax(0, 1fr);
      gap: 8px;
      margin-top: 4px;
    }
    .keeper-field-item-label {
      color: #94a3b8;
      font-size: 10px;
      letter-spacing: 0.35px;
      text-transform: uppercase;
      font-weight: 600;
    }
    .keeper-field-item-value {
      color: #cbd5e1;
      font-size: 11px;
      line-height: 1.4;
    }
    @media (max-width: 680px) {
      .keeper-field-item { grid-template-columns: 1fr; gap: 3px; }
    }
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

    /* TRPG Tab — Dark Fantasy */
    .trpg-layout {
      display: grid;
      grid-template-columns: 2fr 1fr;
      gap: 16px;
    }
    @media (max-width: 900px) {
      .trpg-layout { grid-template-columns: 1fr; }
    }
    .trpg-narrative {
      background: rgba(139, 0, 0, 0.06);
      border: 1px solid rgba(220, 38, 38, 0.15);
      border-radius: 12px;
      padding: 20px;
      min-height: 300px;
      max-height: 70vh;
      overflow-y: auto;
      font-family: 'Georgia', serif;
      line-height: 1.8;
      color: #e2e8f0;
    }
    .trpg-narrative::-webkit-scrollbar { width: 6px; }
    .trpg-narrative::-webkit-scrollbar-track { background: transparent; }
    .trpg-narrative::-webkit-scrollbar-thumb { background: rgba(220,38,38,0.3); border-radius: 3px; }
    .trpg-post { margin-bottom: 16px; padding-bottom: 16px; border-bottom: 1px solid rgba(220,38,38,0.1); }
    .trpg-post:last-child { border-bottom: none; margin-bottom: 0; padding-bottom: 0; }
    .trpg-post-meta { font-size: 0.75em; color: #64748b; margin-bottom: 8px; }
    .trpg-post-body .dice-roll {
      display: inline-block;
      background: rgba(251,191,36,0.15);
      color: #fbbf24;
      padding: 2px 8px;
      border-radius: 4px;
      font-family: monospace;
      font-size: 0.9em;
    }
    .trpg-post-body .result-success { color: #4ade80; font-weight: 600; }
    .trpg-post-body .result-fail { color: #ef4444; font-weight: 600; }
    .trpg-post-body .result-great { color: #fbbf24; font-weight: 700; }
    .trpg-post-body .result-catastrophe { color: #dc2626; font-weight: 700; text-shadow: 0 0 8px rgba(220,38,38,0.5); }
    .trpg-post-body .char-name { font-weight: 700; color: #c4b5fd; }
    .typewriter-cursor {
      display: inline-block;
      width: 2px;
      height: 1.1em;
      background: #dc2626;
      animation: trpg-blink 0.7s step-end infinite;
      vertical-align: text-bottom;
      margin-left: 1px;
    }
    @keyframes trpg-blink { 50% { opacity: 0; } }
    .trpg-sidebar { display: flex; flex-direction: column; gap: 12px; }
    .trpg-room-label {
      font-size: 0.78em;
      color: #94a3b8;
      font-family: 'SF Mono', Monaco, monospace;
      background: rgba(2,6,23,0.35);
      border: 1px solid rgba(148,163,184,0.18);
      border-radius: 6px;
      padding: 3px 8px;
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }
    .trpg-flow-state {
      border: 1px solid rgba(148,163,184,0.22);
      border-radius: 10px;
      background: rgba(2,6,23,0.45);
      padding: 8px;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .trpg-flow-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 8px;
    }
    .trpg-flow-title {
      font-size: 0.72em;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      color: #94a3b8;
    }
    .trpg-flow-badge {
      border: 1px solid rgba(148,163,184,0.3);
      border-radius: 999px;
      padding: 2px 8px;
      font-size: 0.7em;
      color: #cbd5e1;
      background: rgba(15,23,42,0.72);
      white-space: nowrap;
    }
    .trpg-flow-badge.ok {
      border-color: rgba(74,222,128,0.45);
      color: #bbf7d0;
      background: rgba(20,83,45,0.4);
    }
    .trpg-flow-badge.running {
      border-color: rgba(251,191,36,0.45);
      color: #fde68a;
      background: rgba(113,63,18,0.4);
    }
    .trpg-flow-badge.warn {
      border-color: rgba(245,158,11,0.45);
      color: #fde68a;
      background: rgba(120,53,15,0.38);
    }
    .trpg-flow-badge.error {
      border-color: rgba(248,113,113,0.48);
      color: #fecaca;
      background: rgba(127,29,29,0.42);
    }
    .trpg-flow-desc {
      font-size: 0.75em;
      line-height: 1.35;
      color: #cbd5e1;
    }
    .trpg-flow-steps {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 6px;
    }
    .trpg-flow-step {
      border: 1px solid rgba(148,163,184,0.2);
      border-radius: 8px;
      background: rgba(15,23,42,0.5);
      padding: 5px 7px;
      font-size: 0.72em;
      color: #94a3b8;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .trpg-flow-step.done {
      border-color: rgba(74,222,128,0.35);
      color: #bbf7d0;
      background: rgba(20,83,45,0.35);
    }
    .trpg-status-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px;
      margin-bottom: 8px;
    }
    .trpg-status-card {
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(148,163,184,0.16);
      border-radius: 8px;
      padding: 9px 10px;
    }
    .trpg-status-label {
      font-size: 0.68em;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: #94a3b8;
      margin-bottom: 4px;
    }
    .trpg-status-value {
      font-size: 0.95em;
      color: #e2e8f0;
      font-weight: 600;
      line-height: 1.2;
      word-break: break-word;
    }
    .trpg-status-value.warn { color: #fbbf24; }
    .trpg-status-value.bad { color: #ef4444; }
    .trpg-party-card {
      background: rgba(255,255,255,0.03);
      border: 1px solid rgba(255,255,255,0.06);
      border-radius: 8px;
      padding: 12px;
    }
    .trpg-party-card .char-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
    .trpg-party-card .char-class { font-size: 0.75em; color: #94a3b8; }
    .trpg-hp-bar { height: 6px; background: rgba(255,255,255,0.08); border-radius: 3px; overflow: hidden; margin-top: 4px; }
    .trpg-hp-bar .hp-fill { height: 100%; border-radius: 3px; transition: width 0.5s ease; }
    .trpg-hp-bar .hp-high { background: #4ade80; }
    .trpg-hp-bar .hp-mid { background: #fbbf24; }
    .trpg-hp-bar .hp-low { background: #ef4444; }
    .trpg-map {
      background: rgba(0,0,0,0.4);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 8px;
      padding: 12px;
      font-family: 'Courier New', monospace;
      font-size: 0.8em;
      line-height: 1.4;
      color: #94a3b8;
      white-space: pre;
      overflow-x: auto;
    }
    .trpg-section-title {
      color: #dc2626;
      font-size: 0.85em;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 8px;
      font-weight: 600;
    }
    .trpg-section-title.with-action {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
    }
    .trpg-history-toggle-btn {
      border: 1px solid rgba(148,163,184,0.35);
      border-radius: 8px;
      background: rgba(15,23,42,0.65);
      color: #cbd5e1;
      font-size: 0.72em;
      padding: 4px 8px;
      cursor: pointer;
      white-space: nowrap;
    }
    .trpg-history-toggle-btn:hover {
      border-color: rgba(34,211,238,0.55);
      color: #e2e8f0;
    }
    .trpg-history-toggle-btn:disabled {
      opacity: 0.45;
      cursor: not-allowed;
      border-color: rgba(100,116,139,0.35);
    }
    .trpg-round-list {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 180px;
      overflow-y: auto;
      margin-bottom: 6px;
    }
    .trpg-round-item {
      background: rgba(255,255,255,0.03);
      border-left: 3px solid rgba(34,211,238,0.8);
      border-radius: 6px;
      padding: 7px 8px;
      font-size: 0.75em;
      color: #cbd5e1;
      line-height: 1.4;
      word-break: break-word;
    }
    .trpg-round-item.timeout { border-left-color: rgba(239,68,68,0.9); }
    .trpg-round-item.unavailable { border-left-color: rgba(251,191,36,0.9); }
    .trpg-round-item.mismatch { border-left-color: rgba(245,158,11,0.9); }
    .trpg-round-item.ok { border-left-color: rgba(74,222,128,0.9); }
    .trpg-round-item .meta { color: #64748b; font-size: 0.95em; }
    .trpg-empty { text-align: center; color: #64748b; padding: 60px 20px; font-style: italic; }
    .trpg-control-box {
      border: 1px solid rgba(148,163,184,0.18);
      border-radius: 10px;
      background: rgba(2,6,23,0.35);
      padding: 10px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .trpg-control-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px;
    }
    .trpg-control-field {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    .trpg-control-field.full { grid-column: 1 / -1; }
    .trpg-control-field label {
      font-size: 0.7em;
      color: #94a3b8;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .trpg-control-field input,
    .trpg-control-field select,
    .trpg-control-field textarea {
      width: 100%;
      box-sizing: border-box;
      background: rgba(15,23,42,0.8);
      border: 1px solid rgba(148,163,184,0.24);
      border-radius: 6px;
      color: #e2e8f0;
      padding: 6px 8px;
      font-size: 0.78em;
    }
    .trpg-control-field textarea {
      min-height: 66px;
      resize: vertical;
      font-family: 'SF Mono', Monaco, monospace;
      line-height: 1.4;
    }
    .trpg-control-field select[multiple] {
      min-height: 108px;
      font-family: 'SF Mono', Monaco, monospace;
      line-height: 1.3;
    }
    .trpg-control-field input:focus,
    .trpg-control-field select:focus,
    .trpg-control-field textarea:focus {
      outline: none;
      border-color: rgba(34,211,238,0.75);
      box-shadow: 0 0 0 2px rgba(34,211,238,0.14);
    }
    .trpg-run-btn {
      border: 1px solid rgba(34,211,238,0.45);
      border-radius: 8px;
      background: rgba(8,47,73,0.86);
      color: #e2e8f0;
      font-weight: 600;
      font-size: 0.82em;
      padding: 8px 10px;
      cursor: pointer;
      transition: all 0.16s ease;
    }
    .trpg-run-btn:hover { border-color: rgba(34,211,238,0.78); background: rgba(14,116,144,0.45); }
    .trpg-run-btn:disabled { opacity: 0.55; cursor: not-allowed; }
    .trpg-run-btn.recommend {
      border-color: rgba(250,204,21,0.75);
      box-shadow: 0 0 0 1px rgba(250,204,21,0.38), 0 0 16px rgba(250,204,21,0.18);
      background: rgba(113,63,18,0.28);
    }
    .trpg-run-btn.secondary {
      border-color: rgba(148,163,184,0.35);
      background: rgba(15,23,42,0.75);
      color: #cbd5e1;
    }
    .trpg-run-btn.secondary:hover {
      border-color: rgba(148,163,184,0.65);
      background: rgba(30,41,59,0.75);
    }
    .trpg-action-row {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 8px;
    }
    .trpg-action-row.compact {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .trpg-assignment-editor {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 220px;
      overflow-y: auto;
      padding-right: 2px;
    }
    .trpg-assignment-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(160px, 220px);
      gap: 8px;
      align-items: center;
      background: rgba(15,23,42,0.52);
      border: 1px solid rgba(148,163,184,0.2);
      border-radius: 8px;
      padding: 6px 8px;
    }
    .trpg-assignment-row .actor {
      min-width: 0;
      font-size: 0.76em;
      color: #e2e8f0;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .trpg-assignment-row .actor .muted {
      color: #94a3b8;
      font-size: 0.95em;
    }
    .trpg-assignment-row select {
      min-width: 0;
      background: rgba(15,23,42,0.85);
      border: 1px solid rgba(148,163,184,0.28);
      border-radius: 6px;
      color: #e2e8f0;
      padding: 5px 8px;
      font-size: 0.75em;
    }
    .trpg-control-help {
      font-size: 0.72em;
      color: #94a3b8;
      line-height: 1.35;
      margin-top: 2px;
    }
    .trpg-selection-summary {
      border: 1px solid rgba(148,163,184,0.22);
      border-radius: 8px;
      background: rgba(2,6,23,0.35);
      padding: 8px;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .trpg-selection-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
    }
    .trpg-selection-badge {
      border: 1px solid rgba(148,163,184,0.35);
      border-radius: 999px;
      padding: 2px 8px;
      font-size: 0.68em;
      color: #cbd5e1;
      background: rgba(15,23,42,0.72);
      white-space: nowrap;
    }
    .trpg-selection-badge.ok {
      border-color: rgba(74,222,128,0.42);
      color: #bbf7d0;
      background: rgba(20,83,45,0.35);
    }
    .trpg-selection-badge.warn {
      border-color: rgba(245,158,11,0.48);
      color: #fde68a;
      background: rgba(120,53,15,0.35);
    }
    .trpg-selection-meta {
      font-size: 0.72em;
      color: #94a3b8;
      text-align: right;
    }
    .trpg-selection-row {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
    }
    .trpg-selection-chip {
      border: 1px solid rgba(148,163,184,0.3);
      border-radius: 999px;
      padding: 1px 6px;
      font-size: 0.67em;
      color: #cbd5e1;
      background: rgba(15,23,42,0.65);
      white-space: nowrap;
    }
    .trpg-selection-chip.dm {
      border-color: rgba(251,191,36,0.48);
      color: #fde68a;
      background: rgba(113,63,18,0.35);
    }
    .trpg-selection-chip.player {
      border-color: rgba(34,211,238,0.48);
      color: #a5f3fc;
      background: rgba(8,47,73,0.38);
    }
    .trpg-selection-chip.actor {
      border-color: rgba(167,139,250,0.45);
      color: #ddd6fe;
      background: rgba(76,29,149,0.33);
    }
    .trpg-selection-issues {
      margin: 0;
      padding-left: 16px;
      display: flex;
      flex-direction: column;
      gap: 2px;
      font-size: 0.72em;
      color: #fecaca;
    }
    .trpg-keeper-quick {
      display: flex;
      flex-direction: column;
      gap: 6px;
      max-height: 180px;
      overflow-y: auto;
      padding-right: 2px;
    }
    .trpg-keeper-chip {
      display: flex;
      align-items: center;
      gap: 6px;
      background: rgba(15,23,42,0.6);
      border: 1px solid rgba(148,163,184,0.22);
      border-radius: 8px;
      padding: 5px 7px;
    }
    .trpg-keeper-name {
      flex: 1;
      min-width: 0;
      font-size: 0.76em;
      color: #e2e8f0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .trpg-keeper-badges {
      display: inline-flex;
      align-items: center;
      gap: 4px;
      flex-wrap: wrap;
      margin-right: 2px;
    }
    .trpg-keeper-tag {
      border: 1px solid rgba(148,163,184,0.3);
      border-radius: 999px;
      padding: 1px 6px;
      font-size: 0.65em;
      line-height: 1.2;
      color: #cbd5e1;
      background: rgba(15,23,42,0.7);
      white-space: nowrap;
    }
    .trpg-keeper-tag.dm {
      border-color: rgba(251,191,36,0.55);
      color: #fde68a;
      background: rgba(113,63,18,0.35);
    }
    .trpg-keeper-tag.player {
      border-color: rgba(34,211,238,0.5);
      color: #a5f3fc;
      background: rgba(8,47,73,0.45);
    }
    .trpg-keeper-tag.lease {
      border-color: rgba(167,139,250,0.5);
      color: #ddd6fe;
      background: rgba(76,29,149,0.35);
    }
    .trpg-keeper-tag.health-live {
      border-color: rgba(34,197,94,0.55);
      color: #bbf7d0;
      background: rgba(20,83,45,0.4);
    }
    .trpg-keeper-tag.health-warm {
      border-color: rgba(59,130,246,0.55);
      color: #bfdbfe;
      background: rgba(30,58,138,0.35);
    }
    .trpg-keeper-tag.health-stale {
      border-color: rgba(245,158,11,0.55);
      color: #fde68a;
      background: rgba(120,53,15,0.38);
    }
    .trpg-keeper-tag.health-offline {
      border-color: rgba(248,113,113,0.55);
      color: #fecaca;
      background: rgba(127,29,29,0.42);
    }
    .trpg-keeper-tag.model {
      border-color: rgba(148,163,184,0.45);
      color: #e2e8f0;
      background: rgba(15,23,42,0.9);
      max-width: 120px;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .trpg-mini-btn {
      border: 1px solid rgba(148,163,184,0.35);
      border-radius: 6px;
      background: rgba(30,41,59,0.72);
      color: #cbd5e1;
      font-size: 0.7em;
      padding: 3px 7px;
      cursor: pointer;
    }
    .trpg-mini-btn:hover {
      border-color: rgba(34,211,238,0.6);
      color: #e2e8f0;
    }
    .trpg-mini-btn:disabled {
      opacity: 0.45;
      cursor: not-allowed;
      border-color: rgba(100,116,139,0.35);
    }
    .trpg-empty-inline {
      font-size: 0.75em;
      color: #94a3b8;
      padding: 6px 2px;
    }
    .trpg-run-status {
      font-size: 0.75em;
      border: 1px solid rgba(148,163,184,0.2);
      border-radius: 8px;
      background: rgba(15,23,42,0.55);
      color: #cbd5e1;
      padding: 8px 9px;
      line-height: 1.45;
      word-break: break-word;
    }
    .trpg-run-status.ok { border-color: rgba(74,222,128,0.35); color: #bbf7d0; }
    .trpg-run-status.error { border-color: rgba(239,68,68,0.45); color: #fecaca; }
    .trpg-run-status.running { border-color: rgba(251,191,36,0.4); color: #fde68a; }
    .trpg-next-action {
      border: 1px solid rgba(34,211,238,0.35);
      border-radius: 10px;
      background: rgba(8,47,73,0.38);
      padding: 10px;
      display: flex;
      flex-direction: column;
      gap: 8px;
    }
    .trpg-next-action .title {
      font-size: 0.78em;
      color: #67e8f9;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      font-weight: 700;
    }
    .trpg-next-action .desc {
      font-size: 0.78em;
      color: #cbd5e1;
      line-height: 1.45;
      word-break: break-word;
    }
    .trpg-next-action .target {
      border: 1px solid rgba(148,163,184,0.35);
      border-radius: 8px;
      background: rgba(15,23,42,0.6);
      color: #e2e8f0;
      font-weight: 600;
      font-size: 0.84em;
      padding: 8px 10px;
      line-height: 1.4;
    }
    .trpg-next-action-controls {
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .trpg-next-action-btn {
      border: 1px solid rgba(34,211,238,0.45);
      border-radius: 8px;
      background: rgba(8,47,73,0.68);
      color: #67e8f9;
      font-weight: 700;
      font-size: 0.78em;
      padding: 8px 10px;
      cursor: pointer;
      text-align: left;
    }
    .trpg-next-action-btn:hover {
      border-color: rgba(103,232,249,0.8);
      color: #cffafe;
    }
    .trpg-next-action-btn:disabled {
      opacity: 0.5;
      cursor: not-allowed;
      border-color: rgba(100,116,139,0.35);
      color: #94a3b8;
      background: rgba(15,23,42,0.55);
    }
    .trpg-next-action-note {
      font-size: 0.72em;
      color: #94a3b8;
      line-height: 1.35;
    }
    .trpg-dev-note {
      margin-top: 6px;
      font-size: 0.72em;
      color: #94a3b8;
    }
    @media (max-width: 600px) {
      .trpg-control-grid { grid-template-columns: 1fr; }
      .trpg-action-row { grid-template-columns: 1fr; }
    }
  </style>|}
