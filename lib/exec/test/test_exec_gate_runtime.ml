open Masc_exec

let substring_contains ~haystack ~needle =
  let hl = String.length haystack in
  let nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec find i =
      if i + nl > hl then false
      else if String.sub haystack i nl = needle then true
      else find (i + 1)
    in
    find 0

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
    (fun line -> substring_contains ~haystack:line ~needle:"\"kind\":\"Exec_gate.decision\"")
    lines

let test_enforced_strict_safe_blocks () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_status
        ~actor:"unknown/strict"
        ~raw_source:"pwd"
        ~summary:"strict pwd"
        ~timeout_sec:5.0
        [ "pwd" ]
    in
    assert (status = Unix.WEXITED 126);
    assert (substring_contains ~haystack:out ~needle:"ask_required"))

let test_parallel_records_shadow_and_executes () =
  with_tap_capture (fun captured ->
    with_env "MASC_EXEC_GATE" (Some "parallel") (fun () ->
      let out =
        Exec_gate.run_argv
          ~actor:"unknown/strict"
          ~raw_source:"pwd"
          ~summary:"strict pwd"
          ~timeout_sec:5.0
          [ "pwd" ]
      in
      assert (String.trim out <> "");
      match find_gate_line !captured with
      | None -> assert false
      | Some line ->
        assert (substring_contains ~haystack:line ~needle:"\"gate_mode\":\"parallel\"");
        assert (substring_contains ~haystack:line ~needle:"\"gate_verdict\":\"ask\"");
        assert (substring_contains ~haystack:line ~needle:"\"gate_enforced\":false")))

let test_enforced_internal_audited_allows () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_status
        ~actor:"coord/git"
        ~raw_source:"git --version"
        ~summary:"coord git version"
        ~timeout_sec:5.0
        [ "git"; "--version" ]
    in
    assert (status = Unix.WEXITED 0);
    assert (substring_contains ~haystack:out ~needle:"git version"))

let test_enforced_internal_stdin_allows () =
  with_env "MASC_EXEC_GATE" (Some "enforced") (fun () ->
    let status, out =
      Exec_gate.run_argv_with_stdin_and_status
        ~actor:"system/task_sandbox"
        ~raw_source:"cat"
        ~summary:"stdin cat"
        ~timeout_sec:5.0
        ~stdin_content:"hello\n"
        [ "cat" ]
    in
    assert (status = Unix.WEXITED 0);
    assert (substring_contains ~haystack:out ~needle:"hello"))

let () =
  test_enforced_strict_safe_blocks ();
  test_parallel_records_shadow_and_executes ();
  test_enforced_internal_audited_allows ();
  test_enforced_internal_stdin_allows ();
  print_endline "[test_exec_gate_runtime] all tests passed"
