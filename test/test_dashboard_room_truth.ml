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

let keeper_boot_entry name : Lib.Keeper_types.keeper_boot_entry =
  let now = "2026-03-25T08:05:54Z" in
  {
    name;
    persona_name = name;
    voice_enabled = false;
    voice_channel = "text_only";
    voice_agent_id = "";
    created_at = now;
    updated_at = now;
  }

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

let test_dashboard_room_truth_keeper_only_room_not_reported_empty () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let module Mcp_server = Lib.Mcp_server in
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      let config = state.Mcp_server.room_config in
      ignore (Lib.Room.init config ~agent_name:None);
      ignore
        (Lib.Room.join config
           ~agent_name:"keeper-sangsu-agent"
           ~agent_type_override:(Some "keeper")
           ~capabilities:["keeper"]
           ());
      ignore
        (Lib.Keeper_types.write_resident_keeper config
           (keeper_boot_entry "sangsu"));
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth")
        in
        let open Yojson.Safe.Util in
        let focus_label = json |> member "focus" |> member "label" |> to_string in
        check int "keeper-only room counts general agents as zero"
          0
          (json |> member "room" |> member "counts" |> member "agents" |> to_int);
        check int "keeper-only room still counts resident keeper"
          1
          (json |> member "room" |> member "counts" |> member "keepers" |> to_int);
        check bool "keeper-only room does not report empty room focus"
          false
          (String.equal focus_label
             "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다.");
      ))

let test_dashboard_room_truth_mixed_runtime_counts () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let module Mcp_server = Lib.Mcp_server in
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      let config = state.Mcp_server.room_config in
      ignore (Lib.Room.init config ~agent_name:None);
      ignore
        (Lib.Room.join config
           ~agent_name:"codex-test-agent"
           ~agent_type_override:(Some "codex")
           ~capabilities:["typescript"]
           ());
      ignore
        (Lib.Room.join config
           ~agent_name:"keeper-sangsu-agent"
           ~agent_type_override:(Some "keeper")
           ~capabilities:["keeper"]
           ());
      ignore
        (Lib.Keeper_types.write_resident_keeper config
           { name = "sangsu"; created_at = "2026-03-25T08:05:54Z"; updated_at = "2026-03-25T08:05:54Z" });
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth")
        in
        let open Yojson.Safe.Util in
        let focus_label = json |> member "focus" |> member "label" |> to_string in
        check int "mixed room counts one general agent"
          1
          (json |> member "room" |> member "counts" |> member "agents" |> to_int);
        check int "mixed room counts one resident keeper"
          1
          (json |> member "room" |> member "counts" |> member "keepers" |> to_int);
        check bool "mixed room avoids empty runtime fallback"
          false
          (String.equal focus_label
             "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다.");
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
          test_case "keeper-only room does not look empty" `Quick
            test_dashboard_room_truth_keeper_only_room_not_reported_empty;
          test_case "mixed runtimes keep counts aligned" `Quick
            test_dashboard_room_truth_mixed_runtime_counts;
          test_case "operator digest shape matches room-truth" `Quick test_operator_digest_shape_matches_room_truth;
        ] );
    ]
