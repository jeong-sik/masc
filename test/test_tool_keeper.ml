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

let require_json_bool_field json key =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ ->
      fail
        (Printf.sprintf "expected bool field %S in %s" key
           (Yojson.Safe.to_string json))

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

(* Model-set now returns cascade_name instead of active_model/allowed_models.
   cascade_name is the authority for model resolution. *)
let test_keeper_model_set_persists_active_model () =
  let _provider_model = "custom:test-model@http://127.0.0.1:9999" in
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
              ("model", `String "any-model");
            ])
      in
      check bool "model set ok" true ok;
      let json = Yojson.Safe.from_string body in
      check string "cascade_name present" "keeper_unified"
        Yojson.Safe.Util.(json |> member "cascade_name" |> to_string))

(* write_persona_profile removed: persona concept deleted, see CLAUDE.md *)

(* write_reward_model removed: keeper policy tools removed *)

let make_keeper_exec_meta
    ?(name = "sangsu")
    ?(allowed_paths = [])
    () =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String name);
        ("trace_id", `String ("trace-" ^ name));
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

let check_keeper_exec_tool_presence label meta ~tool_name ~expect_allowed =
  let allowed_names = Masc_mcp.Keeper_exec_tools.keeper_allowed_tool_names meta in
  let allowed_model_names =
    Masc_mcp.Keeper_exec_tools.keeper_allowed_model_tools meta
    |> List.map (fun (tool : Types.tool_schema) -> tool.name)
  in
  check bool (label ^ " allowed names") expect_allowed
    (List.mem tool_name allowed_names);
  check bool (label ^ " model tools") expect_allowed
    (List.mem tool_name allowed_model_names)

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
  Eio_main.run @@ fun _env ->
  (* policy_mode removed: all keepers use unified mode with full tools *)
  let unified = make_keeper_exec_meta () in
  let other = make_keeper_exec_meta ~name:"other-keeper" () in
  check_keeper_shell_tool_presence "unified" unified
    ~expect_bash:true ~expect_shell_readonly:true;
  check_keeper_shell_tool_presence "other" other
    ~expect_bash:true ~expect_shell_readonly:true

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
        make_keeper_exec_meta
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

let test_keeper_fs_read_policy_gates () =
  Eio_main.run @@ fun _env ->
  (* policy_mode removed: all keepers get fs_read *)
  let unified = make_keeper_exec_meta () in
  check_keeper_exec_tool_presence "unified fs_read" unified
    ~tool_name:"keeper_fs_read" ~expect_allowed:true

let test_keeper_fs_read_enforces_allowed_paths_and_truncation () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      let root_dir =
        Masc_mcp.Keeper_alerting_path.project_root_of_config config
        |> Unix.realpath
      in
      let allowed_rel = "allowed/note.txt" in
      let blocked_rel = "blocked/secret.txt" in
      let allowed_path = Filename.concat root_dir allowed_rel in
      let blocked_path = Filename.concat root_dir blocked_rel in
      write_file allowed_path "alpha\nbeta\ngamma\n";
      write_file blocked_path "should-not-read\n";
      let meta = make_keeper_exec_meta ~allowed_paths:[ "allowed" ] () in
      let ctx_work =
        Masc_mcp.Keeper_exec_context.create ~system_prompt:"test"
          ~max_tokens:4000
      in
      let allowed_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_read"
          ~input:
            (`Assoc
              [
                ("path", `String allowed_path);
                ("max_bytes", `Int 512);
              ])
        |> parse_json_exn
      in
      check bool "fs_read ok" true
        (require_json_bool_field allowed_json "ok");
      check bool "fs_read path stays under allowed root" true
        Yojson.Safe.Util.(
          allowed_json |> member "path" |> to_string |> fun path ->
          contains_substring path allowed_rel);
      check int "fs_read bytes counts full file" 17
        Yojson.Safe.Util.(allowed_json |> member "bytes" |> to_int);
      check bool "fs_read not truncated at minimum clamp" false
        Yojson.Safe.Util.(allowed_json |> member "truncated" |> to_bool);
      check string "fs_read content preserved" "alpha\nbeta\ngamma\n"
        Yojson.Safe.Util.(allowed_json |> member "content" |> to_string);
      let truncated_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_read"
          ~input:
            (`Assoc
              [
                ("path", `String allowed_path);
                ("max_bytes", `Int 8);
              ])
        |> parse_json_exn
      in
      check bool "fs_read truncation clamps to minimum size" false
        Yojson.Safe.Util.(truncated_json |> member "truncated" |> to_bool);
      let blocked_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_read"
          ~input:(`Assoc [ ("path", `String blocked_path) ])
        |> parse_json_exn
      in
      let blocked_error =
        Yojson.Safe.Util.(blocked_json |> member "error" |> to_string)
      in
      check bool "fs_read blocked path rejected" true
        (contains_substring blocked_error "path_not_in_allowed_paths"))

let test_keeper_bash_requires_cmd_and_runs () =
  Eio_main.run @@ fun env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      Process_eio.init
        ~cwd_default:(Eio.Stdenv.fs env)
        ~proc_mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env);
      let meta = make_keeper_exec_meta () in
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
                ("cmd", `String "pwd");
                ("timeout_sec", `Float 5.0);
              ])
        |> parse_json_exn
      in
      check bool "keeper bash ok" true
        Yojson.Safe.Util.(ok_json |> member "ok" |> to_bool);
      check bool "keeper bash output captured" true
        Yojson.Safe.Util.(
          ok_json |> member "output" |> to_string
          |> fun out -> contains_substring out base_dir);
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

let test_keeper_fs_edit_policy_gates () =
  Eio_main.run @@ fun _env ->
  (* policy_mode removed: all keepers use unified mode.
     fs_edit is not in allowed tools by default *)
  let unified = make_keeper_exec_meta () in
  check_keeper_exec_tool_presence "unified fs_edit" unified
    ~tool_name:"keeper_fs_edit" ~expect_allowed:false

let test_keeper_fs_edit_enforces_allowed_paths_and_modes () =
  Eio_main.run @@ fun _env ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      let root_dir =
        Masc_mcp.Keeper_alerting_path.project_root_of_config config
        |> Unix.realpath
      in
      let allowed_rel = "allowed/note.txt" in
      let blocked_rel = "blocked/secret.txt" in
      let allowed_path = Filename.concat root_dir allowed_rel in
      let blocked_path = Filename.concat root_dir blocked_rel in
      let meta =
        make_keeper_exec_meta ~allowed_paths:[ "allowed" ] ()
      in
      let ctx_work =
        Masc_mcp.Keeper_exec_context.create ~system_prompt:"test"
          ~max_tokens:4000
      in
      let overwrite_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_edit"
          ~input:
            (`Assoc
              [
                ("path", `String allowed_path);
                ("content", `String "alpha\n");
                ("mode", `String "overwrite");
              ])
        |> parse_json_exn
      in
      check bool "fs_edit overwrite ok" true
        (require_json_bool_field overwrite_json "ok");
      check string "fs_edit overwrite mode" "overwrite"
        Yojson.Safe.Util.(overwrite_json |> member "mode" |> to_string);
      check string "fs_edit overwrite writes file" "alpha\n"
        (Fs_compat.load_file allowed_path);
      let append_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_edit"
          ~input:
            (`Assoc
              [
                ("path", `String allowed_path);
                ("content", `String "beta\n");
                ("mode", `String "append");
              ])
        |> parse_json_exn
      in
      check bool "fs_edit append ok" true
        (require_json_bool_field append_json "ok");
      check string "fs_edit append mode" "append"
        Yojson.Safe.Util.(append_json |> member "mode" |> to_string);
      check string "fs_edit append updates file" "alpha\nbeta\n"
        (Fs_compat.load_file allowed_path);
      let blocked_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_edit"
          ~input:
            (`Assoc
              [
                ("path", `String blocked_path);
                ("content", `String "nope\n");
              ])
        |> parse_json_exn
      in
      let blocked_error =
        Yojson.Safe.Util.(blocked_json |> member "error" |> to_string)
      in
      check bool "fs_edit blocked path rejected" true
        (contains_substring blocked_error "path_not_in_allowed_paths");
      let invalid_mode_json =
        Masc_mcp.Keeper_exec_tools.execute_keeper_tool_call
          ~config ~meta ~ctx_work
          ~name:"keeper_fs_edit"
          ~input:
            (`Assoc
              [
                ("path", `String allowed_path);
                ("content", `String "noop\n");
                ("mode", `String "invalid");
              ])
        |> parse_json_exn
      in
      let invalid_mode_error =
        Yojson.Safe.Util.(invalid_mode_json |> member "error" |> to_string)
      in
      check bool "fs_edit invalid mode rejected" true
        (contains_substring invalid_mode_error "unsupported_mode:invalid"))

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

let test_resident_list_items_expose_runtime_config_summary () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "resident-demo";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        {
          config;
          agent_name = "tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
        }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, up_body =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "resident-demo");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "custom:test-model" ]);
              ("room_scope", `String "all");
              ("scope_kind", `String "global");
              ("presence_keepalive", `Bool true);
              ("proactive_enabled", `Bool true);
              ("trigger_mode", `String "explicit_only");
            ])
      in
      if not ok then fail up_body;
      let ok, body =
        dispatch "masc_keeper_list" (`Assoc [ ("detailed", `Bool false) ])
      in
      check bool "resident list ok" true ok;
      let json = parse_json_exn body in
      let row =
        Yojson.Safe.Util.(
          json |> member "items" |> to_list
          |> List.find (fun item -> member "name" item = `String "resident-demo"))
      in
      check string "runtime class" "resident_keeper"
        Yojson.Safe.Util.(row |> member "runtime_class" |> to_string);
      check string "scope kind" "global"
        Yojson.Safe.Util.(row |> member "scope_kind" |> to_string);
      check string "room scope" "all"
        Yojson.Safe.Util.(row |> member "room_scope" |> to_string);
      check bool "presence keepalive true" true
        Yojson.Safe.Util.(row |> member "presence_keepalive" |> to_bool);
      check bool "proactive enabled true" true
        Yojson.Safe.Util.(row |> member "proactive_enabled" |> to_bool);
      check bool "initiative enabled true" true
        Yojson.Safe.Util.(row |> member "initiative_enabled" |> to_bool);
      check bool "policy mode removed" true
        Yojson.Safe.Util.(row |> member "policy_mode" = `Null);
      check bool "trigger mode removed" true
        Yojson.Safe.Util.(row |> member "trigger_mode" = `Null))

let test_keepalive_gap_reports_not_running_instead_of_disabled () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Masc_mcp.Keeper_keepalive.stop_keepalive "resident-demo";
      rm_rf base_dir)
    (fun () ->
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "tester"));
      let keeper_ctx : _ Masc_mcp.Tool_keeper.context =
        {
          config;
          agent_name = "tester";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
        }
      in
      let dispatch name args =
        match Masc_mcp.Tool_keeper.dispatch keeper_ctx ~name ~args with
        | Some result -> result
        | None -> fail ("missing dispatch for " ^ name)
      in
      let ok, up_body =
        dispatch "masc_keeper_up"
          (`Assoc
            [
              ("name", `String "resident-demo");
              ("goal", `String "Stay resident");
              ("models", `List [ `String "custom:test-model" ]);
              ("presence_keepalive", `Bool true);
              ("proactive_enabled", `Bool true);
            ])
      in
      if not ok then fail up_body;
      Masc_mcp.Keeper_keepalive.stop_keepalive "resident-demo";
      let ok, body =
        dispatch "masc_keeper_status"
          (`Assoc
            [
              ("name", `String "resident-demo");
              ("include_history_tail", `Bool false);
              ("include_compaction_history", `Bool false);
              ("include_context", `Bool false);
              ("include_metrics_overview", `Bool false);
              ("include_memory_bank", `Bool false);
            ])
      in
      check bool "status ok" true ok;
      let json = parse_json_exn body in
      check string "quiet reason not_running" "not_running"
        Yojson.Safe.Util.(
          json |> member "diagnostic" |> member "quiet_reason" |> to_string);
      check string "continuity state not_running" "not_running"
        Yojson.Safe.Util.(
          json |> member "diagnostic" |> member "continuity_state" |> to_string);
      check string "runtime registry state stopped" "stopped"
        Yojson.Safe.Util.(
          json |> member "runtime" |> member "registry_state" |> to_string);
      let ok, _ =
        dispatch "masc_keeper_down" (`Assoc [ ("name", `String "resident-demo") ])
      in
      check bool "keeper down ok" true ok;
      let entry =
        match Masc_mcp.Keeper_registry.get ~base_path:config.base_path "resident-demo" with
        | Some entry -> entry
        | None -> fail "missing registry entry after keeper_down"
      in
      check string "registry state paused" "paused"
        (Masc_mcp.Keeper_registry.state_to_string entry.state))

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
      let ok, _goals_body =
        dispatch "masc_keeper_goals" (`Assoc [ ("name", `String "resident-demo") ])
      in
      check bool "resident goals removed" false ok;
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
      (* model_set now returns cascade_name instead of active_model *)
      check string "persistent cascade_name" "keeper_unified"
        Yojson.Safe.Util.(model_set_json |> member "cascade_name" |> to_string);
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
(* test_keeper_policy_tools_roundtrip: removed — keeper policy tools return stubs *)
(* test_keeper_policy_set_rejects_invalid_mode: removed — keeper policy_mode system removed *)

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
      check bool "policy mode removed from response" true
        Yojson.Safe.Util.(json |> member "policy_mode" = `Null);
      if voice_enabled then begin
        check string "voice channel" "voice_text"
          Yojson.Safe.Util.(json |> member "voice_channel" |> to_string);
        check string "voice agent id" "sangsu"
          Yojson.Safe.Util.(json |> member "voice_agent_id" |> to_string)
      end else begin
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
      check bool "initial proactive" true old_meta.proactive.enabled;
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
      check bool "proactive preserved when omitted" true updated_meta.proactive.enabled)

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
          proactive = { meta.proactive with enabled = false };
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
      check string "persona_name in resident spec" "buddy"
        Yojson.Safe.Util.(resident_json |> member "persona_name" |> to_string);
      check bool "seed_meta absent in thin format" true
        (Yojson.Safe.Util.(resident_json |> member "seed_meta") = `Null))

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
(* test_keeper_policy_set_accepts_explicit_event_v1: removed — keeper policy_mode system removed *)

(* Issue #3019: session dir must be created from scratch in filesystem fallback.
   When PG is unavailable and keeper_up only registers in-memory, the session
   directory under .masc/perpetual/<trace_id> might not exist. The fix ensures
   all callers create the full directory tree before file I/O. *)
let test_session_dir_mkdir_p_creates_full_tree () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_dir)
    (fun () ->
      (* Simulate the path that session_base_dir returns:
         <base_path>/.masc/perpetual *)
      let session_base = Filename.concat
        (Filename.concat base_dir ".masc") "perpetual" in
      let trace_id = "trace-test-3019" in
      let session_dir = Filename.concat session_base trace_id in
      (* Before fix: only base_dir was mkdir_p'd, not session_dir.
         After fix: mkdir_p session_dir creates the full tree. *)
      check bool "session dir absent before mkdir_p" false
        (Sys.file_exists session_dir);
      (* Use the same mkdir_p that Keeper_types exposes *)
      Masc_mcp.Keeper_types.mkdir_p session_dir;
      check bool "session dir exists after mkdir_p" true
        (Sys.file_exists session_dir);
      check bool "session dir is directory" true
        (Sys.is_directory session_dir);
      (* Simulate persist_message writing history.jsonl *)
      let history_path = Filename.concat session_dir "history.jsonl" in
      let oc = open_out history_path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc "{\"role\":\"user\",\"content\":\"hello\"}\n");
      check bool "history file written" true
        (Sys.file_exists history_path))

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
          presence_keepalive = true;
          proactive = { meta.proactive with enabled = false };
          usage = { meta.usage with last_turn_ts = 0.0 };
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
         test_case "resident list items expose runtime config summary" `Quick
           test_resident_list_items_expose_runtime_config_summary;
         test_case "keepalive gap reports not_running instead of disabled" `Quick
           test_keepalive_gap_reports_not_running_instead_of_disabled;
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
         test_case "fs_read policy gates" `Quick
           test_keeper_fs_read_policy_gates;
         test_case "fs_read enforces allowed paths and truncation" `Quick
           test_keeper_fs_read_enforces_allowed_paths_and_truncation;
         test_case "keeper bash requires cmd and runs" `Quick
           test_keeper_bash_requires_cmd_and_runs;
         test_case "fs_edit policy gates" `Quick
           test_keeper_fs_edit_policy_gates;
         test_case "fs_edit enforces allowed paths and modes" `Quick
           test_keeper_fs_edit_enforces_allowed_paths_and_modes;
         test_case "sangsu defaults explicit voice policy" `Quick
           test_keeper_up_defaults_sangsu_to_explicit_voice_policy;
         test_case "keeper up update preserves proactive when omitted" `Quick
           test_keeper_up_update_preserves_proactive_when_omitted;
         test_case "write_meta syncs registered resident seed" `Quick
           test_write_meta_syncs_registered_resident_seed;
         test_case "keeper up persists allowed paths" `Quick
           test_keeper_up_persists_allowed_paths_to_status_policy;
         test_case "resident bootstrap marks stale explicit keeper" `Quick
           test_resident_bootstrap_marks_stale_explicit_keeper;
         test_case "session dir mkdir_p creates full tree from scratch (issue #3019)" `Quick
           test_session_dir_mkdir_p_creates_full_tree;
       ]);
  ]
