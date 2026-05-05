module Types = Masc_domain

(** Coverage tests for Tool_code_write — git clone URL parsing
    and org allowlist validation. Pure function tests only. *)

open Alcotest

module Tool_code_write = Masc_mcp.Tool_code_write
module Coord = Masc_mcp.Coord
module Prometheus = Masc_mcp.Prometheus

let msg_contains ~needle haystack =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  nlen = 0 || loop 0

let tool_code_write_policy_load_failure_metric () =
  Prometheus.metric_value_or_zero
    Prometheus.metric_keeper_tool_policy_failures
    ~labels:[("site", "tool_code_write_load_failed"); ("preset", "n/a")]
    ()

(* OCaml's Unix module does not expose unsetenv; for config overrides that are
   read via Env_config_core.trim_opt, an empty string is equivalent to unset. *)
let with_trimmed_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let policy_toml ?(denied_repos = []) allowed_orgs =
  let array items =
    items |> List.map (Printf.sprintf "%S") |> String.concat ", "
  in
  Printf.sprintf
    "[git_clone]\nallowed_orgs = [%s]\ndenied_repos = [%s]\n"
    (array allowed_orgs)
    (array denied_repos)

let with_temp_policy ?denied_repos allowed_orgs f =
  with_temp_dir "tool-code-write-policy" @@ fun base_path ->
  let config_dir = Filename.concat base_path "config" in
  mkdir_p config_dir;
  write_file
    (Filename.concat config_dir "tool_policy.toml")
    (policy_toml ?denied_repos allowed_orgs);
  Tool_code_write.reset_policy_config_cache ();
  Fun.protect ~finally:Tool_code_write.reset_policy_config_cache (fun () ->
    f base_path)

(* ── extract_github_org ──────────────────────────────────────────── *)

let test_https_url () =
  (check (option string)) "https with .git"
    (Some "jeong-sik")
    (Tool_code_write.extract_github_org
       "https://github.com/jeong-sik/masc-mcp.git")

let test_https_url_no_git () =
  (check (option string)) "https without .git"
    (Some "jeong-sik")
    (Tool_code_write.extract_github_org
       "https://github.com/jeong-sik/masc-mcp")

let test_ssh_url () =
  (check (option string)) "ssh URL"
    (Some "jeong-sik")
    (Tool_code_write.extract_github_org
       "git@github.com:jeong-sik/oas.git")

let test_ssh_protocol_url () =
  (check (option string)) "ssh protocol URL"
    (Some "jeong-sik")
    (Tool_code_write.extract_github_org
       "ssh://git@github.com/jeong-sik/oas.git")

let test_non_github_url () =
  (check (option string)) "non-github returns None"
    None
    (Tool_code_write.extract_github_org
       "https://gitlab.com/someone/repo.git")

let test_bare_string () =
  (check (option string)) "bare string returns None"
    None
    (Tool_code_write.extract_github_org "not-a-url")

let test_different_org () =
  (check (option string)) "different org"
    (Some "kidsnote")
    (Tool_code_write.extract_github_org
       "https://github.com/kidsnote/backend.git")

let test_empty_string () =
  (check (option string)) "empty string returns None"
    None
    (Tool_code_write.extract_github_org "")

let test_no_repo_path () =
  (check (option string)) "URL with no path after org"
    None
    (Tool_code_write.extract_github_org
       "https://github.com/jeong-sik")

(* ── Security: authority spoofing ──────────────────────────────── *)

let test_domain_spoofing () =
  (check (option string)) "github.com.evil.com rejected"
    None
    (Tool_code_write.extract_github_org
       "https://github.com.evil.com/jeong-sik/repo.git")

let test_authority_spoofing () =
  (check (option string)) "authority via @ rejected"
    None
    (Tool_code_write.extract_github_org
       "https://jeong-sik@evil.com/repo")

let test_uppercase_normalized () =
  (check (option string)) "uppercase normalized to lowercase"
    (Some "jeong-sik")
    (Tool_code_write.extract_github_org
       "https://github.com/JEONG-SIK/repo.git")

let test_percent_encoded_org () =
  (check (option string)) "percent-encoded org rejected"
    None
    (Tool_code_write.extract_github_org
       "https://github.com/jeong%2Dsik/repo.git")

let test_org_with_dots () =
  (check (option string)) "org with dots rejected"
    None
    (Tool_code_write.extract_github_org
       "https://github.com/jeong.sik/repo.git")

(* ── validate_clone_url ──────────────────────────────────────────── *)

(* Use the shared project-root resolver so isolated build dirs such as
   [.ci_build/default/test] still find config/tool_policy.toml reliably. *)
let project_base_path () = Masc_test_deps.find_project_root ()

let make_ctx () : Tool_code_write.context =
  let base_path = project_base_path () in
  { Tool_code_write.config = Coord.default_config base_path;
    agent_name = "test-agent"; }

let dispatch_exn ctx ~name ~args =
  match Tool_code_write.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> fail ("dispatch returned None for " ^ name)

let test_allowed_org () =
  with_temp_policy [ "jeong-sik" ] @@ fun bp ->
  (check (result unit string)) "allowed org passes"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:bp
       "https://github.com/jeong-sik/masc-mcp.git")

let test_disallowed_org () =
  with_temp_policy [ "jeong-sik" ] @@ fun bp ->
  match Tool_code_write.validate_clone_url ~base_path:bp
    "https://github.com/other-org/repo.git" with
  | Error _ -> ()
  | Ok () -> fail "expected error for disallowed org"

let test_disallowed_org_mentions_workspace_path_hint () =
  with_temp_policy [ "jeong-sik" ] @@ fun bp ->
  match Tool_code_write.validate_clone_url ~base_path:bp
    "https://github.com/yousleepwhen/masc-mcp.git" with
  | Error reason ->
      check bool "error hints against workspace path inference" true
        (msg_contains
           ~needle:"do not infer an org from local workspace path segments"
           reason)
  | Ok () -> fail "expected error for disallowed org"

let test_non_github_rejected () =
  with_temp_policy [] @@ fun bp ->
  match Tool_code_write.validate_clone_url ~base_path:bp
    "https://gitlab.com/jeong-sik/repo.git" with
  | Error _ -> ()
  | Ok () -> fail "expected error for non-github URL"

let test_empty_allowed_orgs_allows_supported_github () =
  with_temp_policy [] @@ fun bp ->
  (check (result unit string)) "explicit empty allowed_orgs allows GitHub"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:bp
       "https://github.com/other-org/repo.git")

let test_empty_allowed_orgs_still_applies_denied_repos () =
  with_temp_policy ~denied_repos:[ "jeong-sik/me" ] [] @@ fun bp ->
  match Tool_code_write.validate_clone_url ~base_path:bp
    "https://github.com/jeong-sik/me.git" with
  | Error reason ->
      check bool "mentions denied list" true
        (msg_contains ~needle:"denied list" reason)
  | Ok () -> fail "expected denied repo to fail even with empty allowed_orgs"

let test_ssh_allowed () =
  with_temp_policy [ "jeong-sik" ] @@ fun bp ->
  (check (result unit string)) "ssh allowed org passes"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:bp
       "git@github.com:jeong-sik/oas.git")

let test_normalize_github_clone_url_converts_ssh_to_https () =
  check string "ssh remote normalized to https"
    "https://github.com/jeong-sik/oas.git"
    (Tool_code_write.normalize_github_clone_url
       "git@github.com:jeong-sik/oas.git")

let test_missing_base_path_without_config_fails_closed () =
  Tool_code_write.reset_policy_config_cache ();
  Fun.protect ~finally:Tool_code_write.reset_policy_config_cache (fun () ->
    with_trimmed_env "MASC_CONFIG_DIR" None @@ fun () ->
    check
      (option string)
      "blank override trims to None"
      None
      (Env_config.config_dir_opt ());
    match Tool_code_write.validate_clone_url ~base_path:"/nonexistent"
      "https://github.com/evil-corp/repo.git" with
  | Error _ -> ()
  | Ok () -> fail "validation should fail closed when config root is missing")

let test_missing_policy_does_not_reuse_previous_cache () =
  with_temp_policy [ "jeong-sik" ] @@ fun configured_bp ->
  (check (result unit string)) "configured policy passes"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:configured_bp
       "https://github.com/jeong-sik/repo.git");
  with_temp_dir "tool-code-write-missing-policy" @@ fun missing_bp ->
  match Tool_code_write.validate_clone_url ~base_path:missing_bp
    "https://github.com/jeong-sik/repo.git" with
  | Error reason ->
      check bool "mentions unavailable policy" true
        (msg_contains ~needle:"Git clone policy unavailable" reason)
  | Ok () -> fail "missing policy should not reuse prior cached config"

let test_policy_load_error_emits_metric () =
  Tool_code_write.reset_policy_config_cache ();
  Fun.protect ~finally:Tool_code_write.reset_policy_config_cache (fun () ->
    with_trimmed_env "MASC_CONFIG_DIR" None @@ fun () ->
    let before = tool_code_write_policy_load_failure_metric () in
    (match Tool_code_write.validate_clone_url ~base_path:"/nonexistent"
       "https://github.com/jeong-sik/repo.git" with
     | Error _ -> ()
     | Ok () -> fail "missing policy should fail closed");
    let after = tool_code_write_policy_load_failure_metric () in
    check bool "policy load failure increments metric" true
      (after >= before +. 1.0))

let test_explicit_config_dir_override_still_validates () =
  with_temp_dir "tool-code-write-env-policy" @@ fun root ->
  let config_dir = Filename.concat root "config" in
  mkdir_p config_dir;
  write_file
    (Filename.concat config_dir "tool_policy.toml")
    (policy_toml [ "jeong-sik" ]);
  Tool_code_write.reset_policy_config_cache ();
  Fun.protect ~finally:Tool_code_write.reset_policy_config_cache (fun () ->
    with_trimmed_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
    check
      (option string)
      "explicit override survives trimming"
      (Some config_dir)
      (Env_config.config_dir_opt ());
    match Tool_code_write.validate_clone_url ~base_path:"/nonexistent"
      "https://github.com/evil-corp/repo.git" with
    | Error _ -> ()
    | Ok () ->
        fail "disallowed org should still be rejected with explicit config override")

let test_mixed_case_org () =
  with_temp_policy [ "jeong-sik" ] @@ fun bp ->
  (check (result unit string)) "mixed-case org passes"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:bp
       "https://github.com/Jeong-Sik/repo.git")

(* ── masc_code_git dispatch coverage ───────────────────────────── *)

let test_code_git_clone_rejects_flag_args () =
  let ctx = make_ctx () in
  let args =
    `Assoc
      [ ("action", `String "clone");
        ("args",
         `List
           [ `String "https://github.com/jeong-sik/masc-mcp.git";
             `String "--upload-pack=/bin/sh" ]) ]
  in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_git" ~args in
  check bool "clone flags rejected" false ok;
  check bool "mentions injection block" true
    (msg_contains ~needle:"clone does not accept flags" msg)

let test_code_git_push_main_blocked_before_cwd_validation () =
  let ctx = make_ctx () in
  let args =
    `Assoc
      [ ("action", `String "push");
        ("args", `List [ `String "origin"; `String "main" ]) ]
  in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_git" ~args in
  check bool "push main rejected" false ok;
  check bool "dangerous op message" true
    (msg_contains ~needle:"Dangerous git operation blocked" msg)

let test_code_git_force_push_blocked_before_cwd_validation () =
  let ctx = make_ctx () in
  let args =
    `Assoc
      [ ("action", `String "push");
        ("args", `List [ `String "--force"; `String "origin"; `String "feature/foo" ]) ]
  in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_git" ~args in
  check bool "force push rejected" false ok;
  check bool "dangerous op message" true
    (msg_contains ~needle:"Dangerous git operation blocked" msg)

let test_code_git_checkout_dot_blocked_before_cwd_validation () =
  let ctx = make_ctx () in
  let args =
    `Assoc
      [ ("action", `String "checkout");
        ("args", `List [ `String "--"; `String "." ]) ]
  in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_git" ~args in
  check bool "checkout dot rejected" false ok;
  check bool "dangerous op message" true
    (msg_contains ~needle:"Dangerous git operation blocked" msg)

(* ── validate_code_shell_command ─────────────────────────────────── *)

let test_validate_code_shell_command_allows_pipe () =
  (* Pipes are now allowed: each segment is independently validated
     against the allowlist; dangerous metacharacters remain blocked. *)
  check (result unit string) "piped allowlisted commands accepted"
    (Ok ())
    (Tool_code_write.validate_code_shell_command "dune build 2>&1 | tail -5")

let test_validate_code_shell_command_rejects_pipe_to_disallowed () =
  match
    Tool_code_write.validate_code_shell_command "dune build | xargs rm -rf"
  with
  | Error _ -> ()
  | Ok () ->
      fail "expected pipe-to-disallowed-command to be rejected by allowlist"

let test_validate_code_shell_command_allows_direct_build () =
  check (result unit string) "direct build allowed" (Ok ())
    (Tool_code_write.validate_code_shell_command "dune build 2>&1")

let test_validate_code_shell_command_rejects_semicolon () =
  match
    Tool_code_write.validate_code_shell_command
      "dune build; tail -5"
  with
  | Error reason ->
      check bool "reason mentions shell injection" true
        (String.starts_with ~prefix:"Shell injection syntax" reason)
  | Ok () -> fail "expected semicolon chaining to be rejected"

(* ── Per-agent containment (#6527 iter 6) ───────────────────────────
   Regression tests for PR #6610 — verify that validate_writable_path
   and validate_clone_cwd refuse cross-agent playground writes even
   for two distinct agent_names sharing the same config.base_path.

   The gate uses String.starts_with against
   Keeper_alerting_path.playground_path_of_keeper agent_name, so a
   lexical check is enough — no real filesystem setup is required
   beyond a tmp base_path that points inside an existing git repo
   (required by Tool_code.validate_path canonicalisation). *)

let is_error result =
  match result with
  | Ok _ -> false
  | Error _ -> true

let contains needle haystack =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0 then true
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

let error_msg result =
  match result with
  | Ok _ -> ""
  | Error (Types.System (Types.System_error.IoError m)) -> m
  | Error _ -> "<non-IoError>"

let make_config base_path : Masc_mcp.Coord.config =
  (* Override MASC_BASE_PATH so default_config does not pick up the
     developer's global MASC root instead of our fresh tmp tree. The
     test runner sets this env var from the user's shell. *)
  Unix.putenv "MASC_BASE_PATH" base_path;
  Masc_mcp.Coord.default_config base_path

(* Ensure the base path exists as a real git repository so
   Tool_code.validate_path (which requires
   Coord_git.git_root ~base_path) can canonicalise against it.

   On macOS, $TMPDIR points to /var/folders/... which is a symlink
   target of /private/var/folders/... Coord_git.git_root returns the
   fully realpath-resolved root, so we also realpath-resolve the
   base_path before returning it — otherwise the prefix check inside
   Tool_code.validate_path trips on the `/private/` divergence. *)
let fresh_base_path () =
  let raw_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "tool_code_write_iter6_%d_%d"
       (Unix.getpid ())
       (int_of_float (Unix.gettimeofday () *. 1_000_000.))) in
  Unix.mkdir raw_dir 0o755;
  let dir = try Unix.realpath raw_dir with _ -> raw_dir in
  (* Initialise a minimal git repository so validate_path has a
     canonical root. An empty `git init` plus an initial commit
     is sufficient; Coord_git.git_root walks up from base_path. *)
  let run_git args =
    let cmd = String.concat " "
      (List.map Filename.quote ("git" :: args) @ [">"; "/dev/null"; "2>&1"]) in
    ignore (Sys.command cmd)
  in
  run_git [ "init"; "-b"; "main"; dir ];
  run_git [ "-C"; dir; "config"; "user.email"; "iter6@example.test" ];
  run_git [ "-C"; dir; "config"; "user.name"; "Iter6 Test" ];
  let readme = Filename.concat dir "README.md" in
  Out_channel.with_open_bin readme
    (fun oc -> output_string oc "# iter6 test\n");
  run_git [ "-C"; dir; "add"; "README.md" ];
  run_git [ "-C"; dir; "commit"; "-m"; "init" ];
  (* Create the playground subtrees for two distinct agents so
     validate_writable_path's path canonicalisation does not trip on
     a missing directory. *)
  let mkdir_p path =
    let rec go acc = function
      | [] -> ()
      | part :: rest ->
        let acc = Filename.concat acc part in
        (try Unix.mkdir acc 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
        go acc rest
    in
    match String.split_on_char '/' path with
    | "" :: parts -> go "/" parts
    | parts -> go "." parts
  in
  mkdir_p (Filename.concat dir ".masc/playground/agent-a/mind");
  mkdir_p (Filename.concat dir ".masc/playground/agent-b/mind");
  mkdir_p (Filename.concat dir ".masc/playground/agent-a/repos");
  mkdir_p (Filename.concat dir ".masc/playground/agent-b/repos");
  dir

let test_writable_path_allows_own_playground () =
  let base_path = fresh_base_path () in
  let config = make_config base_path in
  let path_a = Filename.concat base_path ".masc/playground/agent-a/mind/note.md" in
  let result =
    Tool_code_write.validate_writable_path ~agent_name:"agent-a" config path_a
  in
  (check bool) "agent-a writing into agent-a own playground is allowed"
    false (is_error result)

let test_writable_path_maps_relative_repos_prefix () =
  let base_path = fresh_base_path () in
  let config = make_config base_path in
  let raw = "repos/masc-mcp/lib/demo.ml" in
  let expected =
    Filename.concat base_path ".masc/playground/agent-a/repos/masc-mcp/lib/demo.ml"
    |> Masc_mcp.Tool_code.normalize_path
  in
  let result =
    Tool_code_write.validate_writable_path ~agent_name:"agent-a" config raw
  in
  match result with
  | Error e ->
    fail ("expected repos/ prefix to map into own playground, got: "
          ^ Types.masc_error_to_string e)
  | Ok resolved ->
    (check string) "repos/ path resolves under own playground repos"
      expected resolved

let test_writable_path_blocks_cross_agent () =
  let base_path = fresh_base_path () in
  let config = make_config base_path in
  let path_b = Filename.concat base_path ".masc/playground/agent-b/mind/note.md" in
  let result =
    Tool_code_write.validate_writable_path ~agent_name:"agent-a" config path_b
  in
  (check bool) "agent-a writing into agent-b playground is rejected"
    true (is_error result);
  (check bool) "error mentions own playground prefix" true
    (contains "agent-a" (error_msg result));
  (check bool) "error flags cross-agent block" true
    (contains "Cross-agent" (error_msg result))

let test_clone_cwd_allows_own_repos () =
  let base_path = fresh_base_path () in
  let config = make_config base_path in
  let cwd_a = Filename.concat base_path ".masc/playground/agent-a/repos" in
  let result =
    Tool_code_write.validate_clone_cwd ~agent_name:"agent-a" config cwd_a
  in
  (* validate_clone_cwd may still error on non-git root detection, so
     accept either Ok or an IoError that does NOT mention "Cross-agent".
     The point of this case is to confirm that the per-agent prefix
     check accepts the caller's own path. *)
  (check bool) "agent-a cloning into own repos is not rejected by containment" false
    (contains "Cross-agent" (error_msg result))

let test_clone_cwd_blocks_cross_agent_repos () =
  let base_path = fresh_base_path () in
  let config = make_config base_path in
  let cwd_b = Filename.concat base_path ".masc/playground/agent-b/repos" in
  let result =
    Tool_code_write.validate_clone_cwd ~agent_name:"agent-a" config cwd_b
  in
  (* Cross-agent path must trip either the playground prefix check
     ("Cross-agent playground clones are blocked") or the earlier
     "Not in a git repository" error when base_path has no .git. We
     only assert the rejection, not the exact branch taken. *)
  (check bool) "agent-a cloning into agent-b repos is rejected"
    true (is_error result)

(* ── Runner ──────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Tool_code_write" [
    ("extract_github_org", [
      test_case "https with .git" `Quick test_https_url;
      test_case "https without .git" `Quick test_https_url_no_git;
      test_case "ssh URL" `Quick test_ssh_url;
      test_case "ssh protocol URL" `Quick test_ssh_protocol_url;
      test_case "non-github URL" `Quick test_non_github_url;
      test_case "bare string" `Quick test_bare_string;
      test_case "different org" `Quick test_different_org;
      test_case "empty string" `Quick test_empty_string;
      test_case "no repo path" `Quick test_no_repo_path;
    ]);
    ("security", [
      test_case "domain spoofing" `Quick test_domain_spoofing;
      test_case "authority spoofing" `Quick test_authority_spoofing;
      test_case "uppercase normalized" `Quick test_uppercase_normalized;
      test_case "percent-encoded org" `Quick test_percent_encoded_org;
      test_case "org with dots" `Quick test_org_with_dots;
    ]);
    ("validate_clone_url", [
      test_case "allowed org" `Quick test_allowed_org;
      test_case "disallowed org" `Quick test_disallowed_org;
      test_case "disallowed org hints against workspace path inference" `Quick
        test_disallowed_org_mentions_workspace_path_hint;
      test_case "non-github rejected" `Quick test_non_github_rejected;
      test_case "empty allowed_orgs allows supported GitHub" `Quick
        test_empty_allowed_orgs_allows_supported_github;
      test_case "empty allowed_orgs still applies denied repos" `Quick
        test_empty_allowed_orgs_still_applies_denied_repos;
      test_case "ssh allowed" `Quick test_ssh_allowed;
      test_case "missing config fails closed" `Quick test_missing_base_path_without_config_fails_closed;
      test_case "missing policy does not reuse previous cache" `Quick
        test_missing_policy_does_not_reuse_previous_cache;
      test_case "policy load error emits metric" `Quick
        test_policy_load_error_emits_metric;
      test_case "explicit config dir override still validates" `Quick test_explicit_config_dir_override_still_validates;
      test_case "mixed-case org" `Quick test_mixed_case_org;
      test_case "normalize ssh clone url to https" `Quick
        test_normalize_github_clone_url_converts_ssh_to_https;
    ]);
    ("masc_code_git", [
      test_case "clone rejects flag args" `Quick
        test_code_git_clone_rejects_flag_args;
      test_case "push main blocked before cwd validation" `Quick
        test_code_git_push_main_blocked_before_cwd_validation;
      test_case "force push blocked before cwd validation" `Quick
        test_code_git_force_push_blocked_before_cwd_validation;
      test_case "checkout dot blocked before cwd validation" `Quick
        test_code_git_checkout_dot_blocked_before_cwd_validation;
    ]);
    ("validate_code_shell_command", [
      test_case "allows pipe with allowlisted segments" `Quick
        test_validate_code_shell_command_allows_pipe;
      test_case "rejects pipe to disallowed command" `Quick
        test_validate_code_shell_command_rejects_pipe_to_disallowed;
      test_case "allows direct build" `Quick
        test_validate_code_shell_command_allows_direct_build;
      test_case "rejects semicolon" `Quick
        test_validate_code_shell_command_rejects_semicolon;
    ]);
    ("per_agent_containment_6527_iter6", [
      test_case "writable_path allows own playground" `Quick
        test_writable_path_allows_own_playground;
      test_case "writable_path maps relative repos prefix" `Quick
        test_writable_path_maps_relative_repos_prefix;
      test_case "writable_path blocks cross-agent" `Quick
        test_writable_path_blocks_cross_agent;
      test_case "clone_cwd does not reject own repos on containment axis" `Quick
        test_clone_cwd_allows_own_repos;
      test_case "clone_cwd blocks cross-agent repos" `Quick
        test_clone_cwd_blocks_cross_agent_repos;
    ]);
  ]
