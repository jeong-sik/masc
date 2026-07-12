open Alcotest
open Yojson.Safe.Util

let get_string_field json key =
  json |> member key |> to_string

let classification_of_cmd cmd =
  match Exec_policy.parse_string_to_ir ~mode:Strict cmd with
  | Ok ir -> Masc.Exec_core.classify_command_of_ir ir
  | Error reason ->
      failwith
        ("command parse failed: "
         ^ Exec_policy.block_reason_to_string reason)

let test_rg_no_match_is_semantic_success () =
  let cmd = "rg missing_pattern lib/" in
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd
      ~classification:(classification_of_cmd cmd)
      ~status:(Unix.WEXITED 1)
      ~output:""
      ()
  in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check string "semantic_status" "no_match"
    (get_string_field json "semantic_status");
  check string "family" "search"
    (json |> member "classification" |> member "family" |> to_string)

let test_find_partial_is_semantic_success () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"find lib -name '*.ml'"
      ~status:(Unix.WEXITED 1)
      ~output:"lib/exec_core.ml\nfind: lib/private: Permission denied"
      ()
  in
  check bool "ok" false (json |> member "ok" |> to_bool);
  check string "semantic_status" "partial"
    (get_string_field json "semantic_status")

let test_find_missing_path_is_runtime_error () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"find /tmp /definitely-missing-path-xyz"
      ~status:(Unix.WEXITED 1)
      ~output:"find: /definitely-missing-path-xyz: No such file or directory"
      ()
  in
  check bool "ok" false (json |> member "ok" |> to_bool);
  check string "semantic_status" "runtime_error"
    (get_string_field json "semantic_status")

let test_missing_task_state_path_points_to_task_tools () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"cat .masc/backlog.json"
      ~status:(Unix.WEXITED 1)
      ~output:"cat: .masc/backlog.json: No such file or directory"
      ()
  in
  check bool "ok" false (json |> member "ok" |> to_bool);
  check string "semantic_status" "runtime_error"
    (get_string_field json "semantic_status");
  check string "task tool hint"
    "This is not a keeper-visible task-state path. Do not read .masc/backlog.json \
     or repo-local backlog files from shell. Use keeper_tasks_list for task/backlog \
     state and keeper_context_status for current_task_id/sandbox paths."
    (get_string_field json "recovery_hint")

let test_blocked_json_adds_classification () =
  let cmd = "git push origin main" in
  let json =
    Masc.Exec_core.blocked_result_json
      ~cmd
      ~error:"write_operation_gated"
      ~reason:"write tool_access required"
      ~classification:(classification_of_cmd cmd)
      ~retryability:Masc.Exec_core.Operator_required
      ()
  in
  check string "error" "write_operation_gated"
    (get_string_field json "error");
  check string "semantic_status" "blocked"
    (get_string_field json "semantic_status");
  check string "family" "git_write"
    (json |> member "classification" |> member "family" |> to_string);
  check string "risk" "high"
    (json |> member "classification" |> member "risk" |> to_string);
  check string "hint"
    "Revise the command or switch to the structured shell tool that matches the intent."
    (get_string_field json "hint");
  check string "recovery_hint"
    "Revise the command or switch to the structured shell tool that matches the intent."
    (get_string_field json "recovery_hint");
  check string "retryability" "operator_required"
    (get_string_field json "retryability")

let test_regex_pipe_inside_quotes_keeps_no_match_semantics () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"rg 'a|b' lib/"
      ~status:(Unix.WEXITED 1)
      ~output:""
      ()
  in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check string "semantic_status" "no_match"
    (get_string_field json "semantic_status")

let test_pipeline_last_command_uses_shared_words () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"printf foo | rg 'a|b'"
      ~status:(Unix.WEXITED 1)
      ~output:""
      ()
  in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check string "semantic_status" "no_match"
    (get_string_field json "semantic_status")

let test_unknown_write_is_not_git_write () =
  let ir =
    match Masc_exec_bash_parser.Bash.parse_string "mkdir tmp/generated" with
    | Masc_exec.Parsed.Parsed ir -> ir
    | _ -> Alcotest.fail "failed to parse mkdir command"
  in
  let classification =
    Masc.Exec_core.classify_command_of_ir ir
  in
  check string "family" "unknown"
    (Masc.Exec_core.classification_to_json classification
     |> member "family" |> to_string);
  check bool "risk_class is write" true
    (classification.risk_class <> Masc_exec.Shell_ir_risk.R0_Read)

let temp_dir () =
  let path = Filename.temp_file "exec_core_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun entry -> remove_tree (Filename.concat path entry));
      Unix.rmdir path
  | _ ->
      Unix.unlink path

let test_large_output_persists_artifact () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
      let output = String.make 17000 'x' in
      let json =
        Masc.Exec_core.process_result_json
          ~artifact_policy:Masc.Exec_core.Persist_if_large
          ~base_path
          ~keeper_name:"exec-core"
          ~cmd:"cat README.md"
          ~status:(Unix.WEXITED 0)
          ~output
          ()
      in
      let refs = json |> member "artifact_refs" |> to_list in
      check int "one artifact ref" 1 (List.length refs);
      let artifact_path = List.hd refs |> member "path" |> to_string in
      check bool "artifact exists" true (Sys.file_exists artifact_path);
      check int "artifact bytes" (String.length output)
        ((List.hd refs |> member "bytes" |> to_int));
      check string "persisted contents" output
        (Fs_compat.load_file artifact_path))

let test_inline_only_keeps_artifact_refs_empty () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
      let output = String.make 17000 'x' in
      let json =
        Masc.Exec_core.process_result_json
          ~artifact_policy:Masc.Exec_core.Inline_only
          ~base_path
          ~keeper_name:"exec-core"
          ~cmd:"cat README.md"
          ~status:(Unix.WEXITED 0)
          ~output
          ()
      in
      let refs = json |> member "artifact_refs" |> to_list in
      check int "no artifact ref" 0 (List.length refs))

(* ---------- P1 Tick 3: Exec_semantic JSON integration ------------------ *)

let with_semantic_flag enabled f =
  (* Post-flip: empty string means "default", which is now ON.
     Use explicit "0" for the off case so the test intention is
     preserved regardless of the default. *)
  let prev = Sys.getenv_opt "MASC_BASH_SEMANTIC_EXIT" in
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" (if enabled then "1" else "0");
  let restore () =
    match prev with
    | Some v -> Unix.putenv "MASC_BASH_SEMANTIC_EXIT" v
    | None -> Unix.putenv "MASC_BASH_SEMANTIC_EXIT" ""
  in
  match f () with
  | v -> restore (); v
  | exception e -> restore (); raise e

let run_json ~cmd ~status ~output =
  Masc.Exec_core.process_result_json
    ~base_path:"/tmp"
    ~keeper_name:"exec-core-semantic"
    ~cmd
    ~status
    ~output
    ()

let test_semantic_hidden_on_explicit_off () =
  (* Post-flip: the only way the semantic field vanishes is an
     explicit operator opt-out.  Covers the "byte-identical
     pre-P1 shape" path for rare callers that need it. *)
  with_semantic_flag false (fun () ->
    let json = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    match json |> member "semantic_exit" with
    | `Null -> ()
    | _ -> fail "semantic_exit must be absent when flag is off")

let test_semantic_ok_when_flag_on () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    let sem = json |> member "semantic_exit" in
    check string "kind=ok" "ok" (sem |> member "kind" |> to_string))

let test_semantic_fail_carries_exit_code () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"ls /no/such/path"
                 ~status:(Unix.WEXITED 2) ~output:"ls: …" in
    let sem = json |> member "semantic_exit" in
    check string "kind=fail" "fail" (sem |> member "kind" |> to_string);
    check int "exit_code=2" 2 (sem |> member "exit_code" |> to_int);
    check bool "rci present" true
      (match json |> member "return_code_interpretation" with
       | `String _ -> true | _ -> false))

let test_semantic_git_not_a_repo () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"git status" ~status:(Unix.WEXITED 128)
                 ~output:"fatal: not a git repository" in
    let sem = json |> member "semantic_exit" in
    check string "kind=git_not_a_repo" "git_not_a_repo"
      (sem |> member "kind" |> to_string))

let test_semantic_tool_missing_payload () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"notarealtool --help"
                 ~status:(Unix.WEXITED 127)
                 ~output:"bash: notarealtool: command not found" in
    let sem = json |> member "semantic_exit" in
    check string "kind=tool_missing" "tool_missing"
      (sem |> member "kind" |> to_string);
    check string "tool=notarealtool" "notarealtool"
      (sem |> member "tool" |> to_string))

let test_semantic_flag_isolation () =
  (* Flipping off after on must hide the field again. *)
  with_semantic_flag true (fun () ->
    let _ = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    ());
  with_semantic_flag false (fun () ->
    let json = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    match json |> member "semantic_exit" with
    | `Null -> ()
    | _ -> fail "semantic_exit must stay absent after flag flips off")

(* ---------- P3 Tick 9: output_cap env-gated head+tail truncation --------- *)

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key (Option.value ~default:"" value);
  let restore () =
    match prev with
    | Some v -> Unix.putenv key v
    | None -> Unix.putenv key ""
  in
  match f () with
  | v -> restore (); v
  | exception e -> restore (); raise e

let test_output_cap_absent_by_default () =
  with_env "MASC_BASH_OUTPUT_CAP" None (fun () ->
    let json =
      run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"hello"
    in
    check string "output untouched" "hello" (json |> member "output" |> to_string);
    match json |> member "output_cap" with
    | `Null -> ()
    | _ -> fail "output_cap must be absent when flag is off")

let test_output_cap_on_preserves_small_output () =
  with_env "MASC_BASH_OUTPUT_CAP" (Some "1") (fun () ->
    let json =
      run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"short"
    in
    check string "short output unchanged" "short"
      (json |> member "output" |> to_string);
    let cap = json |> member "output_cap" in
    check int "total_bytes=5" 5 (cap |> member "total_bytes" |> to_int);
    check int "bytes_dropped=0" 0 (cap |> member "bytes_dropped" |> to_int))

let test_output_cap_truncates_large_output () =
  with_env "MASC_BASH_OUTPUT_CAP" (Some "1") (fun () ->
    with_env "MASC_BASH_CAP_HEAD" (Some "8") (fun () ->
      with_env "MASC_BASH_CAP_TAIL" (Some "8") (fun () ->
        let long = "HEADAAAA" ^ String.make 256 'X' ^ "TAILBBBB" in
        let json =
          run_json ~cmd:"cat big" ~status:(Unix.WEXITED 0) ~output:long
        in
        let out = json |> member "output" |> to_string in
        (* separator format from Exec_buffer.render *)
        if not (String.length out > 0 && String.length out < String.length long)
        then fail "output should be shorter than input when capped";
        let cap = json |> member "output_cap" in
        check int "total_bytes" (String.length long)
          (cap |> member "total_bytes" |> to_int);
        let dropped = cap |> member "bytes_dropped" |> to_int in
        if dropped <= 0 then fail "bytes_dropped must be positive";
        check int "head_cap=8" 8 (cap |> member "head_cap" |> to_int);
        check int "tail_cap=8" 8 (cap |> member "tail_cap" |> to_int))))

(* ---------- P8: Teaching Error Messages - diagnosis field -------------- *)

let test_blocked_without_diagnosis_has_no_field () =
  let json =
    Masc.Exec_core.blocked_result_json
      ~cmd:"some command"
      ~error:"generic_blocked"
      ~reason:"blocked for testing"
      ()
  in
  match json |> member "diagnosis" with
  | `Null -> ()
  | _ -> fail "diagnosis must be absent when no ~diag passed"

let test_blocked_with_diagnosis_has_all_fields () =
  let diag =
    { Masc.Exec_core.rule_id = "test_rule"
    ; explanation = "explaining why"
    ; rewrite = Some "use this instead"
    ; tool_suggestion = None
    }
  in
  let json =
    Masc.Exec_core.blocked_result_json
      ~cmd:"bad cmd"
      ~error:"test_blocked"
      ~reason:"testing"
      ~diag:(Some diag)
      ()
  in
  let d = json |> member "diagnosis" in
  check string "rule_id" "test_rule" (d |> member "rule_id" |> to_string);
  check string "explanation" "explaining why"
    (d |> member "explanation" |> to_string);
  check string "rewrite" "use this instead"
    (d |> member "rewrite" |> to_string);
  check bool "tool_suggestion absent" true
    (match d |> member "tool_suggestion" with
     | `Null -> true | _ -> false)

let test_blocked_with_tool_suggestion () =
  let diag =
    { Masc.Exec_core.rule_id = "redirect_blocked"
    ; explanation = "redirects are forbidden"
    ; rewrite = None
    ; tool_suggestion = Some "tool_edit_file"
    }
  in
  let json =
    Masc.Exec_core.blocked_result_json
      ~cmd:"echo hi > file.txt"
      ~error:"readonly_blocked"
      ~reason:"redirect"
      ~diag:(Some diag)
      ()
  in
  let d = json |> member "diagnosis" in
  check string "tool_suggestion" "tool_edit_file"
    (d |> member "tool_suggestion" |> to_string);
  check bool "rewrite absent" true
    (match d |> member "rewrite" with
     | `Null -> true | _ -> false)

let test_blocked_diagnosis_both_rewrite_and_tool () =
  let diag =
    { Masc.Exec_core.rule_id = "chaining_blocked"
    ; explanation = "chaining not allowed"
    ; rewrite = Some "split into two calls"
    ; tool_suggestion = Some "tool_search_files"
    }
  in
  let json =
    Masc.Exec_core.blocked_result_json
      ~cmd:"a && b"
      ~error:"command_blocked_readonly"
      ~reason:"chaining"
      ~diag:(Some diag)
      ()
  in
  let d = json |> member "diagnosis" in
  check string "rewrite" "split into two calls"
    (d |> member "rewrite" |> to_string);
  check string "tool_suggestion" "tool_search_files"
    (d |> member "tool_suggestion" |> to_string)

(* --- P10: structured output tests --- *)

let test_git_status_structured () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git status --porcelain"
      ~status:(Unix.WEXITED 0)
      ~output:" M lib/foo.ml\n?? new_file.txt\n"
      ()
  in
  let so = json |> member "structured_output" in
  let staged = so |> member "staged" |> to_list in
  let unstaged = so |> member "unstaged" |> to_list in
  let untracked = so |> member "untracked" |> to_list in
  check int "staged empty" 0 (List.length staged);
  check int "unstaged 1" 1 (List.length unstaged);
  check int "untracked 1" 1 (List.length untracked)

let test_git_status_with_global_option_structured () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git -C /tmp/repo status --porcelain"
      ~status:(Unix.WEXITED 0)
      ~output:" M lib/foo.ml\n"
      ()
  in
  let so = json |> member "structured_output" in
  let unstaged = so |> member "unstaged" |> to_list in
  check int "unstaged via git -C" 1 (List.length unstaged)

let test_git_log_structured () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git log --oneline -5"
      ~status:(Unix.WEXITED 0)
      ~output:"abc1234 fix bug\ndef5678 add feature\n"
      ()
  in
  let so = json |> member "structured_output" in
  let commits = so |> member "commits" |> to_list in
  check int "commits count" 2 (List.length commits)

let test_failed_git_status_has_no_structured_output () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git status --porcelain"
      ~status:(Unix.WEXITED 128)
      ~output:"fatal: not a git repository (or any of the parent directories): .git\n"
      ()
  in
  check bool "no structured_output on failed git status" true
    (match json |> member "structured_output" with
     | `Null -> true
     | _ -> false)

let test_failed_git_log_has_no_structured_output () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git log --oneline -5"
      ~status:(Unix.WEXITED 128)
      ~output:"fatal: not a git repository (or any of the parent directories): .git\n"
      ()
  in
  check bool "no structured_output on failed git log" true
    (match json |> member "structured_output" with
     | `Null -> true
     | _ -> false)

let test_pipeline_git_status_has_no_structured_output () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git status --porcelain | cat"
      ~status:(Unix.WEXITED 0)
      ~output:" M lib/foo.ml\n"
      ()
  in
  check bool "no structured_output for git status pipeline" true
    (match json |> member "structured_output" with
     | `Null -> true
     | _ -> false)

let test_wc_structured () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"wc -l lib/foo.ml"
      ~status:(Unix.WEXITED 0)
      ~output:"     120 lib/foo.ml"
      ()
  in
  let so = json |> member "structured_output" in
  check int "lines" 120 (so |> member "lines" |> to_int)

let test_git_diff_stat_structured () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git diff --stat"
      ~status:(Unix.WEXITED 0)
      ~output:" lib/foo.ml | 3 ++-\n 1 file changed, 2 insertions(+), 1 deletion(-)\n"
      ()
  in
  let so = json |> member "structured_output" in
  check int "files_changed" 1 (so |> member "files_changed" |> to_int);
  check int "insertions" 2 (so |> member "insertions" |> to_int);
  check int "deletions" 1 (so |> member "deletions" |> to_int)

let test_git_diff_stat_structured_plural () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"git diff --stat"
      ~status:(Unix.WEXITED 0)
      ~output:
        " lib/foo.ml | 3 ++-\n lib/bar.ml | 2 +-\n\
         2 files changed, 3 insertions(+), 2 deletions(-)\n"
      ()
  in
  let so = json |> member "structured_output" in
  check int "files_changed" 2 (so |> member "files_changed" |> to_int);
  check int "insertions" 3 (so |> member "insertions" |> to_int);
  check int "deletions" 2 (so |> member "deletions" |> to_int)

let test_unknown_cmd_no_structured () =
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"echo hello world"
      ~status:(Unix.WEXITED 0)
      ~output:"hello world"
      ()
  in
  check bool "no structured_output for unknown" true
    (match json |> member "structured_output" with
     | `Null -> true
     | _ -> false)

let test_dune_test_structured () =
  let output =
    "Test src/foo.ml: OK\nTest test/bar.ml: FAILED\nTest test/baz.ml: OK\n"
  in
  let json =
    Masc.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"p10-test"
      ~cmd:"dune runtest"
      ~status:(Unix.WEXITED 1)
      ~output
      ()
  in
  let so = json |> member "structured_output" in
  check int "passed" 2 (so |> member "passed" |> to_int);
  check int "failed" 1 (so |> member "failed" |> to_int)

(* --- P11: command history tests --- *)

let with_p11_base_path f =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () -> f base_path)

let test_history_append_and_read () =
  with_p11_base_path @@ fun base_path ->
  let module H = Masc_exec.Bash_history in
  Result.get_ok
    (H.append ~base_path ~keeper_name:"test-keeper"
       { ts = 1000.0; cmd_hash = "abc123"; cmd_prefix = "git status";
         semantic_kind = "Read"; duration_ms = 50; success = true });
  Result.get_ok
    (H.append ~base_path ~keeper_name:"test-keeper"
       { ts = 2000.0; cmd_hash = "def456"; cmd_prefix = "dune build";
         semantic_kind = "Build"; duration_ms = 5000; success = false });
  let results =
    H.suggest ~base_path ~keeper_name:"test-keeper" ~pattern:"git" ~limit:10
  in
  check int "found 1 git entry" 1 (List.length results);
  let e = List.hd results in
  check string "cmd_prefix" "git status" e.cmd_prefix;
  check bool "success" true e.success

let test_history_suggest_empty () =
  with_p11_base_path @@ fun base_path ->
  let module H = Masc_exec.Bash_history in
  let results =
    H.suggest ~base_path ~keeper_name:"no-keeper" ~pattern:"x" ~limit:5
  in
  check int "empty for nonexistent" 0 (List.length results)

let test_history_cmd_hash () =
  let module H = Masc_exec.Bash_history in
  let h = H.cmd_hash "git status" in
  check int "hash length 12" 12 (String.length h)

let test_history_compaction () =
  with_p11_base_path @@ fun base_path ->
  let module H = Masc_exec.Bash_history in
  for i = 1 to 15 do
    Result.get_ok
      (H.append ~base_path ~keeper_name:"compact-test"
         { ts = float_of_int i; cmd_hash = string_of_int i;
           cmd_prefix = "cmd" ^ string_of_int i;
           semantic_kind = "Unknown"; duration_ms = 10; success = true })
  done;
  (* 15 entries is below max_entries (10000), so compact is a no-op *)
  H.compact ~base_path ~keeper_name:"compact-test";
  let results =
    H.suggest ~base_path ~keeper_name:"compact-test" ~pattern:"cmd" ~limit:100
  in
  check int "all 15 preserved" 15 (List.length results)

let test_history_compaction_triggers () =
  with_p11_base_path @@ fun base_path ->
  let module H = Masc_exec.Bash_history in
  (* Exceed max_entries (10_000) so [compact] actually rewrites the file via
     the fd-protected write path (not the no-op branch above). *)
  for i = 1 to 10_001 do
    Result.get_ok
      (H.append ~base_path ~keeper_name:"compact-trigger"
         { ts = float_of_int i; cmd_hash = string_of_int i; cmd_prefix = "cmd";
           semantic_kind = "Unknown"; duration_ms = 10; success = true })
  done;
  H.compact ~base_path ~keeper_name:"compact-trigger";
  let results =
    H.suggest ~base_path ~keeper_name:"compact-trigger" ~pattern:"cmd"
      ~limit:20_000
  in
  (* compact keeps the last compact_to (1_000) entries; the rewrite went
     through the Eio_guard.protect wrapper and produced a valid file. *)
  check int "compacted to compact_to" 1_000 (List.length results)

(* failure_class wire declaration (sangsu incident, 2026-07-12): every failed
   Execute payload must declare its Tool_result class so the OAS failure
   boundary stops collapsing timeouts, policy blocks, and runtime errors into
   one Runtime_failure/Unknown signature. *)

let process_json ?classification ~cmd ~status ~output () =
  Masc.Exec_core.process_result_json
    ?classification
    ~base_path:"/tmp"
    ~keeper_name:"exec-core"
    ~cmd
    ~status
    ~output
    ()

let boundary_of_json json =
  Masc.Keeper_tools_oas_failure_boundary.classify_raw_failure
    (Yojson.Safe.to_string json)

let test_timeout_declares_transient_failure_class () =
  let json = process_json ~cmd:"sleep 999" ~status:(Unix.WEXITED 124) ~output:"" () in
  check bool "ok" false (json |> member "ok" |> to_bool);
  check string "semantic_status" "timeout" (get_string_field json "semantic_status");
  check string "failure_class" "transient_error" (get_string_field json "failure_class");
  let boundary = boundary_of_json json in
  check bool "declared" true
    boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class_declared;
  check bool "boundary transient" true
    (boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class
     = Tool_result.Transient_error)

let test_runtime_error_declares_runtime_failure_class () =
  (* Incident shape: `ls ls lib` exits non-zero immediately. *)
  let json =
    process_json
      ~cmd:"ls ls lib"
      ~status:(Unix.WEXITED 2)
      ~output:"ls: cannot access 'ls': No such file or directory"
      ()
  in
  check string "semantic_status" "runtime_error"
    (get_string_field json "semantic_status");
  check string "failure_class" "runtime_failure" (get_string_field json "failure_class");
  let boundary = boundary_of_json json in
  check bool "declared" true
    boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class_declared;
  check bool "boundary runtime_failure" true
    (boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class
     = Tool_result.Runtime_failure)

let test_blocked_declares_policy_rejection_failure_class () =
  let json =
    Masc.Exec_core.blocked_result_json
      ~cmd:"rm -rf /"
      ~error:"destructive_operation_blocked"
      ~reason:"blocked by policy"
      ()
  in
  check bool "ok" false (json |> member "ok" |> to_bool);
  check string "failure_class" "policy_rejection"
    (get_string_field json "failure_class");
  let boundary = boundary_of_json json in
  check bool "declared" true
    boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class_declared;
  check bool "boundary policy_rejection" true
    (boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class
     = Tool_result.Policy_rejection)

let test_success_carries_no_failure_class () =
  let json = process_json ~cmd:"ls lib" ~status:(Unix.WEXITED 0) ~output:"a.ml" () in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check bool "failure_class absent" true (json |> member "failure_class" = `Null)

let test_semantic_no_match_carries_no_failure_class () =
  let cmd = "rg missing_pattern lib/" in
  let json =
    process_json
      ~classification:(classification_of_cmd cmd)
      ~cmd
      ~status:(Unix.WEXITED 1)
      ~output:""
      ()
  in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check bool "failure_class absent" true (json |> member "failure_class" = `Null)

let test_undeclared_payload_resolves_to_runtime_failure_undeclared () =
  let boundary =
    Masc.Keeper_tools_oas_failure_boundary.classify_raw_failure {|{"error":"boom"}|}
  in
  check bool "resolved runtime_failure" true
    (boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class
     = Tool_result.Runtime_failure);
  check bool "undeclared" false
    boundary.Masc.Keeper_tools_oas_failure_boundary.failure_class_declared

let () =
  run "exec_core"
    [
      ( "semantic_status",
        [
          test_case "rg no match is semantic success" `Quick
            test_rg_no_match_is_semantic_success;
          test_case "find partial is recoverable but not success" `Quick
            test_find_partial_is_semantic_success;
          test_case "find missing path is runtime error" `Quick
            test_find_missing_path_is_runtime_error;
          test_case "missing task-state path points to task tools" `Quick
            test_missing_task_state_path_points_to_task_tools;
          test_case "quoted regex pipe keeps no-match semantics" `Quick
            test_regex_pipe_inside_quotes_keeps_no_match_semantics;
          test_case "pipeline last command uses shared words" `Quick
            test_pipeline_last_command_uses_shared_words;
          test_case "blocked json adds classification" `Quick
            test_blocked_json_adds_classification;
          test_case "unknown write is not git_write" `Quick
            test_unknown_write_is_not_git_write;
          test_case "large output persists artifact" `Quick
            test_large_output_persists_artifact;
          test_case "inline only keeps artifact refs empty" `Quick
            test_inline_only_keeps_artifact_refs_empty;
        ] );
      ( "semantic_exit",
        [
          test_case "explicit opt-out hides field" `Quick
            test_semantic_hidden_on_explicit_off;
          test_case "ok kind on exit 0" `Quick test_semantic_ok_when_flag_on;
          test_case "fail kind carries exit_code" `Quick
            test_semantic_fail_carries_exit_code;
          test_case "git exit 128 maps to git_not_a_repo" `Quick
            test_semantic_git_not_a_repo;
          test_case "exit 127 maps to tool_missing with tool payload"
            `Quick test_semantic_tool_missing_payload;
          test_case "flag flip isolates state" `Quick
            test_semantic_flag_isolation;
        ] );
      ( "output_cap",
        [
          test_case "absent by default" `Quick
            test_output_cap_absent_by_default;
          test_case "small output unchanged, cap metadata emitted"
            `Quick test_output_cap_on_preserves_small_output;
          test_case "large output truncated with bytes_dropped > 0"
            `Quick test_output_cap_truncates_large_output;
        ] );
      ( "p8_diagnosis",
        [
          test_case "no diag => diagnosis absent" `Quick
            test_blocked_without_diagnosis_has_no_field;
          test_case "diag with rewrite => all fields present" `Quick
            test_blocked_with_diagnosis_has_all_fields;
          test_case "diag with tool_suggestion" `Quick
            test_blocked_with_tool_suggestion;
          test_case "diag with both rewrite and tool" `Quick
            test_blocked_diagnosis_both_rewrite_and_tool;
        ] );
      ( "p10_structured_output",
        [
          test_case "git status --porcelain produces structured fields"
            `Quick test_git_status_structured;
          test_case "git status with global option produces structured fields"
            `Quick test_git_status_with_global_option_structured;
          test_case "git log --oneline produces commits array" `Quick
            test_git_log_structured;
          test_case "failed git status has no structured_output" `Quick
            test_failed_git_status_has_no_structured_output;
          test_case "failed git log has no structured_output" `Quick
            test_failed_git_log_has_no_structured_output;
          test_case "git status pipeline has no structured_output" `Quick
            test_pipeline_git_status_has_no_structured_output;
          test_case "wc -l produces lines count" `Quick
            test_wc_structured;
          test_case "git diff --stat produces summary counts" `Quick
            test_git_diff_stat_structured;
          test_case "git diff --stat plural summary counts" `Quick
            test_git_diff_stat_structured_plural;
          test_case "unknown cmd has no structured_output" `Quick
            test_unknown_cmd_no_structured;
          test_case "dune runtest produces passed/failed counts" `Quick
            test_dune_test_structured;
        ] );
      ( "p11_command_history",
        [
          test_case "append and read history entries" `Quick
            test_history_append_and_read;
          test_case "suggest returns empty for nonexistent" `Quick
            test_history_suggest_empty;
          test_case "cmd_hash produces 12-char hex" `Quick
            test_history_cmd_hash;
          test_case "compaction preserves entries below threshold"
            `Quick test_history_compaction;
          test_case "compaction above threshold rewrites to compact_to"
            `Slow test_history_compaction_triggers;
        ] );
      ( "failure_class",
        [
          test_case "timeout declares transient_error" `Quick
            test_timeout_declares_transient_failure_class;
          test_case "runtime error declares runtime_failure" `Quick
            test_runtime_error_declares_runtime_failure_class;
          test_case "blocked declares policy_rejection" `Quick
            test_blocked_declares_policy_rejection_failure_class;
          test_case "success carries no failure_class" `Quick
            test_success_carries_no_failure_class;
          test_case "semantic no-match carries no failure_class" `Quick
            test_semantic_no_match_carries_no_failure_class;
          test_case "undeclared payload resolves to runtime_failure, undeclared"
            `Quick test_undeclared_payload_resolves_to_runtime_failure_undeclared;
        ] );
    ]
