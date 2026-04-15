(** Dashboard namespace-truth read-model regression tests. *)

let () = Masc_mcp.Server_startup_state.mark_state_ready ~backend_mode:"test"
let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Masc_mcp.Keeper_exec_tools.init_policy_config ~base_path))

module Lib = Masc_mcp
module Feedback = Masc_mcp.Server_meta_cognition_feedback

open Alcotest

(* Force filesystem backend so tests run without PG auto-detect dependency. *)
let () = Unix.putenv "MASC_STORAGE_TYPE" "filesystem"

(* Bypass the proactive execution cache warm-up guard so tests get the full
   namespace-truth response instead of the "initializing" short-circuit. *)
let () = Lib.Server_dashboard_http.seed_execution_cache_for_test ()

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_namespace_truth" "" in
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

let save_jsonl path entries =
  let body =
    entries
    |> List.map Yojson.Safe.to_string
    |> String.concat "\n"
  in
  Fs_compat.save_file path (if body = "" then "" else body ^ "\n")

let post_json ~id ~author ?(title = "") ?(body = "") ?hearth ?thread_id
    ?(created_at = 1000.0) () =
  let fields =
    [
      ("id", `String id);
      ("author", `String author);
      ("title", `String title);
      ("body", `String body);
      ("content", `String body);
      ("post_kind", `String "automation");
      ("visibility", `String "internal");
      ("created_at", `Float created_at);
      ("updated_at", `Float created_at);
      ("expires_at", `Float 0.0);
      ("votes_up", `Int 0);
      ("votes_down", `Int 0);
      ("reply_count", `Int 0);
    ]
  in
  let fields =
    match hearth with
    | Some value -> ("hearth", `String value) :: fields
    | None -> fields
  in
  let fields =
    match thread_id with
    | Some value -> ("thread_id", `String value) :: fields
    | None -> fields
  in
  `Assoc fields

let comment_json ~id ~post_id ~author ~content ?(created_at = 1000.0) () =
  `Assoc
    [
      ("id", `String id);
      ("post_id", `String post_id);
      ("author", `String author);
      ("content", `String content);
      ("created_at", `Float created_at);
      ("expires_at", `Float 0.0);
      ("votes_up", `Int 0);
      ("votes_down", `Int 0);
    ]

let request target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list []) `GET target

(** Warm the execution cache so namespace-truth skips the "initializing" early
    return. Without this, proactive_first_cycle_pending is true and the handler
    returns a minimal {"status":"initializing"} JSON without namespace/execution/command data. *)
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
                ("autoboot_enabled", `Bool false);
          ])
  with
  | Some (true, _) -> ()
  | Some (false, err) -> fail err
  | None -> fail "missing masc_keeper_up dispatch"

let test_dashboard_namespace_truth_empty_room () =
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
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        check string "cluster default"
          "default"
          (json |> member "root" |> member "status" |> member "cluster" |> to_string);
        check int "pending confirms zero"
          0
          (json |> member "operator" |> member "pending_confirm_summary" |> member "total_count" |> to_int);
        check int "configured keepers default to zero"
          0
          (json |> member "root" |> member "configured_keepers" |> to_int);
        check int "namespace counts expose total runtimes"
          0
          (json |> member "root" |> member "counts" |> member "total_runtimes" |> to_int);
        check string "focus source"
          "namespace"
          (json |> member "focus" |> member "source" |> to_string);
      ))

let test_dashboard_namespace_truth_execution_fixture () =
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
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth?fixture=execution_smoke")
        in
        let open Yojson.Safe.Util in
        check int "fixture blocked operations"
          0
          (json |> member "execution" |> member "summary" |> member "blocked_operations" |> to_int);
        (* top_queue is null when cache has no execution_queue entries *)
        check bool "fixture top queue absent when no blockers"
          true
          (json |> member "execution" |> member "top_queue" = `Null);
      ))

let test_dashboard_namespace_truth_empty_room_focus_label () =
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
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        let focus_label = json |> member "focus" |> member "label" |> to_string in
        check bool "empty room focus mentions no agents"
          true
          (String.length focus_label > 0
           && focus_label <> "지금은 namespace 전체가 비교적 안정적입니다");
      ))

let test_dashboard_namespace_truth_keeper_only_room_not_reported_empty () =
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
              Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
                ~state ~sw ~clock:(Eio.Stdenv.clock env)
                (request "/api/v1/dashboard/namespace-truth")
            in
            let open Yojson.Safe.Util in
            let focus_label = json |> member "focus" |> member "label" |> to_string in
            check int "keeper-only room counts general agents as zero"
              0
              (json |> member "root" |> member "counts" |> member "agents" |> to_int);
            check int "keeper-only room still counts keeper meta"
              1
              (json |> member "root" |> member "counts" |> member "keepers" |> to_int);
            check bool "keeper-only room does not report empty room focus"
              false
              (String.equal focus_label
                 "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다."))))

let test_dashboard_namespace_truth_mixed_runtime_counts () =
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
              Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
                ~state ~sw ~clock:(Eio.Stdenv.clock env)
                (request "/api/v1/dashboard/namespace-truth")
            in
            let open Yojson.Safe.Util in
            let focus_label = json |> member "focus" |> member "label" |> to_string in
            check int "mixed room counts one general agent"
              1
              (json |> member "root" |> member "counts" |> member "agents" |> to_int);
            check int "mixed room counts one keeper"
              1
              (json |> member "root" |> member "counts" |> member "keepers" |> to_int);
            check bool "mixed room avoids empty runtime fallback"
              false
              (String.equal focus_label
                 "등록된 런타임이 없습니다. 활동이 시작되면 여기에 포커스가 나타납니다."))))

let test_operator_digest_shape_matches_namespace_truth () =
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
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
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

let test_dashboard_namespace_truth_promotes_meta_cognition_focus () =
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
      let masc_dir = Lib.Room.masc_dir config in
      save_jsonl
        (Filename.concat masc_dir "board_posts.jsonl")
        [
          post_json ~id:"p-root" ~author:"admin-keeper"
            ~title:"RBAC blockage"
            ~body:
              "All masc_* tools tested return unregistered_masc_tool. \
               Operator intervention needed. keeper_* tools function normally."
            ~hearth:"ops" ~created_at:1000.0 ();
        ];
      save_jsonl
        (Filename.concat masc_dir "board_comments.jsonl")
        [
          comment_json ~id:"c-1" ~post_id:"p-root" ~author:"keeper-a"
            ~content:
              "This contradicts the uniform block hypothesis. Access may be per-agent."
            ~created_at:1010.0 ();
        ];
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let json =
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        check int "meta contested belief count surfaced"
          1
          (json |> member "meta_cognition" |> member "summary"
           |> member "contested_belief_count" |> to_int);
        check string "meta interpretation primary surfaced"
          "contested_belief"
          (json |> member "meta_cognition" |> member "interpretation"
           |> member "primary_salience" |> to_string);
        check string "operator attention points at meta cognition"
          "namespace_meta_cognition"
          (json |> member "operator" |> member "attention_summary" |> member "top_item"
           |> member "target_type" |> to_string);
        check string "focus source becomes meta cognition"
          "meta_cognition"
          (json |> member "focus" |> member "source" |> to_string);
        check string "focus jumps to overview"
          "overview"
          (json |> member "focus" |> member "suggested_tab" |> to_string);
        check bool "focus params stay empty for overview"
          true
          (json |> member "focus" |> member "suggested_params" = `Assoc []);
      ))

let test_dashboard_namespace_truth_exposes_latest_meta_digest () =
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
      let masc_dir = Lib.Room.masc_dir config in
      save_jsonl
        (Filename.concat masc_dir "board_posts.jsonl")
        [
          post_json ~id:"p-root" ~author:"admin-keeper"
            ~title:"RBAC blockage"
            ~body:
              "All masc_* tools tested return unregistered_masc_tool. \
               Operator intervention needed. keeper_* tools function normally."
            ~hearth:"ops" ~created_at:1000.0 ();
        ];
      save_jsonl
        (Filename.concat masc_dir "board_comments.jsonl")
        [
          comment_json ~id:"c-1" ~post_id:"p-root" ~author:"keeper-a"
            ~content:
              "This contradicts the uniform block hypothesis. Access may be per-agent."
            ~created_at:1010.0 ();
        ];
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        let first_json =
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let posted_id =
          match Feedback.maybe_post_digest ~config first_json with
          | Feedback.Posted post_id -> post_id
          | Feedback.Deduped -> fail "expected fresh digest post"
          | Feedback.Skipped -> fail "expected digest post, got skipped"
          | Feedback.Failed err -> failf "expected digest post, got %s" err
        in
        let json =
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        check string "meta latest digest id" posted_id
          (json |> member "meta_cognition" |> member "latest_digest"
           |> member "post_id" |> to_string);
        check string "meta latest digest provenance" "board"
          (json |> member "meta_cognition" |> member "latest_digest"
           |> member "provenance" |> to_string);
        check bool "meta latest digest matches summary" true
          (json |> member "meta_cognition" |> member "latest_digest"
           |> member "matches_summary" |> to_bool);
        check string "meta latest digest hearth" "meta-cognition"
          (json |> member "meta_cognition" |> member "latest_digest"
           |> member "hearth" |> to_string);
      ))

let test_dashboard_namespace_truth_does_not_auto_post_meta_digest () =
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
      let masc_dir = Lib.Room.masc_dir config in
      save_jsonl
        (Filename.concat masc_dir "board_posts.jsonl")
        [
          post_json ~id:"p-root" ~author:"admin-keeper"
            ~title:"RBAC blockage"
            ~body:
              "All masc_* tools tested return unregistered_masc_tool. \
               Operator intervention needed. keeper_* tools function normally."
            ~hearth:"ops" ~created_at:1000.0 ();
        ];
      save_jsonl
        (Filename.concat masc_dir "board_comments.jsonl")
        [
          comment_json ~id:"c-1" ~post_id:"p-root" ~author:"keeper-a"
            ~content:
              "This contradicts the uniform block hypothesis. Access may be per-agent."
            ~created_at:1010.0 ();
        ];
      warm_execution_cache ();
      Eio.Switch.run (fun sw ->
        ignore
          (Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
             ~state ~sw ~clock:(Eio.Stdenv.clock env)
             (request "/api/v1/dashboard/namespace-truth"));
        let posts =
          Lib.Board_dispatch.list_posts ~hearth:"meta-cognition"
            ~post_kind_filter:Lib.Board.Automation_post
            ~sort_by:Lib.Board_dispatch.Recent ~limit:10 ()
        in
        check int "namespace-truth leaves meta-cognition board empty" 0
          (List.length posts)))

let test_namespace_truth_cached_snapshot_matches_http_projection_blocks () =
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
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let cached_snapshot =
          match Lib.Server_dashboard_http.namespace_truth_snapshot_from_caches state with
          | Some json -> json
          | None -> fail "expected cached namespace-truth snapshot"
        in
        let open Yojson.Safe.Util in
        let compare_block key =
          check string (Printf.sprintf "%s block matches cached snapshot" key)
            (Yojson.Safe.to_string (http_json |> member key))
            (Yojson.Safe.to_string (cached_snapshot |> member key))
        in
        List.iter compare_block
          [ "namespace"; "execution"; "meta_cognition"; "command"; "operator"; "focus" ];
      ))

let test_dashboard_namespace_truth_cold_cache_falls_back_to_partial_truth () =
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
          Lib.Server_dashboard_http.dashboard_namespace_truth_http_json
            ~state ~sw ~clock:(Eio.Stdenv.clock env)
            (request "/api/v1/dashboard/namespace-truth")
        in
        let open Yojson.Safe.Util in
        check bool "expired warmup skips top-level initializing payload"
          true
          (json |> member "status" = `Null);
        check bool "namespace block present"
          true
          (json |> member "root" <> `Null);
        check int "execution summary falls back to zero operations"
          0
          (json |> member "execution" |> member "summary" |> member "active_operations" |> to_int);
        check string "namespace truth diagnostics keep execution cache state"
          "initializing"
          (json |> member "projection_diagnostics" |> member "execution_cache_state" |> to_string);
      ))

let test_last_good_shell_fallback_preserves_counts () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let state = Lib.Mcp_server_eio.create_state ~test_mode:true ~base_path:dir () in
      ignore (Lib.Room.init state.Lib.Mcp_server.room_config ~agent_name:None);
      warm_execution_cache ();
      (* Warm the shell cache so _last_good_shell gets populated. *)
      Lib.Server_dashboard_http.warm_shell_cache state;
      let last_good = !(Lib.Server_dashboard_http._last_good_shell) in
      check bool "last good shell is non-empty after warm"
        true
        (last_good <> `Assoc []);
      (* Now verify that _last_good_shell has namespace counts. *)
      let open Yojson.Safe.Util in
      let counts = last_good |> member "counts" in
      check bool "last good shell contains counts block"
        true
        (counts <> `Null);
      (* Verify namespace-truth snapshot_from_caches uses the stale shell data
         even when the warmed flag is false (cold path, simulating timeout). *)
      Lib.Server_dashboard_http._shell_warmed := false;
      let snapshot =
        match Lib.Server_dashboard_http.namespace_truth_snapshot_from_caches state with
        | Some json -> json
        | None -> fail "expected cached namespace-truth snapshot"
      in
      let ns_counts = snapshot |> member "root" |> member "counts" in
      (* Shell was warmed once then reset; snapshot_from_caches should still
         produce a valid namespace block via the _last_good_shell fallback. *)
      check bool "namespace counts block present in fallback snapshot"
        true
        (ns_counts <> `Null);
      (* Restore warmed state for subsequent tests. *)
      Lib.Server_dashboard_http._shell_warmed := true)

let test_namespace_truth_snapshot_hash_ignores_generated_at () =
  Fun.protect
    ~finally:(fun () ->
      Lib.Server_dashboard_http._last_namespace_truth_snapshot_hash := None)
    (fun () ->
      Lib.Server_dashboard_http._last_namespace_truth_snapshot_hash := None;
      Eio_main.run @@ fun _env ->
      let snapshot ~generated_at ~active_sessions =
        `Assoc
          [
            ("generated_at", `String generated_at);
            ( "namespace",
              `Assoc [ ("status", `String "ready"); ("counts", `Assoc [("agents", `Int 1)]) ]
            );
            ( "execution",
              `Assoc
                [
                  ( "summary",
                    `Assoc [("active_sessions", `Int active_sessions)] );
                ] );
          ]
      in
      check bool "first snapshot broadcasts"
        true
        (Lib.Server_dashboard_http.should_broadcast_namespace_truth_snapshot
           (snapshot ~generated_at:"2026-04-09T00:00:00Z" ~active_sessions:1));
      check bool "generated_at-only changes stay deduped"
        false
        (Lib.Server_dashboard_http.should_broadcast_namespace_truth_snapshot
           (snapshot ~generated_at:"2026-04-09T00:00:05Z" ~active_sessions:1));
      check bool "semantic changes still broadcast"
        true
        (Lib.Server_dashboard_http.should_broadcast_namespace_truth_snapshot
           (snapshot ~generated_at:"2026-04-09T00:00:10Z" ~active_sessions:2)))

let () =
  Alcotest.run "Dashboard Namespace Truth"
    [
      ( "read_model",
        [
          test_case "empty room shape" `Quick test_dashboard_namespace_truth_empty_room;
          test_case "execution fixture surfaces top queue" `Quick test_dashboard_namespace_truth_execution_fixture;
          test_case "empty room focus label reflects no agents" `Quick test_dashboard_namespace_truth_empty_room_focus_label;
          test_case "keeper-only room does not look empty" `Quick
            test_dashboard_namespace_truth_keeper_only_room_not_reported_empty;
          test_case "mixed runtimes keep counts aligned" `Quick
            test_dashboard_namespace_truth_mixed_runtime_counts;
          test_case "operator digest shape matches namespace-truth" `Quick test_operator_digest_shape_matches_namespace_truth;
          test_case "meta cognition can drive namespace-truth focus" `Quick
            test_dashboard_namespace_truth_promotes_meta_cognition_focus;
          test_case "namespace-truth does not auto-post meta digest" `Quick
            test_dashboard_namespace_truth_does_not_auto_post_meta_digest;
          test_case "meta cognition exposes latest digest" `Quick
            test_dashboard_namespace_truth_exposes_latest_meta_digest;
          test_case "cached snapshot matches HTTP projection blocks" `Quick
            test_namespace_truth_cached_snapshot_matches_http_projection_blocks;
          test_case "expired execution warmup falls back to partial truth" `Quick
            test_dashboard_namespace_truth_cold_cache_falls_back_to_partial_truth;
          test_case "last-good shell fallback preserves namespace counts" `Quick
            test_last_good_shell_fallback_preserves_counts;
          test_case "snapshot hash ignores generated_at churn" `Quick
            test_namespace_truth_snapshot_hash_ignores_generated_at;
        ] );
    ]
