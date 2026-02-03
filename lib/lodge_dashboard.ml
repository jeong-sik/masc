(** MASC Lodge Selection Dashboard - Thompson Sampling Statistics

    HTTP endpoint: /dashboard/lodge

    Shows:
    - Agent stats (α, β, selections, votes)
    - Selection entropy (balance metric)
    - Selection distribution chart
    - Recent selection history

    @author MASC-MCP
    @since 2026-02 *)

(** ETag for dashboard HTML - based on build version *)
let etag () =
  let v = Version.version in
  let hash = Digest.string ("lodge-" ^ v) |> Digest.to_hex in
  String.sub hash 0 12

(** Generate agent stats table rows *)
let agent_stats_rows () =
  let stats = Lodge_selection.get_all_stats () in
  let sorted = List.sort (fun a b ->
    Int.compare b.Lodge_selection.selections a.Lodge_selection.selections
  ) stats in
  let tick_interval = Env_config.LodgeV2.tick_interval_seconds in

  String.concat "\n" (List.map (fun (s : Lodge_selection.agent_stats) ->
    let ticks = Lodge_selection.ticks_since_selection ~stats:s ~tick_interval_s:tick_interval in
    let starvation_class = if ticks >= 6 then "warning" else if ticks >= 10 then "danger" else "" in
    let vote_total = s.total_votes_up + s.total_votes_down in
    let vote_ratio = if vote_total > 0
      then Printf.sprintf "%.0f%%" (100.0 *. float s.total_votes_up /. float vote_total)
      else "-" in
    Printf.sprintf {|
      <tr class="%s">
        <td class="agent-name">%s</td>
        <td class="num">%.2f</td>
        <td class="num">%.2f</td>
        <td class="num">%d</td>
        <td class="num">%d</td>
        <td class="num">%s</td>
        <td class="num">%d</td>
        <td class="num">%d</td>
        <td class="num">%d</td>
      </tr>|}
      starvation_class
      s.name s.alpha s.beta s.selections ticks vote_ratio
      s.total_votes_up s.total_votes_down s.posts_created
  ) sorted)

(** Generate selection distribution for chart *)
let selection_distribution_json () =
  let stats = Lodge_selection.get_all_stats () in
  let data = List.map (fun (s : Lodge_selection.agent_stats) ->
    Printf.sprintf {|{"name":"%s","selections":%d,"votes_up":%d,"votes_down":%d}|}
      s.name s.selections s.total_votes_up s.total_votes_down
  ) stats in
  "[" ^ String.concat "," data ^ "]"

(** Calculate entropy as percentage of maximum *)
let entropy_percentage () =
  let stats = Lodge_selection.get_all_stats () in
  let n = List.length stats in
  if n <= 1 then 100.0
  else begin
    let entropy = Lodge_selection.selection_entropy () in
    let max_entropy = Float.log (float n) in
    if max_entropy = 0.0 then 100.0
    else 100.0 *. entropy /. max_entropy
  end

(** Dashboard HTML page *)
let html () = Printf.sprintf {|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Lodge Selection Dashboard</title>
  <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif;
      background: linear-gradient(135deg, #1a1a2e 0%%, #16213e 50%%, #0f3460 100%%);
      color: #e0e0e0;
      min-height: 100vh;
      padding: 20px;
    }
    .container { max-width: 1200px; margin: 0 auto; }

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
      background: linear-gradient(90deg, #f59e0b, #ef4444);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }
    .back-link { color: #4ade80; text-decoration: none; }
    .back-link:hover { text-decoration: underline; }

    .stats-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 15px;
      margin-bottom: 25px;
    }
    .stat-card {
      background: rgba(255,255,255,0.05);
      border-radius: 12px;
      padding: 20px;
      border: 1px solid rgba(255,255,255,0.1);
    }
    .stat-label { font-size: 12px; color: #888; text-transform: uppercase; }
    .stat-value { font-size: 28px; font-weight: 600; margin-top: 5px; }
    .stat-value.good { color: #4ade80; }
    .stat-value.warning { color: #f59e0b; }
    .stat-value.danger { color: #ef4444; }

    .section {
      background: rgba(255,255,255,0.03);
      border-radius: 12px;
      padding: 20px;
      margin-bottom: 20px;
      border: 1px solid rgba(255,255,255,0.08);
    }
    .section h2 {
      font-size: 16px;
      margin-bottom: 15px;
      color: #4ade80;
    }

    table {
      width: 100%%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      padding: 10px 12px;
      text-align: left;
      border-bottom: 1px solid rgba(255,255,255,0.1);
    }
    th {
      background: rgba(255,255,255,0.05);
      font-weight: 600;
      color: #888;
      font-size: 11px;
      text-transform: uppercase;
    }
    td.num { text-align: right; font-family: 'SF Mono', monospace; }
    td.agent-name { font-weight: 500; }
    tr.warning td { background: rgba(245,158,11,0.1); }
    tr.danger td { background: rgba(239,68,68,0.1); }
    tr:hover td { background: rgba(255,255,255,0.05); }

    .charts-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 20px;
    }
    @media (max-width: 800px) {
      .charts-row { grid-template-columns: 1fr; }
    }
    .chart-container {
      background: rgba(255,255,255,0.03);
      border-radius: 12px;
      padding: 20px;
      border: 1px solid rgba(255,255,255,0.08);
    }
    .chart-container h3 {
      font-size: 14px;
      margin-bottom: 15px;
      color: #888;
    }

    .legend {
      font-size: 11px;
      color: #666;
      margin-top: 15px;
      padding-top: 15px;
      border-top: 1px solid rgba(255,255,255,0.1);
    }
    .legend-item { margin: 4px 0; }
    .legend-item span { color: #888; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>🎲 Lodge Selection</h1>
      <a href="/dashboard" class="back-link">← Main Dashboard</a>
    </header>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">Selection Entropy</div>
        <div class="stat-value %s">%.1f%%</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Total Agents</div>
        <div class="stat-value">%d</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Thompson Weight</div>
        <div class="stat-value">%.0f%%</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Max Starvation</div>
        <div class="stat-value">%d ticks</div>
      </div>
    </div>

    <div class="section">
      <h2>Agent Statistics</h2>
      <table>
        <thead>
          <tr>
            <th>Agent</th>
            <th>α (alpha)</th>
            <th>β (beta)</th>
            <th>Selections</th>
            <th>Ticks Since</th>
            <th>Vote %%</th>
            <th>👍</th>
            <th>👎</th>
            <th>Posts</th>
          </tr>
        </thead>
        <tbody>
          %s
        </tbody>
      </table>
      <div class="legend">
        <div class="legend-item"><span>α (alpha):</span> Success prior (increases with upvotes)</div>
        <div class="legend-item"><span>β (beta):</span> Failure prior (increases with downvotes)</div>
        <div class="legend-item"><span>Ticks Since:</span> Ticks since last selection (yellow ≥6, red ≥10)</div>
      </div>
    </div>

    <div class="charts-row">
      <div class="chart-container">
        <h3>Selection Distribution</h3>
        <canvas id="selectionChart"></canvas>
      </div>
      <div class="chart-container">
        <h3>Vote Ratio (Up vs Down)</h3>
        <canvas id="voteChart"></canvas>
      </div>
    </div>
  </div>

  <script>
    const data = %s;

    // Selection Distribution Chart
    new Chart(document.getElementById('selectionChart'), {
      type: 'bar',
      data: {
        labels: data.map(d => d.name),
        datasets: [{
          label: 'Selections',
          data: data.map(d => d.selections),
          backgroundColor: 'rgba(74, 222, 128, 0.6)',
          borderColor: 'rgba(74, 222, 128, 1)',
          borderWidth: 1
        }]
      },
      options: {
        responsive: true,
        plugins: { legend: { display: false } },
        scales: {
          y: { beginAtZero: true, grid: { color: 'rgba(255,255,255,0.1)' } },
          x: { grid: { display: false } }
        }
      }
    });

    // Vote Ratio Chart
    new Chart(document.getElementById('voteChart'), {
      type: 'bar',
      data: {
        labels: data.map(d => d.name),
        datasets: [
          {
            label: 'Upvotes',
            data: data.map(d => d.votes_up),
            backgroundColor: 'rgba(74, 222, 128, 0.6)'
          },
          {
            label: 'Downvotes',
            data: data.map(d => d.votes_down),
            backgroundColor: 'rgba(239, 68, 68, 0.6)'
          }
        ]
      },
      options: {
        responsive: true,
        plugins: { legend: { position: 'bottom' } },
        scales: {
          y: { beginAtZero: true, stacked: true, grid: { color: 'rgba(255,255,255,0.1)' } },
          x: { stacked: true, grid: { display: false } }
        }
      }
    });
  </script>
</body>
</html>|}
  (* Stats grid values *)
  (let e = entropy_percentage () in if e >= 70.0 then "good" else if e >= 50.0 then "warning" else "danger")
  (entropy_percentage ())
  (List.length (Lodge_selection.get_all_stats ()))
  (Env_config.LodgeSelection.thompson_weight *. 100.0)
  Env_config.LodgeSelection.max_starvation_ticks
  (* Table rows *)
  (agent_stats_rows ())
  (* Chart data *)
  (selection_distribution_json ())
