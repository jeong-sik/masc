module R = Goal_criterion_review
module AR = Task.Anti_rationalization
module A = Verification_authority_tools
open Result.Syntax

let prepare config record =
  let* tools = A.create_goal_proof ~config ~submitted_evidence:[] in
  let* layout = A.goal_proof_root_layout tools in
  let schemas = A.schemas tools in
  let tool_json (tool : Types_core.tool_schema) = `Assoc [
    "name", `String tool.name; "description", `String tool.description;
    "input_schema", tool.input_schema] in
  let* canonical = Lane_addon_action.canonical (`Assoc [
    "purpose", `String "goal_criterion_review";
    "base_path", `String config.Workspace_utils.base_path;
    "schemas", `List (List.map tool_json schemas)]) in
  let lookup_binding = Lane_addon_store.digest (Yojson.Safe.to_string canonical) in
  let* lookup_section = Prompt_registry.render_prompt_template Prompt_names.goal_verification_lookup
    ["lookup_tools", String.concat ", " (List.map (fun (tool : Types_core.tool_schema) -> tool.name) schemas);
     "lookup_root_layout", String.concat "\n" layout; "submitted_sources", "[]"] in
  let* prompt = Prompt_registry.render_prompt_template Prompt_names.goal_criterion_review_criterion
    ["criterion", Yojson.Safe.to_string (Goal_store.criterion_to_yojson record.R.criterion);
     "lookup_section", lookup_section] in
  let* system_prompt = Prompt_registry.render_prompt_template Prompt_names.goal_criterion_review_system [] in
  let original : R.original = {prompt; system_prompt; lookup_binding} in
  let lookup : AR.lookup_surface = {schemas; dispatch=A.dispatch tools} in
  Ok (original, lookup)

let log_result = function
  | Ok () -> ()
  | Error error -> Log.Misc.warn "goal criterion review: %s" (R.error_to_string error)

type observation = Reply of R.receipt | Unknown of {
  original : R.original; detail : string;
  tools : Verification_run_registry.tool_observation list;
}
type retained_observation = {record : R.record; observation : observation}
module Observations = Map.Make (struct
  type t = string * string
  let compare = Stdlib.compare
end)
(* A persistence refusal must not discard a model reply already observed by
   this process. Keep the same original until a maintenance pulse can commit
   it; losing the process still leaves the durable dispatch intent unknown. *)
let observed = Atomic.make Observations.empty
let observation_key config record = config.Workspace_utils.base_path, record.R.request_id
let rec remember config record observation =
  let current = Atomic.get observed in
  let key = observation_key config record in
  let saved = match Observations.find_opt key current with
    | Some ({observation=Reply _; _} as saved) -> saved
    | None | Some {observation=Unknown _; _} -> {record; observation} in
  if Atomic.compare_and_set observed current (Observations.add key saved current) then saved
  else remember config record observation
let rec forget config saved =
  let current = Atomic.get observed in
  let key = observation_key config saved.record in
  match Observations.find_opt key current with
  | Some latest when latest == saved ->
    if not (Atomic.compare_and_set observed current (Observations.remove key current)) then forget config saved
  | None | Some _ -> ()
let flush_observation config saved =
  let* () = match saved.observation with
    | Reply receipt -> R.retain_reply config saved.record receipt |> Result.map (fun _ -> ())
    | Unknown {original; detail; tools} -> R.retain_unknown config saved.record original ~detail ~tools in
  forget config saved;
  Ok ()
let flush_observed config =
  Observations.fold (fun (base_path, _) saved state ->
    let* () = state in
    if String.equal base_path config.Workspace_utils.base_path then flush_observation config saved else Ok ())
    (Atomic.get observed) (Ok ())

let process ?(sw=None) config ~goal_id =
  let* record = R.request config ~goal_id ~actor:"system:goal-criterion-review" ~retry:false in
  match record.phase with
  | R.Judged _ -> R.publish config record |> Result.map (fun _ -> ())
  | Dispatching _ | Execution_unknown _ | Reviewed _ | Deferred _ | Superseded _ -> Ok ()
  | Pending _ ->
    match prepare config record with
    | Error detail ->
      let* () = R.defer_preparation config record ~detail in
      Error (R.Store_unavailable detail)
    | Ok (original, lookup) ->
      let* claimed = R.begin_dispatch config record original in
      let unknown = ref None in
      let tools = ref [] in
      let judged = ref None in
      let reply_seen = ref None in
      let exception Retention_failed of R.error in
      let retain_unknown detail =
        match !reply_seen with
        | Some saved -> flush_observation config saved
        | None ->
          let saved = remember config claimed (Unknown {original; detail; tools=List.rev !tools}) in
          flush_observation config saved in
      let on_execution = function
        | AR.Admission_refused | Reply_received _ -> ()
        | Attempt_failed {runtime_id; certainty=AR.Outcome_unknown; error; failure=_} ->
          unknown := Some (runtime_id ^ ": " ^ Agent_core.Error.to_string error)
        | Attempt_failed {certainty=(AR.Before_dispatch | Definite_refusal); _} -> () in
      let on_tool_result ~input result =
        tools := Verification_run_registry.observe_tool_result ~input
          ~finished_at:(Time_compat.now ()) result :: !tools in
      let on_verdict result =
        match !unknown with
        | Some detail -> (match retain_unknown detail with
            | Ok () -> () | Error error -> raise (Retention_failed error))
        | None ->
          let receipt : R.receipt = {original; result; tools=List.rev !tools} in
          let saved = remember config claimed (Reply receipt) in
          reply_seen := Some saved;
          (match flush_observation config saved with
           | Ok () -> judged := Some {claimed with phase=R.Judged receipt}
           | Error error -> raise (Retention_failed error)) in
      (try
         let result = AR.run_retained ~system_prompt:original.system_prompt ~prompt:original.prompt
           ~on_execution ~on_tool_result ~on_verdict ~sw
           ~log_info:(fun message -> Log.Misc.info "[goal-criterion-review] goal_id=%s %s" goal_id message)
           ~log_warn:(fun message -> Log.Misc.warn "[goal-criterion-review] goal_id=%s %s" goal_id message)
           ~lookup ~provider_rest:Verification_retry.provider_rest
           ~base_path:config.Workspace_utils.base_path () in
         (match !judged, !unknown with
          | None, None -> on_verdict result
          | Some _, _ | None, Some _ -> ());
         match !judged with
         | Some saved -> R.publish config saved |> Result.map (fun _ -> ())
         | None -> Error (R.Conflict "Criterion reviewer execution is uncertain; original retained")
       with
       | Eio.Cancel.Cancelled _ as exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         Eio.Cancel.protect (fun () -> log_result (retain_unknown "Criterion review cancelled during dispatch"));
         Printexc.raise_with_backtrace exn backtrace
       | Retention_failed error -> Error error
       | exn ->
         let detail = Printexc.to_string exn in
         Eio.Cancel.protect (fun () -> log_result (retain_unknown detail));
         Error (R.Store_unavailable detail))

let active_goal (goal : Goal_store.goal) = match goal.phase with
  | Goal_phase.Executing | Verifying -> true
  | Awaiting_confirmation | Completed | Dropped | Paused _ | Blocked _ -> false

let collect config =
  let* () = flush_observed config in
  let* goals = Goal_store.list_goals_result config ()
    |> Result.map_error (fun error -> R.Goal_unavailable (Goal_store.Store_unavailable error)) in
  let* records = R.load config in
  (* Retained replies need no new model admission. Recover their publication
     even after a pause/terminal transition or a criterion replacement. *)
  List.iter (fun (record : R.record) -> match record.phase with
    | R.Judged _ -> log_result (R.publish config record |> Result.map (fun _ -> ()))
    | Pending _ | Dispatching _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _ -> ()) records;
  let current = R.current_lookup records in
  Ok (List.filter_map (fun (goal : Goal_store.goal) ->
    if not (active_goal goal) then None else match current goal with
    | None | Some {phase=(R.Pending _ | Judged _); _} -> Some goal.id
    | Some {phase=(R.Dispatching _ | Reviewed _ | Deferred _ | Execution_unknown _ | Superseded _); _} -> None) goals)
let recover ?(sw=None) config =
  let* pending = collect config in
  List.iter (fun goal_id -> log_result (process ~sw config ~goal_id)) pending;
  Ok ()

module Claims = Set.Make (String)
type claims = { running : Claims.t; requested : Claims.t }
let start_runtime ~sw ~clock ~config =
  Eio.Switch.check sw;
  let wake = Eio.Condition.create () in
  let dirty = Atomic.make true in
  let in_flight = Atomic.make {running=Claims.empty; requested=Claims.empty} in
  (* Only the controller below owns retry timers. Cross-domain hooks and
     workers touch immutable atomic claims and the atomic wake flag. *)
  let retries = Hashtbl.create 16 in
  let signal () = Atomic.set dirty true; Eio.Condition.broadcast wake in
  let rec retain_wake goal_id =
    let current = Atomic.get in_flight in
    if Claims.mem goal_id current.running then
      let next = {current with requested=Claims.add goal_id current.requested} in
      if not (Atomic.compare_and_set in_flight current next) then retain_wake goal_id in
  let hook observed ~goal_id =
    if String.equal observed.Workspace_utils.base_path config.Workspace_utils.base_path then (
      retain_wake goal_id; signal ()) in
  let previous = Atomic.get Workspace_hooks.goal_criterion_review_pending_fn in
  Atomic.set Workspace_hooks.goal_criterion_review_pending_fn hook;
  Eio.Switch.on_release sw (fun () ->
    if Atomic.get Workspace_hooks.goal_criterion_review_pending_fn == hook
    then Atomic.set Workspace_hooks.goal_criterion_review_pending_fn previous);
  let retry_ready () =
    match R.load config, Goal_store.list_goals_result config () with
    | Ok records, Ok goals ->
      let now = Eio.Time.now clock in
      let current = R.current_lookup records in
      let waiting = ref [] in
      List.iter (fun (goal : Goal_store.goal) ->
        if active_goal goal then match current goal with
        | Some {phase=R.Deferred receipt; request_id; _}
            when receipt.result.AR.retryable_runtimes <> [] ->
          waiting := request_id :: !waiting;
          (match Hashtbl.find_opt retries request_id with
           | None ->
             let delay = Verification_retry.delay
               ~retry_interval_sec:Env_config.Timeouts.maintenance_pulse_interval_sec
               ~now receipt.result.retryable_runtimes in
             Hashtbl.add retries request_id (now +. delay)
           | Some at when now >= at ->
             (match R.request ~expected_criterion:(Goal_store.criterion_of_goal goal)
                ~expected_request_id:request_id config ~goal_id:goal.id ~actor:"system:goal-criterion-retry" ~retry:true with
              | Ok _ -> signal (); Hashtbl.remove retries request_id
              | Error error -> log_result (Error error))
           | Some _ -> ())
        | None | Some {phase=(R.Pending _ | Dispatching _ | Judged _ | Reviewed _ | Deferred _
            | Execution_unknown _ | Superseded _); _} -> ()) goals;
      let obsolete = Hashtbl.fold (fun id _ obsolete ->
        if List.mem id !waiting then obsolete else id :: obsolete) retries [] in
      List.iter (Hashtbl.remove retries) obsolete
    | Error error, _ -> log_result (Error error)
    | Ok _, Error error -> log_result (Error (R.Goal_unavailable (Goal_store.Store_unavailable error))) in
  let rec reserve goal_id =
    let current = Atomic.get in_flight in
    if Claims.mem goal_id current.running then false else
    if Atomic.compare_and_set in_flight current {current with running=Claims.add goal_id current.running} then true
    else reserve goal_id in
  let rec release goal_id =
    let current = Atomic.get in_flight in
    let requested = Claims.mem goal_id current.requested in
    let next = {running=Claims.remove goal_id current.running;
      requested=Claims.remove goal_id current.requested} in
    if Atomic.compare_and_set in_flight current next then
      (if requested then signal ())
    else release goal_id in
  let launch goal_id =
    Eio.Switch.check sw;
    if reserve goal_id then
      try
        Eio.Switch.check sw;
        Eio.Fiber.fork_daemon ~sw (fun () ->
          Fun.protect ~finally:(fun () -> release goal_id) (fun () ->
            Eio.Fiber.yield ();
            Completion_authority_agent.with_review_slot (fun () ->
              log_result (process ~sw:(Some sw) config ~goal_id));
            `Stop_daemon))
      with exn -> release goal_id; raise exn in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Eio.Fiber.yield ();
    (* Retry unreadable boot state before opening any worker admission. Once
       admitted, this lane's live originals must never be reconciled again. *)
    let reconciled = ref false in
    let rec loop () =
      if Atomic.exchange dirty false then
        (Eio.Switch.check sw;
         if not !reconciled then
           (match Result.bind (flush_observed config) (fun () -> R.recover_interrupted config) with
            | Ok () -> reconciled := true
            | Error error -> log_result (Error error));
         if !reconciled then
           match collect config with
           | Ok pending -> List.iter launch pending
           | Error error -> log_result (Error error));
      if !reconciled then retry_ready ();
      if not (Atomic.get dirty) then
        Eio.Fiber.first
          (fun () -> Eio.Condition.loop_no_mutex wake
            (fun () -> if Atomic.get dirty then Some () else None))
          (fun () -> Eio.Time.sleep clock Env_config.Timeouts.maintenance_pulse_interval_sec;
            signal ());
      loop () in
    loop ())

let active : (string * Eio.Switch.t) option Atomic.t = Atomic.make None
let rec start ~sw ~clock ~config =
  Eio.Switch.check sw;
  let registration = Some (config.Workspace_utils.base_path, sw) in
  if Atomic.compare_and_set active None registration then (
    Eio.Switch.on_release sw (fun () -> ignore (Atomic.compare_and_set active registration None));
    start_runtime ~sw ~clock ~config)
  else match Atomic.get active with
    | Some (base_path, _) when String.equal base_path config.Workspace_utils.base_path -> ()
    | None -> start ~sw ~clock ~config
    | Some _ -> Log.Misc.error "Goal criterion reviewer is already bound to another workspace"

module For_testing = struct
  let process = process
  let recover = recover
end
