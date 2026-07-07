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
  Keeper_runtime_manifest.event_kind ->
  unit

type save_result =
  { working_state : Keeper_working_state.t
  ; state_snapshot_saved : bool
  ; working_state_saved : bool
  }

(* Single owner of the latest-ledger filename: the prompt-side reader
   (RFC-0314 Open Loops layer in [Keeper_unified_turn]) must resolve the
   same path this module writes below. *)
let latest_working_state_path ~session_dir =
  Filename.concat session_dir "working-state.latest.json"

(* Read back the previously-persisted working-state ledger from the latest
   sidecar so that resume/compaction can preserve active loops the current
   [STATE] snapshot omits. The saved payload wraps the ledger under the
   "working_state" key (see [working_state_payload] below); decode via
   [Keeper_working_state.of_json], which also validates the TLA-mirrored
   invariants.

   Returns [None] when the file is absent or any read/parse/decode/validate
   step fails. This keeps resume strictly additive: a missing or corrupt
   sidecar falls back to the current empty+snapshot projection rather than
   crashing the turn. *)
let read_persisted_working_state ~keeper_name ~latest_path =
  if not (Fs_compat.file_exists latest_path) then None
  else
    match Fs_compat.load_file latest_path with
    | exception exn ->
      Log.Keeper.warn ~keeper_name:keeper_name
        "working state readback read failed (%s): %s"
        latest_path (Printexc.to_string exn);
      None
    | contents -> (
      match Yojson.Safe.from_string contents with
      | exception exn ->
        Log.Keeper.warn ~keeper_name:keeper_name
          "working state readback parse failed (%s): %s"
          latest_path (Printexc.to_string exn);
        None
      | json -> (
        match Yojson.Safe.Util.member "working_state" json with
        | `Null ->
          Log.Keeper.warn ~keeper_name:keeper_name
            "working state readback missing working_state field (%s)"
            latest_path;
          None
        | working_state_json -> (
          match Keeper_working_state.of_json working_state_json with
          | Ok state -> Some state
          | Error error ->
            Log.Keeper.warn ~keeper_name:keeper_name
              "working state readback decode failed (%s): %s"
              latest_path error;
            None)))

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
    ~resume_merge
    ~(append_manifest : append_manifest_fn)
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
    latest_working_state_path ~session_dir
  in
  let state_snapshot_ts = Masc_domain.now_iso () in
  let state_snapshot_updated_at_unix = Time_compat.now () in
  let projected_working_state =
    Keeper_working_state_projector.of_state_snapshot
      ~keeper_name
      ~trace_id
      ~keeper_turn_id
      ~updated_at_iso:state_snapshot_ts
      ~updated_at_unix:state_snapshot_updated_at_unix
      state_snapshot
  in
  (* ResumeFromDigest wire: only on resume/compaction turns do we read the
     persisted ledger back and merge its active loops, so a persisted open loop
     survives even if this turn's [STATE] omits it. On a normal turn the
     snapshot projection is authoritative, preserving completion-by-omission.

     Gating mirrors the TLA [ResumeFromDigest] precondition (compacted \/
     handed_off); the caller passes [resume_merge] derived from
     [pre_dispatch_compacted] or a synthesized (no model [STATE]) snapshot. *)
  let working_state, resume_restored_active_loops =
    if not resume_merge then (projected_working_state, 0)
    else
      match read_persisted_working_state ~keeper_name ~latest_path:latest_working_state_sidecar_path with
      | None -> (projected_working_state, 0)
      | Some persisted ->
        let merged =
          Keeper_working_state.merge_resume ~persisted ~current:projected_working_state
        in
        let restored =
          Keeper_working_state.active_open_loop_count merged
          - Keeper_working_state.active_open_loop_count projected_working_state
        in
        let restored = if restored < 0 then 0 else restored in
        Log.Keeper.info ~keeper_name:keeper_name
          "working state resume merge: restored %d active loop(s) from %s (snapshot active=%d, merged active=%d)"
          restored latest_working_state_sidecar_path
          (Keeper_working_state.active_open_loop_count projected_working_state)
          (Keeper_working_state.active_open_loop_count merged);
        (merged, restored)
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
        ("source", `String (Keeper_memory_policy.state_snapshot_source_to_string state_snapshot_source));
        ("active_open_loop_count", `Int active_open_loop_count);
        ("working_state", Keeper_working_state.to_json working_state);
      ]
  in
  let state_snapshot_saved =
    let sidecar_dir = Filename.dirname state_snapshot_sidecar_path in
    (try Fs_compat.mkdir_p sidecar_dir with
     | exn ->
       Log.Keeper.warn ~keeper_name:keeper_name
         "state snapshot sidecar dir create failed: %s"
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
        Log.Keeper.warn ~keeper_name:keeper_name
          "latest state snapshot sidecar save failed: %s"
          e;
        false)
    | Error e ->
      Log.Keeper.warn ~keeper_name:keeper_name
        "state snapshot sidecar save failed: %s"
        e;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CheckpointFailures)
        ~labels:[ "keeper", keeper_name; "site", "state_snapshot_sidecar" ]
        ();
      false
  in
  let working_state_saved =
    let sidecar_dir = Filename.dirname working_state_sidecar_path in
    (try Fs_compat.mkdir_p sidecar_dir with
     | exn ->
       Log.Keeper.warn ~keeper_name:keeper_name
         "working state sidecar dir create failed: %s"
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
        Log.Keeper.warn ~keeper_name:keeper_name
          "latest working state sidecar save failed: %s"
          e;
        false)
    | Error e ->
      Log.Keeper.warn ~keeper_name:keeper_name
        "working state sidecar save failed: %s"
        e;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CheckpointFailures)
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
          ("source", `String (Keeper_memory_policy.state_snapshot_source_to_string state_snapshot_source));
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
          ("resume_merge", `Bool resume_merge);
          ("resume_restored_active_loops", `Int resume_restored_active_loops);
          ("active_open_loop_count", `Int active_open_loop_count);
          ( "working_state_prompt_digest_ids",
            `List
              (List.map (fun id -> `String id) working_state.prompt_digest_ids)
          );
          ("source", `String (Keeper_memory_policy.state_snapshot_source_to_string state_snapshot_source));
        ])
    Keeper_runtime_manifest.Working_state_sidecar_saved;
  { working_state; state_snapshot_saved = state_snapshot_saved
  ; working_state_saved = working_state_saved }
;;
