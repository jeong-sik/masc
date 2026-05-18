(** Dashboard_goals_types_timeline — Stage 22 split (was inline in
    dashboard_goals_types.ml).

    Pure JSON projections for the timeline lane: color helpers, task tree
    JSON, tree flatten, goal-detail keeper JSON, generic timeline event
    record + goal-event timeline normalizer, and the [build_goal_timeline]
    composition that merges task / approval / keeper / goal-event streams.

    Depends on [Dashboard_goals_types_accessor] for the [tree_node] /
    [goal_detail_keeper] records and the task / receipt / trust
    inspectors. Re-included by [Dashboard_goals_types] so the public
    surface is unchanged. *)

open Yojson.Safe.Util
open Dashboard_goals_types_accessor

let goal_status_color = function
  | Goal_store.Active -> "#4ade80"
  | Goal_store.Paused -> "#f59e0b"
  | Goal_store.Done -> "#60a5fa"
  | Goal_store.Dropped -> "#6b7280"

let goal_phase_color = function
  | Goal_phase.Executing -> "#4ade80"
  | Goal_phase.Awaiting_verification -> "#f59e0b"
  | Goal_phase.Awaiting_approval -> "#fb7185"
  | Goal_phase.Blocked -> "#ef4444"
  | Goal_phase.Paused -> "#94a3b8"
  | Goal_phase.Completed -> "#60a5fa"
  | Goal_phase.Dropped -> "#6b7280"

let goal_health_color = function
  | "done" -> "#60a5fa"
  | "paused" -> "#f59e0b"
  | "blocked" -> "#ef4444"
  | "at_risk" -> "#f59e0b"
  | "on_track" -> "#4ade80"
  | _ -> "#94a3b8"

let task_status_color status_label =
  match status_label with
  | "pending" -> "#6b7280"
  | "claimed" -> "#f59e0b"
  | "in_progress" -> "#3b82f6"
  | "awaiting_verification" -> "#a78bfa"
  | "completed" -> "#4ade80"
  | "cancelled" -> "#ef4444"
  | _ -> "#888888"

let task_to_tree_json ((task, linkage_source) : Masc_domain.task * string) =
  let status = task_status_label task in
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("goal_id", Json_util.string_opt_to_json task.goal_id);
      ("status", `String status);
      ("status_color", `String (task_status_color status));
      ("priority", `Int task.priority);
      ("goal_id", Json_util.string_opt_to_json task.goal_id);
      ("assignee",
       match task_assignee task with
       | Some assignee -> `String assignee
       | None -> `Null);
      ("goal_id",
       match task.goal_id with
       | Some goal_id -> `String goal_id
       | None -> `Null);
      ("linkage_source", `String linkage_source);
      ("is_terminal", `Bool (task_is_terminal task));
      ("created_at", `String task.created_at);
      ("updated_at", `String (task_updated_at task));
    ]

let rec flatten_tree acc = function
  | [] -> List.rev acc
  | node :: rest ->
      flatten_tree (node :: acc) (node.children @ rest)

let goal_detail_keeper_json (detail : goal_detail_keeper) =
  let meta = detail.meta in
  let latest_receipt = detail.latest_receipt in
  let latest_causal_event =
    match detail.runtime_trust |> member "latest_causal_event" with
    | `Assoc _ as event -> event
    | _ -> `Null
  in
  let latest_execution_outcome =
    match latest_receipt with
    | Some receipt -> receipt_outcome receipt
    | None -> None
  in
  `Assoc
    [
      ("name", `String meta.name);
      ("agent_name", `String meta.agent_name);
      ( "current_task_id",
        match meta.current_task_id with
        | Some task_id -> `String (Keeper_id.Task_id.to_string task_id)
        | None -> `Null );
      ( "active_goal_ids",
        `List (List.map (fun goal_id -> `String goal_id) meta.active_goal_ids) );
      ( "sandbox_profile",
        `String (Keeper_types.sandbox_profile_to_string meta.sandbox_profile) );
      ("network_mode", `String (Keeper_types.network_mode_to_string meta.network_mode));
      ("cascade_name", `String (Keeper_types.cascade_name_of_meta meta));
      ( "approval_profile",
        match latest_receipt with
        | Some receipt ->
            (match receipt_approval_profile receipt with
             | Some profile -> `String profile
             | None -> `Null)
        | None -> `Null );
      ( "cascade_outcome",
        match latest_receipt with
        | Some receipt ->
            (match receipt_cascade_outcome receipt with
             | Some outcome -> `String outcome
             | None -> `Null)
        | None -> `Null );
      ( "latest_execution_outcome",
        match latest_execution_outcome with
        | Some outcome -> `String outcome
        | None -> `Null );
      ( "latest_execution_at",
        match latest_receipt with
        | Some receipt ->
            (match receipt_ended_at receipt with
             | Some ended_at -> `String ended_at
             | None -> `Null)
        | None -> `Null );
      ( "latest_receipt",
        match latest_receipt with
        | Some receipt -> receipt
        | None -> `Null );
      ("runtime_trust", detail.runtime_trust);
      ("latest_causal_event", latest_causal_event);
    ]

let timeline_event_json ~ts ~kind ~lane ~title ~summary ~severity =
  `Assoc
    [
      ("ts", `String ts);
      ("kind", `String kind);
      ("lane", `String lane);
      ("title", `String title);
      ("summary", `String summary);
      ("severity", `String severity);
    ]

let json_member_or_null field = function
  | `Assoc _ as json -> member field json
  | _ -> `Null

let goal_event_timeline_json event =
  let event_type =
    event |> member "event_type" |> to_string_option
    |> Option.value ~default:"goal_event"
  in
  let payload = event |> member "payload" in
  let payload_field field = json_member_or_null field payload in
  let ts = event |> member "ts" |> to_string_option |> Option.value ~default:"" in
  let title, summary, severity =
    match event_type with
    | "goal_phase" ->
        let phase =
          payload_field "phase" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        let actor =
          payload_field "actor" |> json_member_or_null "id" |> to_string_option
        in
        ( "Goal Phase",
          (match actor with
          | Some actor_id -> Printf.sprintf "phase=%s by %s" phase actor_id
          | None -> Printf.sprintf "phase=%s" phase),
          (match phase with
          | "blocked" -> "bad"
          | "awaiting_verification" | "awaiting_approval" | "paused" -> "warn"
          | _ -> "ok") )
    | "goal_verification_opened" ->
        let request = payload_field "request" in
        let request_id =
          request |> json_member_or_null "id" |> to_string_option
          |> Option.value ~default:"request"
        in
        let required =
          request |> json_member_or_null "policy_snapshot"
          |> json_member_or_null "required_verdicts" |> to_int_option
        in
        ( "Goal Verification Opened",
          (match required with
          | Some n -> Printf.sprintf "request %s quorum=%d" request_id n
          | None -> Printf.sprintf "request %s opened" request_id),
          "warn" )
    | "goal_vote" ->
        let vote = payload_field "vote" in
        let decision =
          vote |> json_member_or_null "decision" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        let principal =
          vote |> json_member_or_null "principal" |> json_member_or_null "id"
          |> to_string_option
          |> Option.value ~default:"principal"
        in
        ( "Goal Vote",
          Printf.sprintf "%s voted %s" principal decision,
          if String.equal decision "reject" then "bad" else "ok" )
    | "goal_verification_resolved" ->
        let status =
          payload_field "status" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        ( "Goal Verification Resolved",
          Printf.sprintf "status=%s" status,
          (match status with
          | "approved" -> "ok"
          | "rejected" -> "bad"
          | _ -> "warn") )
    | "goal_approval_opened" ->
        let request_id = payload_field "request_id" |> to_string_option in
        ( "Goal Approval Opened",
          (match request_id with
          | Some id -> Printf.sprintf "request %s is awaiting operator approval" id
          | None -> "goal is awaiting operator approval"),
          "warn" )
    | "goal_approval_resolved" ->
        let decision =
          payload_field "decision" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        ( "Goal Approval Resolved",
          Printf.sprintf "decision=%s" decision,
          if String.equal decision "reject" then "bad" else "ok" )
    | _ ->
        ("Goal Event", event_type, "ok")
  in
  timeline_event_json ~ts ~kind:event_type ~lane:"goal" ~title ~summary ~severity

let build_goal_timeline node linked_keepers approvals goal_events =
  let task_events =
    node.tasks
    |> List.map (fun ((task, linkage_source) : Masc_domain.task * string) ->
           let status = task_status_label task in
           timeline_event_json ~ts:(task_updated_at task) ~kind:"task"
             ~lane:("task:" ^ task.id)
             ~title:task.title
             ~summary:
               (Printf.sprintf "%s · linkage=%s" status linkage_source)
             ~severity:
               (match status with
                | "cancelled" -> "bad"
                | "awaiting_verification" | "claimed" | "in_progress" ->
                    "warn"
                | _ -> "ok"))
  in
  let approval_events =
    approvals
    |> List.filter_map (fun approval ->
           match approval |> member "requested_at_iso" |> to_string_option with
           | None -> None
           | Some requested_at ->
               let approval_id =
                 approval |> member "id" |> to_string_option
                 |> Option.value ~default:"approval"
               in
               let tool_name =
                 approval |> member "tool_name" |> to_string_option
                 |> Option.value ~default:"tool"
               in
               Some
                 (timeline_event_json ~ts:requested_at ~kind:"approval"
                    ~lane:("approval:" ^ approval_id)
                    ~title:(Printf.sprintf "Approval · %s" tool_name)
                    ~summary:
                      (approval |> member "input_preview" |> to_string_option
                       |> Option.value ~default:"pending operator decision")
                    ~severity:"warn"))
  in
  let keeper_events =
    linked_keepers
    |> List.filter_map (fun (detail : goal_detail_keeper) ->
           match trust_latest_event detail.runtime_trust with
           | Some event ->
               let title =
                 event |> member "title" |> to_string_option
                 |> Option.value ~default:(Printf.sprintf "Keeper · %s" detail.meta.name)
               in
               let summary =
                 event |> member "summary" |> to_string_option
                 |> Option.value ~default:"latest keeper event"
               in
               let severity =
                 event |> member "severity" |> to_string_option
                 |> Option.value ~default:"warn"
               in
               let ts =
                 event |> member "ts" |> to_string_option
                 |> Option.value ~default:(Masc_domain.now_iso ())
               in
               Some
                 (timeline_event_json ~ts ~kind:"keeper_runtime"
                    ~lane:("keeper:" ^ detail.meta.name)
                    ~title:(Printf.sprintf "%s · %s" detail.meta.name title)
                    ~summary ~severity)
           | None ->
               match detail.latest_receipt with
               | None -> None
               | Some receipt -> (
                   match receipt_ended_at receipt with
                   | None -> None
                   | Some ended_at ->
                       let outcome =
                         receipt_outcome receipt |> Option.value ~default:"unknown"
                       in
                       let severity =
                         if receipt_has_error receipt then "bad"
                         else if receipt_has_sandbox_risk receipt
                                 || receipt_has_cascade_risk receipt
                         then "warn"
                         else "ok"
                       in
                       Some
                         (timeline_event_json ~ts:ended_at ~kind:"keeper_receipt"
                            ~lane:("keeper:" ^ detail.meta.name)
                            ~title:(Printf.sprintf "Keeper · %s" detail.meta.name)
                            ~summary:
                              (Printf.sprintf "%s · %s"
                                 outcome
                                 (receipt_cascade_name receipt
                                  |> Option.value ~default:(Keeper_types.cascade_name_of_meta detail.meta)))
                            ~severity)))
  in
  let goal_events = List.map goal_event_timeline_json goal_events in
  task_events @ approval_events @ keeper_events @ goal_events
  |> List.sort (fun left right ->
         let lts = left |> member "ts" |> to_string_option |> Option.value ~default:"" in
         let rts = right |> member "ts" |> to_string_option |> Option.value ~default:"" in
         String.compare rts lts)
