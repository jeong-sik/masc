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

open Dashboard_goals_types_accessor

let json_to_string_opt = function | `String s -> Some s | _ -> None
let goal_phase_color = function
  | Goal_phase.Executing -> "#4ade80"
  (* RFC-0387 stage 2: the proof-pending hue matches the Task domain's
     [AwaitingVerification] so the gate reads as the same shape of wait. *)
  | Goal_phase.Verifying -> "#a78bfa"
  | Goal_phase.Completed -> "#60a5fa"
  | Goal_phase.Dropped -> "#6b7280"

(* Exhaustive on [task_status], not a string match with a grey catch-all. The
   catch-all silently absorbed every label it did not recognise, which is how a
   second status vocabulary survived here: "pending"/"completed" coloured fine
   while the SSOT spelling "todo"/"done" fell through to grey. A new status now
   breaks this match instead of rendering as unknown. *)
let task_status_color (status : Masc_domain.task_status) =
  match status with
  | Masc_domain.Todo -> "#6b7280"
  | Masc_domain.Claimed _ -> "#f59e0b"
  | Masc_domain.InProgress _ -> "#3b82f6"
  | Masc_domain.AwaitingVerification _ -> "#a78bfa"
  | Masc_domain.Done _ -> "#4ade80"
  | Masc_domain.Cancelled _ -> "#ef4444"

let task_to_tree_json (task : Masc_domain.task) =
  `Assoc
    ([
      ("id", `String task.id);
      ("title", `String task.title);
      ("status", `String (Masc_domain.task_status_to_string task.task_status));
      ("status_color", `String (task_status_color task.task_status));
      ("priority", `Int task.priority);
      ("assignee", Json_util.string_opt_to_json (task_assignee task));
      ("is_terminal", `Bool (task_is_terminal task));
      ("created_at", `String task.created_at);
      ("updated_at", `String (task_updated_at task));
    ]
    (* A cancellation that has aged out of the execution payload reaches the
       surface through this tree alone. Without these the card degrades to a
       bare "cancelled" while the status it was built from holds both the actor
       and the reason. [reason] is emitted only when the canceller gave one:
       an absent field and an empty one are different facts. *)
    @ (match task.task_status with
       | Masc_domain.Cancelled { cancelled_by; reason; _ } ->
         [ ("cancelled_by", `String cancelled_by) ]
         (* [stated_reason], not the bare status field: a cancellation whose
            explanation arrived on the handoff context committed with one, and
            this payload carries no handoff_context for the reader to fall back
            through. Serializing only [Cancelled.reason] left the card blank for
            exactly the cancellations the broadcast and the author wake explain. *)
         @ (match
              Masc_domain.stated_reason
                ~reason
                ~handoff_context:task.handoff_context
            with
            | None -> []
            | Some reason -> [ ("reason", `String reason) ])
       | Masc_domain.Todo
       | Masc_domain.Claimed _
       | Masc_domain.InProgress _
       | Masc_domain.AwaitingVerification _
       | Masc_domain.Done _ -> []))

let count_assoc_json preferred_keys table =
  let keys =
    Hashtbl.fold (fun key _ acc -> key :: acc) table []
    |> List.sort_uniq String.compare
  in
  let ordered_keys =
    preferred_keys
    @ List.filter (fun key -> not (List.mem key preferred_keys)) keys
  in
  `Assoc
    (List.map
       (fun key -> key, `Int (Option.value ~default:0 (Hashtbl.find_opt table key)))
       ordered_keys)

let task_summary_to_json tasks =
  let by_status = Hashtbl.create 8 in
  let bump table key =
    let current = Option.value ~default:0 (Hashtbl.find_opt table key) in
    Hashtbl.replace table key (current + 1)
  in
  let done_count = ref 0 in
  let open_count = ref 0 in
  let terminal_count = ref 0 in
  let awaiting_verification_count = ref 0 in
  let cancelled_count = ref 0 in
  let unassigned_count = ref 0 in
  List.iter
    (fun (task : Masc_domain.task) ->
      bump by_status (Masc_domain.task_status_to_string task.task_status);
      if task_is_done task then incr done_count;
      if task_is_terminal task then incr terminal_count else incr open_count;
      (* One exhaustive match over the variant instead of two string equalities
         against a label that had its own spelling. *)
      (match task.task_status with
       | Masc_domain.AwaitingVerification _ -> incr awaiting_verification_count
       | Masc_domain.Cancelled _ -> incr cancelled_count
       | Masc_domain.Todo
       | Masc_domain.Claimed _
       | Masc_domain.InProgress _
       | Masc_domain.Done _ -> ());
      match task_assignee task with None -> incr unassigned_count | Some _ -> ())
    tasks;
  let total = List.length tasks in
  let completion_pct =
    if total = 0 then
      `Null
    else
      `Int
        (int_of_float
           (float_of_int !done_count /. float_of_int total *. 100.0))
  in
  `Assoc
    [
      ("total", `Int total);
      ("done", `Int !done_count);
      ("open", `Int !open_count);
      ("terminal", `Int !terminal_count);
      ("awaiting_verification", `Int !awaiting_verification_count);
      ("cancelled", `Int !cancelled_count);
      ("unassigned", `Int !unassigned_count);
      ("completion_pct", completion_pct);
      (* Preferred keys are the Variant SSOT spelling. They read "pending" and
         "completed" until the emitter moved to [task_status_to_string]; the
         list was not updated with it, so two of the six keys named states the
         counter could no longer contain. Derived from the variant so the two
         cannot drift again. *)
      ( "by_status",
        count_assoc_json
          (List.map
             Masc_domain.task_status_to_string
             [ Masc_domain.Todo
             ; Masc_domain.Claimed { assignee = ""; claimed_at = "" }
             ; Masc_domain.InProgress { assignee = ""; started_at = "" }
             ; Masc_domain.AwaitingVerification
                 { assignee = ""
                 ; started_at = ""
                 ; submitted_at = ""
                 ; intent = Complete_task
                 ; verification_id = ""
                 }
             ; Masc_domain.Done { assignee = ""; completed_at = ""; notes = None }
             ; Masc_domain.Cancelled
                 { cancelled_by = ""; cancelled_at = ""; reason = None }
             ])
          by_status );
    ]

let rec flatten_tree acc = function
  | [] -> List.rev acc
  | node :: rest ->
      flatten_tree (node :: acc) (node.children @ rest)

let goal_detail_keeper_json (detail : goal_detail_keeper) =
  let meta = detail.meta in
  let latest_receipt = detail.latest_receipt in
  let latest_causal_event =
    match Json_util.assoc_member_opt "latest_causal_event" detail.runtime_trust with
    | Some (`Assoc _ as event) -> event
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
      ( "current_task_id",
        match meta.current_task_id with
        | Some task_id -> `String (Keeper_id.Task_id.to_string task_id)
        | None -> `Null );
      ( "sandbox_profile",
        `String (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile) );
      ("network_mode", `String (Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode));
      ("runtime_id", `String (Keeper_meta_contract.runtime_id_of_meta meta));
      ( "runtime_outcome",
        Json_util.string_opt_to_json (Option.bind latest_receipt receipt_runtime_outcome) );
      ( "latest_execution_outcome",
        Json_util.string_opt_to_json latest_execution_outcome );
      ( "latest_execution_at",
        Json_util.string_opt_to_json (Option.bind latest_receipt receipt_ended_at) );
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
  | `Assoc _ as json -> Option.value ~default:`Null (Json_util.assoc_member_opt field json)
  | _ -> `Null

let goal_event_timeline_json event =
  let event_type =
    Json_util.get_string event "event_type"
    |> Option.value ~default:"goal_event"
  in
  let payload = Option.value ~default:`Null (Json_util.assoc_member_opt "payload" event) in
  let payload_field field = json_member_or_null field payload in
  let ts = Json_util.get_string event "ts" |> Option.value ~default:"" in
  let title, summary, severity =
    match event_type with
    | "goal_phase" ->
        (* Each [Option.value ~default:"unknown"] in this match used to
           render in the dashboard timeline as a verbatim value
           (e.g. "phase=unknown by ...", "principal voted unknown",
           "status=unknown", "decision=unknown") that the operator
           reads when investigating a stuck goal.  "unknown" collides
           with any legitimate value named "unknown" in the producer
           event stream, so the operator cannot tell "the payload
           field was missing" apart from "the producer sent the
           string 'unknown'".  Bracketed markers are not emitted by
           any producer, so a non-zero appearance is an unambiguous
           producer-side fix signal. *)
        let phase =
          payload_field "phase" |> json_to_string_opt
          |> Option.value ~default:"<missing payload.phase>"
        in
        (* [payload.actor] is the agent name, a bare string: every producer
           builds it that way ([gate_event_payload] and the two inline
           payloads in workspace_goals.ml). Reading it as [actor.id] made
           [json_member_or_null] return [`Null] for every event ever written,
           so the summary silently lost the actor — the one field that says
           who moved the goal. Marked like [phase] when absent, so a producer
           that stops writing it shows up instead of disappearing.

           The alternative — dropping the "by %s" clause when the field is
           absent — is what this change is fixing. The summary read
           "phase=blocked" for months and read correctly, which is exactly
           why nobody looked. *)
        let actor =
          payload_field "actor" |> json_to_string_opt
          (* NDT-OK: bracketed marker, not a permissive default. *)
          |> Option.value ~default:"<missing payload.actor>"
        in
        (* Enumerated over [Goal_phase.t] rather than matched on the string, so
           adding a phase to the variant fails this match instead of landing in
           a healthy-looking bucket by default.

           A phase this build cannot parse — including the [<missing ...>]
           marker above — is `warn`, not `ok`. The marker is loud in the summary
           text but the old `_ -> "ok"` made the row render neutral, the same as
           a healthy event, so a corrupted producer event was invisible to an
           operator scanning by colour. Live ledger check before the change: all
           78 goal_phase rows carry one of the six known tokens, so nothing
           in the store moves to `warn` because of this. *)
        let severity =
          match Goal_phase.of_string phase with
          | Some (Executing | Verifying | Completed | Dropped) -> "ok"
          | None -> "warn"
        in
        ("Goal Phase", Printf.sprintf "phase=%s by %s" phase actor, severity)
    | _ ->
        ("Goal Event", event_type, "ok")
  in
  timeline_event_json ~ts ~kind:event_type ~lane:"goal" ~title ~summary ~severity

let task_timeline_summary (task : Masc_domain.task) =
  let status = Masc_domain.task_status_to_string task.task_status in
  let actor =
    match task.task_status with
    | Masc_domain.Todo ->
        Option.map (fun name -> "created by " ^ name) task.created_by
    | Masc_domain.Claimed { assignee; _ } -> Some ("claimed by " ^ assignee)
    | Masc_domain.InProgress { assignee; _ } -> Some ("working: " ^ assignee)
    | Masc_domain.AwaitingVerification { assignee; _ } ->
        Some ("submitted by " ^ assignee)
    | Masc_domain.Done { assignee; _ } -> Some ("completed by " ^ assignee)
    | Masc_domain.Cancelled { cancelled_by; _ } ->
        Some ("cancelled by " ^ cancelled_by)
  in
  let handoff =
    Option.bind task.handoff_context (fun context ->
      let summary = String.trim context.summary in
      if String.equal summary "" then None
      else
        Some
          (match context.updated_by with
           | Some author when not (String.equal (String.trim author) "") ->
               Printf.sprintf "handoff by %s: %s" (String.trim author) summary
           | Some _ | None -> "handoff: " ^ summary))
  in
  status :: List.filter_map Fun.id [ actor; handoff ] |> String.concat " · "

let build_goal_timeline node linked_keepers approvals goal_events =
  let task_events =
    node.tasks
    |> List.map (fun (task : Masc_domain.task) ->
           let status = Masc_domain.task_status_to_string task.task_status in
           timeline_event_json ~ts:(task_updated_at task) ~kind:"task"
             ~lane:("task:" ^ task.id)
             ~title:task.title
             ~summary:(task_timeline_summary task)
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
           match Json_util.get_float approval "requested_at" with
           | None -> None
           | Some requested_at_unix ->
               let requested_at =
                 Masc_domain.iso8601_of_unix_seconds requested_at_unix
               in
               let approval_id =
                 Json_util.get_string approval "id"
                 |> Option.value ~default:"approval"
               in
               let tool_name =
                 Json_util.get_string approval "tool_name"
                 |> Option.value ~default:"tool"
               in
               Some
                 (timeline_event_json ~ts:requested_at ~kind:"approval"
                    ~lane:("approval:" ^ approval_id)
                    ~title:(Printf.sprintf "Approval · %s" tool_name)
                    ~summary:
                      (Json_util.get_string approval "input_preview"
                       |> Option.value ~default:"pending operator decision")
                    ~severity:"warn"))
  in
  let keeper_events =
    linked_keepers
    |> List.filter_map (fun (detail : goal_detail_keeper) ->
           match trust_latest_event detail.runtime_trust with
           | Some event ->
               let title =
                 Json_util.get_string event "title"
                 |> Option.value ~default:(Printf.sprintf "Keeper · %s" detail.meta.name)
               in
               let summary =
                 Json_util.get_string event "summary"
                 |> Option.value ~default:"latest keeper event"
               in
               let severity =
                 Json_util.get_string event "severity"
                 |> Option.value ~default:"warn"
               in
               let ts =
                 Json_util.get_string event "ts"
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
                         receipt_outcome receipt
                         |> Option.value ~default:"<missing receipt.outcome>"
                       in
                       let severity =
                         if receipt_has_error receipt then "bad" else "ok"
                       in
                       let receipt_runtime_summary =
                         match receipt_runtime_id receipt with
                         | Some runtime_id -> runtime_id
                         | None -> "<missing receipt.runtime.name>"
                       in
                       Some
                         (timeline_event_json ~ts:ended_at ~kind:"keeper_receipt"
                            ~lane:("keeper:" ^ detail.meta.name)
                            ~title:(Printf.sprintf "Keeper · %s" detail.meta.name)
                            ~summary:
                              (Printf.sprintf "%s · %s"
                                 outcome
                                 receipt_runtime_summary)
                            ~severity)))
  in
  let goal_events = List.map goal_event_timeline_json goal_events in
  task_events @ approval_events @ keeper_events @ goal_events
  |> List.sort (fun left right ->
         let lts = Json_util.get_string left "ts" |> Option.value ~default:"" in
         let rts = Json_util.get_string right "ts" |> Option.value ~default:"" in
         String.compare rts lts)
