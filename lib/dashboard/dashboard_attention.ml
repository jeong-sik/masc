(** Dashboard Attention — items an operator may want to look at.

    Pure functions. Scans workspace snapshots and the operator task list and
    returns the items sorted by severity. Each item carries a suggested next
    step: an MCP tool name, or a sentence when no single tool applies. *)

(* ===== Masc_domain ===== *)

type severity = Critical | Warning | Info

type attention_item = {
  severity : severity;
  summary : string;
  suggested_tool : string;
}

let severity_icon = function
  | Critical -> "[!]"
  | Warning -> "[~]"
  | Info -> "[i]"

let severity_order = function Critical -> 0 | Warning -> 1 | Info -> 2

(* ===== Detection Rules ===== *)

(** Detect stuck agents: Active/Busy but last_seen > threshold *)
let detect_stuck_agents ~(now : float)
    (snapshots : Dashboard_labels.workspace_snapshot list) : attention_item list =
  let all_agents =
    List.concat_map (fun (s : Dashboard_labels.workspace_snapshot) -> s.agents) snapshots
  in
  all_agents
  |> List.filter_map (fun (agent : Masc_domain.agent) ->
         (* Enumerate every [Dashboard_labels.agent_group] variant so
            the compiler flags any new group added. Only [Stuck] yields
            an attention item; [Working], [Idle], [Offline] do not. A
            future group (e.g. [Recovering]) would silently inherit
            "no attention" under the previous [_ -> None] catch-all.
            Same FSM Sparse Match anti-pattern as PRs #14716, #14790,
            #14806, #14810, #14816. *)
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
                 summary =
                   Printf.sprintf "Agent stuck: %s (%s%s)" agent.name elapsed
                     task_info;
                 suggested_tool = "masc_agent_timeline";
               }
         | Dashboard_labels.Working
         | Dashboard_labels.Idle
         | Dashboard_labels.Offline -> None)

(** Detect idle agents when pending tasks exist *)
let detect_idle_with_pending ~(now : float)
    (snapshots : Dashboard_labels.workspace_snapshot list) : attention_item list =
  let all_agents =
    List.concat_map (fun (s : Dashboard_labels.workspace_snapshot) -> s.agents) snapshots
  in
  let all_tasks =
    List.concat_map (fun (s : Dashboard_labels.workspace_snapshot) -> s.tasks) snapshots
  in
  let idle_count =
    List.length
      (List.filter
         (fun a ->
           (* Same exhaustive-enumeration reasoning as
              [detect_stuck_agents] above. *)
           match Dashboard_labels.classify_agent ~now a with
           | Dashboard_labels.Idle -> true
           | Dashboard_labels.Working
           | Dashboard_labels.Stuck
           | Dashboard_labels.Offline -> false)
         all_agents)
  in
  let pending_count =
    List.length
      (List.filter
         (fun (t : Masc_domain.task) -> t.task_status = Masc_domain.Todo)
         all_tasks)
  in
  if idle_count > 0 && pending_count > 0 then
    [
      {
        severity = Info;
        summary =
          Printf.sprintf "%d idle agent%s with %d pending task%s" idle_count
            (if idle_count > 1 then "s" else "")
            pending_count
            (if pending_count > 1 then "s" else "");
        suggested_tool = "masc_add_task";
      };
    ]
  else []

(** Keeper routing observations shared with rejection delivery. A missing
    route is not proof that the owner has stopped, so neither case is graded
    as a critical abandoned task. A submission awaiting a verdict is [Info]:
    the list does not know whether its review is running. *)
let detect_operator_tasks (items : Operator_task_attention.item list)
    : attention_item list =
  List.map
    (fun item ->
       let severity =
         match item with
         | Operator_task_attention.Held_without_keeper_route _ -> Warning
         | Operator_task_attention.Producer_record_unreadable _ -> Warning
         | Operator_task_attention.Awaiting_verdict _ -> Info
       in
       { severity
       ; summary = Operator_task_attention.summary ~ko:false item
       ; suggested_tool = Operator_task_attention.next_step item
       })
    items

(* ===== Main Collection ===== *)

(** Collect all attention items, sorted by severity (critical first). *)
let collect ~(now : float) ~(operator_tasks : Operator_task_attention.item list)
    (snapshots : Dashboard_labels.workspace_snapshot list)
    : attention_item list =
  let items =
    detect_stuck_agents ~now snapshots
    @ detect_idle_with_pending ~now snapshots
    @ detect_operator_tasks operator_tasks
  in
  List.sort
    (fun a b -> compare (severity_order a.severity) (severity_order b.severity))
    items

(** Format attention items as content lines for a dashboard section. Items
    are sorted by severity, so neighbours often share one suggested action. A
    run of items with the same action lists it once, after the run, with the
    number of items above it when there is more than one. *)
let format_items (items : attention_item list) : string list =
  let runs =
    List.fold_right
      (fun item runs ->
        match runs with
        | [] -> [ (item.suggested_tool, [ item ]) ]
        | (tool, members) :: later ->
          if String.equal tool item.suggested_tool
          then (tool, item :: members) :: later
          else (item.suggested_tool, [ item ]) :: runs)
      items []
  in
  List.concat_map
    (fun (tool, members) ->
      let count = List.length members in
      List.map
        (fun item -> Printf.sprintf "%s %s" (severity_icon item.severity) item.summary)
        members
      @ [ (if count > 1
           then Printf.sprintf "    -> %s (%d items above)" tool count
           else Printf.sprintf "    -> %s" tool)
        ])
    runs

(** One-line summary for compact mode. Every severity that has an item is
    named, so the counts in parentheses add up to the total. *)
let compact_summary (items : attention_item list) : string =
  let critical, warning, info =
    List.fold_left
      (fun (critical, warning, info) item ->
        match item.severity with
        | Critical -> critical + 1, warning, info
        | Warning -> critical, warning + 1, info
        | Info -> critical, warning, info + 1)
      (0, 0, 0) items
  in
  match critical + warning + info with
  | 0 -> "No action needed"
  | total ->
    let part count label =
      if count > 0 then [ Printf.sprintf "%d %s" count label ] else []
    in
    Printf.sprintf "%d item%s (%s)" total
      (if total > 1 then "s" else "")
      (String.concat ", "
         (part critical "critical" @ part warning "warning" @ part info "info"))
