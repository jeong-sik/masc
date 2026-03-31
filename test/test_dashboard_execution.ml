(** Dashboard Execution read-model regression tests. *)

module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_execution" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let test_dashboard_execution_fixture () =
  let dir = test_dir () in
  (* Force filesystem backend to prevent PG auto-detection in hermetic tests *)
  let saved_storage = Sys.getenv_opt "MASC_STORAGE_TYPE" in
  Unix.putenv "MASC_STORAGE_TYPE" "filesystem";
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir dir;
      (match saved_storage with
       | Some v -> Unix.putenv "MASC_STORAGE_TYPE" v
       | None -> Unix.putenv "MASC_STORAGE_TYPE" ""))
    (fun () ->
      let config = Room_utils.default_config dir in
      Unix.putenv "MASC_DASHBOARD_FIXTURES_ENABLED" "true";
      Eio_main.run @@ fun env ->
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~fixture:"execution_smoke"
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let execution_queue = json |> member "execution_queue" |> to_list in
        let session_briefs = json |> member "session_briefs" |> to_list in
        let operation_briefs = json |> member "operation_briefs" |> to_list in
        let worker_briefs = json |> member "worker_support_briefs" |> to_list in
        let continuity_briefs = json |> member "continuity_briefs" |> to_list in
        let offline_worker_briefs = json |> member "offline_worker_briefs" |> to_list in
        check bool "summary removed from execution payload" true
          (json |> member "summary" = `Null);
        check string "top queue kind" "session"
          (execution_queue |> List.hd |> member "kind" |> to_string);
        check string "top queue target" "ts-execution-fixture-001"
          (execution_queue |> List.hd |> member "target_id" |> to_string);
        check string "top queue handoff surface" "intervene"
          (execution_queue |> List.hd |> member "top_handoff" |> member "surface" |> to_string);
        check int "session briefs" 2 (List.length session_briefs);
        check int "fixture seen count" 3
          (session_briefs |> List.hd |> member "seen_count" |> to_int);
        check int "fixture planned count" 4
          (session_briefs |> List.hd |> member "planned_count" |> to_int);
        check string "fixture counts basis" "live=recent_turns · planned=roster"
          (session_briefs |> List.hd |> member "counts_basis" |> to_string);
        check int "operation briefs" 2 (List.length operation_briefs);
        check int "worker briefs" 3 (List.length worker_briefs);
        check string "worker signal truth" "live"
          (worker_briefs |> List.hd |> member "signal_truth" |> to_string);
        check string "worker evidence source" "message"
          (worker_briefs |> List.hd |> member "evidence_source" |> to_string);
        check int "continuity briefs" 1 (List.length continuity_briefs);
        check int "offline worker briefs" 1 (List.length offline_worker_briefs);
        check string "continuity skill route summary" "scene-director · +1 · judgment"
          (continuity_briefs |> List.hd |> member "skill_route_summary" |> to_string);
        check string "continuity recent output stays concrete"
          "Prepared the next scene transition and handoff summary"
          (continuity_briefs |> List.hd |> member "recent_output_preview" |> to_string);
        check string "continuity summary remains separate"
          "Continuity pressure is high; handoff prep is underway"
          (continuity_briefs |> List.hd |> member "continuity_summary" |> to_string);
        check int "continuity allowed tool count" 3
          (continuity_briefs |> List.hd |> member "allowed_tool_count" |> to_int);
        check (list string) "continuity allowed tool preview"
          [ "masc_board_get"; "masc_board_post"; "masc_keeper_status" ]
          (continuity_briefs |> List.hd |> member "allowed_tool_preview"
         |> to_list |> List.map to_string);
        check bool "worker focus carried through" true
          (worker_briefs
           |> List.exists (fun row ->
                  row |> member "name" |> to_string = "local-alpha"
                  && row |> member "related_session_id" |> to_string = "ts-execution-fixture-001"));
      ))

let test_dashboard_execution_live_empty_room () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Room_utils.default_config dir in
      Eio_main.run @@ fun env ->
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        check string "default room" "default"
          (json |> member "status" |> member "room" |> to_string);
        check int "execution queue empty" 0
          (json |> member "execution_queue" |> to_list |> List.length);
        check int "session briefs empty" 0
          (json |> member "session_briefs" |> to_list |> List.length);
        check int "operation briefs empty" 0
          (json |> member "operation_briefs" |> to_list |> List.length);
        check int "worker briefs empty" 0
          (json |> member "worker_support_briefs" |> to_list |> List.length);
        check int "continuity briefs empty" 0
          (json |> member "continuity_briefs" |> to_list |> List.length);
      ))

let test_dashboard_execution_current_room_status () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Room_utils.default_config dir in
      Eio_main.run @@ fun env ->
      ignore (Lib.Room.init config ~agent_name:None);
      Lib.Room.write_current_room config "focus-room";
      Lib.Room.ensure_room_bootstrap config "focus-room";
      check (option string) "room state current_room" (Some "focus-room")
        (Lib.Room.read_current_room config);
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let status = json |> member "status" in
        check string "status room follows current room" "focus-room"
          (status |> member "room" |> to_string);
        check string "status current_room exposed" "focus-room"
          (status |> member "current_room" |> to_string);
      ))

let test_dashboard_shell_current_room_status () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:None);
      Lib.Room.write_current_room config "focus-room";
      Lib.Room.ensure_room_bootstrap config "focus-room";
      let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
      let open Yojson.Safe.Util in
      let status = json |> member "status" in
      check string "shell room follows current room" "focus-room"
        (status |> member "room" |> to_string);
      check string "shell current_room exposed" "focus-room"
        (status |> member "current_room" |> to_string);
      check string "shell coordination root surfaced" dir
        (status |> member "coordination_root" |> to_string);
      check string "shell workspace path surfaced" dir
        (status |> member "workspace_path" |> to_string);
      check bool "shell workspace differs false when same root" false
        (status |> member "workspace_differs" |> to_bool);
      check string "shell diagnostics surface" "shell"
        (json |> member "projection_diagnostics" |> member "surface" |> to_string))

let test_dashboard_shell_surfaces_workspace_when_different () =
  let dir = test_dir () in
  let worktrees_dir = Filename.concat dir ".worktrees" in
  let workspace = Filename.concat worktrees_dir "demo" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Unix.mkdir worktrees_dir 0o755;
      Unix.mkdir workspace 0o755;
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config =
        { (Room_utils.default_config dir) with workspace_path = workspace }
      in
      ignore (Lib.Room.init config ~agent_name:None);
      let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
      let open Yojson.Safe.Util in
      let status = json |> member "status" in
      check string "shell coordination root remains base path" dir
        (status |> member "coordination_root" |> to_string);
      check string "shell workspace path uses input path" workspace
        (status |> member "workspace_path" |> to_string);
      check bool "shell workspace differs true when worktree input" true
        (status |> member "workspace_differs" |> to_bool);
      check string "diagnostics coordination root surfaced" dir
        (json |> member "projection_diagnostics" |> member "coordination_root"
         |> to_string);
      check string "diagnostics workspace path surfaced" workspace
        (json |> member "projection_diagnostics" |> member "workspace_path"
         |> to_string))

let create_keeper env sw config name =
  let ctx : _ Lib.Tool_keeper.context =
    {
      config;
      agent_name = "tester";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env); net = None;
    }
  in
  match
    Lib.Tool_keeper.dispatch ctx ~name:"masc_keeper_up"
      ~args:
        (`Assoc
          [
            ("name", `String name);
            ("goal", `String "Dashboard keeper fixture");
            ("proactive_enabled", `Bool false);
          ])
  with
  | Some (true, _) -> ()
  | Some (false, err) -> fail err
  | None -> fail "missing masc_keeper_up dispatch"

let test_dashboard_shell_counts_keepers () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:None);
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-alpha";
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-beta")
          (fun () ->
            create_keeper env sw config "keeper-alpha";
            create_keeper env sw config "keeper-beta";
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-alpha";
            Masc_mcp.Keeper_keepalive.stop_keepalive "keeper-beta";
            let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
            let open Yojson.Safe.Util in
            let counts = json |> member "counts" in
            check int "shell keeper count from keeper meta" 2
              (counts |> member "keepers" |> to_int))))

let test_dashboard_shell_excludes_keeper_agents_from_general_count () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:None);
      ignore
        (Lib.Room.join config
           ~agent_name:"keeper-sangsu-agent"
           ~agent_type_override:(Some "keeper")
           ~capabilities:["keeper"]
           ());
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw config "sangsu";
            Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu";
            let json = Lib.Server_dashboard_http.dashboard_shell_http_json config in
            let open Yojson.Safe.Util in
            let counts = json |> member "counts" in
            check int "keeper-backed room has no general agents" 0
              (counts |> member "agents" |> to_int);
            check int "keeper still counted" 1
              (counts |> member "keepers" |> to_int))))

let test_dashboard_execution_fresh_join_not_marked_stale () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Room_utils.default_config dir in
      Eio_main.run @@ fun env ->
      ignore (Lib.Room.init config ~agent_name:None);
      ignore (Lib.Room.join config ~agent_name:"test-agent-fox" ~capabilities:["housekeeping"] ());
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Dashboard_execution.json
            ~config
            ~sw
            ~clock:(Eio.Stdenv.clock env)
            ~proc_mgr:None
            ()
        in
        let open Yojson.Safe.Util in
        let worker_briefs = json |> member "worker_support_briefs" |> to_list in
        let offline_worker_briefs = json |> member "offline_worker_briefs" |> to_list in
        let has_test_agent =
          List.exists
            (fun row ->
              row |> member "name" |> to_string = "test-agent-fox")
            (worker_briefs @ offline_worker_briefs)
        in
        check bool "freshly joined agent should not appear stale in execution worker briefs"
          false has_test_agent
      ))

let () =
  Alcotest.run "Dashboard Execution"
    [
      ( "read_model",
        [
          Alcotest.test_case "fixture response" `Quick test_dashboard_execution_fixture;
          Alcotest.test_case "live empty room is safe" `Quick test_dashboard_execution_live_empty_room;
          Alcotest.test_case "current room drives status" `Quick
            test_dashboard_execution_current_room_status;
          Alcotest.test_case "shell follows current room" `Quick
            test_dashboard_shell_current_room_status;
          Alcotest.test_case "shell surfaces workspace separately" `Quick
            test_dashboard_shell_surfaces_workspace_when_different;
          Alcotest.test_case "shell counts keepers cheaply" `Quick
            test_dashboard_shell_counts_keepers;
          Alcotest.test_case "shell excludes keeper agents from general count" `Quick
            test_dashboard_shell_excludes_keeper_agents_from_general_count;
          Alcotest.test_case "fresh join is not stale" `Quick
            test_dashboard_execution_fresh_join_not_marked_stale;
        ] );
    ]
