open Alcotest

module Boundaries = Masc.Keeper_turn_boundaries
module Store = Masc.Keeper_checkpoint_store
module U = Yojson.Safe.Util

let trace_id = "replay-trace"
let keeper_id = "replay-keeper"

let checkpoint messages : Agent_core.Checkpoint.t =
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

let write_boundary ~keepers_dir ~turn messages =
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

let rec files_under dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun name ->
    let path = Filename.concat dir name in
    if Sys.is_directory path then files_under path
    else [ path, Digest.to_hex (Digest.file path) ])
;;

let test_workspace_checkpoint_is_replayed cluster_name () =
  Eio_main.run @@ fun env ->
  let base_path = Filename.temp_dir "librarian-replay-cli-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () ->
      let config = Masc.Workspace.default_config base_path in
      let config =
        { config with backend_config = { config.backend_config with cluster_name } }
      in
      let session_dir = Masc.Keeper_fs.keeper_session_dir config trace_id in
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
         ~session_dir ~history_retained:0 (checkpoint messages) with
       | Ok (Store.Saved _) -> ()
       | Ok (Store.Stale_noop _) -> fail "fixture checkpoint was not saved"
       | Error error -> failf "fixture checkpoint: %s" error);
      List.iter (fun turn ->
        write_boundary ~keepers_dir ~turn
          (List.filteri (fun index _ -> index < turn * 2) messages)) [ 1; 2; 3 ];
      let before = files_under base_path in
      List.iter (fun (extent, expected_ranges) ->
          let output =
            Eio.Process.parse_out
              ~env:[| "MASC_CONFIG_DIR=" ^ config_root
                    ; "MASC_BASE_PATH=" ^ base_path
                    ; "MASC_CLUSTER_NAME=" ^ cluster_name
                    |]
              (Eio.Stdenv.process_mgr env) Eio.Buf_read.take_all
              [ Sys.getenv "MASC_TEST_LIBRARIAN_REPLAY_EXE"
              ; "--base-path"; base_path; "--keeper"; keeper_id; "--extent"; extent
              ]
            |> Yojson.Safe.from_string
          in
          check string "resolved fixture keepers" keepers_dir
            (output |> U.member "keepers_dir" |> U.to_string);
          let result = match output |> U.member "keeper" |> U.to_list with
            | [ result ] -> result
            | _ -> fail "expected one replayed Keeper"
          in
          check bool "checkpoint found at producer path" true
            (U.member "skipped" result = `Null);
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
          [ "all", [ 0, 6 ]; "cut-points", [ 0, 2; 2, 4; 4, 6 ] ])
;;

let () =
  run "librarian replay CLI"
    [ "workspace",
        [ test_case "default cluster: producer checkpoint, both extents, no writes" `Quick
            (test_workspace_checkpoint_is_replayed "default")
        ; test_case "named cluster: producer checkpoint, both extents, no writes" `Quick
            (test_workspace_checkpoint_is_replayed "Replay/Cluster")
        ]
    ]
