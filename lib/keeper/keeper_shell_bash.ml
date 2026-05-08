open Keeper_types
open Keeper_exec_shared

let elapsed_duration_ms ~start_time ~end_time =
  let elapsed_ms = (end_time -. start_time) *. 1000. in
  match classify_float elapsed_ms with
  | FP_nan | FP_infinite -> 0
  | _ when elapsed_ms <= 0. -> 0
  | _ when elapsed_ms < 1. -> 1
  | _ -> int_of_float elapsed_ms

module For_testing = struct
  let elapsed_duration_ms = elapsed_duration_ms
end

type shell_quote_state = No_quote | Single_quote | Double_quote

type shell_word = {
  text : string;
  starts_command : bool;
}

let shell_words_with_boundaries cmd =
  let len = String.length cmd in
  let buf = Buffer.create len in
  let quote_state = ref No_quote in
  let escaped = ref false in
  let at_command_start = ref true in
  let word_started_at_command_start = ref true in
  let push_word acc =
    if Buffer.length buf = 0 then acc
    else
      let text =
        Buffer.contents buf
        |> String.trim
        |> String.lowercase_ascii
      in
      Buffer.clear buf;
      at_command_start := false;
      { text; starts_command = !word_started_at_command_start } :: acc
  in
  let start_word_if_needed () =
    if Buffer.length buf = 0 then
      word_started_at_command_start := !at_command_start
  in
  let rec loop i acc =
    if i >= len then List.rev (push_word acc)
    else if !escaped then (
      start_word_if_needed ();
      Buffer.add_char buf cmd.[i];
      escaped := false;
      loop (i + 1) acc)
    else
      match !quote_state, cmd.[i] with
      | Single_quote, '\'' ->
        quote_state := No_quote;
        loop (i + 1) acc
      | Single_quote, ch ->
        start_word_if_needed ();
        Buffer.add_char buf ch;
        loop (i + 1) acc
      | Double_quote, '"' ->
        quote_state := No_quote;
        loop (i + 1) acc
      | Double_quote, '\\' ->
        escaped := true;
        loop (i + 1) acc
      | Double_quote, ch ->
        start_word_if_needed ();
        Buffer.add_char buf ch;
        loop (i + 1) acc
      | No_quote, '\\' ->
        escaped := true;
        loop (i + 1) acc
      | No_quote, '\'' ->
        start_word_if_needed ();
        quote_state := Single_quote;
        loop (i + 1) acc
      | No_quote, '"' ->
        start_word_if_needed ();
        quote_state := Double_quote;
        loop (i + 1) acc
      | No_quote, (' ' | '\t') ->
        loop (i + 1) (push_word acc)
      | No_quote, ('\n' | '\r' | ';' | '&' | '|') ->
        let acc = push_word acc in
        at_command_start := true;
        loop (i + 1) acc
      | No_quote, ch ->
        start_word_if_needed ();
        Buffer.add_char buf ch;
        loop (i + 1) acc
  in
  loop 0 []

let shell_interpreter_names = [ "bash"; "sh"; "zsh" ]

let command_name text = Filename.basename text

let shell_c_payload words =
  match words with
  | shell :: rest when
    shell.starts_command
    && List.mem (command_name shell.text) shell_interpreter_names ->
    let rec loop = function
      | [] -> None
      | flag :: payload :: _ when
        String.length flag.text > 1
        && flag.text.[0] = '-'
        && String.contains flag.text 'c' ->
        Some payload.text
      | flag :: rest when String.length flag.text > 0 && flag.text.[0] = '-' ->
        loop rest
      | _ -> None
    in
    loop rest
  | _ -> None

let is_env_assignment text =
  match String.index_opt text '=' with
  | Some i when i > 0 ->
    let lhs = String.sub text 0 i in
    not (String.contains lhs '/')
  | _ -> false

let rec strip_command_wrappers = function
  | [] -> []
  | word :: rest when is_env_assignment word.text ->
    strip_command_wrappers rest
  | word :: rest when
    let name = command_name word.text in
    String.equal name "command" || String.equal name "exec" ->
    strip_command_wrappers rest
  | word :: rest when String.equal (command_name word.text) "env" ->
    strip_env_args rest
  | words -> words

and strip_env_args = function
  | word :: rest when String.starts_with ~prefix:"-" word.text ->
    strip_env_args rest
  | word :: rest when is_env_assignment word.text ->
    strip_env_args rest
  | words -> strip_command_wrappers words

let gh_pr_create_sequence = function
  | gh :: pr :: create :: _ ->
    String.equal (command_name gh.text) "gh"
    && String.equal pr.text "pr"
    && String.equal create.text "create"
  | _ -> false

let rec cmd_contains_gh_pr_create cmd =
  let words = shell_words_with_boundaries cmd in
  let rec loop = function
    | word :: rest when
      word.starts_command
      && gh_pr_create_sequence (strip_command_wrappers (word :: rest)) ->
      true
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop words
  ||
  match shell_c_payload words with
  | Some payload -> cmd_contains_gh_pr_create payload
  | None -> false

let handle_keeper_bash
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(turn_sandbox_factory_git : Keeper_sandbox_factory.t option)
      ~(exec_cache : Masc_exec.Exec_cache.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ()
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let root = Keeper_alerting_path.project_root_of_config config in
  let cmd_for_log =
    cmd
    |> Worker_dev_tools.sanitize_command_for_log
    |> Worker_dev_tools.truncate_for_log
  in
  let timeout_sec = Keeper_shell_shared.clamp_shell_timeout ~default:Keeper_shell_shared.io_timeout_sec args in
  let run_in_background =
    Safe_ops.json_bool ~default:false "run_in_background" args
  in
  (* Keep read-only shell broadly visible; mutating shell is limited to
     privileged tool presets. *)
  let write_enabled =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some preset -> Keeper_tool_policy.allows_shell_write_for_preset preset
    | None -> false
  in
  let gh_pr_create_block () =
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_shell_bash_failures
      ~labels:[("keeper", meta.name); ("site", "gh_pr_create")]
      ();
    Log.Keeper.warn
      "keeper_bash gh pr create blocked: keeper=%s cmd=%s"
      meta.name cmd_for_log;
    Yojson.Safe.to_string
      (`Assoc
         [ "ok", `Bool false
         ; "error", `String "gh_pr_create_requires_keeper_pr_create"
         ; "reason", `String
             "keeper_bash cannot bypass the PR creation approval and audit policy"
         ; "hint", `String
             "Use keeper_pr_create with draft=true so governance approval and PR lifecycle markers are enforced."
         ; "cmd", `String cmd_for_log
         ])
  in
  if cmd = ""
  then error_json "cmd is required. Good: cmd='ls -la lib/'. Bad: cmd=''."
  else if Env_config_keeper.KeeperSandbox.hard_mode ()
          && meta.sandbox_profile <> Docker
  then
    error_json
      "MASC_KEEPER_SANDBOX_HARD_MODE requires sandbox_profile=docker"
  else if cmd_contains_gh_pr_create cmd
  then gh_pr_create_block ()

  else begin
    (* Tick 22: dark-launch shadow logger.  Runs
       [Worker_dev_tools.diff_command] side-by-side with the
       live gate and emits a structured line for every non-[Agree]
       outcome so operators can collect flip-blocker evidence
       (Legacy_deny_shadow_allow) and inverted-gap cases
       (Legacy_allow_shadow_deny) from real traffic without
       changing any behavior.  Flag-gated by
       [MASC_BASH_AST_SHADOW_LOG]; default off. *)
    (if Worker_dev_tools.shadow_diff_log_enabled () then begin
       let diff, legacy, shadow = Worker_dev_tools.diff_command cmd in
       Legendary_counters.incr_gate_diff diff;
       (* Histogram refinement of the Shadow_cannot_parse bucket —
          per-reason counters let operators prioritise A1-PR-N
          grammar expansion by construct frequency.  Only increments
          when diff=Shadow_cannot_parse; other diff variants do not
          map to a parse-reason tag.  The parse_tag inside
          Shadow_parse_unsupported carries the bare reason
          (e.g. "too_complex:redirect") emitted by
          Worker_dev_tools.shadow_parse_outcome. *)
       (match diff, shadow with
        | Worker_dev_tools.Shadow_cannot_parse,
          Worker_dev_tools.Shadow_parse_unsupported { parse_tag } ->
          Legendary_counters.incr_too_complex_by_tag parse_tag
        | Worker_dev_tools.Shadow_cannot_parse, _ ->
          (* Defensive: diff_of_verdicts only returns
             Shadow_cannot_parse when shadow is
             Shadow_parse_unsupported.  If that invariant changes,
             the "other" bucket preserves the count. *)
          Legendary_counters.incr_too_complex_by_tag "other"
        | _ -> ());
       (match diff with
        | Worker_dev_tools.Agree -> ()
        | _ ->
          Log.Keeper.info
            "gate_diff_shadow keeper=%s cmd_hash=%s diff=%s legacy=%s shadow=%s"
            meta.name
            (Worker_dev_tools.cmd_hash_for_log cmd)
            (Worker_dev_tools.gate_diff_to_string diff)
            (Worker_dev_tools.legacy_verdict_to_tag legacy)
            (Worker_dev_tools.shadow_verdict_to_tag shadow))
     end);
    (* Resolve cwd early — needed for playground detection before validation. *)
    match Keeper_shell_shared.resolve_keeper_shell_write_cwd ~config ~meta ~args with
    | Error e -> error_json e
    | Ok cwd ->
    let env_snap =
      try Some (Exec_core.snapshot_env ~cwd)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | _ -> None
    in
    let cached_result_json
          (entry : Masc_exec.Exec_cache.cache_entry) =
      let st = Unix.WEXITED entry.exit_code in
      Yojson.Safe.to_string
        (Exec_core.process_result_json
           ~base_path:root
           ~keeper_name:meta.name
           ~cmd
           ~extra:[
             "cwd", `String cwd;
             "execution_time_ms", `Int entry.duration_ms;
             "cached", `Bool true;
             "cache_age_ms",
               `Int
                 (int_of_float
                    ((Unix.time () -. entry.cached_at) *. 1000.));
           ]
           ~status:st
           ~output:entry.output
           ~env_snapshot:env_snap
           ())
    in
    let cached_raw_result_json
          (entry : Masc_exec.Exec_cache.cache_entry) =
      match
        Safe_ops.parse_json_safe
          ~context:"Keeper_shell_bash.cached_raw_result_json"
          entry.output
      with
      | Ok (`Assoc fields) ->
        let fields =
          fields
          |> List.remove_assoc "cached"
          |> List.remove_assoc "cache_age_ms"
          |> List.remove_assoc "execution_time_ms"
        in
        Yojson.Safe.to_string
          (`Assoc
            (fields @ [
               "cached", `Bool true;
               "cache_age_ms",
                 `Int
                   (int_of_float
                      ((Unix.time () -. entry.cached_at) *. 1000.));
               "execution_time_ms", `Int entry.duration_ms;
             ]))
      | Ok _ | Error _ -> cached_result_json entry
    in
    let with_raw_json_exec_cache run =
      let cacheable =
        Masc_exec.Risk_classifier.(is_cacheable (classify cmd))
      in
      if not cacheable then run ()
      else
        match exec_cache with
        | None -> run ()
        | Some cache ->
          (match Masc_exec.Exec_cache.lookup cache cmd with
           | Some entry -> cached_raw_result_json entry
           | None ->
             let t0 = Unix.gettimeofday () in
             let raw = run () in
             let elapsed_ms =
               elapsed_duration_ms
                 ~start_time:t0 ~end_time:(Unix.gettimeofday ())
             in
             (match
                Safe_ops.parse_json_safe
                  ~context:"Keeper_shell_bash.with_raw_json_exec_cache"
                  raw
              with
              | Ok json when Safe_ops.json_bool ~default:false "ok" json ->
                Masc_exec.Exec_cache.store cache
                  ~cmd ~exit_code:0 ~output:raw ~duration_ms:elapsed_ms
              | Ok _ | Error _ -> ());
             raw)
    in
    let normalize_path_for_containment path =
      Keeper_alerting_path.normalize_path_for_check path
      |> Keeper_alerting_path.strip_trailing_slashes
    in
    let cwd_canonical =
      normalize_path_for_containment cwd
    in
    let playground_rel =
      Keeper_sandbox.allowed_root_rel_of_meta ~meta
    in
    let playground_abs =
      normalize_path_for_containment (Filename.concat root playground_rel)
    in
    let in_playground =
      String.starts_with ~prefix:(playground_abs ^ "/") (cwd_canonical ^ "/")
      || String.equal playground_abs cwd_canonical
    in
    let base_profile, base_network_mode =
      Keeper_shell_shared.effective_sandbox_profile ~meta ~in_playground
    in
    (* Docker git-credential dispatch. When base profile is Docker and the
       command's leading token is git/gh, allow network egress and mount
       the selected root/keeper GitHub identity bundle read-only for the
       duration of this command. Disabled when
       MASC_KEEPER_SANDBOX_GIT_DISPATCH=false.
       [git_creds_enabled] replaces the former Docker_with_git variant:
       the external profile stays Docker; the dispatcher reads this flag
       to choose between Keeper_shell_shared.run_docker_with_git_bash and Keeper_shell_shared.run_docker_hardened_bash. *)
    let sandbox_profile, sandbox_network_mode, git_creds_enabled =
      if base_profile = Docker
         && Env_config_keeper.KeeperSandbox.with_git_dispatch_enabled ()
         && Keeper_shell_shared.cmd_targets_git_or_gh cmd
      then (Docker, Network_inherit, true)
      else (base_profile, base_network_mode, false)
    in
    let sandbox_root = Keeper_sandbox.allowed_root_rel_of_meta ~meta in
    (* Destructive guard: always active regardless of Docker or preset *)
    if Worker_dev_tools.is_destructive_bash_operation cmd
    then (
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_shell_bash_failures
        ~labels:[("keeper", meta.name); ("site", "destructive")]
        ();
      Log.Keeper.warn "keeper_bash DESTRUCTIVE blocked: %s (keeper=%s)" cmd_for_log meta.name;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"destructive_operation_blocked"
           ~reason:
             "This command is destructive (force push, push to main, rm -rf, \
              etc.) and is blocked for all presets."
           ~alternatives:
             [ "Use `git push` without --force for normal pushes."
             ; "For cleanup, target specific files instead of rm -rf."
             ; "Ask a human operator to perform this destructive action."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "destructive_operation_blocked"
                    ; explanation =
                        "force push, rm -rf, and similar destructive \
                         commands are blocked for all presets to protect \
                         shared state."
                    ; rewrite =
                        Some "For git: use 'git push' without --force. \
                              For cleanup: target specific files (rm file) \
                              instead of rm -rf."
                    ; tool_suggestion = None })
           ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
           ~env_snapshot:env_snap
           ()))
    else if cmd_contains_gh_pr_create cmd
    then gh_pr_create_block ()
    else if base_profile = Docker
            && Env_config_keeper.KeeperSandbox.hard_mode ()
            && Keeper_shell_shared.cmd_targets_gh cmd
    then (
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_shell_bash_failures
        ~labels:[("keeper", meta.name); ("site", "hard_mode")]
        ();
      Log.Keeper.warn
        "keeper_bash gh blocked by hard mode: keeper=%s cmd=%s"
        meta.name cmd_for_log;
      Yojson.Safe.to_string
        (`Assoc
           [ "ok", `Bool false
           ; "error", `String "gh_requires_brokered_structured_tool"
           ; "reason", `String
               "MASC_KEEPER_SANDBOX_HARD_MODE keeps Docker containers on network=none and forbids host credential mounts"
           ; "hint", `String
               "Use keeper_shell op=gh cmd=\"...\"; hard mode runs validated gh commands through the host broker with keeper-scoped GH_CONFIG_DIR."
           ; "cmd", `String cmd_for_log
           ]))
    else if Worker_dev_tools.is_git_branch_switch cmd
            && not (write_enabled && in_playground)
    then (
      Log.Keeper.info
        "keeper_bash branch-switch blocked: %s (keeper=%s, write_enabled=%b, playground=%b)"
        cmd_for_log meta.name write_enabled in_playground;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"branch_switch_blocked"
           ~reason:
             "git checkout/switch/branch mutations require a write-enabled preset \
              (Coding/Delivery/Full) and a keeper-owned sandbox repo or \
              worktree. Clone into your sandbox first \
              (keeper_shell op=git_clone), then create or enter a worktree \
              under repos/<repo>/.worktrees/<task>."
           ~hint:(Printf.sprintf
                    "Use cwd=%srepos/REPO/.worktrees/TASK"
                    sandbox_root)
           ~alternatives:
             [ Printf.sprintf
                 "Clone the repo first: keeper_shell op=git_clone, then use cwd=%srepos/REPO/.worktrees/TASK."
                 sandbox_root
             ; "Use keeper_shell op=git op_cmd='branch -a' to list available branches."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "branch_switch_blocked"
                    ; explanation =
                        "git checkout/switch/branch mutations need a write-enabled preset and a sandbox clone."
                    ; rewrite =
                        Some (Printf.sprintf
                          "First: keeper_shell op=git_clone. Then: set cwd=%srepos/REPO/.worktrees/TASK"
                          sandbox_root)
                    ; tool_suggestion = None })
           ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
           ()))
    else if (not write_enabled) && Worker_dev_tools.is_write_operation cmd
    then (
      Log.Keeper.info "keeper_bash write-gate: %s (keeper=%s, playground=%b)"
        cmd_for_log meta.name in_playground;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"write_operation_gated"
           ~reason:
             "This command modifies state (git push/commit, make deploy, etc.). \
              A write-enabled preset (Coding/Delivery/Full) is required."
           ~alternatives:
             [ "Read-only alternatives: use keeper_bash for git log, git diff, git status."
             ; "If you need write access, ask the operator to assign a Coding/Delivery/Full preset."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "write_operation_gated"
                    ; explanation =
                        "This command modifies state but the current preset is read-only. Write operations require Coding, Delivery, or Full preset."
                    ; rewrite = None
                    ; tool_suggestion =
                        Some "Ask the operator for a write-enabled preset" })
           ~extra:[ "cmd", `String cmd_for_log; "execution_time_ms", `Int 0 ]
           ~env_snapshot:env_snap
           ()))
    else if write_enabled
            && Worker_dev_tools.is_write_operation cmd
            && not in_playground
    then (
      Log.Keeper.info
        "keeper_bash write-containment blocked: %s (keeper=%s, cwd=%s, playground=%b)"
        cmd_for_log meta.name cwd in_playground;
      Yojson.Safe.to_string
        (Exec_core.blocked_result_json
           ~cmd
           ~error:"write_outside_playground_blocked"
           ~reason:
             (Printf.sprintf
                "Write operations (git push/commit, make deploy, etc.) \
                 must run with cwd inside your keeper-owned sandbox clone \
                 or one of its worktrees under %srepos/<repo>/.worktrees/. \
                 Open a sandbox clone first with keeper_shell op=git_clone \
                 if needed, then use masc_worktree_create and set cwd to \
                 the returned worktree path."
                sandbox_root)
           ~hint:(Printf.sprintf
                    "cwd must start with %s and usually looks like %srepos/REPO/.worktrees/TASK"
                    sandbox_root
                    sandbox_root)
           ~alternatives:
             [ Printf.sprintf
                 "Clone into your sandbox: keeper_shell op=git_clone, then cd to %srepos/REPO/."
                 sandbox_root
             ; "Create a worktree inside your sandbox with masc_worktree_create."
             ; "Use keeper_bash with a cwd pointing to your sandbox worktree."
             ]
           ~retryability:Exec_core.Operator_required
           ~diag:
             (Some { Exec_core.rule_id = "write_outside_playground_blocked"
                    ; explanation =
                        "Write operations must run inside the keeper sandbox. The current cwd is outside the sandbox root."
                    ; rewrite =
                        Some (Printf.sprintf
                          "Clone into sandbox: keeper_shell op=git_clone, then set cwd=%srepos/REPO/.worktrees/TASK"
                          sandbox_root)
                    ; tool_suggestion = None })
           ~extra:[ "cmd", `String cmd_for_log; "cwd", `String cwd; "execution_time_ms", `Int 0 ]
           ()))
    else if sandbox_profile = Docker && git_creds_enabled then (
      let detected_tool = if Keeper_shell_shared.cmd_targets_gh cmd then "gh" else "git" in
      Log.Keeper.info
        "DOCKER_GIT_EXEC: keeper=%s cwd=%s cmd=%s detected_tool=%s \
         base_network=%s upgraded_to=inherit"
        meta.name cwd cmd_for_log detected_tool
        (network_mode_to_string base_network_mode);
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_bash_network_upgrade
        ~labels:[ ("keeper", meta.name); ("detected_tool", detected_tool) ]
        ();
      Keeper_shell_shared.run_docker_with_git_bash
        ~turn_sandbox_runtime:
          (Keeper_sandbox_factory.resolve_opt
             turn_sandbox_factory_git ~cwd)
        ~config ~meta ~cwd ~timeout_sec ~cmd ())
    else if sandbox_profile = Docker then (
      Log.Keeper.info
        "DOCKER_EXEC: keeper=%s cwd=%s cmd=%s network=%s"
        meta.name cwd cmd_for_log (network_mode_to_string sandbox_network_mode);
      with_raw_json_exec_cache (fun () ->
        Keeper_shell_shared.run_docker_hardened_bash
          ~turn_sandbox_runtime:
            (Keeper_sandbox_factory.resolve_opt
               turn_sandbox_factory ~cwd)
          ~config ~meta ~cwd ~timeout_sec ~cmd
          ~network_mode:sandbox_network_mode))
    else
      let local_reason =
        if Env_config_keeper.KeeperSandbox.hard_mode () then "hard_mode_local"
        else if not (Env_config_keeper.DockerPlayground.enabled) then
          "playground_disabled"
        else "outside_playground"
      in
      Log.Keeper.info
        "LOCAL_EXEC: keeper=%s cwd=%s reason=%s sandbox_profile=%s \
         playground=%b hard_mode=%b"
        meta.name cwd local_reason
        (sandbox_profile_to_string meta.sandbox_profile)
        in_playground
        (Env_config_keeper.KeeperSandbox.hard_mode ());
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_bash_local_execution
        ~labels:[ ("keeper", meta.name); ("reason", local_reason) ]
        ();
      (* Local execution path: full validation applies *)
      let validate =
        if write_enabled then Worker_dev_tools.validate_command_coding
        else Worker_dev_tools.validate_command
      in
      match validate cmd with
      | Error reason ->
        let reason_str = Worker_dev_tools.block_reason_to_string reason in
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_shell_bash_failures
          ~labels:[("site", "generic_blocked")]
          ();
        Log.Keeper.warn "keeper_bash blocked: %s (cmd=%s)" reason_str cmd_for_log;
        let hint =
          match reason with
          | Worker_dev_tools.Command_not_allowed name
            when String_util.equals_ci name "gh" ->
            "`gh` is not allowed via keeper_bash. Use keeper_shell with \
             op=\"gh\" (e.g. keeper_shell op=gh cmd=\"pr list --state open\")."
          | Chain_or_redirect | Pipes_not_allowed | Unsafe_redirect ->
            "Use separate tool calls instead of chaining. Call keeper_bash once per command."
          | Injection | Process_substitution ->
            "Avoid shell metacharacters. Use keeper_shell with a specific op (rg, find, ls) instead."
          | Command_not_allowed _ ->
            "Check the command for blocked patterns. Use keeper_shell for structured ops (rg, ls, find)."
          | Empty_command ->
            "Provide a non-empty command string."
        in
        let alternatives =
          match reason with
          | Worker_dev_tools.Command_not_allowed name
            when String_util.equals_ci name "gh" ->
            [ "Use keeper_shell with op=\"gh\" for GitHub CLI operations."
            ; "Example: keeper_shell op=gh cmd=\"pr list --state open\"."
            ]
          | Chain_or_redirect | Pipes_not_allowed | Unsafe_redirect ->
            [ "Break the pipeline into separate keeper_bash calls."
            ; "Save intermediate output to a file, then process it in the next call."
            ]
          | Injection | Process_substitution ->
            [ "Use keeper_shell with a specific op (rg, find, ls) for structured queries."
            ; "Avoid $(...) and backtick substitution in commands."
            ]
          | Command_not_allowed _ ->
            [ "Use keeper_shell for structured ops (rg, ls, find)."
            ; "Check if the command is available under a different name or op."
            ]
          | Empty_command ->
            [ "Provide a non-empty command string."
            ; "Example: keeper_bash cmd='ls -la lib/'."
            ]
        in
        Yojson.Safe.to_string
          (Exec_core.blocked_result_json
             ~cmd
             ~error:"command_blocked"
             ~reason:reason_str
             ~hint
             ~alternatives
             ~diag:(Keeper_shell_shared.diagnosis_of_block_reason reason)
             ~extra:[ "execution_time_ms", `Int 0 ]
             ~env_snapshot:env_snap
             ())
      | Ok () ->
        (
            (match Worker_dev_tools.validate_command_paths ~workdir:cwd cmd with
             | Error e -> error_json e
             | Ok () ->
               if write_enabled
                  && Worker_dev_tools.is_write_operation cmd then
                 Log.Keeper.info "WRITE_AUDIT: keeper=%s cwd=%s cmd=%s playground=%b"
                   meta.name cwd cmd_for_log in_playground;
               (* Tick 7: background mode keeps stdout/stderr separate
                  so [keeper_bash_output] can report them distinctly.
                  Foreground mode merges via [2>&1] for backward
                  compatibility with the single [output] JSON field. *)
               if run_in_background then begin
                 let argv = [ "/bin/bash"; "-lc"; cmd ] in
                 match
                   Bg_task.spawn
                     ~base_path:root
                     ~keeper:meta.name
                     ~argv
                     ~cwd
                     ~envp:(Unix.environment ())
                     ~timeout_sec
                     ()
                 with
                 | Ok tid ->
                     Log.Keeper.info
                       "BG_SPAWN: keeper=%s task_id=%s cmd=%s"
                       meta.name (Bg_task.task_id_to_string tid) cmd_for_log;
                     Yojson.Safe.to_string
                       (`Assoc
                         [
                           ("ok", `Bool true);
                           ( "background_task_id",
                             `String (Bg_task.task_id_to_string tid) );
                           ("cmd", `String cmd);
                           ("cwd", `String cwd);
                           ( "hint",
                             `String
                               "Task running in background. Poll with \
                                keeper_bash_output or stop with \
                                keeper_bash_kill." );
                         ])
                 | Error (Bg_task.Spawn_failed e) ->
                     error_json
                       (Printf.sprintf "background spawn failed: %s" e)
                 | Error (Bg_task.Too_many_tasks { keeper = k; limit }) ->
                     error_json
                       (Printf.sprintf
                          "keeper %s exceeded background task limit (%d)"
                          k limit)
                 | Error (Bg_task.Invalid_cwd msg) ->
                     error_json (Printf.sprintf "invalid cwd: %s" msg)
               end
               else begin
                 (* Tick 11: Foreground path with optional auto-background
                    race.  When [MASC_BASH_AUTO_BG] is enabled and an Eio
                    clock is available, route through
                    [Masc_exec.Exec_run.run_with_auto_bg]: the command
                    spawns as a Bg_task, races its exit against
                    [MASC_BLOCKING_BUDGET_MS] (default 15000), and on
                    budget expiry returns a [Promoted] handle the LLM
                    can poll via [keeper_bash_output].  Without the
                    flag, fall back to the legacy blocking call so
                    existing consumers see no shape change. *)
                 let auto_bg_enabled =
                   match Sys.getenv_opt "MASC_BASH_AUTO_BG" with
                   | Some ("1" | "true" | "yes" | "on") -> true
                   | _ -> false
                 in
                 let argv_merged =
                   [ "/bin/bash"; "-lc"; cmd ^ " 2>&1" ]
                 in
                 (* Tick 23: AUTO_BG dark-launch observer.  When
                    [MASC_BASH_AUTO_BG_OBSERVE] is set, time the
                    foreground run and emit a structured log line
                    if the elapsed duration would have tripped the
                    blocking budget had [MASC_BASH_AUTO_BG] been
                    on.  No behavior change; cheap measurement
                    feeds future default-flip decisions. *)
                 let auto_bg_observe_enabled =
                   match Sys.getenv_opt "MASC_BASH_AUTO_BG_OBSERVE" with
                   | Some ("1" | "true" | "TRUE" | "yes" | "on" | "log") -> true
                   | _ -> false
                 in
                 match
                   if auto_bg_enabled
                   then Eio_context.get_clock_opt ()
                   else None
                 with
                 | None ->
                   (* P21: exec cache for foreground path *)
                   (match exec_cache with
                    | Some cache ->
                      (match Masc_exec.Exec_cache.lookup cache cmd with
                       | Some entry ->
                         cached_result_json entry
                       | None ->
                         let t0 = Unix.gettimeofday () in
                         let st, out =
                           Process_eio.run_argv_with_status
                             ~cwd ~timeout_sec argv_merged
                         in
                         let elapsed_ms =
                           elapsed_duration_ms
                             ~start_time:t0 ~end_time:(Unix.gettimeofday ())
                         in
                         if not (Keeper_shell_shared.process_status_is_timeout st) then begin
                           let exit_code = match st with
                             | Unix.WEXITED n -> n
                             | Unix.WSIGNALED n -> 128 + n
                             | Unix.WSTOPPED n -> 256 + n
                           in
                           Masc_exec.Exec_cache.store cache
                             ~cmd ~exit_code ~output:out ~duration_ms:elapsed_ms
                         end;
                         (if auto_bg_observe_enabled then begin
                            let budget_ms =
                              Masc_exec.Exec_run.default_budget_ms ()
                            in
                            let promoted_candidate = elapsed_ms >= budget_ms in
                            Legendary_counters.incr_auto_bg_observed
                              ~promoted_candidate;
                            if promoted_candidate then
                              Log.Keeper.info
                                "auto_bg_would_have_promoted keeper=%s \
                                 cmd_hash=%s duration_ms=%d budget_ms=%d"
                                meta.name
                                (Worker_dev_tools.cmd_hash_for_log cmd)
                                elapsed_ms
                                budget_ms
                          end);
                         Yojson.Safe.to_string
                           (Exec_core.process_result_json
                              ~base_path:root
                              ~keeper_name:meta.name
                              ~cmd
                              ~extra:[
                                "cwd", `String cwd;
                                "execution_time_ms", `Int elapsed_ms;
                              ]
                              ~status:st
                              ~output:out
                              ~env_snapshot:env_snap
                              ()))
                    | None ->
                   let t0 = Unix.gettimeofday () in
                   let st, out =
                     Process_eio.run_argv_with_status
                       ~cwd ~timeout_sec argv_merged
                   in
                   let elapsed_ms =
                     elapsed_duration_ms
                       ~start_time:t0 ~end_time:(Unix.gettimeofday ())
                   in
                   (if auto_bg_observe_enabled then begin
                      let budget_ms =
                        Masc_exec.Exec_run.default_budget_ms ()
                      in
                      let promoted_candidate = elapsed_ms >= budget_ms in
                      Legendary_counters.incr_auto_bg_observed
                        ~promoted_candidate;
                      if promoted_candidate then
                        Log.Keeper.info
                          "auto_bg_would_have_promoted keeper=%s \
                           cmd_hash=%s duration_ms=%d budget_ms=%d"
                          meta.name
                          (Worker_dev_tools.cmd_hash_for_log cmd)
                          elapsed_ms
                          budget_ms
                    end);
                   Yojson.Safe.to_string
                     (Exec_core.process_result_json
                        ~base_path:root
                        ~keeper_name:meta.name
                        ~cmd
                        ~extra:[
                          "cwd", `String cwd;
                          "execution_time_ms", `Int elapsed_ms;
                        ]
                        ~status:st
                        ~output:out
                        ~env_snapshot:env_snap
                        ()))
                 | Some clock ->
                   let run_uncached () =
                     let budget_ms = Masc_exec.Exec_run.default_budget_ms () in
                     let t0_bg = Unix.gettimeofday () in
                     let outcome =
                       Masc_exec.Exec_run.run_with_auto_bg
                         ~clock
                         ~base_path:root
                         ~budget_ms
                         ~keeper:meta.name
                         ~argv:argv_merged
                         ~cwd
                         ~envp:(Unix.environment ())
                         ~timeout_sec
                         ()
                     in
                     (match outcome with
                      | Masc_exec.Exec_run.Completed r ->
                        let elapsed_ms =
                          elapsed_duration_ms
                            ~start_time:t0_bg ~end_time:(Unix.gettimeofday ())
                        in
                        (* P21: store in exec cache if not a timeout *)
                        if not (Keeper_shell_shared.process_status_is_timeout r.status) then
                          (match exec_cache with
                           | Some cache ->
                             let exit_code = match r.status with
                               | Unix.WEXITED n -> n
                               | Unix.WSIGNALED n -> 128 + n
                               | Unix.WSTOPPED n -> 256 + n
                             in
                             Masc_exec.Exec_cache.store cache
                               ~cmd ~exit_code ~output:r.stdout ~duration_ms:elapsed_ms
                           | None -> ());
                        Yojson.Safe.to_string
                          (Exec_core.process_result_json
                             ~base_path:root
                             ~keeper_name:meta.name
                             ~cmd
                             ~extra:[
                               "cwd", `String cwd;
                               "execution_time_ms", `Int elapsed_ms;
                             ]
                             ~status:r.status
                             ~output:r.stdout
                             ~env_snapshot:env_snap
                             ())
                      | Masc_exec.Exec_run.Promoted p ->
                        let elapsed_ms =
                          elapsed_duration_ms
                            ~start_time:t0_bg ~end_time:(Unix.gettimeofday ())
                        in
                        Log.Keeper.info
                          "BG_PROMOTE: keeper=%s task_id=%s budget_ms=%d cmd=%s"
                          meta.name
                          (Bg_task.task_id_to_string p.task_id)
                          budget_ms
                          cmd_for_log;
                        Yojson.Safe.to_string
                          (`Assoc
                            [
                              ("ok", `Bool false);
                              ("promoted", `Bool true);
                              ( "background_task_id",
                                `String
                                  (Bg_task.task_id_to_string p.task_id) );
                              ("cmd", `String cmd);
                              ("cwd", `String cwd);
                              ("partial_output", `String p.partial_stdout);
                              ( "bytes_dropped",
                                `Int p.bytes_dropped_stdout );
                              ("budget_ms", `Int budget_ms);
                              ("execution_time_ms", `Int elapsed_ms);
                              ( "hint",
                                `String
                                  (Printf.sprintf
                                     "Command exceeded \
                                      MASC_BLOCKING_BUDGET_MS=%d. Still \
                                      running in background; poll with \
                                      keeper_bash_output or stop with \
                                      keeper_bash_kill."
                                     budget_ms) );
                            ])
                      | Masc_exec.Exec_run.Spawn_error
                          (Bg_task.Spawn_failed e) ->
                        error_json
                          (Printf.sprintf
                             "auto-bg spawn failed: %s" e)
                      | Masc_exec.Exec_run.Spawn_error
                          (Bg_task.Too_many_tasks { keeper = k; limit }) ->
                        error_json
                          (Printf.sprintf
                             "keeper %s exceeded background task limit (%d)"
                             k limit)
                      | Masc_exec.Exec_run.Spawn_error
                          (Bg_task.Invalid_cwd msg) ->
                        error_json (Printf.sprintf "invalid cwd: %s" msg))
                   in
                   (match exec_cache with
                    | Some cache ->
                      (match Masc_exec.Exec_cache.lookup cache cmd with
                       | Some entry -> cached_result_json entry
                       | None -> run_uncached ())
                    | None -> run_uncached ())
               end))
  end
;;
