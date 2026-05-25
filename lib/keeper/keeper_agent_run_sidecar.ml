(** Keeper_agent_run_sidecar — State snapshot + working state sidecar persistence.

    Extracted from [Keeper_agent_run.run_turn] to reduce the mega-function
    body. Handles path construction, JSON payload assembly, atomic file
    writes, and manifest emissions for both sidecar types. *)

type append_manifest_fn =
  ?elapsed_ms:int ->
  ?logical_seq:int ->
  ?status:string ->
  ?decision:Yojson.Safe.t ->
  ?keeper_turn_id:int ->
  ?oas_turn_count:int ->
  ?checkpoint_path:string ->
  ?compaction_source:string ->
  site:string ->
  Keeper_runtime_manifest.event ->
  unit

type save_result =
  { working_state : Keeper_working_state.t
  ; state_snapshot_saved : bool
  ; working_state_saved : bool
  }

let save_sidecars
    ~keeper_name
    ~agent_name
    ~trace_id
    ~generation
    ~keeper_turn_id
    ~oas_turn_count
    ~session_dir
    ~state_snapshot
    ~state_snapshot_source
    ~append_manifest
    () =
  let state_snapshot_sidecar_path =
    Filename.concat
      (Filename.concat session_dir "state-snapshots")
      (Printf.sprintf "turn-%06d.json" keeper_turn_id)
  in
  let latest_state_snapshot_sidecar_path =
    Filename.concat session_dir "state-snapshot.latest.json"
  in
  let working_state_sidecar_path =
    Filename.concat
      (Filename.concat session_dir "working-state")
      (Printf.sprintf "turn-%06d.json" keeper_turn_id)
  in
  let latest_working_state_sidecar_path =
    Filename.concat session_dir "working-state.latest.json"
  in
  let state_snapshot_ts = Masc_domain.now_iso () in
  let state_snapshot_updated_at_unix = Time_compat.now () in
  let working_state =
    Keeper_working_state_projector.of_state_snapshot
      ~keeper_name
      ~trace_id
      ~keeper_turn_id
      ~updated_at_iso:state_snapshot_ts
      ~updated_at_unix:state_snapshot_updated_at_unix
      state_snapshot
  in
  let active_open_loop_count =
    Keeper_working_state.active_open_loop_count working_state
  in
  let state_snapshot_payload =
    `Assoc
      [
        ("schema_version", `Int 1);
        ("ts", `String state_snapshot_ts);
        ("keeper_name", `String keeper_name);
        ("agent_name", `String agent_name);
        ("trace_id", `String trace_id);
        ("generation", `Int generation);
        ("keeper_turn_id", `Int keeper_turn_id);
        ("oas_turn_count", `Int oas_turn_count);
        ("active_open_loop_count", `Int active_open_loop_count);
        ( "state_snapshot",
          Keeper_memory_policy.keeper_state_snapshot_to_json state_snapshot );
        ("working_state", Keeper_working_state.to_json working_state);
      ]
  in
  let working_state_payload =
    `Assoc
      [
        ("schema_version", `Int 1);
        ("ts", `String state_snapshot_ts);
        ("keeper_name", `String keeper_name);
        ("agent_name", `String agent_name);
        ("trace_id", `String trace_id);
        ("generation", `Int generation);
        ("keeper_turn_id", `Int keeper_turn_id);
        ("oas_turn_count", `Int oas_turn_count);
        ("source", `String state_snapshot_source);
        ("active_open_loop_count", `Int active_open_loop_count);
        ("working_state", Keeper_working_state.to_json working_state);
      ]
  in
  let state_snapshot_saved =
    let sidecar_dir = Filename.dirname state_snapshot_sidecar_path in
    (try Fs_compat.mkdir_p sidecar_dir with
     | exn ->
       Log.Keeper.warn
         "keeper:%s state snapshot sidecar dir create failed: %s"
         keeper_name
         (Printexc.to_string exn));
    match
      Fs_compat.save_file_atomic state_snapshot_sidecar_path
        (Yojson.Safe.pretty_to_string state_snapshot_payload)
    with
    | Ok () -> (
      match
        Fs_compat.save_file_atomic latest_state_snapshot_sidecar_path
          (Yojson.Safe.pretty_to_string state_snapshot_payload)
      with
      | Ok () -> true
      | Error e ->
        Log.Keeper.warn
          "keeper:%s latest state snapshot sidecar save failed: %s"
          keeper_name e;
        false)
    | Error e ->
      Log.Keeper.warn
        "keeper:%s state snapshot sidecar save failed: %s"
        keeper_name e;
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_checkpoint_failures
        ~labels:[ "keeper", keeper_name; "site", "state_snapshot_sidecar" ]
        ();
      false
  in
  let working_state_saved =
    let sidecar_dir = Filename.dirname working_state_sidecar_path in
    (try Fs_compat.mkdir_p sidecar_dir with
     | exn ->
       Log.Keeper.warn
         "keeper:%s working state sidecar dir create failed: %s"
         keeper_name
         (Printexc.to_string exn));
    match
      Fs_compat.save_file_atomic working_state_sidecar_path
        (Yojson.Safe.pretty_to_string working_state_payload)
    with
    | Ok () -> (
      match
        Fs_compat.save_file_atomic latest_working_state_sidecar_path
          (Yojson.Safe.pretty_to_string working_state_payload)
      with
      | Ok () -> true
      | Error e ->
        Log.Keeper.warn
          "keeper:%s latest working state sidecar save failed: %s"
          keeper_name e;
        false)
    | Error e ->
      Log.Keeper.warn
        "keeper:%s working state sidecar save failed: %s"
        keeper_name e;
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_checkpoint_failures
        ~labels:[ "keeper", keeper_name; "site", "working_state_sidecar" ]
        ();
      false
  in
  append_manifest ~site:"state_snapshot_sidecar"
    ~keeper_turn_id
    ~oas_turn_count
    ~status:(if state_snapshot_saved then "saved" else "error")
    ~decision:
      (`Assoc
        [
          ("state_snapshot_sidecar_path", `String state_snapshot_sidecar_path);
          ( "latest_state_snapshot_sidecar_path",
            `String latest_state_snapshot_sidecar_path );
          ("state_snapshot_sidecar_saved", `Bool state_snapshot_saved);
          ("active_open_loop_count", `Int active_open_loop_count);
          ( "working_state_prompt_digest_ids",
            `List
              (List.map (fun id -> `String id) working_state.prompt_digest_ids)
          );
          ("source", `String state_snapshot_source);
        ])
    Keeper_runtime_manifest.State_snapshot_sidecar_saved;
  append_manifest ~site:"working_state_sidecar"
    ~keeper_turn_id
    ~oas_turn_count
    ~status:(if working_state_saved then "saved" else "error")
    ~decision:
      (`Assoc
        [
          ("working_state_sidecar_path", `String working_state_sidecar_path);
          ( "latest_working_state_sidecar_path",
            `String latest_working_state_sidecar_path );
          ("working_state_sidecar_saved", `Bool working_state_saved);
          ("active_open_loop_count", `Int active_open_loop_count);
          ( "working_state_prompt_digest_ids",
            `List
              (List.map (fun id -> `String id) working_state.prompt_digest_ids)
          );
          ("source", `String state_snapshot_source);
        ])
    Keeper_runtime_manifest.Working_state_sidecar_saved;
  { working_state; state_snapshot_saved = state_snapshot_saved
  ; working_state_saved = working_state_saved }
;;
