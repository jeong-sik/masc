open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

let temp_dir () =
  let dir = Filename.temp_file "test_tool_mdal_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let write_text path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let parse_json_exn s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error e -> failwith ("invalid json: " ^ e)

let contains_substring haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let dispatch_exn ctx ~name ~args =
  match Tool_mdal.dispatch ctx ~name ~args with
  | Some (ok, body) -> (ok, body)
  | None -> failwith ("dispatch returned None for " ^ name)

let reset_loop_registry () =
  Hashtbl.clear Tool_mdal.active_loops;
  Tool_mdal.latest_loop_id := None

let verified_evidence ?(model_used = "claude:test-mdal")
    ?(tool_call_count = 1) ?(tool_names = [ "masc_spawn" ])
    ?(session_id = "session-mdal-1") () : Mdal.worker_evidence =
  {
    engine = `Api_tool_loop;
    model_used;
    tool_call_count;
    tool_names;
    session_id;
    status = `Verified;
  }

let strict_runner ?(changes = "Adjusted one branch")
    ?(failed_attempts = "") ?(next_suggestion = "Add another case")
    ?(model_used = "claude:test-mdal") ?(tool_call_count = 1)
    ?(tool_names = [ "masc_spawn" ]) ?(session_id = "session-mdal-1")
    ?(cost_usd = Some 0.01) () : Mdal_worker.runner =
 fun ~config:_ _state ~current_metric:_ ->
  Ok
    {
      Mdal_worker.prompt = "worker-prompt";
      report = { changes; failed_attempts; next_suggestion };
      evidence =
        verified_evidence ~model_used ~tool_call_count ~tool_names ~session_id ();
      cost_usd;
    }

let missing_evidence_runner ?(raw_output = "{\"changes\":\"noop\"}")
    ?(tool_call_count = 0) ?(tool_names = [])
    ?(model_used = "claude:test-mdal")
    ?(session_id = "session-mdal-missing") () : Mdal_worker.runner =
 fun ~config:_ _state ~current_metric:_ ->
  Error
    (Mdal_worker.Evidence_missing
       {
         prompt = "worker-prompt";
         raw_output;
         model_used;
         session_id;
         tool_call_count;
         tool_names;
       })

(** Mock [measure_metric] to avoid process spawning entirely.
    Parses the shell command string to extract the expected float.
    Handles three patterns used by tests:
    - [printf 'N\n'] → [Ok N]
    - [if \[ -f FILE \]; then exit 1; else printf 'N\n'; fi] → file-existence check
    - anything else → [Error "unknown mock command"] *)
let mock_measure_metric (cmd : string) : (float, string) result =
  let printf_re = Str.regexp "printf '\\([0-9.]+\\)" in
  let file_check_re = Str.regexp "if \\[ -f \\([^ ]*\\) \\]" in
  if Str.string_match file_check_re cmd 0 then
    let path = Str.matched_group 1 cmd in
    (* Remove shell quoting if present *)
    let unquoted =
      if String.length path >= 2
         && path.[0] = '\''
         && path.[String.length path - 1] = '\'' then
        String.sub path 1 (String.length path - 2)
      else path
    in
    if Sys.file_exists unquoted then
      Error (Printf.sprintf "mock: exit 1 (file exists: %s)" unquoted)
    else (
      (* Use search_forward (not string_match) to find printf anywhere after ] *)
      match (try Some (Str.search_forward printf_re cmd (Str.match_end ())) with Not_found -> None) with
      | Some _ ->
        (match float_of_string_opt (Str.matched_group 1 cmd) with
        | Some v -> Ok v
        | None -> Error "mock: cannot parse float from else branch")
      | None -> Error "mock: no printf in else branch")
  else if Str.string_match printf_re cmd 0 then
    (match float_of_string_opt (Str.matched_group 1 cmd) with
    | Some v -> Ok v
    | None -> Error (Printf.sprintf "mock: cannot parse float: %s" cmd))
  else Error (Printf.sprintf "mock: unknown command: %s" cmd)

let make_ctx ?config ?worker_runner () : Tool_mdal.context =
  { agent_name = "tester"; config; sw = None; proc_mgr = None; worker_runner; clock = None }

let start_custom_loop ?(metric_fn = "printf '0.5\\n'")
    ?(goal = "metric > 0.6") ?(target = "Improve score")
    ?(tools_allow = []) ?(tools_deny = []) ?config ?worker_runner () =
  let ctx = make_ctx ?config ?worker_runner () in
  let ok, body =
    dispatch_exn ctx ~name:"masc_mdal_start"
      ~args:
        (`Assoc
          [
            ("profile", `String "custom");
            ("metric_fn", `String metric_fn);
            ("goal", `String goal);
            ("target", `String target);
            ("tools_allow", `List (List.map (fun item -> `String item) tools_allow));
            ("tools_deny", `List (List.map (fun item -> `String item) tools_deny));
          ])
  in
  (ctx, ok, parse_json_exn body)

let loop_id_of_json json =
  json |> Yojson.Safe.Util.member "loop_id" |> Yojson.Safe.Util.to_string

let make_legacy_state ?(loop_id = "legacy-mdal-loop")
    ?(status = `Running) () : Mdal.loop_state =
  let now = Time_compat.now () in
  {
    Mdal.loop_id = loop_id;
    profile =
      {
        Mdal.name = "custom";
        metric_fn = "printf '0.5\\n'";
        goal = { Bounded.path = "metric"; condition = Bounded.Gt 0.6 };
        target = "legacy loop";
        reference = None;
        agent = "auto";
        max_iterations = 5;
        max_time_seconds = Some 60.0;
        stagnation_threshold = 0.01;
        stagnation_count = 3;
        heuristics = "";
        tools_allow = [ "masc_spawn" ];
        tools_deny = [];
      };
    strict_mode = false;
    status;
    error_message = None;
    stop_reason = None;
    current_iteration = 0;
    history = [];
    stagnation_streak = 0;
    baseline_metric = 0.5;
    start_time = now -. 10.0;
    updated_at = now;
    stopped_at = None;
    state_post_id = "legacy-post";
    execution_mode = `Manual_only;
    worker_engine = None;
    worker_model = None;
  }

let test_builtin_requires_metric_fn () =
  reset_loop_registry ();
  let ok, body =
    dispatch_exn
      (make_ctx ~worker_runner:(strict_runner ()) ())
      ~name:"masc_mdal_start"
      ~args:(`Assoc [ ("profile", `String "coverage") ])
  in
  Alcotest.(check bool) "start rejected" false ok;
  let json = parse_json_exn body in
  let error = json |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.to_string in
  Alcotest.(check bool) "mentions explicit metric_fn" true
    (contains_substring error "metric_fn");
  Alcotest.(check bool) "names profile" true
    (contains_substring error "coverage")

let test_strict_start_accepts_explicit_metric_fn () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx = make_ctx ~config ~worker_runner:(strict_runner ()) () in
  let ok, body =
    dispatch_exn ctx ~name:"masc_mdal_start"
      ~args:
        (`Assoc
          [
            ("profile", `String "coverage");
            ("metric_fn", `String "printf '50\\n'");
          ])
  in
  Alcotest.(check bool) "start ok" true ok;
  let json = parse_json_exn body in
  Alcotest.(check string) "profile" "coverage"
    (json |> Yojson.Safe.Util.member "profile" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "execution mode" "worker_spawn"
    (json |> Yojson.Safe.Util.member "execution_mode" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "strict mode" true
    (json |> Yojson.Safe.Util.member "strict_mode" |> Yojson.Safe.Util.to_bool);
  Alcotest.(check string) "worker engine" "api_tool_loop"
    (json |> Yojson.Safe.Util.member "worker_engine" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "evidence policy" "hard"
    (json |> Yojson.Safe.Util.member "evidence_policy" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "durability" "persistent_backend"
    (json |> Yojson.Safe.Util.member "durability" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_start_rejects_codex_worker () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx = make_ctx ~config ~worker_runner:(strict_runner ()) () in
  let ok, body =
    dispatch_exn ctx ~name:"masc_mdal_start"
      ~args:
        (`Assoc
          [
            ("profile", `String "custom");
            ("metric_fn", `String "printf '0.5\\n'");
            ("goal", `String "metric > 0.6");
            ("target", `String "Reject codex");
            ("agent", `String "codex");
          ])
  in
  Alcotest.(check bool) "start rejected" false ok;
  let json = parse_json_exn body in
  let error = json |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.to_string in
  Alcotest.(check bool) "mentions codex unsupported" true
    (contains_substring error "does not support `codex`");
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_strict_iteration_records_verified_evidence () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let runner =
    strict_runner ~changes:"Adjusted one branch"
      ~next_suggestion:"Add another case"
      ~tool_names:[ "masc_spawn" ] ~session_id:"session-mdal-success" ()
  in
  let ctx, ok_start, start_json =
    start_custom_loop ~config ~worker_runner:runner
      ~goal:"score > 0.6" ~target:"Improve score"
      ~tools_allow:[ "masc_spawn"; "masc_code_search" ]
      ~tools_deny:[ "masc_code_search" ] ()
  in
  Alcotest.(check bool) "custom start ok" true ok_start;
  let worker_prompt =
    start_json |> Yojson.Safe.Util.member "worker_prompt"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "reference-free prompt still has allowed tools" true
    (contains_substring worker_prompt "Allowed tools: masc_spawn");
  Alcotest.(check bool) "prompt keeps denylist" true
    (contains_substring worker_prompt "Forbidden tools: masc_code_search");
  let loop_id = loop_id_of_json start_json in
  let ok_iter, iter_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String loop_id) ])
  in
  Alcotest.(check bool) "iterate ok" true ok_iter;
  let iter_json = parse_json_exn iter_body in
  Alcotest.(check string) "status running" "running"
    (iter_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "assessment" "flat"
    (iter_json |> Yojson.Safe.Util.member "assessment" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "assessment basis" "measured_delta"
    (iter_json |> Yojson.Safe.Util.member "assessment_basis"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "iteration mode" "strict_worker"
    (iter_json |> Yojson.Safe.Util.member "iteration_mode"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "worker engine" "api_tool_loop"
    (iter_json |> Yojson.Safe.Util.member "worker_engine"
    |> Yojson.Safe.Util.to_string);
  Alcotest.(check int) "tool call count" 1
    (iter_json |> Yojson.Safe.Util.member "tool_call_count"
    |> Yojson.Safe.Util.to_int);
  Alcotest.(check (list string)) "tool names" [ "masc_spawn" ]
    (iter_json |> Yojson.Safe.Util.member "tool_names"
    |> Yojson.Safe.Util.to_list |> List.map Yojson.Safe.Util.to_string);
  Alcotest.(check string) "session id" "session-mdal-success"
    (iter_json |> Yojson.Safe.Util.member "session_id"
    |> Yojson.Safe.Util.to_string);
  let evidence =
    iter_json |> Yojson.Safe.Util.member "iteration"
    |> Yojson.Safe.Util.member "evidence"
  in
  Alcotest.(check string) "evidence status" "verified"
    (evidence |> Yojson.Safe.Util.member "evidence_status"
    |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_custom_goal_label_is_honored () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx, ok_start, start_json =
    start_custom_loop ~config ~worker_runner:(strict_runner ())
      ~goal:"score >= 0.5" ~target:"Score reaches baseline" ()
  in
  Alcotest.(check bool) "custom start ok" true ok_start;
  let loop_id = loop_id_of_json start_json in
  let ok_iter, iter_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String loop_id) ])
  in
  Alcotest.(check bool) "iterate ok" true ok_iter;
  let iter_json = parse_json_exn iter_body in
  Alcotest.(check string) "status completed" "completed"
    (iter_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "goal met" true
    (iter_json |> Yojson.Safe.Util.member "goal_met" |> Yojson.Safe.Util.to_bool);
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_auto_stop_response_is_complete () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx, ok_start, start_json =
    start_custom_loop ~config ~worker_runner:(strict_runner ())
      ~goal:"metric > 1.0"
      ~target:"Impossible target for stop-path check"
      ~metric_fn:"printf '0.5\\n'"
      ()
  in
  Alcotest.(check bool) "custom start ok" true ok_start;
  let loop_id = loop_id_of_json start_json in
  let state =
    match Hashtbl.find_opt Tool_mdal.active_loops loop_id with
    | Some state -> state
    | None -> Alcotest.fail "expected active loop"
  in
  state.current_iteration <- state.profile.max_iterations;
  let ok_iter, iter_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String loop_id) ])
  in
  Alcotest.(check bool) "iterate stop response is error-shaped" false ok_iter;
  let iter_json = parse_json_exn iter_body in
  Alcotest.(check string) "status stopped" "stopped"
    (iter_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "reason included" "max_iterations_reached"
    (iter_json |> Yojson.Safe.Util.member "reason" |> Yojson.Safe.Util.to_string);
  Alcotest.(check (float 0.0001)) "final metric included" 0.5
    (iter_json |> Yojson.Safe.Util.member "final_metric" |> Yojson.Safe.Util.to_float);
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_persisted_loop_hydrates_to_interrupted () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx, ok_start, start_json =
    start_custom_loop ~config ~worker_runner:(strict_runner ())
      ~goal:"metric > 1.0" ~target:"Hydration test" ()
  in
  Alcotest.(check bool) "custom start ok" true ok_start;
  let loop_id = loop_id_of_json start_json in
  reset_loop_registry ();
  let ok_status, status_body =
    dispatch_exn ctx ~name:"masc_mdal_status"
      ~args:(`Assoc [ ("loop_id", `String loop_id) ])
  in
  Alcotest.(check bool) "status ok" true ok_status;
  let status_json = parse_json_exn status_body in
  Alcotest.(check string) "status interrupted" "interrupted"
    (status_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "recoverable true" true
    (status_json |> Yojson.Safe.Util.member "recoverable" |> Yojson.Safe.Util.to_bool);
  Alcotest.(check string) "stop reason" "server_restart"
    (status_json |> Yojson.Safe.Util.member "stop_reason" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_interrupted_loop_can_resume () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx, ok_start, start_json =
    start_custom_loop ~config ~worker_runner:(strict_runner ())
      ~goal:"metric > 0.6" ~target:"Resume test" ()
  in
  Alcotest.(check bool) "custom start ok" true ok_start;
  let loop_id = loop_id_of_json start_json in
  reset_loop_registry ();
  let ok_iter, iter_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String loop_id) ])
  in
  Alcotest.(check bool) "iterate ok" true ok_iter;
  let iter_json = parse_json_exn iter_body in
  Alcotest.(check string) "status running" "running"
    (iter_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_manual_fields_are_rejected_in_strict_mode () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx, ok_start, start_json =
    start_custom_loop ~config ~worker_runner:(strict_runner ())
      ~goal:"metric > 0.6" ~target:"Reject manual fields" ()
  in
  Alcotest.(check bool) "custom start ok" true ok_start;
  let loop_id = loop_id_of_json start_json in
  let ok_iter, iter_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:
        (`Assoc
          [
            ("loop_id", `String loop_id);
            ("changes", `String "manual note");
          ])
  in
  Alcotest.(check bool) "manual iterate rejected" false ok_iter;
  let iter_json = parse_json_exn iter_body in
  let error = iter_json |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.to_string in
  Alcotest.(check bool) "mentions strict mdal manual rejection" true
    (contains_substring error "does not accept manual iteration fields");
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_missing_evidence_interrupts_loop () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx, ok_start, start_json =
    start_custom_loop ~config
      ~worker_runner:(missing_evidence_runner ~raw_output:"{\"changes\":\"noop\"}" ())
      ~goal:"metric > 0.6" ~target:"Evidence required" ()
  in
  Alcotest.(check bool) "custom start ok" true ok_start;
  let loop_id = loop_id_of_json start_json in
  let ok_iter, iter_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String loop_id) ])
  in
  Alcotest.(check bool) "iterate interrupted response is error-shaped" false ok_iter;
  let iter_json = parse_json_exn iter_body in
  Alcotest.(check string) "status interrupted" "interrupted"
    (iter_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check string) "reason" "worker_evidence_missing"
    (iter_json |> Yojson.Safe.Util.member "reason" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "recoverable" true
    (iter_json |> Yojson.Safe.Util.member "recoverable" |> Yojson.Safe.Util.to_bool);
  Alcotest.(check int) "tool_call_count zero" 0
    (iter_json |> Yojson.Safe.Util.member "tool_call_count"
    |> Yojson.Safe.Util.to_int);
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_legacy_loop_cannot_iterate () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx = make_ctx ~config ~worker_runner:(strict_runner ()) () in
  let state = make_legacy_state () in
  Mdal_store.save_loop config state;
  Mdal_store.save_latest_loop_id config state.loop_id;
  let ok_iter, iter_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String state.loop_id) ])
  in
  Alcotest.(check bool) "legacy iterate rejected" false ok_iter;
  let iter_json = parse_json_exn iter_body in
  let error = iter_json |> Yojson.Safe.Util.member "error" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "status interrupted after hydration" "interrupted"
    (iter_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);
  Alcotest.(check bool) "mentions strict mode" true
    (contains_substring error "predates strict MDAL worker mode");
  cleanup_dir base_dir;
  reset_loop_registry ()

let test_terminal_states_reject_iterate () =
  reset_loop_registry ();
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "tester"));
  let ctx = make_ctx ~config ~worker_runner:(strict_runner ()) () in

  let completed_loop_id =
    let _, ok_start, start_json =
      start_custom_loop ~config ~worker_runner:(strict_runner ())
        ~goal:"score >= 0.5" ~target:"Complete immediately" ()
    in
    Alcotest.(check bool) "completed start ok" true ok_start;
    let loop_id = loop_id_of_json start_json in
    ignore
      (dispatch_exn ctx ~name:"masc_mdal_iterate"
         ~args:(`Assoc [ ("loop_id", `String loop_id) ]));
    loop_id
  in
  let ok_completed, completed_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String completed_loop_id) ])
  in
  Alcotest.(check bool) "completed iterate rejected" false ok_completed;
  let completed_json = parse_json_exn completed_body in
  Alcotest.(check string) "completed status" "completed"
    (completed_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);

  let stopped_loop_id =
    let _, ok_start, start_json =
      start_custom_loop ~config ~worker_runner:(strict_runner ())
        ~goal:"metric > 1.0" ~target:"Manual stop test" ()
    in
    Alcotest.(check bool) "stopped start ok" true ok_start;
    let loop_id = loop_id_of_json start_json in
    ignore
      (dispatch_exn ctx ~name:"masc_mdal_stop"
         ~args:(`Assoc [ ("loop_id", `String loop_id); ("reason", `String "manual stop") ]));
    loop_id
  in
  let ok_stopped, stopped_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String stopped_loop_id) ])
  in
  Alcotest.(check bool) "stopped iterate rejected" false ok_stopped;
  let stopped_json = parse_json_exn stopped_body in
  Alcotest.(check string) "stopped status" "stopped"
    (stopped_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);

  let fail_marker = Filename.concat base_dir "metric_fail" in
  let quoted_marker = Filename.quote fail_marker in
  let error_loop_id =
    let metric_fn =
      Printf.sprintf "if [ -f %s ]; then exit 1; else printf '0.5\\n'; fi"
        quoted_marker
    in
    let _, ok_start, start_json =
      start_custom_loop ~config ~worker_runner:(strict_runner ())
        ~metric_fn ~goal:"metric > 1.0" ~target:"Error test" ()
    in
    Alcotest.(check bool) "error start ok" true ok_start;
    let loop_id = loop_id_of_json start_json in
    write_text fail_marker "fail";
    ignore
      (dispatch_exn ctx ~name:"masc_mdal_iterate"
         ~args:(`Assoc [ ("loop_id", `String loop_id) ]));
    loop_id
  in
  let ok_error, error_body =
    dispatch_exn ctx ~name:"masc_mdal_iterate"
      ~args:(`Assoc [ ("loop_id", `String error_loop_id) ])
  in
  Alcotest.(check bool) "error iterate rejected" false ok_error;
  let error_json = parse_json_exn error_body in
  Alcotest.(check string) "error status" "error"
    (error_json |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string);

  cleanup_dir base_dir;
  reset_loop_registry ()

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mdal.measure_metric_override := Some mock_measure_metric;
  Alcotest.run "Tool_mdal"
    [
      ( "tool contract",
        [
          Alcotest.test_case "built-in requires metric_fn" `Quick
            test_builtin_requires_metric_fn;
          Alcotest.test_case "strict start accepts explicit metric_fn" `Quick
            test_strict_start_accepts_explicit_metric_fn;
          Alcotest.test_case "start rejects codex worker" `Quick
            test_start_rejects_codex_worker;
          Alcotest.test_case "strict iteration records verified evidence" `Quick
            test_strict_iteration_records_verified_evidence;
          Alcotest.test_case "custom goal label is honored" `Quick
            test_custom_goal_label_is_honored;
          Alcotest.test_case "auto stop response is complete" `Quick
            test_auto_stop_response_is_complete;
          Alcotest.test_case "persisted loop hydrates to interrupted" `Quick
            test_persisted_loop_hydrates_to_interrupted;
          Alcotest.test_case "interrupted loop can resume" `Quick
            test_interrupted_loop_can_resume;
          Alcotest.test_case "manual fields are rejected in strict mode" `Quick
            test_manual_fields_are_rejected_in_strict_mode;
          Alcotest.test_case "missing evidence interrupts loop" `Quick
            test_missing_evidence_interrupts_loop;
          Alcotest.test_case "legacy loop cannot iterate" `Quick
            test_legacy_loop_cannot_iterate;
          Alcotest.test_case "terminal states reject iterate" `Quick
            test_terminal_states_reject_iterate;
        ] );
    ]
