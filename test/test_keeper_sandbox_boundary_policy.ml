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

let has_suffix text suffix =
  let text_len = String.length text in
  let suffix_len = String.length suffix in
  text_len >= suffix_len
  && String.equal (String.sub text (text_len - suffix_len) suffix_len) suffix

let rec source_files_under rel =
  let root = repo_root () in
  let rec loop rel =
    let abs = Filename.concat root rel in
    match Unix.lstat abs with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Sys.readdir abs
      |> Array.to_list
      |> List.concat_map (fun name -> loop (Filename.concat rel name))
    | { Unix.st_kind = Unix.S_REG; _ }
      when has_suffix rel ".ml" || has_suffix rel ".mli" -> [ rel ]
    | _ -> []
    | exception Unix.Unix_error _ -> []
  in
  loop rel

let source_files_containing ~under needle =
  source_files_under under
  |> List.filter (fun rel -> contains (read_source rel) needle)
  |> List.sort String.compare

let assert_only_sources_contain ~under ~needle expected =
  Alcotest.(check (list string))
    (Printf.sprintf "%s owner for %S" under needle)
    (List.sort String.compare expected)
    (source_files_containing ~under needle)

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
  let parse_ml = "lib/keeper/keeper_shell_command_parse.ml" in
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
  assert_contains semantics_ml "let parsed_stages_of_ir";
  assert_contains semantics_ml "Masc_exec.Shell_ir.Pipeline";
  assert_contains semantics_ml "Keeper_shell_command_parse.parse_cmd_to_ir_opt";
  assert_not_contains semantics_ml "Exec_policy.parse_string_to_ir";
  assert_contains parse_ml "Exec_policy.parse_string_to_ir";
  assert_not_contains semantics_ml "Option.value"

let test_keeper_raw_command_parse_owner () =
  assert_only_sources_contain
    ~under:"lib/keeper"
    ~needle:"Exec_policy.parse_string_to_ir"
    [ "lib/keeper/keeper_shell_command_parse.ml" ];
  assert_contains "lib/keeper/keeper_shell_command_parse.mli" "parse_cmd_to_ir_opt"

let test_keeper_command_word_classifier_owner () =
  let words_ml = "lib/keeper/keeper_shell_command_words.ml" in
  let semantics_ml = "lib/keeper/keeper_shell_command_semantics.ml" in
  let shell_ops_ml = "lib/keeper/keeper_shell_ops.ml" in
  assert_only_sources_contain
    ~under:"lib/keeper"
    ~needle:"Exec_policy_mutation_classifier"
    [ words_ml ];
  assert_contains words_ml "let first_token_of_cmd";
  assert_contains words_ml "let cmd_prefix";
  assert_contains shell_ops_ml "Keeper_shell_command_words.cmd_prefix";
  assert_not_contains semantics_ml "cmd_prefix"

let test_nested_runtime_uses_shell_command_words () =
  let rel = "lib/keeper/keeper_sandbox_docker_nested_runtime.ml" in
  let mli = "lib/keeper/keeper_sandbox_docker_nested_runtime.mli" in
  assert_contains rel "Command_words.guard_tokens_of_cmd";
  assert_not_contains rel "Exec_policy.parse_string_to_ir";
  assert_not_contains rel "Exec_policy_mutation_classifier";
  assert_not_contains mli "shell_guard_token";
  assert_not_contains mli "shell_guard_tokens"

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

let test_gh_tool_layer_uses_gh_runner () =
  List.iter
    (fun rel ->
       assert_contains rel "Keeper_gh_runner.run_argv";
       assert_not_contains rel "Keeper_sandbox_runner.run_command_with_status";
       assert_not_contains rel "Keeper_sandbox_docker.";
       assert_not_contains rel "meta.sandbox_profile = Docker";
       assert_not_contains rel "run_docker_shell_command_with_status")
    [ "lib/keeper/keeper_tool_github_pr.ml"
    ; "lib/keeper/keeper_tool_pr_review.ml"
    ]

let test_gh_runner_owns_sandbox_routing () =
  let rel = "lib/keeper/keeper_gh_runner.ml" in
  assert_contains rel "Keeper_sandbox_runner.run_command_with_status";
  assert_contains rel "network_mode = Network_inherit";
  assert_contains rel "git_creds_enabled = true"

let test_gh_repo_owns_repo_slug_discovery () =
  let repo_ml = "lib/keeper/keeper_gh_repo.ml" in
  let shared_ml = "lib/keeper/keeper_gh_shared.ml" in
  let shared_mli = "lib/keeper/keeper_gh_shared.mli" in
  assert_contains repo_ml "let validate_repo_slug";
  assert_contains repo_ml "let repo_slug_of_git_root";
  assert_contains repo_ml "Masc_exec.Exec_gate.run_argv_with_status";
  assert_contains "lib/keeper/keeper_tool_github_pr.ml" "Keeper_gh_repo.repo_slug_of_git_root";
  assert_contains "lib/keeper/keeper_tool_pr_review.ml" "Keeper_gh_repo.repo_slug_of_git_root";
  assert_not_contains shared_ml "Masc_exec.Exec_gate.run_argv";
  assert_not_contains shared_ml "let validate_repo_slug";
  assert_not_contains shared_ml "let repo_slug_of_git_root";
  assert_not_contains shared_mli "val validate_repo_slug";
  assert_not_contains shared_mli "val repo_slug_of_git_root";
  assert_not_contains "lib/keeper/keeper_tool_github_pr.ml" "Keeper_gh_shared.repo_slug";
  assert_not_contains "lib/keeper/keeper_tool_pr_review.ml" "Keeper_gh_shared.repo_slug"

let test_shell_read_ops_use_sandbox_read_runner () =
  let rel = "lib/keeper/keeper_shell_ops.ml" in
  assert_contains rel "Keeper_sandbox_read_runner.";
  assert_contains rel "Keeper_sandbox_read_runner.backend_via";
  assert_not_contains rel "Keeper_sandbox_read_backend.";
  assert_not_contains rel "\"via\", `String \"docker\""

let test_shell_path_owner () =
  let path_ml = "lib/keeper/keeper_shell_path.ml" in
  let shell_ops_ml = "lib/keeper/keeper_shell_ops.ml" in
  let gh_pr_ml = "lib/keeper/keeper_tool_github_pr.ml" in
  assert_contains "lib/dune" "keeper_shell_path";
  assert_contains path_ml "let resolve_keeper_shell_read_cwd";
  assert_contains path_ml "let resolve_keeper_shell_write_cwd";
  assert_contains path_ml "let resolve_keeper_shell_read_path";
  assert_contains path_ml "let shell_command_available";
  assert_contains shell_ops_ml "Keeper_shell_path.resolve_keeper_shell_read_path";
  assert_contains shell_ops_ml "Keeper_shell_path.resolve_keeper_shell_read_cwd";
  assert_contains shell_ops_ml "Keeper_shell_path.shell_command_available";
  assert_contains gh_pr_ml "Keeper_shell_path.resolve_keeper_shell_write_cwd";
  assert_contains gh_pr_ml "Keeper_shell_path.resolve_keeper_shell_read_cwd";
  assert_not_contains shell_ops_ml "Keeper_shell_shared.resolve_keeper_shell";
  assert_not_contains gh_pr_ml "Keeper_shell_shared.resolve_keeper_shell"

let test_shell_shared_is_removed () =
  let shell_ops_ml = "lib/keeper/keeper_shell_ops.ml" in
  let bash_ml = "lib/keeper/keeper_shell_bash.ml" in
  let exec_tools_ml = "lib/keeper/keeper_exec_tools.ml" in
  let exec_shell_ml = "lib/keeper/keeper_exec_shell.ml" in
  assert_source_absent "lib/keeper/keeper_shell_shared.ml";
  assert_source_absent "lib/keeper/keeper_shell_shared.mli";
  List.iter
    (fun module_name -> assert_contains "lib/dune" module_name)
    [
      "keeper_shell_op";
      "keeper_shell_timeout";
      "keeper_shell_runtime_paths";
      "keeper_shell_path";
      "keeper_shell_readonly_policy";
    ];
  assert_contains exec_shell_ml "Keeper_shell_op.valid_strings";
  assert_contains exec_shell_ml "Keeper_shell_timeout.gh_min_timeout_sec";
  assert_contains exec_shell_ml "Keeper_shell_runtime_paths.rewrite_turn_runtime_paths_to_host";
  assert_contains exec_shell_ml "Keeper_shell_readonly_policy.readonly_hint_of_category";
  assert_contains shell_ops_ml "Keeper_shell_timeout.read_timeout_sec";
  assert_contains shell_ops_ml "Keeper_shell_runtime_paths.rewrite_turn_runtime_paths_to_host";
  assert_contains bash_ml "Keeper_shell_timeout.clamp_shell_timeout";
  assert_contains exec_tools_ml "Keeper_shell_op.valid_strings";
  assert_not_contains shell_ops_ml "Keeper_shell_shared.";
  assert_not_contains bash_ml "Keeper_shell_shared.";
  assert_not_contains exec_tools_ml "Keeper_shell_shared.";
  assert_not_contains exec_shell_ml "Keeper_shell_shared"

let test_shell_ops_host_ir_uses_keeper_shell_ir_facade () =
  let rel = "lib/keeper/keeper_shell_ops.ml" in
  assert_contains rel "Keeper_shell_ir.simple";
  assert_contains rel "Keeper_shell_ir.dispatch";
  assert_not_contains rel "Shell_gate.gate_typed";
  assert_not_contains rel "Exec_policy.validate_shell_ir_paths";
  assert_not_contains rel "Exec_dispatch.dispatch_decided";
  assert_not_contains rel "Shell_ir_risk.classify";
  assert_not_contains rel "Masc_exec.Shell_ir.Simple";
  assert_not_contains rel "Masc_exec.Shell_ir.Lit";
  assert_not_contains rel "Keeper_shell_shared.run_argv_with_status_retry_eintr"

let test_keeper_bash_dispatch_uses_keeper_shell_ir_facade () =
  let rel = "lib/keeper/keeper_shell_bash.ml" in
  assert_contains rel "Keeper_shell_ir.dispatch_classified";
  assert_contains rel "Keeper_shell_ir.classify";
  assert_not_contains rel "Shell_gate.gate_typed";
  assert_not_contains rel "Exec_policy.validate_shell_ir_paths";
  assert_not_contains rel "Exec_dispatch.dispatch_decided";
  assert_not_contains rel "Keeper_shell_ir.gate_verdict_map"

let test_keeper_gh_shared_ir_construction_uses_keeper_shell_ir_facade () =
  let rel = "lib/keeper/keeper_gh_shared.ml" in
  assert_contains rel "gh_simple_command_to_shell_ir";
  assert_contains rel "Keeper_shell_ir.simple";
  assert_contains rel "Keeper_shell_ir.classify";
  assert_contains rel "Keeper_shell_command_parse.parse_cmd_to_ir_opt";
  assert_not_contains rel "Exec_policy.parse_string_to_ir";
  assert_not_contains rel "let shell_arg text";
  assert_not_contains rel "Masc_exec.Bin.of_known Masc_exec.Bin.Gh";
  assert_not_contains rel "Masc_exec.Shell_ir_risk.classify"

let test_keeper_bash_input_lowering_uses_keeper_shell_ir_facade () =
  let rel = "lib/keeper/keeper_tool_bash_input.ml" in
  assert_contains rel "Keeper_shell_ir.simple_bin";
  assert_contains rel "Keeper_shell_ir.pipeline";
  assert_not_contains rel "Masc_exec.Shell_ir.Lit";
  assert_not_contains rel "Masc_exec.Shell_ir.Simple";
  assert_not_contains rel "Masc_exec.Shell_ir.Pipeline";
  assert_not_contains rel "Masc_exec.Path_scope.classify"

let test_docker_shell_path_validation_uses_keeper_shell_ir_facade () =
  let rel = "lib/keeper/keeper_sandbox_docker.ml" in
  assert_contains rel "Keeper_shell_command_parse.parse_cmd_to_ir_opt";
  assert_contains rel "Keeper_shell_ir.validate_paths";
  assert_not_contains rel "Exec_policy.parse_string_to_ir";
  assert_not_contains rel "Exec_policy.validate_shell_ir_paths"

let test_pr_metrics_use_shell_command_semantics () =
  let rel = "lib/keeper/keeper_hooks_oas_pr_metrics.ml" in
  assert_contains rel "Keeper_shell_command_semantics.effective_stages_of_cmd";
  assert_not_contains rel "Exec_policy.parse_string_to_ir";
  assert_not_contains rel "Exec_policy_mutation_classifier.literal_words_of_simple";
  assert_not_contains rel "Masc_exec.Shell_ir.Simple";
  assert_not_contains rel "Masc_exec.Shell_ir.Pipeline"

let test_approval_queue_uses_shell_command_words () =
  let rel = "lib/keeper/keeper_approval_queue.ml" in
  assert_contains rel "Keeper_shell_command_words.first_token_of_cmd";
  assert_not_contains rel "Exec_policy.parse_string_to_ir";
  assert_not_contains rel "Exec_policy_mutation_classifier.flat_stage_words"

let test_fs_tools_use_sandbox_read_runner () =
  let rel = "lib/keeper/keeper_exec_fs.ml" in
  assert_contains rel "Keeper_sandbox_read_runner.";
  assert_contains rel "Keeper_sandbox_read_runner.backend_via";
  assert_contains rel "Keeper_sandbox_runner.route_label";
  assert_not_contains rel "Keeper_sandbox_read_backend.";
  assert_not_contains rel "\"via\", `String \"docker\""

let test_legacy_docker_read_module_is_removed () =
  assert_source_absent "lib/keeper/keeper_docker_read.ml";
  assert_source_absent "lib/keeper/keeper_docker_read.mli";
  assert_source_absent "test/test_keeper_docker_read.ml";
  source_files_under "lib/keeper"
  |> List.iter (fun rel -> assert_not_contains rel "Keeper_docker_read")

let test_sandbox_runtime_sources_do_not_depend_on_shell_surface_names () =
  let sandbox_runtime_sources =
    source_files_under "lib/keeper"
    |> List.filter (fun rel ->
      let base = Filename.basename rel in
      String.starts_with ~prefix:"keeper_sandbox" base
      || String.starts_with ~prefix:"keeper_docker" base
      || String.equal base "sandbox_error.ml"
      || String.equal base "sandbox_error.mli")
  in
  Alcotest.(check bool)
    "sandbox runtime sources discovered"
    true
    (sandbox_runtime_sources <> []);
  let forbidden =
    [ "Keeper_shell_docker"
    ; "keeper_shell_docker"
    ; "Keeper_shell_bash_docker"
    ; "keeper_shell_bash_docker"
    ; "shell_docker"
    ; "shell_bash"
    ]
  in
  List.iter
    (fun rel -> List.iter (assert_not_contains rel) forbidden)
    sandbox_runtime_sources

let test_backend_host_exec_uses_sandbox_actor () =
  let backend_sources =
    [ "lib/keeper/keeper_sandbox_docker.ml"
    ; "lib/keeper/keeper_sandbox_read_backend.ml"
    ; "lib/keeper/keeper_docker_client_real.ml"
    ]
  in
  List.iter
    (fun rel ->
       assert_not_contains rel "~actor:`Keeper_shell";
       assert_not_contains rel "actor = `Keeper_shell")
    backend_sources;
  assert_contains "lib/keeper/keeper_sandbox_docker.ml" "~actor:`System_task_sandbox"

let test_shell_ops_drops_gh_bridge () =
  let shell_ops = "lib/keeper/keeper_shell_ops.ml" in
  assert_source_absent "lib/keeper/keeper_shell_gh_bridge.ml";
  assert_source_absent "lib/keeper/keeper_shell_gh_bridge.mli";
  assert_not_contains shell_ops "Keeper_shell_gh_bridge";
  assert_not_contains shell_ops "\"gh\"";
  assert_not_contains shell_ops "gh_command_from_args";
  assert_not_contains shell_ops "gh_simple_command_to_shell_ir"

let test_shell_ops_drops_git_clone_bridge () =
  let shell_ops = "lib/keeper/keeper_shell_ops.ml" in
  assert_source_absent "lib/keeper/keeper_shell_git_bridge.ml";
  assert_source_absent "lib/keeper/keeper_shell_git_bridge.mli";
  assert_not_contains shell_ops "Keeper_shell_git_bridge";
  assert_not_contains shell_ops "\"git_clone\"";
  assert_not_contains shell_ops "\"git clone\"";
  assert_not_contains shell_ops "Tool_code_write.validate_clone_url";
  assert_not_contains shell_ops "normalize_existing_origin_to_https"

let test_active_gates_do_not_name_retired_shell_docker () =
  List.iter
    (fun rel ->
       assert_not_contains rel "lib/keeper/keeper_shell_docker.ml";
       assert_not_contains rel "keeper_shell_docker.ml")
    [ "scripts/keeper-cwd-leak-gate.sh"
    ; "scripts/lint/exhaustive-guard.allowlist"
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
            "keeper raw command parse owner is centralized"
            `Quick
            test_keeper_raw_command_parse_owner;
          Alcotest.test_case
            "keeper command word classifier owner is centralized"
            `Quick
            test_keeper_command_word_classifier_owner;
          Alcotest.test_case
            "nested runtime uses shell command words"
            `Quick
            test_nested_runtime_uses_shell_command_words;
          Alcotest.test_case
            "sandbox failure recording is not shell-docker coupled"
            `Quick
            test_sandbox_failure_recording_not_shell_docker_coupled;
          Alcotest.test_case
            "gh tool layer uses gh runner"
            `Quick
            test_gh_tool_layer_uses_gh_runner;
          Alcotest.test_case
            "gh runner owns sandbox routing"
            `Quick
            test_gh_runner_owns_sandbox_routing;
          Alcotest.test_case
            "gh repo slug discovery is outside gh parser shared module"
            `Quick
            test_gh_repo_owns_repo_slug_discovery;
          Alcotest.test_case
            "shell read ops use sandbox read runner"
            `Quick
            test_shell_read_ops_use_sandbox_read_runner;
          Alcotest.test_case
            "shell path helpers have a dedicated owner"
            `Quick
            test_shell_path_owner;
          Alcotest.test_case
            "shell shared compatibility facade is removed"
            `Quick
            test_shell_shared_is_removed;
          Alcotest.test_case
            "shell ops host IR uses keeper shell IR facade"
            `Quick
            test_shell_ops_host_ir_uses_keeper_shell_ir_facade;
          Alcotest.test_case
            "keeper bash dispatch uses keeper shell IR facade"
            `Quick
            test_keeper_bash_dispatch_uses_keeper_shell_ir_facade;
          Alcotest.test_case
            "keeper gh shared IR construction uses keeper shell IR facade"
            `Quick
            test_keeper_gh_shared_ir_construction_uses_keeper_shell_ir_facade;
          Alcotest.test_case
            "keeper bash input lowering uses keeper shell IR facade"
            `Quick
            test_keeper_bash_input_lowering_uses_keeper_shell_ir_facade;
          Alcotest.test_case
            "docker shell path validation uses keeper shell IR facade"
            `Quick
            test_docker_shell_path_validation_uses_keeper_shell_ir_facade;
          Alcotest.test_case
            "pr metrics use shell command semantics"
            `Quick
            test_pr_metrics_use_shell_command_semantics;
          Alcotest.test_case
            "approval queue uses shell command words"
            `Quick
            test_approval_queue_uses_shell_command_words;
          Alcotest.test_case
            "fs tools use sandbox read runner"
            `Quick
            test_fs_tools_use_sandbox_read_runner;
          Alcotest.test_case
            "legacy docker read module is removed"
            `Quick
            test_legacy_docker_read_module_is_removed;
          Alcotest.test_case
            "sandbox runtime sources do not depend on shell surface names"
            `Quick
            test_sandbox_runtime_sources_do_not_depend_on_shell_surface_names;
          Alcotest.test_case
            "backend host exec uses sandbox actor"
            `Quick
            test_backend_host_exec_uses_sandbox_actor;
          Alcotest.test_case
            "shell ops drops gh compatibility bridge"
            `Quick
            test_shell_ops_drops_gh_bridge;
          Alcotest.test_case
            "shell ops drops git compatibility bridge"
            `Quick
            test_shell_ops_drops_git_clone_bridge;
          Alcotest.test_case
            "active gates do not name retired shell docker"
            `Quick
            test_active_gates_do_not_name_retired_shell_docker;
        ] );
    ]
