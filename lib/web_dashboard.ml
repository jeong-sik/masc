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

(** Generate the dashboard HTML page *)
let html () = {|<!DOCTYPE html>
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

    /* Heart animation */
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

    /* Tabs */
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
        <h2>Agents</h2>
        <div class="agent-list" id="agent-list">
          <div class="empty">No agents connected</div>
        </div>
      </div>

      <div class="section">
        <h2>Recent Broadcasts</h2>
        <div class="message-list" id="message-list">
          <div class="empty">No recent messages</div>
        </div>
      </div>
    </div>

    <!-- Board + Journal tabs -->
    <div class="section" style="margin-bottom: 20px;">
      <div class="tab-bar">
        <button class="tab-btn active" onclick="switchTab('board')">📋 Board</button>
        <button class="tab-btn" onclick="switchTab('journal')">📓 Journal</button>
      </div>
      <div id="tab-board">
        <div class="board-controls">
          <label>Sort:</label>
          <select class="sort-select" id="sort-select" onchange="changeSort(this.value)">
            <option value="newest">🕐 Newest first</option>
            <option value="popular">🔥 Most popular</option>
            <option value="oldest">📜 Oldest first</option>
            <option value="controversial">💬 Controversial</option>
          </select>
          <label class="auto-scroll-toggle">
            <input type="checkbox" id="auto-scroll" checked onchange="toggleAutoScroll(this.checked)">
            <span>📜 Auto-scroll</span>
          </label>
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
            <div class="trending-section">
              <div class="trending-title">🔥 Trending</div>
              <div id="trending-tags">
                <span class="trending-tag" style="color:#666;">Loading...</span>
              </div>
            </div>
          </div>
        </div>
      </div>
      <div id="tab-journal" style="display:none;">
        <div class="journal-list" id="journal-list">
          <div class="empty">Loading journal...</div>
        </div>
      </div>
    </div>

    <div class="section">
      <h2>Task Board</h2>
      <div class="task-board">
        <div class="task-column">
          <h3>Todo <span class="count" id="todo-count">0</span></h3>
          <div class="task-list" id="todo-list"></div>
        </div>
        <div class="task-column">
          <h3>In Progress <span class="count" id="progress-count">0</span></h3>
          <div class="task-list" id="progress-list"></div>
        </div>
        <div class="task-column">
          <h3>Done <span class="count" id="done-count">0</span></h3>
          <div class="task-list" id="done-list"></div>
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

    // Fetch initial data via REST API
    async function fetchData() {
      try {
        const [status, tasks, agents, msgs] = await Promise.all([
          apiCall('status'),
          apiCall('tasks'),
          apiCall('agents'),
          apiCall('messages')
        ]);

        updateStats(agents, tasks, status);
        updateAgents(agents);
        updateTasks(tasks);
        updateMessages(msgs);
        updateTempo(status);
      } catch (e) {
        console.error('Fetch error:', e);
      }
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

    // === Connection status ===
    let eventCount = 0;
    let sseConnected = false;
    let fetchDataTimer = null;
    let fetchBoardTimer = null;
    let fallbackIntervalId = null;
    const connStatus = document.getElementById('connection-status');
    const connText = document.getElementById('conn-text');
    const eventCounter = document.getElementById('event-counter');

    function updateConnectionStatus(connected) {
      sseConnected = connected;
      statusDot.classList.toggle('connected', connected);
      connStatus.classList.toggle('connected', connected);
      connStatus.classList.toggle('disconnected', !connected);
      connText.textContent = connected ? 'Connected' : 'Disconnected';
      // Fallback polling only when SSE is disconnected (CPU optimization)
      if (connected) {
        if (fallbackIntervalId) { clearInterval(fallbackIntervalId); fallbackIntervalId = null; }
      } else {
        if (!fallbackIntervalId) fallbackIntervalId = setInterval(fetchData, 15000);
      }
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
      const sseParams = new URLSearchParams();
      if (agent) sseParams.set('agent', agent);
      if (token) sseParams.set('token', token);
      const sseUrl = sseParams.toString() ? ('/sse?' + sseParams.toString()) : '/sse';
      const es = new EventSource(sseUrl);
      es.onopen = () => {
        updateConnectionStatus(true);
        console.log('SSE connected');
      };
      es.onerror = () => {
        updateConnectionStatus(false);
        showToast('Connection lost. Reconnecting...', 'warning');
        setTimeout(connectSSE, 3000);
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

    // === Tab switching ===
    function switchTab(tab) {
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      document.getElementById('tab-board').style.display = tab === 'board' ? 'block' : 'none';
      document.getElementById('tab-journal').style.display = tab === 'journal' ? 'block' : 'none';
      event.target.classList.add('active');
      if (tab === 'journal') fetchJournal();
    }

    // === Board ===
    function timeAgo(ts) {
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

    async function fetchBoard() {
      try {
        const res = await fetch('/api/v1/board');
        const data = await res.json();
        renderBoardList(data.posts || []);
      } catch(e) { console.error('Board fetch error:', e); }
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
      el.innerHTML = filtered.map(p => `
        <div class="board-post" onclick="showPost('${p.id}')">
          <div class="author-avatar ${getAvatarClass(p.author)}">${getAuthorEmoji(p.author)}</div>
          <div class="board-post-body">
            <div class="board-post-header">
              <span class="board-post-author">${p.author}</span>${isVerifiedAgent(p.author) ? '<span class="verified-badge">✓</span>' : ''}
              <span class="board-post-time">${timeAgo(p.created_at)}</span>
            </div>
            <div class="board-post-content">${formatContent(p.content, {collapsed: true, postId: p.id})}</div>
            <div class="board-post-footer">
              <span class="vote-up ${isLiked(p.id) ? 'liked' : ''}" onclick="event.stopPropagation();likePost('${p.id}')">
                ${isLiked(p.id) ? '❤️' : '🤍'} ${p.votes_up}
              </span>
              <span>💬 ${p.reply_count}</span>
              <span class="bookmark-btn ${isBookmarked(p.id) ? 'saved' : ''}" onclick="event.stopPropagation();toggleBookmark('${p.id}')">
                ${isBookmarked(p.id) ? '🔖' : '📑'}
              </span>
              <span class="share-btn" onclick="event.stopPropagation();sharePost('${p.id}')">↗️</span>
              <span style="margin-left:auto;opacity:0.4;font-size:9px">${p.visibility === 'public' ? '🌐' : '🔒'}</span>
            </div>
          </div>
        </div>
      `).join('');
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
    let currentSort = localStorage.getItem('boardSort') || 'newest';
    let autoScrollEnabled = localStorage.getItem('autoScroll') !== 'false';

    // Initialize sort dropdown and auto-scroll
    document.addEventListener('DOMContentLoaded', () => {
      const sortSelect = document.getElementById('sort-select');
      if (sortSelect) sortSelect.value = currentSort;
      const autoScrollCheck = document.getElementById('auto-scroll');
      if (autoScrollCheck) autoScrollCheck.checked = autoScrollEnabled;
      // Fetch server version
      fetch('/health').then(r => r.json()).then(d => {
        const badge = document.getElementById('version-badge');
        if (badge && d.version) badge.textContent = 'v' + d.version;
      }).catch(() => {});
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
      fetchBoard();
    }

    function sortPosts(posts) {
      return [...posts].sort((a, b) => {
        switch (currentSort) {
          case 'newest':
            return b.created_at - a.created_at;
          case 'oldest':
            return a.created_at - b.created_at;
          case 'popular':
            return (b.votes_up - b.votes_down) - (a.votes_up - a.votes_down);
          case 'controversial':
            // High engagement but mixed votes
            const engagementA = a.votes_up + a.votes_down + a.reply_count;
            const engagementB = b.votes_up + b.votes_down + b.reply_count;
            return engagementB - engagementA;
          default:
            return b.created_at - a.created_at;
        }
      });
    }

    function filterByTag(tag) {
      currentTagFilter = currentTagFilter === tag ? null : tag;
      updateTagFilterBar();
      fetchBoard();
    }

    function clearTagFilter() {
      currentTagFilter = null;
      updateTagFilterBar();
      fetchBoard();
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

    async function showPost(postId) {
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
      } catch(e) { console.error('Post fetch error:', e); }
    }

    function showBoardList() {
      document.getElementById('board-detail-view').classList.remove('active');
      document.getElementById('board-list-view').style.display = 'flex';
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

    // Initial load + polling fallback
    fetchData();
    fetchBoard();
    connectSSE();


  </script>
</body>
</html>|}
