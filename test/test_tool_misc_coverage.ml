(** Coverage tests for Tool_misc *)

open Masc_mcp

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()

let () = Printf.printf "\n=== Tool_misc Coverage Tests ===\n"

let str_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub > len_s then false
  else
    let rec loop i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = sub then true
      else loop (i + 1)
    in
    loop 0

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

(* Test helper — runs inside Eio context for code paths that use Eio.Mutex *)
let test name f =
  try
    Eio_main.run (fun _env -> f ());
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
      | Some value -> Unix.putenv name value
      | None -> Unix.putenv name "");
      f ())

(* Create test context *)
let test_counter = ref 0
let make_test_ctx () =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-misc-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Room.default_config tmp in
  let _ = Room.init config ~agent_name:(Some "test-agent") in
  { Tool_misc.config; agent_name = "test-agent" }

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_misc.dispatch ctx ~name:"unknown_tool" ~args = None)
)

(* Test dispatch dashboard — may require Eio runtime; skip gracefully if unavailable *)
let () = test "dispatch_dashboard" (fun () ->
  let ctx = make_test_ctx () in
  ignore (Room.add_task ctx.config ~title:"default task" ~priority:2 ~description:"");
  Room.write_current_room ctx.config "second-room";
  Room.ensure_room_bootstrap ctx.config "second-room";
  let second_room = Room.config_with_resolved_scope ctx.config in
  ignore (Room.add_task second_room ~title:"second task" ~priority:1 ~description:"");
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "MASC Dashboard");
      (* Header follows the current_room pointer. *)
      assert (str_contains result "Room: second-room");
      assert (not (str_contains result "2 room"));
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

(* Test dispatch dashboard compact — may require Eio runtime *)
let () = test "dispatch_dashboard_compact" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("compact", `Bool true)] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "MASC [");
      assert (str_contains result "ATTENTION:");
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_dashboard_current_scope" (fun () ->
  let ctx = make_test_ctx () in
  Room.write_current_room ctx.config "focus-room";
  Room.ensure_room_bootstrap ctx.config "focus-room";
  let focused = Room.config_with_resolved_scope ctx.config in
  ignore (Room.add_task focused ~title:"focus task" ~priority:2 ~description:"");
  let args = `Assoc [("scope", `String "current")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "MASC Dashboard");
      assert (str_contains result "Room: focus-room")
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_dashboard_invalid_scope" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("scope", `String "everywhere")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert (not success);
      assert (str_contains result "Invalid dashboard scope")
  | None -> failwith "dispatch returned None"
)

(* Test dispatch gc — Eio context provided by test helper *)
let () = test "dispatch_gc" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("days", `Int 7)] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some (success, result) ->
      assert success;
      assert (String.length result > 0)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch gc with default days *)
let () = test "dispatch_gc_default" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some (success, result) ->
      assert success;
      assert (String.length result > 0)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch cleanup_zombies *)
let () = test "dispatch_cleanup_zombies" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_cleanup_zombies" ~args with
  | Some (success, result) ->
      assert success;
      assert (String.length result > 0)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_transport_status" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_transport_status" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      assert (Yojson.Safe.Util.member "http" json <> `Null);
      assert (Yojson.Safe.Util.member "websocket" json <> `Null);
      assert (Yojson.Safe.Util.member "webrtc" json <> `Null)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_websocket_discovery" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_websocket_discovery" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      assert (Yojson.Safe.Util.member "enabled" json <> `Null);
      assert (Yojson.Safe.Util.member "mode" json <> `Null);
      assert (Yojson.Safe.Util.member "session_count" json <> `Null)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_webrtc_offer" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ("agent_name", `String "offer-agent");
        ("ice_candidates", `List [ `String "candidate:127.0.0.1:5000" ]);
        ("dtls_fingerprint", `String "sha-256:AA:BB:CC");
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_webrtc_offer" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      let offer_id = Yojson.Safe.Util.(json |> member "offer_id" |> to_string) in
      assert (String.length offer_id > 0);
      ignore (Server_webrtc_transport.cleanup_expired_offers ~max_age_s:0.0 ())
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_webrtc_answer" (fun () ->
  let ctx = make_test_ctx () in
  let offer_args =
    `Assoc
      [
        ("agent_name", `String "offer-agent");
        ("ice_candidates", `List [ `String "candidate:127.0.0.1:5001" ]);
      ]
  in
  let offer_result =
    match Tool_misc.dispatch ctx ~name:"masc_webrtc_offer" ~args:offer_args with
    | Some (true, result) -> parse_json result
    | Some (false, result) -> failwith result
    | None -> failwith "offer dispatch returned None"
  in
  let offer_id =
    Yojson.Safe.Util.(offer_result |> member "offer_id" |> to_string)
  in
  let answer_args =
    `Assoc
      [
        ("offer_id", `String offer_id);
        ("agent_name", `String "answer-agent");
        ("ice_candidates", `List [ `String "candidate:127.0.0.1:5002" ]);
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_webrtc_answer" ~args:answer_args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      let peer_id = Yojson.Safe.Util.(json |> member "peer_id" |> to_string) in
      assert (String.length peer_id > 0);
      Server_webrtc_transport.remove_peer peer_id
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_webrtc_offer_disabled" (fun () ->
  with_env "MASC_WEBRTC_ENABLED" (Some "0") (fun () ->
    let ctx = make_test_ctx () in
    let args =
      `Assoc
        [
          ("agent_name", `String "offer-agent");
          ("ice_candidates", `List [ `String "candidate:127.0.0.1:5000" ]);
        ]
    in
    match Tool_misc.dispatch ctx ~name:"masc_webrtc_offer" ~args with
    | Some (success, result) ->
        assert (not success);
        assert (str_contains result "webrtc transport disabled")
    | None -> failwith "dispatch returned None"))

let () = test "dispatch_webrtc_answer_disabled" (fun () ->
  with_env "MASC_WEBRTC_ENABLED" (Some "0") (fun () ->
    let ctx = make_test_ctx () in
    let args =
      `Assoc
        [
          ("offer_id", `String "offer-1");
          ("agent_name", `String "answer-agent");
          ("ice_candidates", `List [ `String "candidate:127.0.0.1:5002" ]);
        ]
    in
    match Tool_misc.dispatch ctx ~name:"masc_webrtc_answer" ~args with
    | Some (success, result) ->
        assert (not success);
        assert (str_contains result "webrtc transport disabled")
    | None -> failwith "dispatch returned None"))

let () = test "dispatch_tool_admin_snapshot" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_snapshot" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      assert (Yojson.Safe.Util.member "tool_inventory" json <> `Null);
      assert (Yojson.Safe.Util.member "auth" json <> `Null);
      assert (Yojson.Safe.Util.member "http_auth_strict" (Yojson.Safe.Util.member "auth" json) <> `Null);
      assert (Yojson.Safe.Util.member "bind_host" (Yojson.Safe.Util.member "auth" json) <> `Null);
      assert (Yojson.Safe.Util.member "bind_is_loopback" (Yojson.Safe.Util.member "auth" json) <> `Null);
      assert (Yojson.Safe.Util.member "mode" json = `Null);
      (* keeper_policies removed with policy_mode purge *)
      assert (Yojson.Safe.Util.member "keeper_policies" json = `Null);
      assert (Yojson.Safe.Util.member "command_plane" json <> `Null)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_rejects_mode" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ("section", `String "mode");
        ("enabled_categories", `List [ `String "core"; `String "auth" ]);
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some (success, _result) ->
      assert (not success)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_auth" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ("section", `String "auth");
        ("enabled", `Bool true);
        ("require_token", `Bool true);
        ("default_role", `String "reader");
        ("token_expiry_hours", `Int 12);
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      assert (Yojson.Safe.Util.(json |> member "section" |> to_string) = "auth");
      let cfg = Auth.load_auth_config ctx.config.base_path in
      assert cfg.enabled;
      assert cfg.require_token;
      assert (cfg.default_role = Types.Reader);
      assert (cfg.token_expiry_hours = 12)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_auth_invalid_does_not_mutate" (fun () ->
  let ctx = make_test_ctx () in
  let before = Auth.load_auth_config ctx.config.base_path in
  let args =
    `Assoc
      [
        ("section", `String "auth");
        ("enabled", `Bool true);
        ("default_role", `String "not-a-role");
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some (success, _result) ->
      assert (not success);
      let after = Auth.load_auth_config ctx.config.base_path in
      assert (after.enabled = before.enabled);
      assert (after.require_token = before.require_token);
      assert (after.default_role = before.default_role)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_unit_policy" (fun () ->
  let ctx = make_test_ctx () in
  let define_args =
    `Assoc
      [
        ("unit_id", `String "squad-admin-test");
        ("kind", `String "squad");
        ("label", `String "Admin Test Squad");
        ("parent_unit_id", `String "company-runtime");
      ]
  in
  ignore (Command_plane_v2.upsert_unit ctx.config ~actor:ctx.agent_name define_args);
  let args =
    `Assoc
      [
        ("section", `String "unit_policy");
        ("unit_id", `String "squad-admin-test");
        ( "policy",
          `Assoc
            [
              ("tool_allowlist", `List [ `String "masc_board_post" ]);
              ("model_allowlist", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("approval_class", `String "guarded");
            ] );
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      assert (Yojson.Safe.Util.(json |> member "section" |> to_string) = "unit_policy");
      let warnings = Yojson.Safe.Util.(json |> member "warnings" |> to_list) in
      assert (List.length warnings = 2)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_keeper_policy" (fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let ctx = make_test_ctx () in
  let keeper_ctx : _ Tool_keeper.context =
    {
      config = ctx.config;
      agent_name = "tester";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env);
    }
  in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive "admin-keeper")
    (fun () ->
      match
        Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String "admin-keeper");
                ("goal", `String "Admin tool policy test");
                ("proactive_enabled", `Bool false);
              ])
      with
      | Some (true, _) -> (
          (* keeper_policy section removed with policy_mode purge —
             admin_update should reject the section *)
          let args =
            `Assoc
              [
                ("section", `String "keeper_policy");
                ("name", `String "admin-keeper");
              ]
          in
          match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
          | Some (false, _msg) -> () (* expected: section no longer supported *)
          | Some (true, _) -> failwith "keeper_policy section should be rejected"
          | None -> failwith "dispatch returned None")
      | Some (false, err) -> failwith err
      | None -> failwith "keeper up dispatch returned None")
)

(* Test helper functions *)
let () = test "get_int_present" (fun () ->
  let args = `Assoc [("key", `Int 42)] in
  assert (Tool_args.get_int args "key" 0 = 42)
)

let () = test "get_int_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_int args "key" 99 = 99)
)

let () = test "get_bool_true" (fun () ->
  let args = `Assoc [("key", `Bool true)] in
  assert (Tool_args.get_bool args "key" false = true)
)

let () = test "get_bool_false" (fun () ->
  let args = `Assoc [("key", `Bool false)] in
  assert (Tool_args.get_bool args "key" true = false)
)

let () = test "get_bool_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_bool args "key" true = true)
)

let () = test "get_string_present" (fun () ->
  let args = `Assoc [("key", `String "value")] in
  assert (Tool_args.get_string args "key" "default" = "value")
)

let () = test "get_string_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_string args "key" "default" = "default")
)

let () = Printf.printf "\n✅ All Tool_misc tests passed!\n"

let () = exit 0
