(** Source-level guardrails for the keeper sandbox boundary.

    The behavioral tests prove individual path translations. These tests
    pin the architectural split so future changes do not move TOML
    parsing, Docker container paths, or generic command semantics back
    into the wrong layer. *)

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let read_source rel =
  let path = Filename.concat (repo_root ()) rel in
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)

let contains haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0
  then true
  else
    let rec loop i =
      i + needle_len <= hay_len
      && (String.equal (String.sub haystack i needle_len) needle
          || loop (i + 1))
    in
    loop 0

let assert_contains rel needle =
  Alcotest.(check bool)
    (Printf.sprintf "%s contains %S" rel needle)
    true
    (contains (read_source rel) needle)

let assert_not_contains rel needle =
  Alcotest.(check bool)
    (Printf.sprintf "%s does not contain %S" rel needle)
    false
    (contains (read_source rel) needle)

let assert_source_absent rel =
  Alcotest.(check bool)
    (Printf.sprintf "%s is absent" rel)
    false
    (Sys.file_exists (Filename.concat (repo_root ()) rel))

let test_config_contract_uses_structured_toml () =
  let rel = "lib/config/keeper_sandbox_config.ml" in
  assert_contains rel "Otoml.Parser.from_string_result";
  assert_contains rel "valid_sandbox_profile_strings";
  assert_not_contains rel "strip_inline_comment";
  assert_not_contains rel "unquote"

let test_legacy_profile_aliases_removed_from_runtime () =
  let rel = "lib/keeper/keeper_types_profile_sandbox.ml" in
  assert_not_contains rel "legacy_local";
  assert_not_contains rel "docker_hardened";
  assert_not_contains rel "docker_with_git";
  assert_not_contains rel "sandbox_profile_of_string_with_warning"

let test_coord_consumes_config_projection_only () =
  let rel = "lib/coord/coord_worktree_paths.ml" in
  assert_contains rel "Keeper_sandbox_config.host_root_rel_of_agent";
  assert_contains rel "Keeper_sandbox_config.visible_path_of_host_path";
  assert_not_contains rel "Env_config_keeper.DockerPlayground";
  assert_not_contains rel "keeper_uses_docker_sandbox";
  assert_not_contains rel "sandbox_profile";
  assert_not_contains rel "strip_inline_comment";
  assert_not_contains rel "unquote"

let test_tool_layer_uses_sandbox_contract () =
  let rel = "lib/tool_code.ml" in
  assert_contains rel "Keeper_sandbox.host_root_rel_of_config_agent";
  assert_contains rel "Keeper_sandbox.host_path_of_visible_path";
  assert_not_contains rel "Coord_worktree.keeper_uses_docker_sandbox";
  assert_not_contains rel "Env_config_keeper.DockerPlayground";
  assert_not_contains rel "\"/home/keeper/playground\""

let test_docker_does_not_own_command_semantics () =
  let docker_mli = "lib/keeper/keeper_sandbox_docker.mli" in
  let docker_ml = "lib/keeper/keeper_sandbox_docker.ml" in
  let semantics_ml = "lib/keeper/keeper_shell_command_semantics.ml" in
  assert_not_contains docker_mli "run_docker_with_git_bash";
  assert_not_contains docker_ml "run_docker_with_git_bash";
  assert_not_contains docker_mli "run_docker_hardened_bash";
  assert_not_contains docker_ml "run_docker_hardened_bash";
  assert_not_contains docker_mli "val cmd_targets_git_or_gh";
  assert_not_contains docker_mli "val cmd_targets_gh";
  assert_not_contains docker_mli "val resolve_sandbox_root_git_cwd";
  assert_not_contains docker_mli "val stages_targets_git_or_gh";
  assert_not_contains docker_mli "val stages_targets_gh";
  assert_not_contains docker_mli "val resolve_sandbox_root_git_cwd_of_stages";
  assert_not_contains docker_ml "let cmd_targets_git_or_gh";
  assert_not_contains docker_ml "let cmd_targets_gh";
  assert_not_contains docker_ml "let resolve_sandbox_root_git_cwd";
  assert_not_contains docker_ml "let stages_targets_git_or_gh";
  assert_not_contains docker_ml "let stages_targets_gh";
  assert_not_contains docker_ml "let resolve_sandbox_root_git_cwd_of_stages";
  assert_contains semantics_ml "let stages_targets_git_or_gh";
  assert_contains semantics_ml "let stages_targets_gh";
  assert_contains semantics_ml "let resolve_sandbox_root_git_cwd_of_stages";
  assert_contains semantics_ml "Exec_policy_mutation_classifier.parsed_of_string";
  assert_not_contains semantics_ml "Option.value"

let test_sandbox_failure_recording_not_shell_docker_coupled () =
  let docker_mli = "lib/keeper/keeper_sandbox_docker.mli" in
  let docker_ml = "lib/keeper/keeper_sandbox_docker.ml" in
  let failure_ml = "lib/keeper/keeper_sandbox_exec_failure.ml" in
  assert_source_absent "lib/keeper/keeper_shell_docker.ml";
  assert_source_absent "lib/keeper/keeper_shell_docker.mli";
  assert_source_absent "lib/keeper/keeper_shell_docker_exec_failure.ml";
  assert_source_absent "lib/keeper/keeper_shell_docker_exec_failure.mli";
  assert_source_absent "lib/keeper/keeper_shell_bash_docker.ml";
  assert_source_absent "lib/keeper/keeper_shell_bash_docker.mli";
  assert_not_contains docker_mli "Keeper_shell_docker";
  assert_not_contains docker_ml "Keeper_shell_docker";
  assert_not_contains docker_mli "Keeper_shell_docker_exec_failure";
  assert_not_contains docker_ml "Keeper_shell_docker_exec_failure";
  assert_contains docker_mli "Keeper_sandbox_exec_failure";
  assert_contains docker_ml "Keeper_sandbox_exec_failure";
  assert_contains failure_ml "Sandbox backend exec failure";
  assert_not_contains failure_ml "keeper_shell_docker.ml"

let test_tool_layer_does_not_select_concrete_backend () =
  List.iter
    (fun rel ->
       assert_contains rel "Keeper_sandbox_runner.run_command_with_status";
       assert_not_contains rel "Keeper_sandbox_docker.";
       assert_not_contains rel "meta.sandbox_profile = Docker";
       assert_not_contains rel "run_docker_shell_command_with_status")
    [ "lib/keeper/keeper_tool_github_pr.ml"
    ; "lib/keeper/keeper_tool_pr_review.ml"
    ]

let () =
  Alcotest.run
    "keeper_sandbox_boundary_policy"
    [
      ( "config",
        [
          Alcotest.test_case
            "uses structured TOML parser"
            `Quick
            test_config_contract_uses_structured_toml;
          Alcotest.test_case
            "rejects removed legacy profile aliases"
            `Quick
            test_legacy_profile_aliases_removed_from_runtime;
        ] );
      ( "layers",
        [
          Alcotest.test_case
            "coord consumes config projection"
            `Quick
            test_coord_consumes_config_projection_only;
          Alcotest.test_case
            "tool layer uses sandbox contract"
            `Quick
            test_tool_layer_uses_sandbox_contract;
          Alcotest.test_case
            "docker does not own command semantics"
            `Quick
            test_docker_does_not_own_command_semantics;
          Alcotest.test_case
            "sandbox failure recording is not shell-docker coupled"
            `Quick
            test_sandbox_failure_recording_not_shell_docker_coupled;
          Alcotest.test_case
            "tool layer does not select concrete backend"
            `Quick
            test_tool_layer_does_not_select_concrete_backend;
        ] );
    ]
