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

let expire_execution_warmup () =
  let surface = Lib.Server_dashboard_http._execution_cache in
  Lib.Server_dashboard_http_cache.invalidate_cached_surface surface;
  let stale_attempt_ts = Unix.gettimeofday () -. 120.0 in
  surface.last_attempt_unix <- Some stale_attempt_ts;
  surface.last_attempt_at <- Some "stale_attempt_for_test"

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

let test_dashboard_room_truth_empty_room () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      Eio.Switch.run (fun sw ->
        warm_execution_cache ();
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
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Lib.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw config "sangsu";
            warm_execution_cache ();
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
            check int "keeper-only room still counts keeper meta"
              1
              (json |> member "room" |> member "counts" |> member "keepers" |> to_int);
            check bool "keeper-only room does not report empty room focus"
              false
              (String.equal focus_label
                 "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다."))))

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
      Eio.Switch.run (fun sw ->
        Fun.protect
          ~finally:(fun () ->
            Lib.Keeper_keepalive.stop_keepalive "sangsu")
          (fun () ->
            create_keeper env sw config "sangsu";
            warm_execution_cache ();
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
            check int "mixed room counts one keeper"
              1
              (json |> member "room" |> member "counts" |> member "keepers" |> to_int);
            check bool "mixed room avoids empty runtime fallback"
              false
              (String.equal focus_label
                 "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다."))))

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

let test_room_truth_cached_snapshot_matches_http_projection_blocks () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      warm_execution_cache ();
      Lib.Server_dashboard_http.warm_shell_cache state;
      Eio.Switch.run (fun sw ->
        let http_json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth")
        in
        let cached_snapshot =
          match Lib.Server_dashboard_http.room_truth_snapshot_from_caches state with
          | Some json -> json
          | None -> fail "expected cached room-truth snapshot"
        in
        let open Yojson.Safe.Util in
        let compare_block key =
          check string (Printf.sprintf "%s block matches cached snapshot" key)
            (Yojson.Safe.to_string (http_json |> member key))
            (Yojson.Safe.to_string (cached_snapshot |> member key))
        in
        List.iter compare_block ["room"; "execution"; "command"; "operator"; "focus"];
      ))

let test_dashboard_room_truth_cold_cache_falls_back_to_partial_truth () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      warm_execution_cache ();
      cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      expire_execution_warmup ();
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_room_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/room-truth")
        in
        let open Yojson.Safe.Util in
        check bool "expired warmup skips top-level initializing payload"
          true
          (json |> member "status" = `Null);
        check bool "room block still present"
          true
          (json |> member "room" <> `Null);
        check int "execution summary falls back to zero sessions"
          0
          (json |> member "execution" |> member "summary" |> member "active_sessions" |> to_int);
        check string "room truth diagnostics keep execution cache state"
          "initializing"
          (json |> member "projection_diagnostics" |> member "execution_cache_state" |> to_string);
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
          test_case "cached snapshot matches HTTP projection blocks" `Quick
            test_room_truth_cached_snapshot_matches_http_projection_blocks;
          test_case "expired execution warmup falls back to partial truth" `Quick
            test_dashboard_room_truth_cold_cache_falls_back_to_partial_truth;
        ] );
    ]
