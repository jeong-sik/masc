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
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Lib.Room_utils.default_config dir in
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
        let summary = json |> member "summary" in
        let execution_queue = json |> member "execution_queue" |> to_list in
        let session_briefs = json |> member "session_briefs" |> to_list in
        let operation_briefs = json |> member "operation_briefs" |> to_list in
        let worker_briefs = json |> member "worker_support_briefs" |> to_list in
        let lodge_tick = json |> member "lodge_tick" in
        let lodge_checkins = json |> member "lodge_checkins" |> to_list in
        let continuity_briefs = json |> member "continuity_briefs" |> to_list in
        let offline_worker_briefs = json |> member "offline_worker_briefs" |> to_list in
        check int "fixture blocked sessions" 1 (summary |> member "blocked_sessions" |> to_int);
        check int "fixture blocked operations" 2 (summary |> member "blocked_operations" |> to_int);
        check int "lodge checked count" 3 (lodge_tick |> member "checked" |> to_int);
        check int "lodge checkins" 3 (List.length lodge_checkins);
        check string "top queue kind" "session"
          (execution_queue |> List.hd |> member "kind" |> to_string);
        check string "top queue target" "ts-execution-fixture-001"
          (execution_queue |> List.hd |> member "target_id" |> to_string);
        check string "top queue handoff surface" "intervene"
          (execution_queue |> List.hd |> member "top_handoff" |> member "surface" |> to_string);
        check int "session briefs" 2 (List.length session_briefs);
        check int "operation briefs" 2 (List.length operation_briefs);
        check int "worker briefs" 3 (List.length worker_briefs);
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
          (continuity_briefs |> List.hd |> member "allowed_tool_names" |> to_list |> List.length);
        check bool "worker focus carried through" true
          (worker_briefs
           |> List.exists (fun row ->
                  row |> member "name" |> to_string = "llama-local-alpha"
                  && row |> member "related_session_id" |> to_string = "ts-execution-fixture-001"));
      ))

let test_dashboard_execution_live_empty_room () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let config = Lib.Room_utils.default_config dir in
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
      let config = Lib.Room_utils.default_config dir in
      ignore (Lib.Room.init config ~agent_name:None);
      ignore (Lib.Room.room_create config ~name:"Focus Room" ~description:None);
      let enter_result =
        Lib.Room.room_enter config ~room_id:"focus-room" ~agent_type:"claude" ()
      in
      let open Yojson.Safe.Util in
      check string "room enter current_room" "focus-room"
        (enter_result |> member "current_room" |> to_string);
      check (option string) "room state current_room" (Some "focus-room")
        (Lib.Room.read_current_room config);
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
        let status = json |> member "status" in
        check string "status room follows current room" "focus-room"
          (status |> member "room" |> to_string);
        check string "status current_room exposed" "focus-room"
          (status |> member "current_room" |> to_string);
      ))

let () =
  Alcotest.run "Dashboard Execution"
    [
      ( "read_model",
        [
          Alcotest.test_case "fixture mode" `Quick test_dashboard_execution_fixture;
          Alcotest.test_case "live empty room is safe" `Quick test_dashboard_execution_live_empty_room;
          Alcotest.test_case "current room drives status" `Quick
            test_dashboard_execution_current_room_status;
        ] );
    ]
