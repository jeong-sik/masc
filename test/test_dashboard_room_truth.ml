(** Dashboard room truth read-model regression tests. *)

module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_room_truth" "" in
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

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target

let test_dashboard_room_truth_empty_room () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      Eio_main.run @@ fun env ->
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth")
        in
        let open Yojson.Safe.Util in
        check string "room default"
          "default"
          (json |> member "room" |> member "status" |> member "room" |> to_string);
        check string "current_room exposed"
          "default"
          (json |> member "room" |> member "status" |> member "current_room" |> to_string);
        check int "pending confirms zero"
          0
          (json |> member "operator" |> member "pending_confirm_summary" |> member "total_count" |> to_int);
        check string "focus source"
          "orchestra"
          (json |> member "focus" |> member "source" |> to_string);
      ))

let test_dashboard_room_truth_execution_fixture () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      Eio_main.run @@ fun env ->
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth?fixture=execution_smoke")
        in
        let open Yojson.Safe.Util in
        check int "fixture blocked sessions"
          1
          (json |> member "execution" |> member "summary" |> member "blocked_sessions" |> to_int);
        check string "fixture top queue target"
          "ts-execution-fixture-001"
          (json |> member "execution" |> member "top_queue" |> member "target_id" |> to_string);
      ))

let () =
  Alcotest.run "Dashboard Room Truth"
    [
      ( "read_model",
        [
          test_case "empty room shape" `Quick test_dashboard_room_truth_empty_room;
          test_case "execution fixture surfaces top queue" `Quick test_dashboard_room_truth_execution_fixture;
        ] );
    ]
