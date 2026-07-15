(** Outcomes rollup: aggregate successes / failures / validation for a keeper.

    Data sources (all already in-process, zero new schema):
    - [Keeper_transition_audit.recent_completed_turns] (50-entry ring) ->
      turn outcomes classified after [mark_turn_finished].
    - [Keeper_transition_audit.recent_transitions] (50-entry ring) ->
      compaction / handoff outcomes classified by [selected_event].
    - [registry_entry] crash_log / restart_count / turn_consecutive_failures
      -> resilience counters.
    - [Dashboard_harness_health.read_recent_verdicts] -> OAS verdict pass/fail
      scoped to this keeper by [agent_name].

    Conservation law (spec {!KeeperOutcomesConservation.tla}):
      successes.substantive_turns + failures.turn_failed = observed_turns
    holds by construction because both turn buckets come from the
    same completed-turn ring. *)
let compute_outcomes_rollup
    ~keeper_name
    ~agent_name
    ~recent_crash_count
    ~(registry_entry : Keeper_registry.registry_entry option) : Yojson.Safe.t =
  let succ_turns = ref 0 in
  let succ_compactions = ref 0 in
  let succ_handoffs = ref 0 in
  let fail_turn = ref 0 in
  let fail_compaction = ref 0 in
  let fail_handoff = ref 0 in
  let completed_turns =
    Keeper_transition_audit.recent_completed_turns ~keeper_name ~limit:50
  in
  List.iter
    (fun (turn : Keeper_transition_audit.completed_turn_record) ->
      match turn.outcome with
      | Keeper_transition_audit.Turn_substantive -> incr succ_turns
      | Keeper_transition_audit.Turn_failed -> incr fail_turn)
    completed_turns;
  let transitions =
    Keeper_transition_audit.recent_transitions ~keeper_name ~limit:50
  in
  List.iter
    (fun (tr : Keeper_transition_audit.transition_record) ->
      match tr.selected_event with
      | Keeper_state_machine.Compaction_completed -> incr succ_compactions
      | Compaction_failed _ -> incr fail_compaction
      | Handoff_completed _ -> incr succ_handoffs
      | Handoff_failed _ -> incr fail_handoff
      | _ -> Log.Dashboard.debug "ignored transition event")
    transitions;
  let observed_turns = List.length completed_turns in
  let restarts, consecutive_fail =
    match registry_entry with
    | Some (e : Keeper_registry.registry_entry) ->
        (e.restart_count, e.turn_consecutive_failures)
    | None -> (0, 0)
  in
  let keeper_verdicts =
    try
      Dashboard_harness_health.read_recent_verdicts_for_agents
        ~limit:50
        ~agent_names:[ keeper_name; agent_name ]
        ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> []
  in
  let pass_v = ref 0 in
  let fail_v = ref 0 in
  let unknown_v = ref 0 in
  let fail_reasons = Hashtbl.create 8 in
  List.iter
    (fun (v : Dashboard_harness_health.harness_verdict_item) ->
      match Eval_calibration.verdict_of_string (String.lowercase_ascii v.verdict) with
      | Some Task.Anti_rationalization.Approve -> incr pass_v
      | Some (Task.Anti_rationalization.Reject reason) ->
          incr fail_v;
          let r =
            match (v.fallback_reason, String.trim reason) with
            | Some fallback_reason, _ -> fallback_reason
            | None, "" -> "unspecified"
            | None, parsed_reason -> parsed_reason
          in
          let cur = Hashtbl.find_opt fail_reasons r |> Option.value ~default:0 in
          Hashtbl.replace fail_reasons r (cur + 1)
      | None -> incr unknown_v)
    keeper_verdicts;
  let top_failure_reasons =
    Hashtbl.fold (fun k v acc -> (k, v) :: acc) fail_reasons []
    |> List.sort (fun (left_reason, left_count) (right_reason, right_count) ->
         let count_cmp = compare right_count left_count in
         if count_cmp <> 0 then count_cmp else String.compare left_reason right_reason)
    |> List.filteri (fun i _ -> i < 3)
    |> List.map (fun (r, _) -> `String r)
  in
  let last_verdict_at =
    match keeper_verdicts with
    | [] -> `Null
    | v :: _ -> `Float v.timestamp
  in
  `Assoc
    [
      ("window", `String "transition_ring_last_50");
      ("observed_turns", `Int observed_turns);
      ( "successes",
        `Assoc
          [
            ("substantive_turns", `Int !succ_turns);
            ("compactions_ok", `Int !succ_compactions);
            ("handoffs_ok", `Int !succ_handoffs);
          ] );
      ( "failures",
        `Assoc
          [
            ("turn_failed", `Int !fail_turn);
            ("compaction_failed", `Int !fail_compaction);
            ("handoff_failed", `Int !fail_handoff);
            ("crashes", `Int recent_crash_count);
            ("restarts", `Int restarts);
            ("consecutive_fail_current", `Int consecutive_fail);
          ] );
      ( "validation",
        `Assoc
          [
            ( "oas_verdicts",
              `Assoc
                [
                  ("pass", `Int !pass_v);
                  ("fail", `Int !fail_v);
                  ("unknown", `Int !unknown_v);
                  ("top_failure_reasons", `List top_failure_reasons);
                ] );
            ("last_verdict_at", last_verdict_at);
          ] );
    ]
