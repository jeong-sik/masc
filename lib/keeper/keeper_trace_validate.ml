(** Keeper_trace_validate — validate JSONL traces against TLA+ safety invariants.

    Pure module. Reads files, parses JSON, delegates to Keeper_invariant_check. *)

module SM = Keeper_state_machine

type step = {
  seq : int;
  phase : SM.phase;
  conditions : SM.conditions;
  restart_count : int;
}

type located_violation = {
  seq : int;
  violation : Keeper_invariant_check.violation;
}

(* ── JSON parsing ─────────────────────────────────────── *)

let get_bool json key =
  match Yojson.Safe.Util.member key json with
  | `Bool b -> Ok b
  | _ -> Error (Printf.sprintf "missing or invalid bool field: %s" key)

let parse_conditions (json : Yojson.Safe.t) : (SM.conditions, string) result =
  let ( let* ) = Result.bind in
  let launch_pending =
    match Yojson.Safe.Util.member "launch_pending" json with
    | `Bool b -> b
    | _ -> false
  in
  let* fiber_alive = get_bool json "fiber_alive" in
  let* heartbeat_healthy = get_bool json "heartbeat_healthy" in
  let* turn_healthy = get_bool json "turn_healthy" in
  let* manual_reconcile_required = get_bool json "manual_reconcile_required" in
  let* context_within_budget = get_bool json "context_within_budget" in
  let* context_handoff_needed = get_bool json "context_handoff_needed" in
  let* compaction_active = get_bool json "compaction_active" in
  let* handoff_active = get_bool json "handoff_active" in
  let* operator_paused = get_bool json "operator_paused" in
  let* stop_requested = get_bool json "stop_requested" in
  let* restart_budget_remaining = get_bool json "restart_budget_remaining" in
  let* backoff_elapsed = get_bool json "backoff_elapsed" in
  let* guardrail_triggered = get_bool json "guardrail_triggered" in
  let* drain_complete = get_bool json "drain_complete" in
  (* Newer fields are tolerated as optional so historical trace files
     recorded before the Overflowed phase existed still parse. *)
  let context_overflow =
    match Yojson.Safe.Util.member "context_overflow" json with
    | `Bool b -> b
    | _ -> false
  in
  let compact_retry_exhausted =
    match Yojson.Safe.Util.member "compact_retry_exhausted" json with
    | `Bool b -> b
    | _ -> false
  in
  Ok SM.{
    launch_pending;
    fiber_alive; heartbeat_healthy; turn_healthy; manual_reconcile_required;
    context_within_budget; context_handoff_needed;
    compaction_active; handoff_active; operator_paused;
    stop_requested; restart_budget_remaining;
    backoff_elapsed; guardrail_triggered; drain_complete;
    context_overflow; compact_retry_exhausted;
  }

let parse_step (line : string) : (step, string) result =
  let ( let* ) = Result.bind in
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error msg ->
    Error (Printf.sprintf "JSON parse error: %s" msg)
  | json ->
    let seq = match Yojson.Safe.Util.member "seq" json with
      | `Int n -> n | _ -> 0
    in
    let phase_str = match Yojson.Safe.Util.member "new_phase" json with
      | `String s -> s | _ -> ""
    in
    let* phase = match SM.phase_of_string phase_str with
      | Some p -> Ok p
      | None -> Error (Printf.sprintf "unknown phase: %s" phase_str)
    in
    let conditions_json = Yojson.Safe.Util.member "conditions_after" json in
    let* conditions = parse_conditions conditions_json in
    let restart_count = match Yojson.Safe.Util.member "restart_count" json with
      | `Int n -> n | _ -> 0
    in
    Ok { seq; phase; conditions; restart_count }

(* ── Validation ───────────────────────────────────────── *)

let validate_trace_file (path : string) : (located_violation list, string) result =
  match Fs_compat.load_file path with
  | exception exn ->
    Error (Printf.sprintf "cannot read file: %s" (Printexc.to_string exn))
  | content ->
    let lines = String.split_on_char '\n' content
      |> List.filter (fun s -> String.length s > 0)
    in
    let rec loop prev_step violations = function
      | [] -> Ok (List.rev violations)
      | line :: rest ->
        match parse_step line with
        | Error msg ->
          Error (Printf.sprintf "line parse error: %s" msg)
        | Ok curr ->
          let step_violations =
            Keeper_invariant_check.check_step_invariants
              ~prev_phase:prev_step.phase
              ~prev_conditions:prev_step.conditions
              ~prev_restart_count:prev_step.restart_count
              ~new_phase:curr.phase
              ~new_conditions:curr.conditions
              ~new_restart_count:curr.restart_count
          in
          let located = List.map (fun v ->
            { seq = curr.seq; violation = v }
          ) step_violations in
          loop curr (located @ violations) rest
    in
    match lines with
    | [] -> Error "empty trace file"
    | first :: rest ->
      match parse_step first with
      | Error msg -> Error (Printf.sprintf "first line parse error: %s" msg)
      | Ok init -> loop init [] rest
