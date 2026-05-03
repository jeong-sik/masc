(** Regression test for [Coord_worktree.load_git_clone_policy] path resolution.

    Bug: prior to this fix, the loader read [<base_path>/config/tool_policy.toml]
    only, but the canonical config root is [<base_path>/.masc/config/]. Result
    was empty [allowed_orgs] for keepers whose lookup goes through this loader,
    surfacing as [No allowed orgs configured for git clone] in clone attempts.

    These tests pin the new behaviour: canonical path takes precedence, legacy
    path is honoured as a fallback, and absence of both is a clean empty
    return.
*)

open Alcotest

module CW = Coord_worktree

let contains ~needle haystack =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else loop (i + 1)
  in
  nlen = 0 || loop 0

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else Sys.remove path
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

let policy_with_orgs ?(denied_repos = []) orgs =
  let arr = orgs |> List.map (Printf.sprintf "%S") |> String.concat ", " in
  let denied =
    denied_repos |> List.map (Printf.sprintf "%S") |> String.concat ", "
  in
  Printf.sprintf
    "[git_clone]\nallowed_orgs = [%s]\ndenied_repos = [%s]\n"
    arr denied

let write_canonical_policy base content =
  let dir = Filename.concat (Filename.concat base ".masc") "config" in
  mkdir_p dir;
  write_file (Filename.concat dir "tool_policy.toml") content

let test_canonical_masc_config () =
  with_temp_dir "coord-worktree-policy-canon" @@ fun base ->
  let dir = Filename.concat (Filename.concat base ".masc") "config" in
  mkdir_p dir;
  write_file (Filename.concat dir "tool_policy.toml")
    (policy_with_orgs [ "jeong-sik"; "kidsnote" ]);
  let allowed, _denied = CW.load_git_clone_policy ~base_path:base in
  check (list string) "canonical .masc/config/ resolves orgs"
    [ "jeong-sik"; "kidsnote" ] allowed

let test_legacy_config_dir () =
  with_temp_dir "coord-worktree-policy-legacy" @@ fun base ->
  let dir = Filename.concat base "config" in
  mkdir_p dir;
  write_file (Filename.concat dir "tool_policy.toml")
    (policy_with_orgs [ "legacy-org" ]);
  let allowed, _denied = CW.load_git_clone_policy ~base_path:base in
  check (list string) "legacy <base>/config/ honoured when canonical missing"
    [ "legacy-org" ] allowed

let test_canonical_takes_priority () =
  with_temp_dir "coord-worktree-policy-priority" @@ fun base ->
  let canon = Filename.concat (Filename.concat base ".masc") "config" in
  mkdir_p canon;
  write_file (Filename.concat canon "tool_policy.toml")
    (policy_with_orgs [ "canonical" ]);
  let legacy = Filename.concat base "config" in
  mkdir_p legacy;
  write_file (Filename.concat legacy "tool_policy.toml")
    (policy_with_orgs [ "legacy" ]);
  let allowed, _denied = CW.load_git_clone_policy ~base_path:base in
  check (list string) "canonical wins over legacy when both exist"
    [ "canonical" ] allowed

let test_neither_present () =
  with_temp_dir "coord-worktree-policy-none" @@ fun base ->
  let allowed, denied = CW.load_git_clone_policy ~base_path:base in
  check (list string) "no policy file → empty allowed" [] allowed;
  check (list string) "no policy file → empty denied" [] denied

let test_validate_missing_policy_fails_closed () =
  with_temp_dir "coord-worktree-policy-validate-none" @@ fun base ->
  match CW.validate_clone_origin_url ~base_path:base
    "https://github.com/jeong-sik/masc-mcp.git" with
  | Error reason ->
      check bool "mentions unavailable policy" true
        (contains ~needle:"Git clone policy unavailable" reason)
  | Ok () -> fail "missing policy must fail closed"

let test_validate_empty_allowed_allows_supported_github () =
  with_temp_dir "coord-worktree-policy-validate-open" @@ fun base ->
  write_canonical_policy base (policy_with_orgs []);
  (check (result unit string)) "explicit empty allowed_orgs allows GitHub"
    (Ok ())
    (CW.validate_clone_origin_url ~base_path:base
       "https://github.com/other-org/repo.git")

let test_validate_empty_allowed_rejects_non_github () =
  with_temp_dir "coord-worktree-policy-validate-nongh" @@ fun base ->
  write_canonical_policy base (policy_with_orgs []);
  match CW.validate_clone_origin_url ~base_path:base
    "https://gitlab.com/other-org/repo.git" with
  | Error _ -> ()
  | Ok () -> fail "non-GitHub URL must be rejected even with empty allowed_orgs"

let test_validate_empty_allowed_allows_local_origin_under_base () =
  with_temp_dir "coord-worktree-policy-validate-local" @@ fun base ->
  write_canonical_policy base (policy_with_orgs []);
  let local_origin = Filename.concat base ".remote.git" in
  mkdir_p local_origin;
  (check (result unit string)) "local origin under base_path is allowed"
    (Ok ())
    (CW.validate_clone_origin_url ~base_path:base local_origin)

let test_validate_empty_allowed_rejects_local_origin_outside_base () =
  with_temp_dir "coord-worktree-policy-validate-local-base" @@ fun base ->
  with_temp_dir "coord-worktree-policy-validate-local-outside" @@ fun outside ->
  write_canonical_policy base (policy_with_orgs []);
  let local_origin = Filename.concat outside ".remote.git" in
  mkdir_p local_origin;
  match CW.validate_clone_origin_url ~base_path:base local_origin with
  | Error reason ->
      check bool "mentions outside base_path" true
        (contains ~needle:"outside base_path" reason)
  | Ok () -> fail "local origin outside base_path must be rejected"

let test_validate_empty_allowed_applies_denied_repos () =
  with_temp_dir "coord-worktree-policy-validate-denied" @@ fun base ->
  write_canonical_policy base
    (policy_with_orgs ~denied_repos:[ "jeong-sik/me" ] []);
  match CW.validate_clone_origin_url ~base_path:base
    "https://github.com/jeong-sik/me.git" with
  | Error reason ->
      check bool "mentions denied list" true
        (contains ~needle:"denied list" reason)
  | Ok () -> fail "denied repo must be rejected"

let test_validate_allowed_org_rejects_other_org () =
  with_temp_dir "coord-worktree-policy-validate-allowed" @@ fun base ->
  write_canonical_policy base (policy_with_orgs [ "jeong-sik" ]);
  match CW.validate_clone_origin_url ~base_path:base
    "https://github.com/other-org/repo.git" with
  | Error reason ->
      check bool "mentions allowed list" true
        (contains ~needle:"not in allowed list" reason)
  | Ok () -> fail "org outside non-empty allowed_orgs must be rejected"

let () =
  Alcotest.run "coord_worktree policy path"
    [
      ( "load_git_clone_policy",
        [
          test_case "canonical .masc/config/" `Quick test_canonical_masc_config;
          test_case "legacy <base>/config/" `Quick test_legacy_config_dir;
          test_case "canonical takes priority" `Quick test_canonical_takes_priority;
          test_case "neither path present" `Quick test_neither_present;
        ] );
      ( "validate_clone_origin_url",
        [
          test_case "missing policy fails closed" `Quick
            test_validate_missing_policy_fails_closed;
          test_case "empty allowed_orgs allows supported GitHub" `Quick
            test_validate_empty_allowed_allows_supported_github;
          test_case "empty allowed_orgs rejects non-GitHub" `Quick
            test_validate_empty_allowed_rejects_non_github;
          test_case "empty allowed_orgs allows local origin under base" `Quick
            test_validate_empty_allowed_allows_local_origin_under_base;
          test_case "empty allowed_orgs rejects local origin outside base" `Quick
            test_validate_empty_allowed_rejects_local_origin_outside_base;
          test_case "empty allowed_orgs applies denied repos" `Quick
            test_validate_empty_allowed_applies_denied_repos;
          test_case "non-empty allowed_orgs rejects other org" `Quick
            test_validate_allowed_org_rejects_other_org;
        ] );
    ]
