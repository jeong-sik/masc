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
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  let len = String.length contents in
  let b_index = String.index contents 'B' in
  let start = b_index + 2 in
  let max_bytes = len - start in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Tool_keeper.read_file_tail_lines path ~max_bytes ~max_lines:10 in
    check (list string) "drops partial fragment" ["CCCCC"; "DDDDD"] lines)

let test_read_file_tail_lines_keeps_line_boundary_start () =
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  let len = String.length contents in
  let b_index = String.index contents 'B' in
  let max_bytes = len - b_index in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Tool_keeper.read_file_tail_lines path ~max_bytes ~max_lines:10 in
    check (list string) "keeps full first line" ["BBBBB"; "CCCCC"; "DDDDD"] lines)

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
              let labels = Masc_mcp.Tool_keeper.keeper_fallback_model_labels () in
              check (list string) "glm fallback only" ["glm:glm-4.7"] labels)))

let test_maybe_append_keeper_fallback_models_adds_glm_when_local_only () =
  with_env "ZAI_API_KEY" "zai-test" (fun () ->
      let labels =
        Masc_mcp.Tool_keeper.maybe_append_keeper_fallback_models
          ["llama:qwen3.5-35b-a3b-ud-q8-xl"]
      in
      let llama_listening =
        match Masc_mcp.Tool_keeper.model_specs_of_strings ["llama:qwen3.5-35b-a3b-ud-q8-xl"] with
        | Ok [spec] -> Masc_mcp.Tool_keeper.model_spec_is_available spec
        | _ -> false
      in
      let expected =
        if llama_listening then
          ["llama:qwen3.5-35b-a3b-ud-q8-xl"]
        else
          ["llama:qwen3.5-35b-a3b-ud-q8-xl"; "glm:glm-4.7"]
      in
      check (list string) "append glm fallback only when local runtime unavailable"
        expected labels)

let test_llm_client_sanitize_message_utf8_repairs_invalid_fields () =
  let raw =
    {
      Masc_mcp.Llm_client.role = Masc_mcp.Llm_client.User;
      content = "hello\x80.world";
      name = Some "to\xFFol";
      tool_call_id = Some "id\x80";
    }
  in
  let sanitized = Masc_mcp.Llm_client.sanitize_message_utf8 raw in
  check bool "role preserved" true (sanitized.role = raw.role);
  check bool "content valid utf8" true (string_is_valid_utf8 sanitized.content);
  check bool "content changed" true (sanitized.content <> raw.content);
  check bool "name valid utf8" true
    (match sanitized.name with Some v -> string_is_valid_utf8 v | None -> false);
  check bool "tool_call_id valid utf8" true
    (match sanitized.tool_call_id with Some v -> string_is_valid_utf8 v | None -> false);
  check bool "name kept present" true (Option.is_some sanitized.name);
  check bool "tool_call_id kept present" true (Option.is_some sanitized.tool_call_id)

let test_llm_client_sanitize_messages_utf8_preserves_message_count () =
  let msgs =
    [
      Masc_mcp.Llm_client.user_msg "ok\x80";
      Masc_mcp.Llm_client.assistant_msg "fine\xFF";
    ]
  in
  let sanitized = Masc_mcp.Llm_client.sanitize_messages_utf8 msgs in
  check int "count preserved" 2 (List.length sanitized);
  check bool "all valid utf8" true
    (List.for_all
       (fun (msg : Masc_mcp.Llm_client.message) -> string_is_valid_utf8 msg.content)
       sanitized)

let test_resolved_keeper_skill_route_marks_agent_judgment () =
  let fallback_route : Masc_mcp.Tool_keeper.keeper_skill_route = {
    primary_skill = "masc-heartbeat";
    secondary_skills = [ "masc-keeper-autonomy" ];
    reason = "fallback";
  } in
  let reply =
    "SKILL: lodge-social (+masc-heartbeat)\nSKILL_REASON: agent-selected\nActual reply body"
  in
  let resolved =
    Masc_mcp.Tool_keeper.resolved_keeper_skill_route
      ~selection_mode:Masc_mcp.Tool_keeper.SkillSelectAgent
      ~fallback_route
      ~reply_raw:reply
  in
  check string "selection mode" "agent" resolved.selection_mode;
  check string "provenance" "judgment" resolved.provenance;
  check string "primary skill" "lodge-social" resolved.route.primary_skill

let test_resolved_keeper_skill_route_falls_back_when_agent_parse_missing () =
  let fallback_route : Masc_mcp.Tool_keeper.keeper_skill_route = {
    primary_skill = "masc-heartbeat";
    secondary_skills = [ "masc-keeper-autonomy" ];
    reason = "fallback";
  } in
  let resolved =
    Masc_mcp.Tool_keeper.resolved_keeper_skill_route
      ~selection_mode:Masc_mcp.Tool_keeper.SkillSelectAgent
      ~fallback_route
      ~reply_raw:"No skill header here"
  in
  check string "selection mode" "heuristic" resolved.selection_mode;
  check string "provenance" "fallback" resolved.provenance;
  check string "primary skill" "masc-heartbeat" resolved.route.primary_skill

let test_keeper_model_set_persists_active_model () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; sw; clock = Eio.Stdenv.clock env }
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
              ("models", `List [ `String "custom:initial-model" ]);
              ("active_model", `String "custom:initial-model");
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
              ("model", `String "custom:updated-model");
            ])
      in
      check bool "model set ok" true ok;
      let json = Yojson.Safe.from_string body in
      check string "active model updated" "custom:updated-model"
        Yojson.Safe.Util.(json |> member "active_model" |> to_string);
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
      check string "status active model" "custom:updated-model"
        Yojson.Safe.Util.(status_json |> member "active_model" |> to_string))

let write_persona_profile ~me_root ~persona_name ~content =
  let persona_dir = Filename.concat (Filename.concat me_root "personas") persona_name in
  mkdir_p persona_dir;
  let profile_path = Filename.concat persona_dir "profile.json" in
  let oc = open_out profile_path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

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
        "active_goal_count": 0.8
      }
    }
  }
}|})

let test_persona_list_and_create_from_persona () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let me_root = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      rm_rf base_dir;
      rm_rf me_root)
    (fun () ->
      write_persona_profile ~me_root ~persona_name:"sangsu"
        ~content:
          {|{
  "name": "상수",
  "role": "홍상수 영화 속 찌질한 40대 남자",
  "trait": "직설적이고 현실적",
  "keeper": {
    "goal": "상수처럼 대화한다",
    "models": ["llama:qwen3.5-35b-a3b-ud-q8-xl"],
    "allowed_models": ["llama:qwen3.5-35b-a3b-ud-q8-xl"],
    "active_model": "llama:qwen3.5-35b-a3b-ud-q8-xl",
    "room_scope": "all",
    "trigger_mode": "explicit_only",
    "mention_targets": ["sangsu"],
    "presence_keepalive": false,
    "proactive_enabled": false
  }
}|};
      with_env "ME_ROOT" me_root (fun () ->
        let config = Masc_mcp.Room.default_config base_dir in
        ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
        let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
          { config; sw; clock = Eio.Stdenv.clock env }
        in
        let dispatch name args =
          match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
          | Some result -> result
          | None -> fail ("missing dispatch for " ^ name)
        in
        let ok, list_body = dispatch "masc_persona_list" (`Assoc []) in
        check bool "persona list ok" true ok;
        let list_json = Yojson.Safe.from_string list_body in
        check bool "contains sangsu" true
          Yojson.Safe.Util.(
            list_json |> member "personas" |> to_list
            |> List.exists (fun row -> member "persona_name" row = `String "sangsu"));
        let ok, dry_body =
          dispatch "masc_keeper_create_from_persona"
            (`Assoc
              [
                ("persona_name", `String "sangsu");
                ("dry_run", `Bool true);
              ])
        in
        check bool "dry run ok" true ok;
        let dry_json = Yojson.Safe.from_string dry_body in
        check bool "dry run resident" true
          Yojson.Safe.Util.(dry_json |> member "resident" |> to_bool);
        check string "dry run trigger mode" "explicit_only"
          Yojson.Safe.Util.(dry_json |> member "resolved_args" |> member "trigger_mode" |> to_string);
        let ok, create_body =
          dispatch "masc_keeper_create_from_persona"
            (`Assoc
              [
                ("persona_name", `String "sangsu");
                ("name", `String "sangsu");
              ])
        in
        check bool "create ok" true ok;
        let create_json = Yojson.Safe.from_string create_body in
        check bool "created true" true Yojson.Safe.Util.(create_json |> member "created" |> to_bool);
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
        check string "status room scope" "all"
          Yojson.Safe.Util.(status_json |> member "meta" |> member "room_scope" |> to_string)))

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
        { config; sw; clock = Eio.Stdenv.clock env }
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
      check bool "resident keeper up" true ok;
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

let test_keeper_policy_tools_roundtrip () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let reward_model_path = Filename.concat base_dir "reward-model.json" in
      write_reward_model reward_model_path;
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; sw; clock = Eio.Stdenv.clock env }
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
      Masc_mcp.Tool_keeper.append_jsonl_line
        (Masc_mcp.Tool_keeper.keeper_policy_log_path config "sangsu")
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
      check bool "dataset file exists" true (Sys.file_exists export_path);
      let ok, replay_body =
        dispatch "masc_keeper_eval_replay"
          (`Assoc
            [
              ("name", `String "sangsu");
              ("limit", `Int 10);
            ])
      in
      check bool "eval replay ok" true ok;
      let replay_json = Yojson.Safe.from_string replay_body in
      check int "replayed count" 1
        Yojson.Safe.Util.(replay_json |> member "replayed_count" |> to_int))

let test_keeper_policy_set_rejects_invalid_mode () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        { config; sw; clock = Eio.Stdenv.clock env }
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

let () =
  run "Tool_keeper" [
    ("read_file_tail_lines", [
         test_case "drops partial first line" `Quick test_read_file_tail_lines_drops_partial_first_line;
         test_case "keeps line-boundary start" `Quick test_read_file_tail_lines_keeps_line_boundary_start;
         test_case "fallback labels prefer available remote models" `Quick
           test_keeper_fallback_model_labels_prefers_available_remote_models;
         test_case "append glm fallback for local only model" `Quick
           test_maybe_append_keeper_fallback_models_adds_glm_when_local_only;
         test_case "llm client repairs invalid utf8 fields" `Quick
           test_llm_client_sanitize_message_utf8_repairs_invalid_fields;
         test_case "llm client preserves message list size" `Quick
           test_llm_client_sanitize_messages_utf8_preserves_message_count;
         test_case "resolved skill route uses agent judgment" `Quick
           test_resolved_keeper_skill_route_marks_agent_judgment;
         test_case "resolved skill route falls back when parse missing" `Quick
           test_resolved_keeper_skill_route_falls_back_when_agent_parse_missing;
         test_case "keeper model set persists active model" `Quick
           test_keeper_model_set_persists_active_model;
         test_case "persona list and create from persona" `Quick
           test_persona_list_and_create_from_persona;
         test_case "resident and persistent lists split" `Quick
           test_resident_keeper_and_persistent_agent_lists_split;
         test_case "policy tools roundtrip" `Quick
           test_keeper_policy_tools_roundtrip;
         test_case "policy set rejects invalid mode" `Quick
           test_keeper_policy_set_rejects_invalid_mode;
       ]);
  ]
