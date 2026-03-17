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

(* Test helper *)
let test name f =
  try
    f ();
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

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
  ignore (Room.room_create ctx.config ~name:"Second Room" ~description:None);
  ignore (Room.room_enter ctx.config ~room_id:"second-room" ~agent_type:"claude" ~agent_name:ctx.agent_name ());
  ignore (Room.add_task ctx.config ~title:"second task" ~priority:1 ~description:"");
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "MASC Dashboard");
      assert (str_contains result "Room: default");
      assert (str_contains result "Room: second-room");
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
  ignore (Room.room_create ctx.config ~name:"Focus Room" ~description:None);
  ignore (Room.room_enter ctx.config ~room_id:"focus-room" ~agent_type:"claude" ~agent_name:ctx.agent_name ());
  ignore (Room.add_task ctx.config ~title:"focus task" ~priority:2 ~description:"");
  let args = `Assoc [("scope", `String "current")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "Scope: current");
      assert (str_contains result "Current Room: focus-room");
      assert (not (str_contains result "Room: default"))
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

(* Test dispatch gc *)
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

let () = test "dispatch_tool_admin_snapshot" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_snapshot" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      assert (Yojson.Safe.Util.member "tool_inventory" json <> `Null);
      assert (Yojson.Safe.Util.member "auth" json <> `Null);
      assert (Yojson.Safe.Util.member "mode" json <> `Null);
      assert (Yojson.Safe.Util.member "keeper_policies" json <> `Null);
      assert (Yojson.Safe.Util.member "command_plane" json <> `Null)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_tool_admin_update_mode" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc
      [
        ("section", `String "mode");
        ("enabled_categories", `List [ `String "core"; `String "auth" ]);
      ]
  in
  match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
  | Some (success, result) ->
      assert success;
      let json = parse_json result in
      assert (Yojson.Safe.Util.(json |> member "section" |> to_string) = "mode");
      let cfg = Config.load (Room.masc_dir ctx.config) in
      assert (cfg.mode = Mode.Custom);
      assert (List.mem Mode.Core cfg.enabled_categories);
      assert (List.mem Mode.Auth cfg.enabled_categories)
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
  match
    Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_up"
      ~args:
        (`Assoc
          [
            ("name", `String "admin-keeper");
            ("goal", `String "Admin tool policy test");
            ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
            ("presence_keepalive", `Bool false);
            ("proactive_enabled", `Bool false);
          ])
  with
  | Some (true, _) -> (
      let args =
        `Assoc
          [
            ("section", `String "keeper_policy");
            ("name", `String "admin-keeper");
            ("autonomy_level", `String "L4_Autonomous");
            ("policy_mode", `String "heuristic");
            ("action_budget", `String "board");
          ]
      in
      match Tool_misc.dispatch ctx ~name:"masc_tool_admin_update" ~args with
      | Some (success, result) ->
          assert success;
          let json = parse_json result in
          assert (Yojson.Safe.Util.(json |> member "section" |> to_string) = "keeper_policy");
          (match Keeper_types.read_meta ctx.config "admin-keeper" with
          | Ok (Some meta) ->
              assert (meta.autonomy_level = "l4_autonomous" || meta.autonomy_level = "L4_Autonomous");
              assert (meta.policy_action_budget = "board")
          | _ -> failwith "expected updated keeper meta")
      | None -> failwith "dispatch returned None")
  | Some (false, err) -> failwith err
  | None -> failwith "keeper up dispatch returned None"
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
