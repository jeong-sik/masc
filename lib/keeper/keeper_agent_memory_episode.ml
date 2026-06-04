(** Keeper_agent_memory_episode -- post-run episode persistence adapter.

    Keeps OAS memory persistence details out of [Keeper_agent_run], preserving
    the keeper runner as a thin orchestration layer. *)

let record_activity_emit_gap ~config ~keeper_name ~outcome_label ~error =
  let masc_root = Workspace_utils.masc_dir config in
  try
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"keeper_memory_activity"
      ~producer:"keeper_agent_memory_episode.emit_flush_activity"
      ~durable_store:(Filename.concat masc_root "activity-events")
      ~dashboard_surface:"/api/v1/agent-timeline"
      ~stale_reason:"episode_flush_activity_emit_failed"
      ~keeper_name
      ~error:
        (Printf.sprintf "outcome=%s error=%s" outcome_label error)
      ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | gap_exn ->
    Log.Keeper.warn
      "keeper:%s episode.flush activity coverage-gap record failed \
       outcome=%s: %s"
      keeper_name outcome_label (Printexc.to_string gap_exn)

let emit_flush_activity
    ~(config : Workspace_utils.config)
    ~(keeper_name : string)
    ~(turn : int)
    ?(oas_turn_count : int option)
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
      @ (match oas_turn_count with
         | None -> []
         | Some count -> [ ("oas_turn_count", `Int count) ])
      @ (match outcome with
         | None -> []
         | Some value -> [ ("outcome", `String value) ])
    in
    try
      (Atomic.get Workspace_hooks.activity_emit_fn) config
        ~actor:Workspace_hooks.{ kind = "keeper"; id = keeper_name }
        ~kind:"episode.flush"
        ~payload:(`Assoc payload)
        ~tags
        ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      let outcome_label =
        match outcome with
        | None -> "success"
        | Some value -> value
      in
      Prometheus.inc_counter
        Keeper_metrics.(to_string MemoryActivityEmitFailures)
        ~labels:[("keeper", keeper_name); ("outcome", outcome_label)]
        ();
      let error = Printexc.to_string exn in
      record_activity_emit_gap ~config ~keeper_name ~outcome_label ~error;
      Log.Keeper.error
        "keeper:%s episode.flush activity emit failed outcome=%s: %s"
        keeper_name outcome_label error

let record_success
    ~(config : Workspace_utils.config)
    ~(keeper_name : string)
    ~(memory : Agent_sdk.Memory.t)
    ~(turn : int)
    ?(oas_turn_count : int option)
    ~(trace_id : string)
    ?state_snapshot_source
    ~(snapshot : Keeper_memory_policy.keeper_state_snapshot)
    () : unit =
  try
    Memory_oas_bridge.store_episode_from_snapshot ?state_snapshot_source ~memory
      ~keeper_name ~turn ?oas_turn_count ~trace_id snapshot;
    let episodes, procedures =
      Memory_oas_bridge.flush_incremental ~memory ~agent_name:keeper_name
    in
    if episodes > 0 || procedures > 0 then begin
      Log.Keeper.debug
        "keeper:%s post-run flush episodes=%d procedures=%d"
        keeper_name episodes procedures;
      emit_flush_activity ~config ~keeper_name ~turn ?oas_turn_count
        ~episodes ~procedures
        ~tags:[ "memory"; "episode"; "flush" ]
        ()
    end
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter Keeper_metrics.(to_string EpisodeCreateFailures)
      ~labels:[("keeper", keeper_name)]
      ();
    Log.Keeper.error "keeper:%s episode_create failed: %s"
      keeper_name (Printexc.to_string exn)


let record_failure
    ~(config : Workspace_utils.config)
    ~(keeper_name : string)
    ~(memory : Agent_sdk.Memory.t)
    ~(turn : int)
    ?(oas_turn_count : int option)
    ~(trace_id : string)
    ~(error_kind : Memory_oas_bridge.error_kind)
    ~(error_message : string)
    () : unit =
  try
    Memory_oas_bridge.store_failed_turn_episode ~memory
      ~keeper_name ~turn ?oas_turn_count ~trace_id ~error_kind ~error_message ();
    let episodes, procedures =
      Memory_oas_bridge.flush_incremental ~memory ~agent_name:keeper_name
    in
    if episodes > 0 || procedures > 0 then begin
      Log.Keeper.debug
        "keeper:%s post-run failure flush episodes=%d procedures=%d"
        keeper_name episodes procedures;
      emit_flush_activity ~config ~keeper_name ~turn ?oas_turn_count
        ~episodes ~procedures ~outcome:"failure"
        ~tags:[ "memory"; "episode"; "flush"; "failure" ]
        ()
    end
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Prometheus.inc_counter Keeper_metrics.(to_string EpisodeCreateFailures)
      ~labels:[("keeper", keeper_name)]
      ();
    Log.Keeper.error "keeper:%s failed_turn_episode_create failed: %s"
      keeper_name (Printexc.to_string exn)
