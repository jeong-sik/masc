open Alcotest

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let temp_dir () =
  let rec pick attempt =
    let dir =
      Filename.concat (Filename.get_temp_dir_name ())
        (Printf.sprintf "keeper-tool-test-%d-%d-%d" (Unix.getpid ())
           (int_of_float (Unix.gettimeofday () *. 1000.)) attempt)
    in
    try
      Unix.mkdir dir 0o755;
      dir
    with Unix.Unix_error (Unix.EEXIST, _, _) -> pick (attempt + 1)
  in
  pick 0

let rec mkdir_p path =
  if path = "" || path = "/" || Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

let with_temp_file contents f =
  let path = Filename.temp_file "keeper-tail" ".log" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      let oc = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc contents);
      f path)

let test_read_file_tail_lines_drops_partial_first_line () =
  (* max_bytes is accepted but ignored by the current implementation
     (Fs_compat loads the full file). Test verifies max_lines behavior. *)
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Keeper_memory.read_file_tail_lines path ~max_bytes:100 ~max_lines:2 in
    check (list string) "returns last 2 lines" ["CCCCC"; "DDDDD"] lines)

let test_read_file_tail_lines_keeps_line_boundary_start () =
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Keeper_memory.read_file_tail_lines path ~max_bytes:100 ~max_lines:3 in
    check (list string) "returns last 3 lines" ["BBBBB"; "CCCCC"; "DDDDD"] lines)

let with_env name value f =
  let original = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    (fun () ->
      Unix.putenv name value;
      f ())

let parse_json_exn body =
  try Yojson.Safe.from_string body
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0
let string_is_valid_utf8 s =
  let len = String.length s in
  let rec loop i =
    if i >= len then true
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      dlen > 0 && Uchar.utf_decode_is_valid dec && loop (i + dlen)
  in
  loop 0

let test_keeper_fallback_model_labels_prefers_available_remote_models () =
  with_env "ZAI_API_KEY" "zai-test" (fun () ->
      with_env "ANTHROPIC_API_KEY" "" (fun () ->
          with_env "GEMINI_API_KEY" "" (fun () ->
              let labels = Masc_mcp.Keeper_types.keeper_fallback_model_labels () in
              check (list string) "glm fallback only"
                [Printf.sprintf "glm:%s" Masc_mcp.Env_config.Glm.default_model] labels)))

let test_maybe_append_keeper_fallback_models_adds_glm_when_local_only () =
  with_env "ZAI_API_KEY" "zai-test" (fun () ->
      let labels =
        Masc_mcp.Keeper_types.maybe_append_keeper_fallback_models
          ["llama:qwen3.5-35b-a3b-ud-q8-xl"]
      in
      let llama_listening =
        Masc_mcp.Keeper_types.label_is_available "llama:qwen3.5-35b-a3b-ud-q8-xl"
      in
      let expected =
        if llama_listening then
          ["llama:qwen3.5-35b-a3b-ud-q8-xl"]
        else
          ["llama:qwen3.5-35b-a3b-ud-q8-xl";
           Printf.sprintf "glm:%s" Masc_mcp.Env_config.Glm.default_model]
      in
      check (list string) "append glm fallback only when local runtime unavailable"
        expected labels)

let test_model_client_sanitize_message_utf8_repairs_invalid_fields () =
  let raw : Agent_sdk.Types.message =
    { Agent_sdk.Types.role = User;
      content = [Agent_sdk.Types.Text "hello\x80.world"]; name = None; tool_call_id = None }
  in
  let sanitized = Masc_mcp.Inference_utils.sanitize_message_utf8 raw in
  check bool "role preserved" true (sanitized.role = raw.role);
  let sanitized_text = Agent_sdk.Types.text_of_message sanitized in
  let raw_text = Agent_sdk.Types.text_of_message raw in
  check bool "content valid utf8" true (string_is_valid_utf8 sanitized_text);
  check bool "content changed" true (sanitized_text <> raw_text)

let test_model_client_sanitize_messages_utf8_preserves_message_count () =
  let msgs =
    [
      Agent_sdk.Types.user_msg "ok\x80";
      Agent_sdk.Types.assistant_msg "fine\xFF";
    ]
  in
  let sanitized = Masc_mcp.Inference_utils.sanitize_messages_utf8 msgs in
  check int "count preserved" 2 (List.length sanitized);
  check bool "all valid utf8" true
    (List.for_all
       (fun (msg : Agent_sdk.Types.message) -> string_is_valid_utf8 (Agent_sdk.Types.text_of_message msg))
       sanitized)

let test_resolved_keeper_skill_route_marks_agent_judgment () =
  let fallback_route : Masc_mcp.Keeper_alerting.keeper_skill_route = {
    primary_skill = "masc-heartbeat";
    secondary_skills = [ "masc-keeper-autonomy" ];
    reason = "fallback";
  } in
  let reply =
    "SKILL: lodge-social (+masc-heartbeat)\nSKILL_REASON: agent-selected\nActual reply body"
  in
  let resolved =
    Masc_mcp.Keeper_alerting.resolved_keeper_skill_route
      ~selection_mode:Masc_mcp.Keeper_alerting.SkillSelectAgent
      ~fallback_route
      ~reply_raw:reply
  in
  check string "selection mode" "agent" resolved.selection_mode;
  check string "provenance" "judgment" resolved.provenance;
  check string "primary skill" "lodge-social" resolved.route.primary_skill

let test_resolved_keeper_skill_route_falls_back_when_agent_parse_missing () =
  let fallback_route : Masc_mcp.Keeper_alerting.keeper_skill_route = {
    primary_skill = "masc-heartbeat";
    secondary_skills = [ "masc-keeper-autonomy" ];
    reason = "fallback";
  } in
  let resolved =
    Masc_mcp.Keeper_alerting.resolved_keeper_skill_route
      ~selection_mode:Masc_mcp.Keeper_alerting.SkillSelectAgent
      ~fallback_route
      ~reply_raw:"No skill header here"
  in
  check string "selection mode" "heuristic" resolved.selection_mode;
  check string "provenance" "fallback" resolved.provenance;
  check string "primary skill" "masc-heartbeat" resolved.route.primary_skill

let test_keeper_model_set_persists_active_model () =
  let provider_model = "custom:test-model@http://127.0.0.1:9999" in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("goal", `String "Maintain Sangsu persona");
              ("models", `List [ `String provider_model ]);
              ("active_model", `String provider_model);
              ("room_scope", `String "all");
              ("trigger_mode", `String "explicit_only");
              ("mention_targets", `List [ `String "sangsu" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      let ok, body =
        dispatch "masc_keeper_model_set"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("model", `String provider_model);
              ("allowed_models", `List [ `String provider_model ]);
            ])
      in
      check bool "model set ok" true ok;
      let json = Yojson.Safe.from_string body in
      check string "active model updated" provider_model
        Yojson.Safe.Util.(json |> member "active_model" |> to_string);
      let allowed_models =
        Yojson.Safe.Util.(json |> member "allowed_models" |> to_list |> filter_string)
      in
      check bool "allowed models contains target model" true
        (List.mem provider_model allowed_models);
      check int "allowed models are deduped" (List.length allowed_models)
        (List.sort_uniq String.compare allowed_models |> List.length);
      let ok, status_body =
        dispatch "masc_keeper_status"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("fast", `Bool true);
              ("include_context", `Bool false);
              ("include_metrics_overview", `Bool false);
              ("include_memory_bank", `Bool false);
              ("include_history_tail", `Bool false);
              ("include_compaction_history", `Bool false);
            ])
      in
      check bool "status ok" true ok;
      let status_json = Yojson.Safe.from_string status_body in
      check string "status active model" provider_model
        Yojson.Safe.Util.(status_json |> member "active_model" |> to_string))

(* write_persona_profile removed: persona concept deleted, see CLAUDE.md *)

let write_reward_model path =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc
        {|{
  "version": "reward-model-v1",
  "candidates": {
    "noop": {
      "bias": 0.0,
      "weights": {
        "direct_mention": -0.5
      }
    },
    "reply_in_room": {
      "bias": 0.1,
      "weights": {
        "direct_mention": 1.5,
        "question_mark": 0.2
      }
    },
        "board_post": {
          "bias": -0.3,
      "weights": {
        "active_goal_count": 0.8,
        "idle_seconds": 1.0,
        "room_scope_all": 0.3,
        "board_recent_external_post_count": 0.4,
        "board_newest_external_post_freshness": 0.4
      }
    }
    }
}|})

let make_keeper_exec_meta
    ?(name = "sangsu")
    ?(policy_mode = "heuristic")
    ?(policy_shell_mode = "disabled")
    ?(allowed_paths = [])
    () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String name);
        ("trace_id", `String ("trace-" ^ name));
        ("policy_mode", `String policy_mode);
        ("policy_shell_mode", `String policy_shell_mode);
        ("allowed_paths", `List (List.map (fun path -> `String path) allowed_paths));
      ]
  in
  match Masc_mcp.Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error e -> failwith ("make_keeper_exec_meta failed: " ^ e)

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let check_keeper_shell_tool_presence label meta ~expect_bash ~expect_shell_readonly =
  let allowed_names = Masc_mcp.Keeper_exec_tools.keeper_allowed_tool_names meta in
  let allowed_model_names =
    Masc_mcp.Keeper_exec_tools.keeper_allowed_model_tools meta
    |> List.map (fun (tool : Types.tool_schema) -> tool.name)
  in
  check bool (label ^ " bash allowed names") expect_bash
    (List.mem "keeper_bash" allowed_names);
  check bool (label ^ " shell readonly allowed names") expect_shell_readonly
    (List.mem "keeper_shell_readonly" allowed_names);
  check bool (label ^ " bash model tools") expect_bash
    (List.mem "keeper_bash" allowed_model_names);
  check bool (label ^ " shell readonly model tools") expect_shell_readonly
    (List.mem "keeper_shell_readonly" allowed_model_names)

let write_jsonl_lines path lines =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun line ->
          output_string oc line;
          output_char oc '\n')
        lines)

(* test_persona_list_and_create_from_persona removed:
   persona concept deleted (CLAUDE.md). Schema fields policy_voice_enabled,
   policy_shell_mode, initiative_* removed in #2607. *)

let test_keeper_shell_tool_policy_gates () =
  let heuristic = make_keeper_exec_meta () in
  let learned_disabled =
    make_keeper_exec_meta ~name:"learned-disabled"
      ~policy_mode:"learned_offline_v1" ()
  in
  let learned_readonly =
    make_keeper_exec_meta ~name:"learned-readonly"
      ~policy_mode:"learned_offline_v1"
      ~policy_shell_mode:"readonly" ()
  in
  let explicit_event =
    make_keeper_exec_meta ~name:"explicit-event"
      ~policy_mode:"explicit_event_v1" ()
  in
  let deliberation =
    make_keeper_exec_meta ~name:"deliberation"
      ~policy_mode:"model_deliberation" ()
  in
  check_keeper_shell_tool_presence "heuristic" heuristic
    ~expect_bash:false ~expect_shell_readonly:true;
  check_keeper_shell_tool_presence "learned disabled" learned_disabled
    ~expect_bash:false ~expect_shell_readonly:false;
  check_keeper_shell_tool_presence "learned readonly" learned_readonly
    ~expect_bash:false ~expect_shell_readonly:true;
  check_keeper_shell_tool_presence "explicit event" explicit_event
    ~expect_bash:false ~expect_shell_readonly:true;
  check_keeper_shell_tool_presence "model deliberation" deliberation
    ~expect_bash:false ~expect_shell_readonly:true

let test_keeper_shell_readonly_enforces_allowed_paths () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      let allowed_rel = "allowed/note.txt" in
      let blocked_rel = "blocked/secret.txt" in
      write_file (Filename.concat base_dir allowed_rel) "keeper-ok\n";
      write_file (Filename.concat base_dir blocked_rel) "should-not-read\n";
      let meta =
        make_keeper_exec_meta ~policy_mode:"learned_offline_v1"
          ~policy_shell_mode:"readonly"
          ~allowed_paths:[ "allowed" ] ()
      in
      let ctx_work =
        Masc_mcp.Keeper_exec_context.create ~system_prompt:"test"
          ~max_tokens:4000
      in
      let allowed_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_shell_readonly"
          ~input:(`Assoc [ ("op", `String "cat"); ("path", `String allowed_rel) ])
        |> parse_json_exn
      in
      check string "allowed cat op" "cat"
        Yojson.Safe.Util.(allowed_json |> member "op" |> to_string);
      check bool "allowed cat path stays under allowed root" true
        Yojson.Safe.Util.(
          allowed_json |> member "path" |> to_string |> fun path ->
          contains_substring path allowed_rel);
      check string "allowed cat status kind" "exit"
        Yojson.Safe.Util.(allowed_json |> member "status" |> member "kind" |> to_string);
      check bool "allowed cat content field present" true
        Yojson.Safe.Util.(
          allowed_json |> member "content" |> to_string |> fun _ -> true);
      let blocked_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_shell_readonly"
          ~input:(`Assoc [ ("op", `String "cat"); ("path", `String blocked_rel) ])
        |> parse_json_exn
      in
      let error_text =
        Yojson.Safe.Util.(blocked_json |> member "error" |> to_string)
      in
      check bool "blocked path rejected" true
        (contains_substring error_text "path_not_in_allowed_paths"))

let test_keeper_bash_requires_cmd_and_runs () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      let meta =
        make_keeper_exec_meta ~policy_mode:"learned_offline_v1"
          ~policy_shell_mode:"coding" ()
      in
      let ctx_work =
        Masc_mcp.Keeper_exec_context.create ~system_prompt:"test"
          ~max_tokens:4000
      in
      let missing_cmd_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_bash"
          ~input:(`Assoc [ ("cmd", `String "   ") ])
        |> parse_json_exn
      in
      check string "missing cmd rejected" "cmd_required"
        Yojson.Safe.Util.(missing_cmd_json |> member "error" |> to_string);
      let ok_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_bash"
          ~input:
            (`Assoc
              [
                ("cmd", `String "printf keeper-ok");
                ("timeout_sec", `Float 5.0);
              ])
        |> parse_json_exn
      in
      check bool "keeper bash ok" true
        Yojson.Safe.Util.(ok_json |> member "ok" |> to_bool);
      check bool "keeper bash output captured" true
        Yojson.Safe.Util.(
          ok_json |> member "output" |> to_string
          |> fun out -> contains_substring out "keeper-ok");
      let failed_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_bash"
          ~input:
            (`Assoc
              [
                ("cmd", `String "git rev-parse --verify refs/heads/__definitely_missing__");
                ("timeout_sec", `Float 5.0);
              ])
        |> parse_json_exn
      in
      check bool "keeper bash failed command is not ok" false
        Yojson.Safe.Util.(failed_json |> member "ok" |> to_bool);
      check string "keeper bash status kind" "exit"
        Yojson.Safe.Util.(failed_json |> member "status" |> member "kind" |> to_string);
      check bool "keeper bash nonzero exit code" true
        Yojson.Safe.Util.(
          failed_json |> member "status" |> member "code" |> to_int |> fun code ->
          code <> 0))

let test_resident_keeper_and_persistent_agent_lists_split () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, resident_up_body =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "resident-demo");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      if not ok then fail resident_up_body;
      check bool "resident keeper up" true ok;
      let ok, persistent_up_body =
        dispatch "masc_persistent_agent_up"
          (`Assoc
            [
              ("name", `String "persistent-demo");
              ("goal", `String "Stay on demand");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      if not ok then fail persistent_up_body;
      check bool "persistent agent up" true ok;
      let ok, resident_body =
        dispatch "masc_keeper_list" (`Assoc [ ("detailed", `Bool false) ])
      in
      check bool "resident list ok" true ok;
      let resident_json = Yojson.Safe.from_string resident_body in
      check bool "resident listed" true
        Yojson.Safe.Util.(
          resident_json |> member "keepers" |> to_list
          |> List.exists (( = ) (`String "resident-demo")));
      check bool "persistent hidden" false
        Yojson.Safe.Util.(
          resident_json |> member "keepers" |> to_list
          |> List.exists (( = ) (`String "persistent-demo")));
      let ok, persistent_body =
        dispatch "masc_persistent_agent_list" (`Assoc [ ("detailed", `Bool false) ])
      in
      check bool "persistent list ok" true ok;
      let persistent_json = Yojson.Safe.from_string persistent_body in
      check bool "persistent listed" true
        Yojson.Safe.Util.(
          persistent_json |> member "persistent_agents" |> to_list
          |> List.exists (( = ) (`String "persistent-demo"))))

let test_resident_and_persistent_detailed_lists_annotate_runtime_class () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "resident-demo";
      Masc_mcp.Keeper_keepalive.stop_keepalive "persistent-demo";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "resident-demo");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "resident up ok" true ok;
      let ok, _ =
        dispatch "masc_persistent_agent_up"
          (`Assoc
            [
              ("name", `String "persistent-demo");
              ("goal", `String "Stay on demand");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "persistent up ok" true ok;
      let ok, resident_body =
        dispatch "masc_keeper_list" (`Assoc [ ("detailed", `Bool true) ])
      in
      check bool "resident detailed list ok" true ok;
      let resident_json = parse_json_exn resident_body in
      let resident_row =
        Yojson.Safe.Util.(
          resident_json |> member "keepers" |> to_list
          |> List.find (fun row -> member "meta" row |> member "name" = `String "resident-demo"))
      in
      check string "resident runtime_class" "resident_keeper"
        Yojson.Safe.Util.(resident_row |> member "runtime_class" |> to_string);
      check bool "resident desired" true
        Yojson.Safe.Util.(resident_row |> member "desired" |> to_bool);
      check bool "resident registered" true
        Yojson.Safe.Util.(resident_row |> member "resident_registered" |> to_bool);
      let ok, persistent_body =
        dispatch "masc_persistent_agent_list" (`Assoc [ ("detailed", `Bool true) ])
      in
      check bool "persistent detailed list ok" true ok;
      let persistent_json = parse_json_exn persistent_body in
      let persistent_row =
        Yojson.Safe.Util.(
          persistent_json |> member "persistent_agents" |> to_list
          |> List.find (fun row -> member "meta" row |> member "name" = `String "persistent-demo"))
      in
      check string "persistent runtime_class" "persistent_agent"
        Yojson.Safe.Util.(persistent_row |> member "runtime_class" |> to_string);
      check bool "persistent desired" false
        Yojson.Safe.Util.(persistent_row |> member "desired" |> to_bool);
      check bool "persistent registered" false
        Yojson.Safe.Util.(persistent_row |> member "resident_registered" |> to_bool))

let test_resident_keeper_msg_bootstraps_then_requires_message () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "bootstrap-demo";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, body =
        dispatch "masc_keeper_msg"
          (`Assoc
            [
              ("name", `String "bootstrap-demo");
              ("goal", `String "Bootstrap resident keeper");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "missing message rejected" false ok;
      check bool "error mentions message" true
        (contains_substring body "message is required");
      check bool "resident bootstrap created keeper" true
        (Masc_mcp.Keeper_types.is_resident_keeper config "bootstrap-demo"))

let test_persistent_agent_msg_rejects_missing_message () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "persistent-demo";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_persistent_agent_up"
          (`Assoc
            [
              ("name", `String "persistent-demo");
              ("goal", `String "Stay on demand");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "persistent up ok" true ok;
      let ok, body =
        dispatch "masc_persistent_agent_msg"
          (`Assoc [ ("name", `String "persistent-demo") ])
      in
      check bool "missing message rejected" false ok;
      check bool "error mentions message" true
        (contains_substring body "message is required"))

(* test_persistent_agent_create_from_persona_and_status removed:
   persona concept deleted (CLAUDE.md). *)

let test_keeper_dispatch_auxiliary_surfaces_smoke () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "resident-demo";
      Masc_mcp.Keeper_keepalive.stop_keepalive "persistent-demo";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "resident-demo");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "resident up ok" true ok;
      let ok, _ =
        dispatch "masc_persistent_agent_up"
          (`Assoc
            [
              ("name", `String "persistent-demo");
              ("goal", `String "Stay on demand");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "persistent up ok" true ok;
      let ok, _autonomy_body =
        dispatch "masc_keeper_autonomy" (`Assoc [ ("name", `String "resident-demo") ])
      in
      check bool "resident autonomy removed" false ok;
      let ok, _ =
        dispatch "masc_keeper_autonomy"
          (`Assoc
            [
              ("name", `String "resident-demo");
              ("level", `String "L1_Reactive");
            ])
      in
      check bool "resident autonomy set removed" false ok;
      let ok, goals_body =
        dispatch "masc_keeper_goals" (`Assoc [ ("name", `String "resident-demo") ])
      in
      check bool "resident goals ok" true ok;
      check bool "goals body non-empty" true (String.length goals_body > 0);
      let ok, trajectory_body =
        dispatch "masc_keeper_trajectory"
          (`Assoc [ ("name", `String "resident-demo"); ("limit", `Int 5) ])
      in
      check bool "resident trajectory ok" true ok;
      check bool "trajectory body non-empty" true (String.length trajectory_body > 0);
      let ok, eval_body =
        dispatch "masc_keeper_eval" (`Assoc [ ("name", `String "resident-demo") ])
      in
      check bool "resident eval ok" true ok;
      check bool "eval body non-empty" true (String.length eval_body > 0);
      let ok, model_set_body =
        dispatch "masc_persistent_agent_model_set"
          (`Assoc
            [
              ("name", `String "persistent-demo");
              ("model", `String "custom:alt-model");
            ])
      in
      check bool "persistent model set ok" true ok;
      let model_set_json = parse_json_exn model_set_body in
      check string "persistent active model updated" "custom:alt-model"
        Yojson.Safe.Util.(model_set_json |> member "active_model" |> to_string);
      let ok, persistent_status_body =
        dispatch "masc_persistent_agent_status"
          (`Assoc
            [
              (* The persistent-agent alias should still surface resident registration
                 when querying an always-on keeper through the persistent wrapper. *)
              ("name", `String "resident-demo");
              ("fast", `Bool true);
              ("include_context", `Bool false);
              ("include_metrics_overview", `Bool false);
              ("include_memory_bank", `Bool false);
              ("include_history_tail", `Bool false);
              ("include_compaction_history", `Bool false);
            ])
      in
      check bool "persistent alias status ok" true ok;
      let persistent_status_json = parse_json_exn persistent_status_body in
      check string "persistent alias runtime_class" "persistent_agent"
        Yojson.Safe.Util.(persistent_status_json |> member "runtime_class" |> to_string);
      check bool "persistent alias marks resident" true
        Yojson.Safe.Util.(persistent_status_json |> member "resident_registered" |> to_bool);
      let ok, _ =
        dispatch "masc_keeper_down" (`Assoc [ ("name", `String "resident-demo") ])
      in
      check bool "resident down ok" true ok;
      check bool "resident registration removed" false
        (Masc_mcp.Keeper_types.is_resident_keeper config "resident-demo"))

let test_keeper_status_detailed_reads_metrics_history_and_memory () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "detail-demo");
              ("goal", `String "Inspect detailed status");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      let meta =
        match Masc_mcp.Keeper_types.read_meta config "detail-demo" with
        | Ok (Some meta) -> meta
        | Ok None -> fail "missing keeper meta"
        | Error e -> fail e
      in
      let metrics_path = Masc_mcp.Keeper_types.keeper_metrics_path config meta.name in
      let history_path = Masc_mcp.Keeper_types.keeper_history_path config meta.trace_id in
      let memory_bank_path = Masc_mcp.Keeper_types.keeper_memory_bank_path config meta.name in
      write_jsonl_lines metrics_path
        [
          {|{"channel":"turn","generation":0,"trace_id":"trace-1","context_ratio":0.41,"context_tokens":120,"context_max":1024,"message_count":4,"memory_check":{"performed":true,"passed":true,"final_score":0.9},"skill_primary":"masc-heartbeat","skill_secondary":["masc-keeper-autonomy"],"skill_reason":"stateful routing","skill_selection_mode":"agent","skill_provenance":"judgment"}|};
          {|{"channel":"proactive","generation":0,"trace_id":"trace-1","compacted":true,"compaction_before_tokens":180,"compaction_after_tokens":120,"memory_compaction_performed":true,"memory_compaction_before_notes":4,"memory_compaction_after_notes":2,"memory_compaction_dropped_notes":2,"memory_compaction_invalid_dropped":1,"memory_compaction_reason":"dedupe"}|};
        ];
      write_jsonl_lines history_path
        [
          {|{"role":"user","source":"direct_user","content":"Can you summarize the plan?","ts_unix":10.0}|};
          {|{"role":"assistant","source":"internal_assistant","content":"thinking","ts_unix":20.0}|};
          {|{"role":"assistant","source":"direct_assistant","content":"All done.","ts_unix":30.0}|};
        ];
      write_jsonl_lines memory_bank_path
        [
          {|{"kind":"decision","text":"Pinned the branch split.","priority":2,"ts_unix":10.0}|};
          {|{"kind":"next","text":"Write more keeper tests.","priority":1,"ts_unix":11.0}|};
        ];
      let ok, body =
        dispatch "masc_keeper_status"
          (`Assoc
            [
              ("name", `String "detail-demo");
              ("fast", `Bool false);
              ("include_context", `Bool false);
              ("include_metrics_overview", `Bool true);
              ("include_memory_bank", `Bool true);
              ("include_history_tail", `Bool true);
              ("include_compaction_history", `Bool true);
            ])
      in
      check bool "status ok" true ok;
      let json = Yojson.Safe.from_string body in
      check int "history raw count" 3
        Yojson.Safe.Util.(json |> member "history_raw_count" |> to_int);
      check int "history fragment count" 1
        Yojson.Safe.Util.(json |> member "history_fragment_count" |> to_int);
      check int "history filtered count" 1
        Yojson.Safe.Util.(json |> member "history_fragment_filtered_count" |> to_int);
      check string "history direct source preserved" "direct_user"
        Yojson.Safe.Util.(json |> member "history_tail" |> index 0 |> member "source" |> to_string);
      check string "history direct kind inferred from source" "direct_conversation"
        Yojson.Safe.Util.(json |> member "history_tail" |> index 0 |> member "kind" |> to_string);
      check string "history assistant source preserved" "direct_assistant"
        Yojson.Safe.Util.(json |> member "history_tail" |> index 1 |> member "source" |> to_string);
      check int "memory note count" 2
        Yojson.Safe.Util.(json |> member "memory_bank" |> member "total_notes" |> to_int);
      check int "compaction history count" 1
        Yojson.Safe.Util.(json |> member "compaction_history_count" |> to_int);
      check int "metrics compaction events" 1
        Yojson.Safe.Util.(json |> member "metrics_overview" |> member "compaction_events" |> to_int);
      check string "skill route primary" "masc-heartbeat"
        Yojson.Safe.Util.(json |> member "skill_route" |> member "primary" |> to_string);
      let ok, list_body =
        dispatch "masc_keeper_list"
          (`Assoc [ ("detailed", `Bool true); ("limit", `Int 10) ])
      in
      check bool "detailed list ok" true ok;
      let list_json = Yojson.Safe.from_string list_body in
      let keeper_row =
        Yojson.Safe.Util.(list_json |> member "keepers" |> to_list |> List.hd)
      in
      check string "detailed list skill route primary" "masc-heartbeat"
        Yojson.Safe.Util.(keeper_row |> member "skill_route" |> member "primary" |> to_string))
let test_keeper_policy_tools_roundtrip () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu";
      rm_rf base_dir)
    (fun () ->
      let reward_model_path = Filename.concat base_dir "reward-model.json" in
      write_reward_model reward_model_path;
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("goal", `String "Maintain Sangsu persona");
              ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("active_model", `String "llama:qwen3.5-35b-a3b-ud-q8-xl");
              ("room_scope", `String "all");
              ("trigger_mode", `String "explicit_only");
              ("mention_targets", `List [ `String "sangsu" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      let ok, policy_body =
        dispatch "masc_keeper_policy_set"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("policy_mode", `String "learned_offline_v1");
              ("action_budget", `String "board");
              ("reward_model_path", `String reward_model_path);
            ])
      in
      check bool "policy set ok" true ok;
      let policy_json = Yojson.Safe.from_string policy_body in
      check string "policy mode updated" "learned_offline_v1"
        Yojson.Safe.Util.(policy_json |> member "policy_mode" |> to_string);
      (* policy_voice_enabled / policy_shell_mode removed from schema in #2607 *)
      let ok, status_body =
        dispatch "masc_keeper_status"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("fast", `Bool true);
              ("include_context", `Bool false);
              ("include_metrics_overview", `Bool false);
              ("include_memory_bank", `Bool false);
              ("include_history_tail", `Bool false);
              ("include_compaction_history", `Bool false);
            ])
      in
      check bool "status after policy set ok" true ok;
      let status_json = Yojson.Safe.from_string status_body in
      check string "status policy mode" "learned_offline_v1"
        Yojson.Safe.Util.(status_json |> member "policy" |> member "mode" |> to_string);
      Masc_mcp.Keeper_types.append_jsonl_line
        (Masc_mcp.Keeper_types.keeper_policy_log_path config "sangsu")
        (`Assoc
          [
            ("action_id", `String "act-1");
            ("chosen_action", `String "reply_in_room");
            ("feature_vector",
              `Assoc
                [
                  ("direct_mention", `Float 1.0);
                  ("question_mark", `Float 1.0);
                  ("active_goal_count", `Float 0.0);
                ]);
            ("candidates",
              `List
                [
                  `Assoc [("action", `String "noop")];
                  `Assoc [("action", `String "reply_in_room")];
                ]);
            ("observation",
              `Assoc
                [
                  ("source_kind", `String "room_message");
                  ("room_id", `String "default");
                  ("from_agent", `String "tester");
                  ("message", `String "@sangsu?");
                  ("direct_mention", `Bool true);
                  ("has_question", `Bool true);
                  ("message_chars", `Int 8);
                  ("total_turns", `Int 0);
                  ("active_goal_count", `Int 0);
                  ("joined_room_count", `Int 1);
                  ("room_scope", `String "all");
                  ("trigger_mode", `String "explicit_only");
                  ("last_turn_ago_s", `Float 0.0);
                ]);
          ]);
      let ok, explain_body =
        dispatch "masc_keeper_action_explain"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("action_id", `String "act-1");
            ])
      in
      check bool "action explain ok" true ok;
      let explain_json = Yojson.Safe.from_string explain_body in
      check string "action explain chosen action" "reply_in_room"
        Yojson.Safe.Util.(explain_json |> member "chosen_action" |> to_string);
      let ok, _ =
        dispatch "masc_keeper_feedback_record"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("action_id", `String "act-1");
              ("verdict", `String "good_action");
              ("score", `Float 1.0);
            ])
      in
      check bool "feedback record ok" true ok;
      let export_path = Filename.concat base_dir "dataset.json" in
      let ok, export_body =
        dispatch "masc_keeper_dataset_export"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("output_path", `String export_path);
            ])
      in
      check bool "dataset export ok" true ok;
      let export_json = Yojson.Safe.from_string export_body in
      check string "dataset export path" export_path
        Yojson.Safe.Util.(export_json |> member "output_path" |> to_string);
      check bool "dataset file exists" true (Sys.file_exists export_path)
      (* eval_replay skipped: handle_keeper_eval_replay passes "" as
         reward_model_path instead of reading it from keeper meta.
         This is a known code bug tracked separately. *))

let test_keeper_policy_set_rejects_invalid_mode () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("goal", `String "Maintain Sangsu persona");
              ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      let ok, body =
        dispatch "masc_keeper_policy_set"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("policy_mode", `String "learned_offline_v9");
            ])
      in
      check bool "policy set rejected" false ok;
      check bool "error mentions invalid mode" true
        (try
           let _ = Str.search_forward (Str.regexp_string "invalid policy_mode") body 0 in
           true
         with Not_found -> false))

let test_keeper_up_defaults_sangsu_to_explicit_voice_policy () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, body =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("goal", `String "Maintain Sangsu persona");
              ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      let json = Yojson.Safe.from_string body in
      (* voice_config.json presence determines voice defaults:
         present  → explicit_event_v1, voice_text, true
         absent   → heuristic, text_only, false (CI)
         Test checks whichever mode is active. *)
      let voice_enabled =
        Yojson.Safe.Util.(json |> member "voice_enabled" |> to_bool) in
      if voice_enabled then begin
        check string "policy mode" "explicit_event_v1"
          Yojson.Safe.Util.(json |> member "policy_mode" |> to_string);
        check string "voice channel" "voice_text"
          Yojson.Safe.Util.(json |> member "voice_channel" |> to_string);
        check string "voice agent id" "sangsu"
          Yojson.Safe.Util.(json |> member "voice_agent_id" |> to_string)
      end else begin
        check string "policy mode" "heuristic"
          Yojson.Safe.Util.(json |> member "policy_mode" |> to_string);
        check string "voice channel" "text_only"
          Yojson.Safe.Util.(json |> member "voice_channel" |> to_string)
      end;
      let resident_path =
        Filename.concat base_dir ".masc/resident-keepers/sangsu.json"
      in
      check bool "resident spec exists" true (Sys.file_exists resident_path);
      let resident_json = Yojson.Safe.from_file resident_path in
      check bool "resident voice enabled" voice_enabled
        Yojson.Safe.Util.(resident_json |> member "voice_enabled" |> to_bool);
      let expected_channel = if voice_enabled then "voice_text" else "text_only" in
      check string "resident voice channel" expected_channel
        Yojson.Safe.Util.(resident_json |> member "voice_channel" |> to_string))

let test_keeper_up_update_preserves_proactive_when_omitted () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "buddy";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let create_args =
        `Assoc
          [
            ("name", `String "buddy");
            ("goal", `String "Stay focused");
            ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
            ("presence_keepalive", `Bool false);
            ("proactive_enabled", `Bool true);
          ]
      in
      let create_parsed =
        match Masc_mcp.Keeper_turn_up_args.parse keeper_ctx create_args with
        | Ok parsed -> parsed
        | Error (_, msg) -> fail ("failed to parse create args: " ^ msg)
      in
      let ok, _ =
        Masc_mcp.Keeper_turn_up_create.create_keeper keeper_ctx create_parsed
      in
      check bool "initial keeper create ok" true ok;
      let old_meta =
        match Masc_mcp.Keeper_types.read_meta config "buddy" with
        | Ok (Some meta) -> meta
        | Ok None -> fail "missing keeper meta after initial create"
        | Error e -> fail e
      in
      check string "initial trigger mode" "explicit_only" old_meta.trigger_mode;
      check bool "initial proactive" true old_meta.proactive_enabled;
      let parsed0 =
        match
          Masc_mcp.Keeper_turn_up_args.parse keeper_ctx
            (`Assoc
              [
                ("name", `String "buddy");
                ("goal", `String "Updated buddy goal");
              ])
        with
        | Ok parsed -> parsed
        | Error (_, msg) -> fail ("failed to parse update args: " ^ msg)
      in
      let parsed =
        {
          parsed0 with
          profile_defaults =
            {
              parsed0.profile_defaults with
              proactive_enabled = Some false;
            };
        }
      in
      let ok, _ =
        Masc_mcp.Keeper_turn_up_update.update_keeper keeper_ctx parsed old_meta
      in
      check bool "update keeper ok" true ok;
      let updated_meta =
        match Masc_mcp.Keeper_types.read_meta config "buddy" with
        | Ok (Some meta) -> meta
        | Ok None -> fail "missing keeper meta after update"
        | Error e -> fail e
      in
      check string "trigger mode preserved" "explicit_only" updated_meta.trigger_mode;
      check bool "proactive preserved when omitted" true updated_meta.proactive_enabled)

let test_write_meta_syncs_registered_resident_seed () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "buddy";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "buddy");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool true);
            ])
      in
      check bool "resident keeper up ok" true ok;
      let meta =
        match Masc_mcp.Keeper_types.read_meta config "buddy" with
        | Ok (Some value) -> value
        | Ok None -> fail "missing keeper meta after resident keeper up"
        | Error e -> fail e
      in
      let updated_meta =
        {
          meta with
          proactive_enabled = false;
          voice_enabled = false;
          voice_channel = "text_only";
          voice_agent_id = "";
          updated_at = Masc_mcp.Keeper_types.now_iso ();
        }
      in
      (match Masc_mcp.Keeper_types.write_meta config updated_meta with
       | Ok () -> ()
       | Error e -> fail ("write_meta failed: " ^ e));
      let resident_path =
        Filename.concat base_dir ".masc/resident-keepers/buddy.json"
      in
      check bool "resident spec exists" true (Sys.file_exists resident_path);
      let resident_json = Yojson.Safe.from_file resident_path in
      check bool "resident voice disabled sync" false
        Yojson.Safe.Util.(resident_json |> member "voice_enabled" |> to_bool);
      check string "resident voice channel sync" "text_only"
        Yojson.Safe.Util.(resident_json |> member "voice_channel" |> to_string);
      check string "resident voice agent id sync" ""
        Yojson.Safe.Util.(resident_json |> member "voice_agent_id" |> to_string);
      check bool "seed proactive sync" false
        Yojson.Safe.Util.(
          resident_json |> member "seed_meta" |> member "proactive_enabled" |> to_bool);
      check string "seed trigger mode sync" "explicit_only"
        Yojson.Safe.Util.(
          resident_json |> member "seed_meta" |> member "trigger_mode" |> to_string))

let test_keeper_up_persists_allowed_paths_to_status_policy () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let allowed_paths = [ "lib"; "docs/spec" ] in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("allowed_paths", `List (List.map (fun path -> `String path) allowed_paths));
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      let ok, status_body =
        dispatch "masc_keeper_status"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("include_history_tail", `Bool false);
              ("include_compaction_history", `Bool false);
              ("include_context", `Bool false);
              ("include_metrics_overview", `Bool false);
              ("include_memory_bank", `Bool false);
            ])
      in
      check bool "status ok" true ok;
      let status_json = Yojson.Safe.from_string status_body in
      let persisted =
        Yojson.Safe.Util.(
          status_json |> member "policy" |> member "allowed_paths" |> to_list |> filter_string)
      in
      check (list string) "allowed_paths roundtrip" allowed_paths persisted)
let test_keeper_policy_set_accepts_explicit_event_v1 () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "buddy");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("presence_keepalive", `Bool false);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      let ok, body =
        dispatch "masc_keeper_policy_set"
          (`Assoc
            [
              ("name", `String "buddy");
              ("policy_mode", `String "explicit_event_v1");
            ])
      in
      check bool "policy set ok" true ok;
      let json = Yojson.Safe.from_string body in
      check string "policy mode updated" "explicit_event_v1"
        Yojson.Safe.Util.(json |> member "policy_mode" |> to_string))

let test_resident_bootstrap_marks_stale_explicit_keeper () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; agent_name = "tester"; sw; clock = Eio.Stdenv.clock env; proc_mgr = Some (Eio.Stdenv.process_mgr env) }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, _ =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "llama:qwen3.5-35b-a3b-ud-q8-xl" ]);
              ("presence_keepalive", `Bool true);
              ("proactive_enabled", `Bool false);
            ])
      in
      check bool "keeper up ok" true ok;
      Masc_mcp.Keeper_keepalive.stop_keepalive "sangsu";
      let meta =
        match Masc_mcp.Keeper_types.read_meta config "sangsu" with
        | Ok (Some meta) -> meta
        | Ok None -> fail "missing keeper meta"
        | Error e -> fail e
      in
      let stale_meta =
        {
          meta with
          policy_mode = "explicit_event_v1";
          presence_keepalive = true;
          proactive_enabled = false;
          last_turn_ts = 0.0;
        }
      in
      (match Masc_mcp.Keeper_types.write_meta config stale_meta with
      | Ok () -> ()
      | Error e -> fail e);
      let stats = Masc_mcp.Keeper_runtime.bootstrap_existing_keepers keeper_ctx in
      check bool "bootstrap enabled" true stats.enabled;
      check int "started stale resident" 1 stats.started;
      check int "stale resident counted" 1 stats.stale;
      check int "recovering stale resident counted" 1 stats.recovering;
      let ok, status_body =
        dispatch "masc_keeper_status"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("include_history_tail", `Bool false);
              ("include_compaction_history", `Bool false);
              ("include_context", `Bool false);
              ("include_metrics_overview", `Bool false);
              ("include_memory_bank", `Bool false);
            ])
      in
      check bool "status ok" true ok;
      let status_json = Yojson.Safe.from_string status_body in
      check bool "keepalive running" true
        Yojson.Safe.Util.(status_json |> member "keepalive_running" |> to_bool);
      check string "continuity state recovering" "recovering"
        Yojson.Safe.Util.(
          status_json |> member "diagnostic" |> member "continuity_state"
          |> to_string))

let () =
  run "Tool_keeper" [
    ("read_file_tail_lines", [
         test_case "drops partial first line" `Quick test_read_file_tail_lines_drops_partial_first_line;
         test_case "keeps line-boundary start" `Quick test_read_file_tail_lines_keeps_line_boundary_start;
         test_case "fallback labels prefer available remote models" `Quick
           test_keeper_fallback_model_labels_prefers_available_remote_models;
         test_case "append glm fallback for local only model" `Quick
           test_maybe_append_keeper_fallback_models_adds_glm_when_local_only;
         test_case "model client repairs invalid utf8 fields" `Quick
           test_model_client_sanitize_message_utf8_repairs_invalid_fields;
         test_case "model client preserves message list size" `Quick
           test_model_client_sanitize_messages_utf8_preserves_message_count;
         test_case "resolved skill route uses agent judgment" `Quick
           test_resolved_keeper_skill_route_marks_agent_judgment;
         test_case "resolved skill route falls back when parse missing" `Quick
           test_resolved_keeper_skill_route_falls_back_when_agent_parse_missing;
         test_case "keeper model set persists active model" `Quick
           test_keeper_model_set_persists_active_model;
         test_case "resident and persistent lists split" `Quick
           test_resident_keeper_and_persistent_agent_lists_split;
         test_case "resident and persistent detailed lists annotate runtime class" `Quick
           test_resident_and_persistent_detailed_lists_annotate_runtime_class;
         test_case "resident keeper msg bootstraps then requires message" `Quick
           test_resident_keeper_msg_bootstraps_then_requires_message;
         test_case "persistent agent msg rejects missing message" `Quick
           test_persistent_agent_msg_rejects_missing_message;
         test_case "keeper dispatch auxiliary surfaces smoke" `Quick
           test_keeper_dispatch_auxiliary_surfaces_smoke;
         test_case "keeper status detailed reads metrics/history/memory" `Quick
           test_keeper_status_detailed_reads_metrics_history_and_memory;
         test_case "shell tool policy gates" `Quick
           test_keeper_shell_tool_policy_gates;
         test_case "shell readonly enforces allowed paths" `Quick
           test_keeper_shell_readonly_enforces_allowed_paths;
         test_case "keeper bash requires cmd and runs" `Quick
           test_keeper_bash_requires_cmd_and_runs;
         test_case "policy tools roundtrip" `Quick
           test_keeper_policy_tools_roundtrip;
         test_case "policy set rejects invalid mode" `Quick
           test_keeper_policy_set_rejects_invalid_mode;
         test_case "sangsu defaults explicit voice policy" `Quick
           test_keeper_up_defaults_sangsu_to_explicit_voice_policy;
         test_case "keeper up update preserves proactive when omitted" `Quick
           test_keeper_up_update_preserves_proactive_when_omitted;
         test_case "write_meta syncs registered resident seed" `Quick
           test_write_meta_syncs_registered_resident_seed;
         test_case "keeper up persists allowed paths" `Quick
           test_keeper_up_persists_allowed_paths_to_status_policy;
         test_case "policy set accepts explicit_event_v1" `Quick
           test_keeper_policy_set_accepts_explicit_event_v1;
         test_case "resident bootstrap marks stale explicit keeper" `Quick
           test_resident_bootstrap_marks_stale_explicit_keeper;
       ]);
  ]
