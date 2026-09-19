open Alcotest

module Boundaries = Masc.Keeper_turn_boundaries
module Store = Masc.Keeper_checkpoint_store
module U = Yojson.Safe.Util

let trace_id = "replay-trace"
let keeper_id = "replay-keeper"

let checkpoint ~trace_id messages : Agent_core.Checkpoint.t =
  { version = Agent_core.Checkpoint.checkpoint_version
  ; session_id = trace_id
  ; agent_name = keeper_id
  ; model = "fixture-model"
  ; system_prompt = None
  ; messages
  ; usage = Agent_core.Types.empty_usage
  ; turn_count = 3
  ; created_at = 1000.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }
;;

let write_boundary ~keepers_dir ~trace_id ~turn messages =
  let position =
    match Boundaries.position_of_messages messages with
    | Ok position -> position
    | Error error -> failf "fixture position: %s" error
  in
  let record : Boundaries.record =
    { recorded_at = Float.of_int turn
    ; event = Boundaries.Turn_ended
        { turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn:turn
        ; history_at_start =
            (if turn = 1 then Boundaries.Fresh_history else Boundaries.Continued_history)
        ; position
        }
    }
  in
  match Boundaries.append ~keepers_dir ~keeper_id record with
  | Ok () -> ()
  | Error error -> failf "fixture boundary: %s" (Boundaries.append_error_to_string error)
;;

let write_metadata config ~trace_id =
  let meta =
    match Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_id; "trace_id", `String trace_id ]) with
    | Ok meta -> meta
    | Error detail -> failf "fixture metadata: %s" detail
  in
  let path = Masc.Keeper_types_profile.keeper_meta_path config keeper_id in
  Yojson.Safe.to_file path (Masc.Keeper_meta_json.meta_to_json meta);
  path
;;

let run_cli ?base_argument ?env_base_path env ~base_path ~config_root ~cluster_name ~extent =
  Eio.Process.parse_out
    ~cwd:Eio.Path.(Eio.Stdenv.fs env / base_path)
    ~env:[| "MASC_CONFIG_DIR=" ^ config_root
          ; "MASC_BASE_PATH=" ^ Option.value ~default:base_path env_base_path
          ; "MASC_CLUSTER_NAME=" ^ cluster_name
          |]
    (Eio.Stdenv.process_mgr env) Eio.Buf_read.take_all
    [ Sys.getenv "MASC_TEST_LIBRARIAN_REPLAY_EXE"
    ; "--base-path"; Option.value ~default:base_path base_argument
    ; "--keeper"; keeper_id; "--extent"; extent
    ]
  |> Yojson.Safe.from_string
;;

let keeper_result output =
  match output |> U.member "keeper" |> U.to_list with
  | [ result ] -> result
  | _ -> fail "expected one Keeper result"
;;

let rec files_under dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun name ->
    let path = Filename.concat dir name in
    if Sys.is_directory path then files_under path
    else [ path, Digest.to_hex (Digest.file path) ])
;;

type base_argument = Absolute | Relative | Linked_worktree | Conflicting_environment

let test_workspace_checkpoint_is_replayed ?(shared_config = false)
    ?(argument = Absolute) cluster_name () =
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key None @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None @@ fun () ->
  Eio_main.run @@ fun env ->
  let base_path = Filename.temp_dir "librarian-replay-cli-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
      let base_argument = match argument with
        | Absolute | Conflicting_environment -> base_path
        | Relative -> "."
        | Linked_worktree ->
          let run args = Eio.Process.run (Eio.Stdenv.process_mgr env)
            ([ "git"; "-c"; "core.hooksPath=/dev/null"
             ; "-c"; "commit.gpgsign=false" ] @ args) in
          run [ "init"; "--quiet"; base_path ];
          run [ "-C"; base_path; "-c"; "user.name=Replay fixture"
              ; "-c"; "user.email=replay@example.invalid"
              ; "commit"; "--quiet"; "--allow-empty"; "-m"; "fixture" ];
          let path = Filename.concat base_path ".worktrees/replay" in
          run [ "-C"; base_path; "worktree"; "add"; "--quiet"; "--detach"; path ];
          path
      in
      let env_base_path = match argument with
        | Conflicting_environment -> Filename.concat base_path "other-workspace"
        | Absolute | Relative | Linked_worktree -> base_path
      in
      let config = Masc.Workspace.default_config base_path in
      let config =
        { config with backend_config = { config.backend_config with cluster_name } }
      in
      let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
      let metadata_path = write_metadata config ~trace_id in
      let config_root =
        Filename.concat (Masc.Workspace.masc_root_dir config) "config"
      in
      let keepers_dir = Filename.concat config_root "keepers" in
      Fs_compat.mkdir_p keepers_dir;
      let messages =
        List.init 6 (fun index ->
          Agent_core.Types.make_message
            ~role:(if index mod 2 = 0 then Agent_core.Types.User else Agent_core.Types.Assistant)
            [ Agent_core.Types.Text (Printf.sprintf "synthetic-message-%d" index) ])
      in
      (match Store.save_agent_core_classified
         ~session_dir ~history_retained:0 (checkpoint ~trace_id messages) with
       | Ok (Store.Saved _) -> ()
       | Ok (Store.Stale_noop _) -> fail "fixture checkpoint was not saved"
       | Error error -> failf "fixture checkpoint: %s" error);
      List.iter (fun turn ->
        write_boundary ~keepers_dir ~trace_id ~turn
          (List.filteri (fun index _ -> index < turn * 2) messages)) [ 1; 2; 3 ];
      if shared_config then (
        let other_trace = "replay-other-cluster-trace" in
        let other_config =
          { config with
            backend_config = { config.backend_config with cluster_name = "Other/Cluster" }
          }
        in
        ignore (write_metadata other_config ~trace_id:other_trace : string);
        let other_messages = List.filteri (fun index _ -> index < 2) messages in
        (match Store.save_agent_core_classified
           ~session_dir:(Masc.Keeper_fs.keeper_session_dir other_config other_trace)
           ~history_retained:0 (checkpoint ~trace_id:other_trace other_messages) with
         | Ok (Store.Saved _) -> ()
         | Ok (Store.Stale_noop _) -> fail "other cluster checkpoint was not saved"
         | Error error -> failf "other cluster checkpoint: %s" error);
        let restarted : Boundaries.record =
          { recorded_at = 4.0
          ; event = Boundaries.History_restarted { trace_id = other_trace }
          }
        in
        (match Boundaries.append ~keepers_dir ~keeper_id restarted with
         | Ok () -> ()
         | Error error -> failf "other cluster restart: %s"
             (Boundaries.append_error_to_string error));
        write_boundary ~keepers_dir ~trace_id:other_trace ~turn:1 other_messages);
      let before = files_under base_path in
      List.iter (fun (extent, expected_ranges) ->
          let output =
            run_cli ~base_argument ~env_base_path env ~base_path ~config_root ~cluster_name ~extent
          in
          check string "resolved fixture keepers" keepers_dir
            (output |> U.member "keepers_dir" |> U.to_string);
          let result = keeper_result output in
          (match U.member "skipped" result with
           | `Null -> ()
           | detail -> failf "fixture checkpoint was skipped: %s"
               (Yojson.Safe.to_string detail));
          check string "replay drains all cut points" "nothing_to_read"
            (result |> U.member "stopped_by" |> U.member "kind" |> U.to_string);
          check int "no atoms left" 0 (result |> U.member "atoms_left" |> U.to_int);
          check int "all atoms reached" 6 (result |> U.member "reached_atom" |> U.to_int);
          check int "no repeated atoms" 0
            (result |> U.member "atoms_carried_twice" |> U.to_int);
          check (list (pair int int)) "ranges advance across actual CLI rounds"
            expected_ranges
            (result |> U.member "round" |> U.to_list |> List.map (fun round ->
              (round |> U.member "start_atom" |> U.to_int),
              (round |> U.member "end_atom" |> U.to_int)));
          check (list (pair string string)) "replay leaves workspace files unchanged"
            before (files_under base_path))
          [ "all", [ 0, 6 ]; "cut-points", [ 0, 2; 2, 4; 4, 6 ] ];
      if shared_config then (
        let boundary_path = Boundaries.path_for_keepers_dir ~keepers_dir ~keeper_id in
        let oc = open_out_gen [ Open_wronly; Open_append; Open_binary ] 0o600 boundary_path in
        output_string oc "not-json\n";
        close_out oc;
        let before_bad_line = files_under base_path in
        let result =
          run_cli env ~base_path ~config_root ~cluster_name ~extent:"all" |> keeper_result
        in
        check string "unreadable shared boundary is not filtered away" "unreadable_line"
          (result |> U.member "stopped_by" |> U.member "kind" |> U.to_string);
        check int "unreadable boundary carries no atoms" 0
          (result |> U.member "reached_atom" |> U.to_int);
        check (list (pair string string)) "invalid boundary remains unchanged"
          before_bad_line (files_under base_path);
        Sys.remove metadata_path;
        let before_absent = files_under base_path in
        let result =
          run_cli env ~base_path ~config_root ~cluster_name ~extent:"all" |> keeper_result
        in
        check string "archived log does not choose another cluster" "metadata_absent"
          (result |> U.member "skipped" |> U.to_string);
        check (list (pair string string)) "absent metadata is not created"
          before_absent (files_under base_path);
        Yojson.Safe.to_file metadata_path (`Assoc []);
        let before_invalid = files_under base_path in
        let result =
          run_cli env ~base_path ~config_root ~cluster_name ~extent:"all" |> keeper_result
        in
        check bool "invalid metadata is explicitly skipped" true
          (String.starts_with ~prefix:"metadata_not_current:"
             (result |> U.member "skipped" |> U.to_string));
        check (list (pair string string)) "invalid metadata is not repaired"
          before_invalid (files_under base_path);
        let oc = open_out metadata_path in
        output_string oc "{";
        close_out oc;
        let before_unreadable = files_under base_path in
        let result =
          run_cli env ~base_path ~config_root ~cluster_name ~extent:"all" |> keeper_result
        in
        check bool "unreadable metadata is explicitly skipped" true
          (String.starts_with ~prefix:"metadata_unreadable:"
             (result |> U.member "skipped" |> U.to_string));
        check (list (pair string string)) "unreadable metadata is not repaired"
          before_unreadable (files_under base_path)))
;;

let test_missing_store_is_not_an_empty_replay keeper_argument () =
  Eio_main.run @@ fun env ->
  let base_path = Filename.temp_dir "librarian-replay-missing-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) @@ fun () ->
  let output = Eio.Process.parse_out
    ~env:[| "MASC_BASE_PATH=" ^ base_path; "MASC_CONFIG_DIR=" ^ base_path ^ "/config" |]
    ~is_success:(Int.equal 2)
    (Eio.Stdenv.process_mgr env) Eio.Buf_read.take_all
    ([ Sys.getenv "MASC_TEST_LIBRARIAN_REPLAY_EXE"; "--base-path"; base_path ]
     @ keeper_argument) in
  check string "a failed directory read is not a successful JSON result" "" output;
  check (list (pair string string)) "failed read creates no files" [] (files_under base_path)
;;

let () =
  run "librarian replay CLI"
    [ "workspace",
        [ test_case "default cluster: producer checkpoint, both extents, no writes" `Quick
            (test_workspace_checkpoint_is_replayed "default")
        ; test_case "named cluster: producer checkpoint, both extents, no writes" `Quick
            (test_workspace_checkpoint_is_replayed "Replay/Cluster")
        ; test_case "shared config: active cluster trace, unreadable log, metadata required" `Quick
            (test_workspace_checkpoint_is_replayed ~shared_config:true "Replay/Cluster")
        ; test_case "relative base: producer checkpoint, both extents, no writes" `Quick
            (test_workspace_checkpoint_is_replayed ~argument:Relative "Replay/Cluster")
        ; test_case "linked worktree: producer checkpoint, both extents, no writes" `Quick
            (test_workspace_checkpoint_is_replayed ~argument:Linked_worktree "Replay/Cluster")
        ; test_case "explicit base wins over a different environment base" `Quick
            (test_workspace_checkpoint_is_replayed ~argument:Conflicting_environment "Replay/Cluster")
        ; test_case "missing store fails instead of reporting no Keepers" `Quick
            (test_missing_store_is_not_an_empty_replay [])
        ; test_case "named Keeper cannot hide a missing store" `Quick
            (test_missing_store_is_not_an_empty_replay [ "--keeper"; keeper_id ])
        ]
    ]
