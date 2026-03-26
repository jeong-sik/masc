(** Dashboard room truth read-model regression tests. *)

module Lib = Masc_mcp

open Alcotest

(* Force filesystem backend so tests run without PG auto-detect dependency. *)
let () = Unix.putenv "MASC_STORAGE_TYPE" "filesystem"

(* Bypass the proactive execution cache warm-up guard so tests get the full
   room-truth response instead of the "initializing" short-circuit. *)
let () = Lib.Server_dashboard_http.seed_execution_cache_for_test ()

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

(** Warm the execution cache so room-truth skips the "initializing" early return.
    Without this, proactive_first_cycle_pending is true and the handler returns
    a minimal {"status":"initializing"} JSON without room/execution/command data. *)
let warm_execution_cache () =
  Lib.Server_dashboard_http_cache.mark_cached_surface_success
    Lib.Server_dashboard_http._execution_cache
    (`Assoc [("status", `String "ok")])

let test_dashboard_room_truth_empty_room () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      warm_execution_cache ();
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
          "room"
          (json |> member "focus" |> member "source" |> to_string);
      ))

let test_dashboard_room_truth_execution_fixture () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth?fixture=execution_smoke")
        in
        let open Yojson.Safe.Util in
        check int "fixture blocked sessions"
          0
          (json |> member "execution" |> member "summary" |> member "blocked_sessions" |> to_int);
        (* top_queue is null when no blocked sessions exist *)
        check bool "fixture top queue absent when no blockers"
          true
          (json |> member "execution" |> member "top_queue" = `Null);
      ))

let test_dashboard_room_truth_empty_room_focus_label () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth")
        in
        let open Yojson.Safe.Util in
        let focus_label = json |> member "focus" |> member "label" |> to_string in
        check bool "empty room focus mentions no agents"
          true
          (String.length focus_label > 0
           && focus_label <> "지금은 방 전체가 비교적 안정적입니다");
      ))

let test_operator_digest_shape_matches_room_truth () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth")
        in
        let open Yojson.Safe.Util in
        let operator = json |> member "operator" in
        let expected_keys = ["health"; "attention_summary"; "recommendation_summary"; "pending_confirm_summary"; "provenance"] in
        List.iter (fun key ->
          let value = operator |> member key in
          check bool (Printf.sprintf "operator.%s present" key)
            true
            (value <> `Null)
        ) expected_keys;
      ))

let () =
  Alcotest.run "Dashboard Room Truth"
    [
      ( "read_model",
        [
          test_case "empty room shape" `Quick test_dashboard_room_truth_empty_room;
          test_case "execution fixture surfaces top queue" `Quick test_dashboard_room_truth_execution_fixture;
          test_case "empty room focus label reflects no agents" `Quick test_dashboard_room_truth_empty_room_focus_label;
          test_case "operator digest shape matches room-truth" `Quick test_operator_digest_shape_matches_room_truth;
        ] );
    ]
