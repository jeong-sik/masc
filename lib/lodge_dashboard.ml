(** MASC Lodge Selection Dashboard - Thompson Sampling Statistics

    HTTP endpoint: /dashboard/lodge

    Clean, minimal design matching main dashboard style.

    @author MASC-MCP
    @since 2026-02 *)

(** ETag for dashboard HTML - based on build version *)
let etag () =
  let v = Version.version in
  let hash = Digest.string ("lodge-" ^ v) |> Digest.to_hex in
  String.sub hash 0 12

(** Get agent emoji map from Neo4j via Lodge_heartbeat *)
let get_emoji_map () =
  match Lodge_heartbeat.load_lodge_agents_full () with
  | Ok json ->
    let open Yojson.Safe.Util in
    let agents = member "agents" json |> to_list in
    List.fold_left (fun acc agent ->
      let name = member "name" agent |> to_string in
      let emoji = match member "emoji" agent with `String s -> s | _ -> "🤖" in
      (name, emoji) :: acc
    ) [] agents
  | Error _ -> []

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

(** Format time ago string *)
let format_time_ago secs =
  if secs < 60.0 then "just now"
  else if secs < 3600.0 then Printf.sprintf "%.0fm ago" (secs /. 60.0)
  else if secs < 86400.0 then Printf.sprintf "%.0fh ago" (secs /. 3600.0)
  else Printf.sprintf "%.0fd ago" (secs /. 86400.0)

(** Generate agent list items *)
let agent_list_items () =
  let stats = Lodge_selection.get_all_stats () in
  let sorted = List.sort (fun a b ->
    Int.compare b.Lodge_selection.selections a.Lodge_selection.selections
  ) stats in
  let tick_interval = Env_config.LodgeV2.tick_interval_seconds in
  let emoji_map = get_emoji_map () in
  let max_selections = List.fold_left (fun acc s -> max acc s.Lodge_selection.selections) 1 stats in
  let now = Time_compat.now () in

  String.concat "\n" (List.map (fun (s : Lodge_selection.agent_stats) ->
    let ticks = Lodge_selection.ticks_since_selection ~stats:s ~tick_interval_s:tick_interval in
    let status_class =
      if ticks >= 10 then "status-danger"
      else if ticks >= 6 then "status-warning"
      else "status-ok" in
    let selection_text = if s.selections = 1 then "1 selection" else Printf.sprintf "%d selections" s.selections in
    let emoji = try List.assoc s.name emoji_map with Not_found -> "🤖" in
    let bar_width = int_of_float (100.0 *. float s.selections /. float max_selections) in
    let last_selected =
      if s.last_selected_at > 0.0 then format_time_ago (now -. s.last_selected_at)
      else "never" in
    Printf.sprintf {|<div class="agent-item">
  <div class="agent-bar" style="width: %d%%"></div>
  <span class="agent-dot %s"></span>
  <span class="agent-emoji">%s</span>
  <span class="agent-name">%s</span>
  <span class="agent-time">%s</span>
  <span class="agent-stat">%s</span>
</div>|}
      bar_width status_class emoji s.name last_selected selection_text
  ) sorted)

(** Total selections across all agents *)
let total_selections () =
  let stats = Lodge_selection.get_all_stats () in
  List.fold_left (fun acc s -> acc + s.Lodge_selection.selections) 0 stats

(** Dashboard HTML page *)
let html () = Printf.sprintf {|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Lodge Selection</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', 'Segoe UI', sans-serif;
      background: linear-gradient(135deg, #0f0c29 0%%, #1a1a2e 50%%, #16213e 100%%);
      color: #e0e0e0;
      min-height: 100vh;
      padding: 20px;
    }
    .container { max-width: 900px; margin: 0 auto; }

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
    .back-link {
      color: #4ade80;
      text-decoration: none;
      font-size: 14px;
    }
    .back-link:hover { text-decoration: underline; }

    .stats-grid {
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 15px;
      margin-bottom: 25px;
    }
    @media (max-width: 700px) {
      .stats-grid { grid-template-columns: repeat(2, 1fr); }
    }
    .stat-card {
      background: rgba(255,255,255,0.05);
      border-radius: 12px;
      padding: 20px;
      border: 1px solid rgba(255,255,255,0.1);
    }
    .stat-label {
      font-size: 11px;
      color: #888;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .stat-value {
      font-size: 32px;
      font-weight: bold;
      color: #4ade80;
      margin-top: 5px;
    }
    .stat-value.warning { color: #f59e0b; }
    .stat-value.danger { color: #ef4444; }

    .section {
      background: rgba(255,255,255,0.03);
      border-radius: 12px;
      padding: 20px;
      border: 1px solid rgba(255,255,255,0.08);
    }
    .section-header {
      display: flex;
      align-items: center;
      gap: 8px;
      margin-bottom: 15px;
      color: #4ade80;
      font-size: 14px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }

    .agent-item {
      position: relative;
      display: flex;
      align-items: center;
      padding: 12px 15px;
      background: rgba(255,255,255,0.03);
      border-radius: 8px;
      margin-bottom: 8px;
      overflow: hidden;
    }
    .agent-item:hover { background: rgba(255,255,255,0.06); }
    .agent-item:last-child { margin-bottom: 0; }

    .agent-bar {
      position: absolute;
      left: 0;
      top: 0;
      height: 100%%;
      background: rgba(74, 222, 128, 0.1);
      border-radius: 8px;
      transition: width 0.3s ease;
    }

    .agent-dot {
      position: relative;
      width: 10px;
      height: 10px;
      border-radius: 50%%;
      margin-right: 10px;
      flex-shrink: 0;
    }
    .agent-dot.status-ok { background: #4ade80; }
    .agent-dot.status-warning { background: #f59e0b; }
    .agent-dot.status-danger { background: #ef4444; }

    .agent-emoji {
      position: relative;
      font-size: 18px;
      margin-right: 10px;
    }

    .agent-name {
      position: relative;
      flex: 1;
      font-weight: 500;
      color: #e0e0e0;
    }
    .agent-time {
      position: relative;
      font-size: 12px;
      color: #555;
      margin-right: 15px;
      min-width: 60px;
    }
    .agent-stat {
      position: relative;
      font-size: 13px;
      color: #888;
      font-family: 'SF Mono', Monaco, monospace;
    }

    .legend {
      margin-top: 20px;
      padding-top: 15px;
      border-top: 1px solid rgba(255,255,255,0.1);
      font-size: 12px;
      color: #666;
      display: flex;
      gap: 20px;
    }
    .legend-item {
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .legend-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%%;
    }
    .legend-dot.ok { background: #4ade80; }
    .legend-dot.warn { background: #f59e0b; }
    .legend-dot.bad { background: #ef4444; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>Lodge Selection</h1>
      <a href="/dashboard" class="back-link">← Dashboard</a>
    </header>

    <div class="stats-grid">
      <div class="stat-card">
        <div class="stat-label">Entropy</div>
        <div class="stat-value%s">%.0f%%</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Agents</div>
        <div class="stat-value">%d</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Selections</div>
        <div class="stat-value">%d</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Thompson</div>
        <div class="stat-value">%.0f%%</div>
      </div>
    </div>

    <div class="section">
      <div class="section-header">
        Agent Rankings
      </div>
      %s
      <div class="legend">
        <div class="legend-item"><span class="legend-dot ok"></span> Active</div>
        <div class="legend-item"><span class="legend-dot warn"></span> 6+ ticks</div>
        <div class="legend-item"><span class="legend-dot bad"></span> 10+ ticks</div>
      </div>
    </div>
  </div>
</body>
</html>|}
  (* Entropy color class *)
  (let e = entropy_percentage () in
   if e >= 70.0 then ""
   else if e >= 50.0 then " warning"
   else " danger")
  (* Stats values *)
  (entropy_percentage ())
  (List.length (Lodge_selection.get_all_stats ()))
  (total_selections ())
  (Env_config.LodgeSelection.thompson_weight *. 100.0)
  (* Agent list *)
  (agent_list_items ())
