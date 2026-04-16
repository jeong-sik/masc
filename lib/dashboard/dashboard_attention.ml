(** Dashboard Attention — Collect actionable items that require operator intervention.

    Pure functions. Scans room snapshots to produce a sorted list
    of items the operator should act on. Each item includes a suggested MCP tool. *)

(* ===== Types ===== *)

type severity = Critical | Warning | Info

type attention_item = {
  severity : severity;
  category : string;
  summary : string;
  suggested_tool : string;
}

let severity_to_string = function
  | Critical -> "critical"
  | Warning -> "warning"
  | Info -> "info"

let severity_icon = function
  | Critical -> "[!]"
  | Warning -> "[~]"
  | Info -> "[i]"

let severity_order = function Critical -> 0 | Warning -> 1 | Info -> 2

(** Coerce to canonical [Severity.t] for cross-module communication. *)
let to_severity : severity -> Severity.t = function
  | Critical -> Critical
  | Warning -> Warning
  | Info -> Info

(* ===== Detection Rules ===== *)

(** Detect stuck agents: Active/Busy but last_seen > threshold *)
let detect_stuck_agents ~(now : float)
    (snapshots : Dashboard_labels.room_snapshot list) : attention_item list =
  let all_agents =
    List.concat_map (fun (s : Dashboard_labels.room_snapshot) -> s.agents) snapshots
  in
  all_agents
  |> List.filter_map (fun (agent : Types.agent) ->
         match Dashboard_labels.classify_agent ~now agent with
         | Dashboard_labels.Stuck ->
             let task_info =
               match agent.current_task with
               | Some t -> Printf.sprintf ", task: %s" t
               | None -> ""
             in
             let elapsed =
               match Dashboard_labels.parse_iso_timestamp agent.last_seen with
               | Some ts -> Printf.sprintf "%.0fm" ((now -. ts) /. 60.0)
               | None -> "?m"
             in
             Some
               {
                 severity = Critical;
                 category = "stuck_agent";
                 summary =
                   Printf.sprintf "Agent stuck: %s (%s%s)" agent.name elapsed
                     task_info;
                 suggested_tool = "masc_observe_capacity";
               }
         | _ -> None)

(** Detect idle agents when pending tasks exist *)
let detect_idle_with_pending ~(now : float)
    (snapshots : Dashboard_labels.room_snapshot list) : attention_item list =
  let all_agents =
    List.concat_map (fun (s : Dashboard_labels.room_snapshot) -> s.agents) snapshots
  in
  let all_tasks =
    List.concat_map (fun (s : Dashboard_labels.room_snapshot) -> s.tasks) snapshots
  in
  let idle_count =
    List.length
      (List.filter
         (fun a ->
           match Dashboard_labels.classify_agent ~now a with
           | Dashboard_labels.Idle -> true
           | _ -> false)
         all_agents)
  in
  let pending_count =
    List.length
      (List.filter
         (fun (t : Types.task) -> t.task_status = Types.Todo)
         all_tasks)
  in
  if idle_count > 0 && pending_count > 0 then
    [
      {
        severity = Info;
        category = "idle_with_pending";
        summary =
          Printf.sprintf "%d idle agent%s with %d pending task%s" idle_count
            (if idle_count > 1 then "s" else "")
            pending_count
            (if pending_count > 1 then "s" else "");
        suggested_tool = "masc_dispatch_plan";
      };
    ]
  else []

(* ===== Main Collection ===== *)

(** Collect all attention items, sorted by severity (critical first). *)
let collect ~(now : float) (snapshots : Dashboard_labels.room_snapshot list)
    : attention_item list =
  let items =
    detect_stuck_agents ~now snapshots
    @ detect_idle_with_pending ~now snapshots
  in
  List.sort
    (fun a b -> compare (severity_order a.severity) (severity_order b.severity))
    items

(** Format attention items as content lines for a dashboard section. *)
let format_items (items : attention_item list) : string list =
  List.concat_map
    (fun item ->
      [
        Printf.sprintf "%s %s" (severity_icon item.severity) item.summary;
        Printf.sprintf "    -> %s" item.suggested_tool;
      ])
    items

(** One-line summary for compact mode. *)
let compact_summary (items : attention_item list) : string =
  let critical =
    List.length
      (List.filter (fun i -> i.severity = Critical) items)
  in
  let warning =
    List.length
      (List.filter (fun i -> i.severity = Warning) items)
  in
  let total = List.length items in
  if total = 0 then "No action needed"
  else
    let parts = [] in
    let parts =
      if critical > 0 then
        parts @ [ Printf.sprintf "%d critical" critical ]
      else parts
    in
    let parts =
      if warning > 0 then
        parts @ [ Printf.sprintf "%d warning" warning ]
      else parts
    in
    Printf.sprintf "%d item%s (%s)" total
      (if total > 1 then "s" else "")
      (String.concat ", " parts)
