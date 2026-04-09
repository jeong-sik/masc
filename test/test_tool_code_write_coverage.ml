(** Coverage tests for Tool_code_write — git clone URL parsing
    and org allowlist validation. Pure function tests only. *)

open Alcotest

module Tool_code_write = Masc_mcp.Tool_code_write

let with_env name value f =
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

let test_allowed_org () =
  let bp = project_base_path () in
  (check (result unit string)) "allowed org passes"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:bp
       "https://github.com/jeong-sik/masc-mcp.git")

let test_disallowed_org () =
  let bp = project_base_path () in
  match Tool_code_write.validate_clone_url ~base_path:bp
    "https://github.com/other-org/repo.git" with
  | Error _ -> ()
  | Ok () -> fail "expected error for disallowed org"

let test_non_github_rejected () =
  let bp = project_base_path () in
  match Tool_code_write.validate_clone_url ~base_path:bp
    "https://gitlab.com/jeong-sik/repo.git" with
  | Error _ -> ()
  | Ok () -> fail "expected error for non-github URL"

let test_ssh_allowed () =
  let bp = project_base_path () in
  (check (result unit string)) "ssh allowed org passes"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:bp
       "git@github.com:jeong-sik/oas.git")

let test_missing_base_path_without_config_fails_closed () =
  Tool_code_write.reset_policy_config_cache ();
  Fun.protect ~finally:Tool_code_write.reset_policy_config_cache (fun () ->
    with_env "MASC_CONFIG_DIR" None @@ fun () ->
    match Tool_code_write.validate_clone_url ~base_path:"/nonexistent"
      "https://github.com/evil-corp/repo.git" with
    | Error _ -> ()
    | Ok () -> fail "validation should fail closed when config root is missing")

let test_explicit_config_dir_override_still_validates () =
  let project_root = project_base_path () in
  let config_dir = Filename.concat project_root "config" in
  Tool_code_write.reset_policy_config_cache ();
  Fun.protect ~finally:Tool_code_write.reset_policy_config_cache (fun () ->
    with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
    match Tool_code_write.validate_clone_url ~base_path:"/nonexistent"
      "https://github.com/evil-corp/repo.git" with
    | Error _ -> ()
    | Ok () ->
        fail "disallowed org should still be rejected with explicit config override")

let test_mixed_case_org () =
  let bp = project_base_path () in
  (check (result unit string)) "mixed-case org passes"
    (Ok ())
    (Tool_code_write.validate_clone_url ~base_path:bp
       "https://github.com/Jeong-Sik/repo.git")

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
      test_case "non-github rejected" `Quick test_non_github_rejected;
      test_case "ssh allowed" `Quick test_ssh_allowed;
      test_case "missing config fails closed" `Quick test_missing_base_path_without_config_fails_closed;
      test_case "explicit config dir override still validates" `Quick test_explicit_config_dir_override_still_validates;
      test_case "mixed-case org" `Quick test_mixed_case_org;
    ]);
  ]
