(** Outcomes rollup: aggregate successes / failures / validation for a keeper.

    Data sources (all already in-process, zero new schema):
    - [Keeper_transition_audit.recent_completed_turns] (50-entry ring) ->
      turn outcomes classified after [mark_turn_finished].
    - [registry_entry] crash_log / restart_count / turn_consecutive_failures
      -> resilience counters.
    - [Dashboard_harness_health.read_recent_verdicts] -> AGENT_CORE verdict pass/fail
      scoped to this keeper by [agent_name].

    Conservation law (spec {!KeeperOutcomesConservation.tla}):
      successes.substantive_turns + failures.turn_failed = observed_turns
    holds by construction because both turn buckets come from the
    same completed-turn ring. *)
module String_map = Set_util.StringMap

let compute_outcomes_rollup
    ~base_path
    ~keeper_name
    ~agent_name
    ~recent_crash_count
    ~(registry_entry : Keeper_registry.registry_entry option) : Yojson.Safe.t =
  let completed_turns =
    Keeper_transition_audit.recent_completed_turns ~keeper_name ~limit:50
  in
  let succ_turns, fail_turn =
    List.fold_left
      (fun (succ, fail) (turn : Keeper_transition_audit.completed_turn_record) ->
         match turn.outcome with
         | Keeper_transition_audit.Turn_substantive -> succ + 1, fail
         | Keeper_transition_audit.Turn_failed -> succ, fail + 1)
      (0, 0)
      completed_turns
  in
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
        ~base_path
        ~agent_names:[ keeper_name; agent_name ]
        ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> []
  in
  let pass_v, fail_v, unknown_v, fail_reasons =
    List.fold_left
      (fun (pass_v, fail_v, unknown_v, fail_reasons)
        (v : Dashboard_harness_health.harness_verdict_item) ->
         match Eval_calibration.verdict_of_string (String.lowercase_ascii v.verdict) with
         | Some (Task.Anti_rationalization.Approve _) ->
           pass_v + 1, fail_v, unknown_v, fail_reasons
         | Some (Task.Anti_rationalization.Reject reason) ->
           let r =
             match v.fallback_reason, String.trim reason with
             | Some fallback_reason, _ -> fallback_reason
             | None, "" -> "unspecified"
             | None, parsed_reason -> parsed_reason
           in
           let cur = String_map.find_opt r fail_reasons |> Option.value ~default:0 in
           pass_v, fail_v + 1, unknown_v, String_map.add r (cur + 1) fail_reasons
         | None -> pass_v, fail_v, unknown_v + 1, fail_reasons)
      (0, 0, 0, String_map.empty)
      keeper_verdicts
  in
  let top_failure_reasons =
    String_map.bindings fail_reasons
    |> List.sort (fun (left_reason, left_count) (right_reason, right_count) ->
         let count_cmp = Int.compare right_count left_count in
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
            ("substantive_turns", `Int succ_turns);
          ] );
      ( "failures",
        `Assoc
          [
            ("turn_failed", `Int fail_turn);
            ("crashes", `Int recent_crash_count);
            ("restarts", `Int restarts);
            ("consecutive_fail_current", `Int consecutive_fail);
          ] );
      ( "validation",
        `Assoc
          [
            ( "agent_core_verdicts",
              `Assoc
                [
                  ("pass", `Int pass_v);
                  ("fail", `Int fail_v);
                  ("unknown", `Int unknown_v);
                  ("top_failure_reasons", `List top_failure_reasons);
                ] );
            ("last_verdict_at", last_verdict_at);
          ] );
    ]
