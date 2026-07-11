(* test/test_env_git_noninteractive.ml

   Covers RFC-0007 PR-1 / #9639 Cluster B:
   - [Env_git_noninteractive] canonical env pairs (presence + format)
   - [Env_git_noninteractive.inject_into_environment] override semantics
   - [Env_keeper_scrub] scrub list membership and exact-match rule
   - [Env_keeper_scrub.filter_keeper_environment] strips scrubbed keys while
     preserving pass-through entries and entries without ['='] *)

open Masc

let fail msg = failwith msg
let assert_true msg b = if not b then fail msg
let assert_false msg b = if b then fail msg

let assert_contains ~msg xs needle =
  if not (List.mem needle xs) then
    fail (Printf.sprintf "%s: %s not in list" msg needle)

let test_env_has_required_keys () =
  let keys = List.map fst Env_git_noninteractive.env in
  assert_contains ~msg:"GIT_TERMINAL_PROMPT present" keys "GIT_TERMINAL_PROMPT";
  assert_contains ~msg:"GIT_ASKPASS present" keys "GIT_ASKPASS";
  assert_contains ~msg:"GCM_INTERACTIVE present" keys "GCM_INTERACTIVE";
  assert_contains ~msg:"SSH_ASKPASS present" keys "SSH_ASKPASS"

let test_env_values_enforce_noninteractive () =
  let lookup k = List.assoc_opt k Env_git_noninteractive.env in
  assert_true "GIT_TERMINAL_PROMPT = 0" (lookup "GIT_TERMINAL_PROMPT" = Some "0");
  assert_true "GIT_ASKPASS empty string" (lookup "GIT_ASKPASS" = Some "");
  assert_true "GCM_INTERACTIVE = Never" (lookup "GCM_INTERACTIVE" = Some "Never");
  assert_true "SSH_ASKPASS empty string" (lookup "SSH_ASKPASS" = Some "")

let test_env_pairs_serialized () =
  assert_contains ~msg:"env_pairs has GIT_TERMINAL_PROMPT=0"
    Env_git_noninteractive.env_pairs "GIT_TERMINAL_PROMPT=0";
  assert_contains ~msg:"env_pairs has GIT_ASKPASS="
    Env_git_noninteractive.env_pairs "GIT_ASKPASS="

let test_docker_args_pair_structure () =
  let args = Env_git_noninteractive.docker_args in
  (* Each (K, V) produces exactly two argv tokens: "-e", "K=V". *)
  let expected_len = List.length Env_git_noninteractive.env * 2 in
  if List.length args <> expected_len then
    fail
      (Printf.sprintf "docker_args length = %d, expected %d"
         (List.length args) expected_len);
  (* Verify alternation: indexes 0, 2, 4, ... are always "-e". *)
  List.iteri
    (fun i token ->
      if i mod 2 = 0 && token <> "-e" then
        fail (Printf.sprintf "docker_args[%d] = %s, expected -e" i token))
    args

let test_inject_override_existing () =
  let existing = [| "GIT_TERMINAL_PROMPT=1"; "PATH=/usr/bin"; "FOO=bar" |] in
  let out = Env_git_noninteractive.inject_into_environment existing in
  let out_list = Array.to_list out in
  assert_contains ~msg:"canonical value wins" out_list "GIT_TERMINAL_PROMPT=0";
  assert_false "pre-existing GIT_TERMINAL_PROMPT=1 evicted"
    (List.mem "GIT_TERMINAL_PROMPT=1" out_list);
  assert_contains ~msg:"unrelated PATH preserved" out_list "PATH=/usr/bin";
  assert_contains ~msg:"unrelated FOO preserved" out_list "FOO=bar"

let test_inject_injects_when_missing () =
  let existing = [| "PATH=/bin" |] in
  let out = Env_git_noninteractive.inject_into_environment existing in
  let out_list = Array.to_list out in
  assert_contains ~msg:"injects GIT_TERMINAL_PROMPT=0 when absent"
    out_list "GIT_TERMINAL_PROMPT=0";
  assert_contains ~msg:"injects GIT_ASKPASS= when absent"
    out_list "GIT_ASKPASS="

let test_scrub_membership () =
  assert_true "ANTHROPIC_API_KEY denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "ANTHROPIC_API_KEY"));
  assert_true "AWS_SECRET_ACCESS_KEY denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "AWS_SECRET_ACCESS_KEY"));
  assert_true "ACTIONS_ID_TOKEN_REQUEST_TOKEN denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "ACTIONS_ID_TOKEN_REQUEST_TOKEN"));
  assert_true "OTEL_EXPORTER_OTLP_HEADERS denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "OTEL_EXPORTER_OTLP_HEADERS"));
  assert_true "GH_TOKEN denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "GH_TOKEN"));
  assert_true "GITHUB_TOKEN denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "GITHUB_TOKEN"));
  assert_true "GH_CONFIG_DIR denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "GH_CONFIG_DIR"));
  assert_true "SSH_AUTH_SOCK denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "SSH_AUTH_SOCK"));
  assert_true "GIT_CONFIG_GLOBAL denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "GIT_CONFIG_GLOBAL"));
  assert_true "GIT_CONFIG_COUNT denied"
    (not (Env_keeper_scrub.is_keeper_process_allowed "GIT_CONFIG_COUNT"));
  assert_true "PATH allowed"
    (Env_keeper_scrub.is_keeper_process_allowed "PATH")

let test_scrub_exact_match_only () =
  (* Suffix pattern now blocks anything ending in _API_KEY. *)
  assert_true "ANTHROPIC_API_KEY_SUFFIX denied (suffix match)"
    (not (Env_keeper_scrub.is_keeper_process_allowed "ANTHROPIC_API_KEY_SUFFIX"));
  assert_true "PREFIX_ANTHROPIC_API_KEY denied (suffix match)"
    (not (Env_keeper_scrub.is_keeper_process_allowed "PREFIX_ANTHROPIC_API_KEY"))

let test_scrub_and_pass_disjoint () =
  let safe =
    [ "GIT_AUTHOR_NAME"; "GIT_AUTHOR_EMAIL"
    ; "GIT_COMMITTER_NAME"; "GIT_COMMITTER_EMAIL"
    ]
  in
  List.iter
    (fun p ->
      assert_true
        (Printf.sprintf "safe entry %s must be allowed" p)
        (Env_keeper_scrub.is_keeper_process_allowed p))
    safe

let test_filter_environment () =
  let env = [|
    "PATH=/usr/bin";
    "ANTHROPIC_API_KEY=sk-ant-xxx";
    "GH_TOKEN=ghp_yyy";
    "GITHUB_TOKEN=github_yyy";
    "GH_CONFIG_DIR=/host/gh";
    "AWS_SECRET_ACCESS_KEY=zzz";
    "SSH_AUTH_SOCK=/tmp/sock";
    "GIT_CONFIG_GLOBAL=/host/.gitconfig";
    "GIT_CONFIG_COUNT=1";
    "FOO=bar";
    "malformed_entry_no_equals";  (* no '=' — key equals the whole entry *)
  |] in
  let out = Env_keeper_scrub.filter_keeper_environment env in
  let out_list = Array.to_list out in
  assert_contains ~msg:"PATH preserved" out_list "PATH=/usr/bin";
  assert_false "FOO dropped (not on allowlist)"
    (List.mem "FOO=bar" out_list);
  assert_false "malformed_entry_no_equals dropped (not on allowlist)"
    (List.mem "malformed_entry_no_equals" out_list);
  assert_false "ANTHROPIC_API_KEY stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"ANTHROPIC_API_KEY=" e) out_list);
  assert_false "AWS_SECRET_ACCESS_KEY stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"AWS_SECRET_ACCESS_KEY=" e) out_list);
  assert_false "GH_TOKEN stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"GH_TOKEN=" e) out_list);
  assert_false "GITHUB_TOKEN stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"GITHUB_TOKEN=" e) out_list);
  assert_false "GH_CONFIG_DIR stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"GH_CONFIG_DIR=" e) out_list);
  assert_false "SSH_AUTH_SOCK stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"SSH_AUTH_SOCK=" e) out_list);
  assert_false "GIT_CONFIG_GLOBAL stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"GIT_CONFIG_GLOBAL=" e) out_list);
  assert_false "GIT_CONFIG_COUNT stripped"
    (List.exists (fun e -> String.starts_with ~prefix:"GIT_CONFIG_COUNT=" e) out_list)

let test_no_forgotten_git_askpass_literals () =
  (* Enforcement grep: outside of the SSOT module itself, [lib/] must not
     contain inline "GIT_ASKPASS" / "GIT_TERMINAL_PROMPT" literals. If this
     test fails, route the new call site through
     [Env_git_noninteractive.docker_args] or
     [Env_git_noninteractive.inject_into_environment] instead. *)
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some d -> d
    | None -> Sys.getcwd ()
  in
  let lib_dir = Filename.concat root "lib" in
  let argv =
    [|
      "rg";
      "--no-messages";
      "-l";
      "GIT_ASKPASS|GIT_TERMINAL_PROMPT";
      lib_dir;
      "--glob";
      "!env_git_noninteractive.*";
      "--glob";
      "*.ml";
      "--glob";
      "*.mli";
    |]
  in
  let lines, _status =
    With_process.with_process_args_in "rg" argv
      With_process.drain_lines
  in
  let offenders =
    List.filter
      (fun line ->
        let base = Filename.basename line in
        base <> "env_git_noninteractive.ml"
        && base <> "env_git_noninteractive.mli"
        && base <> "env_keeper_scrub.ml")
      lines
  in
  if offenders <> [] then
    fail
      (Printf.sprintf
         "Found inline GIT_ASKPASS/GIT_TERMINAL_PROMPT outside SSOT: %s"
         (String.concat "; " offenders))

let () =
  test_env_has_required_keys ();
  test_env_values_enforce_noninteractive ();
  test_env_pairs_serialized ();
  test_docker_args_pair_structure ();
  test_inject_override_existing ();
  test_inject_injects_when_missing ();
  test_scrub_membership ();
  test_scrub_exact_match_only ();
  test_scrub_and_pass_disjoint ();
  test_filter_environment ();
  test_no_forgotten_git_askpass_literals ();
  print_endline "test_env_git_noninteractive: OK"
