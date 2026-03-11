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
        let continuity_briefs = json |> member "continuity_briefs" |> to_list in
        let offline_worker_briefs = json |> member "offline_worker_briefs" |> to_list in
        check int "fixture blocked sessions" 1 (summary |> member "blocked_sessions" |> to_int);
        check int "fixture blocked operations" 2 (summary |> member "blocked_operations" |> to_int);
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

let () =
  Alcotest.run "Dashboard Execution"
    [
      ( "read_model",
        [
          Alcotest.test_case "fixture mode" `Quick test_dashboard_execution_fixture;
          Alcotest.test_case "live empty room is safe" `Quick test_dashboard_execution_live_empty_room;
        ] );
    ]
