let json_member key json =
  match Json_util.assoc_member_opt key json with
  | Some v -> v
  | None -> `Null
let json_int_opt_member key json = Json_util.get_int json key
let json_float_opt_member key json = Json_util.get_float json key
let json_string_opt_member key json = Json_util.get_string_nonempty json key

let json_string_opt_value = function
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let json_bool_opt_member key json = Json_util.get_bool json key

let assoc_bool_default key ~default fields =
  match List.assoc_opt key fields with
  | Some (`Bool value) -> value
  | _ -> default

let json_string_list_member = Json_util.json_string_list_member

let assoc_string_opt key fields =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None

let take = List.take

let goal_ids_of_json json =
  match json_string_list_member "goal_ids" json with
  | [] -> (
      match json_string_opt_member "goal_id" json with
      | Some goal_id -> [ goal_id ]
      | None -> [])
  | goal_ids -> goal_ids

let keeper_turn_id_of_json json =
  match json_int_opt_member "keeper_turn_id" json with
  | Some _ as value -> value
  | None -> (
      match json_int_opt_member "turn_id" json with
      | Some _ as value -> value
      | None -> json_int_opt_member "turn" json)

let timeline_event_json ?trace_id ?keeper_turn_id ?task_id ?(goal_ids = [])
    ?next_human_action ?observed_at_unix ?(observation_only = false)
    ~ts_unix ~kind ~title ~summary ~severity () =
  let observed_at_unix = Option.value ~default:ts_unix observed_at_unix in
  `Assoc
    [
      ("kind", `String kind);
      ("ts", `String (Masc_domain.iso8601_of_unix_seconds ts_unix));
      ("ts_unix", `Float ts_unix);
      ("observed_at", `String (Masc_domain.iso8601_of_unix_seconds observed_at_unix));
      ("observed_at_unix", `Float observed_at_unix);
      ("observation_only", `Bool observation_only);
      ("trace_id", Json_util.string_opt_to_json trace_id);
      ("keeper_turn_id", Json_util.int_opt_to_json keeper_turn_id);
      ("task_id", Json_util.string_opt_to_json task_id);
      ("goal_ids", `List (List.map (fun goal_id -> `String goal_id) goal_ids));
      ("title", `String title);
      ("summary", `String summary);
      ("severity", `String severity);
      ("next_human_action", Json_util.string_opt_to_json next_human_action);
    ]

let severity_of_decision = function
  | "run" -> "ok"
  | "skip" -> "warn"
  | _ -> "warn"

let severity_of_tool_call = function
  | Some true -> "ok"
  | Some false -> "bad"
  | None -> "warn"

let outcome_word_of_tool_call = function
  | Some true -> "succeeded"
  | Some false -> "failed"
  | None -> "outcome unknown"

(* Severities follow how the writer already treats each event: [Log.Keeper.error]
   at the site becomes "bad", [Log.Keeper.warn] becomes "warn", and the paths
   that log nothing because they are the success path become "ok". *)
let severity_of_approval_event (event : Keeper_approval.Audit.event)
    decision_kind =
  match event with
  | Gate_allowed | Grant_consumed | Rule_created | Rule_deleted
  | Auto_judge_operator_retry_started | Summary_updated ->
      "ok"
  | Pending | Gate_exact_rule_expired | Gate_grant_unavailable
  | Auto_judge_block_observation_superseded
  | Auto_judge_restart_worker_recovered | Auto_judge_restart_judgment_recovered
    ->
      "warn"
  | Gate_exact_rule_store_degraded -> "bad"
  | Resolved -> (
      (* The writer records the decision on its own axis; reading that is what
         the old substring scan for "reject" over the rendered decision text was
         approximating. An approval whose text merely mentioned the word came
         out as a rejection. *)
      match decision_kind with
      | Some Keeper_approval.Audit.Decision_reject -> "bad"
      | Some Keeper_approval.Audit.Decision_approve | None -> "ok")

let tool_call_timeline_event json =
  match json_float_opt_member "ts" json, json_string_opt_member "tool" json with
  | Some ts_unix, Some tool_name ->
      let success = json_bool_opt_member "success" json in
      let outcome_word = outcome_word_of_tool_call success in
      let duration_ms = json_float_opt_member "duration_ms" json in
      let summary =
        match duration_ms with
        | Some ms ->
            Printf.sprintf "%s %s in %.0fms" tool_name outcome_word ms
        | None -> Printf.sprintf "%s %s" tool_name outcome_word
      in
      Some
        (timeline_event_json
           ?trace_id:(json_string_opt_member "trace_id" json)
           ?keeper_turn_id:(keeper_turn_id_of_json json)
           ?task_id:(json_string_opt_member "task_id" json)
           ~goal_ids:(goal_ids_of_json json)
           ~ts_unix ~kind:"tool_call"
           ~title:(Printf.sprintf "Tool · %s" tool_name)
           ~summary ~severity:(severity_of_tool_call success) ())
  | _ -> None

let live_pending_approval_timeline_event json =
  match json_float_opt_member "requested_at" json with
  | None -> None
  | Some ts_unix ->
      let tool_name =
        json_string_opt_member "tool_name" json |> Option.value ~default:"tool"
      in
      let approval_id =
        json_string_opt_member "id" json |> Option.value ~default:"unknown"
      in
      let task_id = json_string_opt_member "task_id" json in
      let summary =
        Printf.sprintf
          "operator decision requested · id=%s · Keeper lane remains available"
          approval_id
      in
      Some
        (timeline_event_json
           ?task_id
           ~ts_unix ~kind:"approval_pending_live"
           ~title:(Printf.sprintf "Operator Decision Pending · %s" tool_name)
           ~summary
           ~severity:"warn"
           ~observation_only:true
           ~next_human_action:"resolve_approval"
           ())

let approval_event_timeline_event json =
  match json_float_opt_member "ts" json, json_string_opt_member "event" json with
  | Some ts_unix, Some event ->
      let tool_name =
        json_string_opt_member "tool" json |> Option.value ~default:"tool"
      in
      let keeper_name = json_string_opt_member "keeper" json in
      let approval_summary text =
        match keeper_name with
        | Some keeper when String.trim keeper <> "" ->
            Printf.sprintf "%s · keeper=%s" text keeper
        | _ -> text
      in
      let decision = json_string_opt_member "decision" json in
      let decision_kind =
        Option.bind
          (json_string_opt_member "decision_kind" json)
          Keeper_approval.Audit.decision_kind_of_string
      in
      let approval_title = Printf.sprintf "Approval · %s" tool_name in
      let rule_title = Printf.sprintf "Approval Rule · %s" tool_name in
      let gate_title = Printf.sprintf "Approval Gate · %s" tool_name in
      let judge_title = Printf.sprintf "Approval Judge · %s" tool_name in
      let render (parsed : Keeper_approval.Audit.event) =
        match parsed with
        | Pending ->
            ( "approval_requested",
              approval_title,
              "approval requested and waiting for operator decision",
              Some "resolve_approval" )
        | Resolved ->
            (* A record with no decision is not one that was resolved as
               "resolved"; say which of the two the operator is looking at. *)
            let outcome =
              match decision with
              | Some recorded -> Printf.sprintf "approval %s" recorded
              | None -> "approval resolved with no recorded decision"
            in
            ("approval_resolved", approval_title, outcome, None)
        | Summary_updated ->
            ("approval_summary", approval_title, "approval summary updated", None)
        | Rule_created ->
            ( "approval_rule_created",
              rule_title,
              "persistent approval rule recorded",
              None )
        | Rule_deleted ->
            ( "approval_rule_deleted",
              rule_title,
              "persistent approval rule removed",
              None )
        | Gate_allowed ->
            ("approval_gate_allowed", gate_title, "gate allowed the call", None)
        | Grant_consumed ->
            ( "approval_grant_consumed",
              gate_title,
              "one-shot approval grant consumed",
              None )
        | Gate_exact_rule_expired ->
            ( "approval_gate_rule_expired",
              gate_title,
              "exact Always Allowed rule had expired, so the call needs a \
               decision again",
              Some "resolve_approval" )
        | Gate_exact_rule_store_degraded ->
            ( "approval_gate_store_degraded",
              gate_title,
              "exact rule store is unreadable, so no rule can be honoured",
              Some "inspect_approval_store" )
        | Gate_grant_unavailable ->
            ( "approval_gate_grant_unavailable",
              gate_title,
              "approved grant could not be read back",
              Some "retry_or_rerun" )
        | Auto_judge_operator_retry_started ->
            ( "approval_judge_retry",
              judge_title,
              "operator restarted the auto judge",
              None )
        | Auto_judge_block_observation_superseded ->
            ( "approval_judge_observation_superseded",
              judge_title,
              "auto judge block observation was superseded by a later write",
              None )
        | Auto_judge_restart_worker_recovered ->
            ( "approval_judge_recovered",
              judge_title,
              "auto judge worker recovered durable work after a restart",
              None )
        | Auto_judge_restart_judgment_recovered ->
            ( "approval_judge_recovered",
              judge_title,
              "auto judge recovered a durable judgment after a restart",
              None )
      in
      let kind, title, summary, next_human_action, severity =
        match Keeper_approval.Audit.event_of_string event with
        | Some parsed ->
            let kind, title, summary, next_human_action = render parsed in
            ( kind,
              title,
              approval_summary summary,
              next_human_action,
              severity_of_approval_event parsed decision_kind )
        | None ->
            (* Written by a build that knew a spelling this one does not. Say so
               rather than dressing it as a warning about the tool. *)
            ( "approval_event_unrecognized",
              approval_title,
              approval_summary
                (Printf.sprintf "unrecognized approval audit event %S" event),
              None,
              "warn" )
      in
      Some
        (timeline_event_json
           ?keeper_turn_id:(keeper_turn_id_of_json json)
           ?task_id:(json_string_opt_member "task_id" json)
           ~goal_ids:(goal_ids_of_json json)
           ?next_human_action
           ~ts_unix ~kind ~title ~summary ~severity ())
  | _ -> None

let decision_timeline_event json =
  match json_float_opt_member "wall_clock" json with
  | None -> None
  | Some ts_unix ->
      let turn_verdict =
        json_string_opt_member "turn_verdict" json
        |> Option.value ~default:"unknown"
      in
      let reasons =
        json_string_list_member "turn_reasons" json
      in
      let summary =
        match reasons with
        | [] -> Printf.sprintf "turn verdict=%s" turn_verdict
        | _ -> String.concat "; " reasons
      in
      Some
        (timeline_event_json ~ts_unix ~kind:"decision"
           ~title:"Turn Decision"
           ~summary
           ~severity:(severity_of_decision turn_verdict) ())


let transition_timeline_event json =
  match json_float_opt_member "wall_clock_at_decision" json with
  | None -> None
  | Some ts_unix ->
      let prev_phase =
        json |> json_member "prev_phase"
        |> json_string_opt_value
      in
      let new_phase =
        json |> json_member "new_phase"
        |> json_string_opt_value
      in
      let selected_event =
        json |> json_member "selected_event"
      in
      let event_type =
        (match json_string_opt_member "event_type" json with
         | Some _ as value -> value
         | None -> json_string_opt_member "type" selected_event)
        |> Option.value ~default:"transition"
      in
      let prev_phase = Option.value ~default:"unknown" prev_phase in
      let new_phase = Option.value ~default:"unknown" new_phase in
      let transition_outcome =
        json_string_opt_member "transition_outcome" json
        |> Option.value ~default:"unknown"
      in
      let summary =
        Printf.sprintf
          "%s -> %s via %s; outcome=%s"
          prev_phase
          new_phase
          event_type
          transition_outcome
      in
      Some
        (timeline_event_json ~ts_unix ~kind:"transition"
           ~title:(Printf.sprintf "Transition · %s" event_type)
           ~summary ~severity:"info" ())

let receipt_timeline_event receipt =
  match json_string_opt_member "ended_at" receipt with
  | None -> None
  | Some ended_at -> (
      match Masc_domain.parse_iso8601_opt ended_at with
      | None -> None
      | Some ts_unix when ts_unix <= 0.0 -> None
      | Some ts_unix ->
        let outcome =
          json_string_opt_member "outcome" receipt
          |> Option.value ~default:"unknown"
        in
        let completion_contract_result =
          json_string_opt_member "completion_contract_result" receipt
          |> Option.value ~default:"unknown"
        in
        let runtime_outcome =
          receipt |> json_member "runtime"
          |> json_string_opt_member "outcome"
          |> Option.value ~default:"not_observed"
        in
        let error_kind =
          match json_member "error" receipt with
          | `Assoc _ as error -> json_string_opt_member "kind" error
          | _ -> None
        in
        let severity =
          match error_kind with
          | Some _ -> "bad"
          | None ->
              if String.equal runtime_outcome "failed"
              then "bad"
              else if
                String.equal runtime_outcome "passed_to_next_model"
                || (receipt |> json_member "runtime"
                    |> json_bool_opt_member "fallback_applied"
                    |> Option.value ~default:false)
              then "warn"
              else "ok"
        in
        Some
          (timeline_event_json
             ?trace_id:(json_string_opt_member "trace_id" receipt)
             ?keeper_turn_id:(json_int_opt_member "turn_count" receipt)
             ?task_id:(json_string_opt_member "current_task_id" receipt)
             ~goal_ids:(goal_ids_of_json receipt)
             ~ts_unix ~kind:"execution_receipt"
             ~title:"Execution Receipt"
             ~summary:
               (Printf.sprintf "%s · completion_observation=%s · runtime=%s"
                  outcome completion_contract_result runtime_outcome)
             ~severity ()))

let blocker_timeline_event ?task_id ?(goal_ids = []) ?trace_id
    ?observed_at_unix ~ts_unix ~runtime_blocker_fields
    ~next_human_action ?(observation_only = true) () =
  let blocker_class = assoc_string_opt "runtime_blocker_class" runtime_blocker_fields in
  let blocker_summary =
    assoc_string_opt "runtime_blocker_summary" runtime_blocker_fields
  in
  match blocker_class, blocker_summary with
  | None, None -> None
  | Some blocker_class, Some summary
    when String.trim summary <> "" ->
      Some
        (timeline_event_json ?trace_id ?task_id ~goal_ids ?next_human_action
           ?observed_at_unix ~observation_only
           ~ts_unix ~kind:"runtime_blocker"
           ~title:"Runtime Blocker"
           ~summary
           ~severity:
             (match blocker_class with
              | "runtime_exhausted" -> "bad"
              | _ -> "warn")
           ())
  | None, Some summary
    when String.trim summary <> "" ->
      Some
        (timeline_event_json ?trace_id ?task_id ~goal_ids ?next_human_action
           ?observed_at_unix ~observation_only
           ~ts_unix ~kind:"runtime_blocker"
           ~title:"Runtime Blocker"
           ~summary ~severity:"warn" ())
  | Some blocker_class, None ->
      Some
        (timeline_event_json ?trace_id ?task_id ~goal_ids ?next_human_action
           ?observed_at_unix ~observation_only
           ~ts_unix ~kind:"runtime_blocker"
           ~title:"Runtime Blocker"
           ~summary:blocker_class ~severity:"warn" ())
  | Some _, Some _ | None, Some _ -> None


let latest_tool_call_json ~(keeper_name : string) =
  Keeper_tool_call_log.read_latest ~keeper_name ()

let pending_approval_json_with_reader
    ~(read_pending :
       base_path:string ->
       (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result)
    ~(base_path : string) ~(keeper_name : string) =
  read_pending ~base_path
  |> Result.map (fun entries ->
         entries
         |> List.filter (fun json ->
                String.equal keeper_name
                  (Safe_ops.json_string ~default:"" "keeper_name" json))
         |> List.sort (fun left right ->
                Float.compare
                  (Safe_ops.json_float ~default:0.0 "requested_at" right)
                  (Safe_ops.json_float ~default:0.0 "requested_at" left)))

let sort_timeline_events events =
  List.sort
    (fun left right ->
      match
        Bool.compare
          (json_bool_opt_member "observation_only" left
           |> Option.value ~default:false)
          (json_bool_opt_member "observation_only" right
           |> Option.value ~default:false)
      with
      | 0 ->
          Float.compare
            (json_float_opt_member "ts_unix" right |> Option.value ~default:0.0)
            (json_float_opt_member "ts_unix" left |> Option.value ~default:0.0)
      | cmp -> cmp)
    events

let latest_causal_from_timeline = function
  | `List items -> (
      match
        List.find_opt
          (fun json ->
             not
               (json_bool_opt_member "observation_only" json
                |> Option.value ~default:false))
          items
      with
      | Some event -> event
      | None -> (
          match items with
          | event :: _ -> event
          | [] -> `Null))
  | _ -> `Null
