open Masc_exec

let with_env name value f =
  let old = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_tap_capture f =
  let captured = ref [] in
  Exec_tap.enable ~writer:(fun line -> captured := line :: !captured);
  Fun.protect
    ~finally:(fun () -> Exec_tap.disable ())
    (fun () -> f captured)

let find_gate_line lines =
  List.find_opt
    (fun line -> String_util.contains_substring line "\"kind\":\"Exec_gate.decision\"")
    lines

let test_enforced_strict_safe_blocks () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_status
        ~actor:`Other_agent
        ~raw_source:"pwd"
        ~summary:"strict pwd"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Test ())
        [ "pwd" ]
    in
    assert (status = Unix.WEXITED 126);
    assert (String_util.contains_substring out "ask_required"))

let test_parallel_records_shadow_and_executes () =
  with_tap_capture (fun captured ->
    with_env "MASC_EXEC_GATE" (Some "parallel") (fun () ->
      let out =
        Exec_gate.run_argv
          ~actor:`Other_agent
          ~raw_source:"pwd"
          ~summary:"strict pwd"
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Test ())
          [ "pwd" ]
      in
      assert (String.trim out <> "");
      match find_gate_line !captured with
      | None -> assert false
      | Some line ->
        assert (String_util.contains_substring line "\"gate_mode\":\"parallel\"");
        assert (String_util.contains_substring line "\"gate_verdict\":\"ask\"");
        assert (String_util.contains_substring line "\"gate_enforced\":false")))

let test_enforced_internal_audited_allows () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_status
        ~actor:`Coord_git
        ~raw_source:"git --version"
        ~summary:"coord git version"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Test ())
        [ "git"; "--version" ]
    in
    assert (status = Unix.WEXITED 0);
    assert (String_util.contains_substring out "git version"))

let test_enforced_internal_stdin_allows () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_stdin_and_status
        ~actor:`System_task_sandbox
        ~raw_source:"cat"
        ~summary:"stdin cat"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Test ())
        ~stdin_content:"hello\n"
        [ "cat" ]
    in
    assert (status = Unix.WEXITED 0);
    assert (String_util.contains_substring out "hello"))

let test_typed_safe_enforced_blocks () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_status
        ~actor:`Other_agent
        ~raw_source:"ls"
        ~summary:"typed ls"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Test ())
        [ "ls" ]
    in
    assert (status = Unix.WEXITED 126);
    assert (String_util.contains_substring out "ask_required"))

let test_typed_audited_internal_allows () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_status
        ~actor:`Coord_git
        ~raw_source:"git status"
        ~summary:"typed git status"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Test ())
        [ "git"; "status" ]
    in
    assert (status <> Unix.WEXITED 126))

let test_typed_safe_parallel_records_shadow_and_executes () =
  with_tap_capture (fun captured ->
    with_env "MASC_EXEC_GATE" (Some "parallel") (fun () ->
      let out =
        Exec_gate.run_argv
          ~actor:`Other_agent
          ~raw_source:"ls"
          ~summary:"typed ls"
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Test ())
          [ "ls" ]
      in
      assert (String.trim out <> "");
      match find_gate_line !captured with
      | None -> assert false
      | Some line ->
        assert (String_util.contains_substring line "\"gate_mode\":\"parallel\"");
        assert (String_util.contains_substring line "\"gate_verdict\":\"ask\"");
        assert (String_util.contains_substring line "\"gate_enforced\":false")))

let () =
  test_enforced_strict_safe_blocks ();
  test_parallel_records_shadow_and_executes ();
  test_enforced_internal_audited_allows ();
  test_enforced_internal_stdin_allows ();
  test_typed_safe_enforced_blocks ();
  test_typed_audited_internal_allows ();
  test_typed_safe_parallel_records_shadow_and_executes ();
  print_endline "[test_exec_gate_runtime] all tests passed"
