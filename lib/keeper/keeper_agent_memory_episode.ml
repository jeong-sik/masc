(** Keeper_agent_memory_episode -- post-run episode persistence adapter.

    Keeps OAS memory persistence details out of [Keeper_agent_run], preserving
    the keeper runner as a thin orchestration layer. *)

let emit_flush_activity
    ~(config : Coord_utils.config)
    ~(keeper_name : string)
    ~(turn : int)
    ~(episodes : int)
    ~(procedures : int)
    ?outcome
    ~(tags : string list)
    () : unit =
  if episodes > 0 || procedures > 0 then
    let payload =
      [ ("keeper", `String keeper_name)
      ; ("episodes", `Int episodes)
      ; ("procedures", `Int procedures)
      ; ("turn", `Int turn)
      ]
      @
      match outcome with
      | None -> []
      | Some value -> [ ("outcome", `String value) ]
    in
    try
      (Atomic.get Coord_hooks.activity_emit_fn) config
        ~actor:Coord_hooks.{ kind = "keeper"; id = keeper_name }
        ~kind:"episode.flush"
        ~payload:(`Assoc payload)
        ~tags
        ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> ()

let record_success
    ~(config : Coord_utils.config)
    ~(keeper_name : string)
    ~(memory : Agent_sdk.Memory.t)
    ~(turn : int)
    ~(trace_id : string)
    ~(snapshot : Keeper_memory_policy.keeper_state_snapshot)
    () : unit =
  try
    Memory_oas_bridge.store_episode_from_snapshot ~memory
      ~keeper_name ~turn ~trace_id snapshot;
    let episodes, procedures =
      Memory_oas_bridge.flush_incremental ~memory ~agent_name:keeper_name
    in
    if episodes > 0 || procedures > 0 then begin
      Log.Keeper.debug
        "keeper:%s post-run flush episodes=%d procedures=%d"
        keeper_name episodes procedures;
      emit_flush_activity ~config ~keeper_name ~turn
        ~episodes ~procedures
        ~tags:[ "memory"; "episode"; "flush" ]
        ()
    end
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.error "keeper:%s episode_create failed: %s"
      keeper_name (Printexc.to_string exn)

(** #10341: classify [error_kind] into the matching {!Agent_stress.stress_kind}
    so the stress ledger receives signal for failure modes other than the
    keepalive-only [Failure_streak] currently emitted by
    [keeper_keepalive].  Returns [None] for kinds that do not map to a
    pre-existing stress dimension (those are still recorded in the
    institution episode store via [store_failed_turn_episode]).

    Mapping rationale:
    - [*_timeout] / [*_timeout_*] / [oas_timeout_budget] → [Timeout]
      (matches the Timeout dimension defined in agent_stress.mli).
    - [completion_contract_violation] → [Parse_degraded] (the LLM
      response failed contract parse — semantically a parse-degraded
      output, not a timeout or hard failure streak). *)
let stress_kind_of_error_kind error_kind : Agent_stress.stress_kind option =
  let trimmed =
    String.trim (Memory_oas_bridge.error_kind_to_string error_kind)
  in
  let ends_with suffix s =
    let ls = String.length s in
    let lp = String.length suffix in
    ls >= lp && String.equal (String.sub s (ls - lp) lp) suffix
  in
  let contains needle s =
    let ln = String.length needle in
    let ls = String.length s in
    if ln = 0 || ln > ls then false
    else
      let rec loop i =
        if i + ln > ls then false
        else if String.equal (String.sub s i ln) needle then true
        else loop (i + 1)
      in
      loop 0
  in
  if trimmed = "" then None
  else if ends_with "_timeout" trimmed
       || contains "_timeout_" trimmed
       || String.equal trimmed "oas_timeout_budget"
  then Some Agent_stress.Timeout
  else if String.equal trimmed "completion_contract_violation"
  then Some Agent_stress.Parse_degraded
  else None

let record_failure
    ~(config : Coord_utils.config)
    ~(keeper_name : string)
    ~(memory : Agent_sdk.Memory.t)
    ~(turn : int)
    ~(trace_id : string)
    ~(error_kind : Memory_oas_bridge.error_kind)
    ~(error_message : string)
    () : unit =
  try
    Memory_oas_bridge.store_failed_turn_episode ~memory
      ~keeper_name ~turn ~trace_id ~error_kind ~error_message ();
    (* #10341: surface non-keepalive failure modes (timeout, parse) into
       the Agent_stress ledger so the stress dimensions defined in
       agent_stress.mli stop being write-only-for-Failure_streak. *)
    (match stress_kind_of_error_kind error_kind with
     | None -> ()
     | Some kind ->
         Agent_stress.record
           {
             agent_name = keeper_name;
             room_id = "";
             kind;
             timestamp = Unix.gettimeofday ();
           });
    let episodes, procedures =
      Memory_oas_bridge.flush_incremental ~memory ~agent_name:keeper_name
    in
    if episodes > 0 || procedures > 0 then begin
      Log.Keeper.debug
        "keeper:%s post-run failure flush episodes=%d procedures=%d"
        keeper_name episodes procedures;
      emit_flush_activity ~config ~keeper_name ~turn
        ~episodes ~procedures ~outcome:"failure"
        ~tags:[ "memory"; "episode"; "flush"; "failure" ]
        ()
    end
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.error "keeper:%s failed_turn_episode_create failed: %s"
      keeper_name (Printexc.to_string exn)
