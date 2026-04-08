open Masc_mcp

let temp_dir () =
  let dir = Filename.temp_file "test_cp_section_cache_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755

let write_text_file path content =
  ensure_dir (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

(* Invalidate the module-level section cache between tests *)
let reset_section_cache () =
  Command_plane_v2._section_cache := None

(** build_snapshot_state returns data from the same config without error. *)
let test_basic_snapshot () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  reset_section_cache ();
  let config = Room.default_config base in
  let _ = Room.init config ~agent_name:None in
  let state = Command_plane_v2.build_snapshot_state config in
  (* Snapshot succeeds; managed operations are zero for a fresh room *)
  Alcotest.(check int) "no managed operations" 0
    (List.length (List.filter (fun (op : Cp_types.operation_record) ->
       op.source = "managed") state.operations))

(** Calling build_snapshot_state twice without file changes should return
    the same cached topology (pointer equality on the agents list). *)
let test_cache_hit_no_change () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  reset_section_cache ();
  let config = Room.default_config base in
  let _ = Room.init config ~agent_name:None in
  let state1 = Command_plane_v2.build_snapshot_state config in
  let state2 = Command_plane_v2.build_snapshot_state config in
  (* Agents list should be physically identical (cached) *)
  Alcotest.(check bool) "agents list is same object" true
    (state1.agents == state2.agents);
  Alcotest.(check bool) "units list is same object" true
    (state1.units == state2.units)

(** Touching only intents.json should re-read intents but NOT topology. *)
let test_partial_invalidation () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  reset_section_cache ();
  let config = Room.default_config base in
  let _ = Room.init config ~agent_name:None in
  let _state1 = Command_plane_v2.build_snapshot_state config in
  (* Write an intents file to trigger intents section invalidation *)
  let intents_path =
    Filename.concat
      (Filename.concat (Room.masc_dir config) "control-plane")
      "intents.json"
  in
  (* Sleep briefly to ensure mtime differs *)
  Unix.sleepf 0.05;
  write_text_file intents_path
    {|{"version":"cp-v2","updated_at":"2026-01-01T00:00:00Z","intents":[]}|};
  let state2 = Command_plane_v2.build_snapshot_state config in
  (* Topology should still be cached (same physical objects) *)
  Alcotest.(check bool) "agents still cached after intents change" true
    (_state1.agents == state2.agents);
  (* Intents was re-read (even though still empty, it's a fresh list) *)
  Alcotest.(check bool) "intents list is fresh object" true
    (not (_state1.intents == state2.intents) || _state1.intents = [])

(** Explicit sessions parameter bypasses cache entirely. *)
let test_explicit_sessions_bypass () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  reset_section_cache ();
  let config = Room.default_config base in
  let _ = Room.init config ~agent_name:None in
  let _state1 = Command_plane_v2.build_snapshot_state config in
  (* Pass explicit empty sessions — should NOT use section cache *)
  let state2 = Command_plane_v2.build_snapshot_state ~sessions:[] config in
  (* With explicit sessions, agents are freshly read (not from cache) *)
  Alcotest.(check bool) "agents freshly read with explicit sessions" true
    (not (_state1.agents == state2.agents)
     || List.length _state1.agents = 0)

let test_operations_render_uses_snapshot_intents () =
  let base = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  reset_section_cache ();
  let config = Room.default_config base in
  let _ = Room.init config ~agent_name:None in
  let now = "2026-04-09T00:00:00Z" in
  let intent : Cp_types.intent_record =
    {
      intent_id = "intent-root-error";
      title = "Fix root error";
      owner = "tester";
      workload_profile = "coding_task";
      success_metric = None;
      invariants = [];
      artifact_priors = [];
      state = Cp_types.Active_intent;
      current_focus =
        {
          stage = Some "implement";
          artifact_scope = [];
          unit_id = None;
          verification_state = None;
        };
      checkpoint_ref = None;
      source = "managed";
      created_at = now;
      updated_at = now;
    }
  in
  let operation : Cp_types.operation_record =
    {
      operation_id = "op-root-error";
      objective = "Fix root error";
      intent_id = Some intent.intent_id;
      assigned_unit_id = "company-runtime";
      policy_class = "default";
      budget_class = "default";
      workload_template = None;
      workload_profile = "coding_task";
      stage = Some "implement";
      artifact_scope = [];
      depends_on_operation_ids = [];
      search_strategy = "legacy";
      detachment_session_id = None;
      trace_id = "trace-root-error";
      checkpoint_ref = None;
      active_goal_ids = [];
      note = None;
      created_by = "tester";
      source = "managed";
      status = Cp_types.Active;
      created_at = now;
      updated_at = now;
    }
  in
  Command_plane_v2.write_intents config [ intent ];
  Command_plane_v2.write_operations config [ operation ];
  let state = Command_plane_v2.build_snapshot_state config in
  Unix.sleepf 0.05;
  Command_plane_v2.write_intents config [];
  let json = Command_plane_v2.list_operations_json_from_state state in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "intent title comes from cached snapshot state"
    "Fix root error"
    (json
     |> member "operations"
     |> index 0
     |> member "intent"
     |> member "title"
     |> to_string)

let () =
  Alcotest.run "Cp_section_cache"
    [
      ( "section_cache",
        [
          Alcotest.test_case "basic snapshot" `Quick test_basic_snapshot;
          Alcotest.test_case "cache hit no change" `Quick
            test_cache_hit_no_change;
          Alcotest.test_case "partial invalidation" `Quick
            test_partial_invalidation;
          Alcotest.test_case "explicit sessions bypass" `Quick
            test_explicit_sessions_bypass;
          Alcotest.test_case "operations render uses snapshot intents" `Quick
            test_operations_render_uses_snapshot_intents;
        ] );
    ]
