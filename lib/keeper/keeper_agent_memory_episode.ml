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
    ~(memory : Oas.Memory.t)
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

let record_failure
    ~(config : Coord_utils.config)
    ~(keeper_name : string)
    ~(memory : Oas.Memory.t)
    ~(turn : int)
    ~(trace_id : string)
    ~(error_kind : string)
    ~(error_message : string)
    () : unit =
  try
    Memory_oas_bridge.store_failed_turn_episode ~memory
      ~keeper_name ~turn ~trace_id ~error_kind ~error_message ();
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
