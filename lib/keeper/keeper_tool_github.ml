(** Keeper GitHub primitive — gh CLI wrapper with hallucination gate.

    This is the atomic `keeper_github` tool: executes a validated gh CLI
    command after running through:
    1. Pre-execution hallucination gate (PR/issue number cache validation)
    2. Permission gates (dangerous ops, workflow ops, preset checks)
    3. Subprocess with GH_CONFIG_DIR isolation (anyang-keepers token)
    4. Post-execution output truncation + not-found hint detection
    5. Cache invalidation on successful mutations (pr create, etc.)

    Gate logic and shared helpers live in {!Keeper_gh_shared}.

    This module absorbed the former keeper_exec_github once the per-tool
    extraction (Steps 1-4) completed and keeper_exec_github became a
    single-handler shell. *)

open Keeper_types
open Keeper_exec_shared
open Keeper_gh_shared
let handle_keeper_github
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let gh_args = Safe_ops.json_string_list "args" args in
  let repo_param = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  let timeout_sec =
    Safe_ops.json_float ~default:30.0 "timeout_sec" args |> fun n -> max 1.0 (min 180.0 n)
  in
  let gh_raw_base =
    if cmd <> "" then cmd else if gh_args <> [] then String.concat " " gh_args else ""
  in
  let root = Keeper_alerting_path.project_root_of_config config in
  if gh_raw_base = ""
  then error_json "cmd is required. \
                   Good: cmd='pr list --state open'. Bad: cmd=''. \
                   Single gh subcommand only, no chaining."
  else
  let repo_slug =
    if repo_param = "" then Ok None else Result.map Option.some (validate_repo_slug repo_param)
  in
  match repo_slug with
  | Error reason -> error_json reason
  | Ok repo_slug ->
  (* Structured repo parameter: if provided, inject --repo flag.
     If not provided but cmd contains --repo/-R with wrong owner, correct it.
     This is the root fix for LLM hallucinating repo owners (#6043). *)
  let gh_raw, gh_cmd =
    match cmd <> "", repo_slug with
    | true, Some slug ->
        let normalized =
          if has_repo_flag gh_raw_base then fst (correct_repo_flag ~correct_slug:slug gh_raw_base)
          else Printf.sprintf "%s --repo %s" gh_raw_base slug
        in
        normalized, "gh " ^ normalized
    | false, Some slug ->
        let normalized_args = inject_repo_flag_args ~repo_slug:slug gh_args in
        String.concat " " normalized_args,
        "gh " ^ String.concat " " (List.map Filename.quote normalized_args)
    | true, None -> (
        match project_repo_slug () with
        | Some slug when has_repo_flag gh_raw_base ->
            let corrected, _ = correct_repo_flag ~correct_slug:slug gh_raw_base in
            corrected, "gh " ^ corrected
        | _ ->
            gh_raw_base, "gh " ^ gh_raw_base)
    | false, None -> (
        match project_repo_slug () with
        | Some slug when args_have_repo_flag gh_args ->
            let normalized_args = inject_repo_flag_args ~repo_slug:slug gh_args in
            String.concat " " normalized_args,
            "gh " ^ String.concat " " (List.map Filename.quote normalized_args)
        | _ ->
            String.concat " " gh_args,
            "gh " ^ String.concat " " (List.map Filename.quote gh_args))
  in
  (
    match Worker_dev_tools.validate_gh_command gh_raw with
    | Error reason ->
      Log.Keeper.warn "keeper_github blocked: %s (cmd=%s)" reason gh_raw;
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "command_blocked"
            ; "reason", `String reason
            ])
    | Ok () ->
      (* Pre-execution hallucination gate. When the command targets a
         specific PR/issue number, verify that number actually exists in
         the repo's cached list. On mismatch, return the valid
         alternatives as a JSON array -- the LLM picks from the list
         instead of guessing. On `Unknown (cache miss / fetch failure),
         fallthrough to normal execution (fail-open). See
         [keeper_gh_cache.ml]. *)
      let invalid_number =
        match extract_gh_target_number gh_raw with
        | None -> None
        | Some (kind, number) ->
          let slug =
            match repo_slug with
            | Some s -> s
            | None -> Option.value ~default:"" (project_repo_slug ())
          in
          (match
             validate_number ~config ~repo_slug:slug ~kind ~number
           with
           | `Valid | `Unknown -> None
           | `Invalid valids ->
             let rc = record_rejection ~repo_slug:slug ~kind ~number in
             Some (kind, number, valids, rc, slug))
      in
      (match invalid_number with
       | Some (kind, number, valids, rejection_count, slug) ->
         let kind_label =
           match kind with PR -> "PR" | Issue -> "issue"
         in
         let shown =
           let rec take n = function
             | [] -> []
             | _ when n <= 0 -> []
             | x :: rest -> x :: take (n - 1) rest
           in
           take (Keeper_tool_policy.gh_cache_max_alternatives ()) valids
         in
         let valid_str =
           shown |> List.map string_of_int |> String.concat ", "
         in
         let sub_label =
           match kind with PR -> "pr" | Issue -> "issue"
         in
         let suggested =
           match shown with
           | recent :: _ ->
             Printf.sprintf "gh %s view %d" sub_label recent
           | [] -> Printf.sprintf "gh %s list --state open" sub_label
         in
         let is_repeat = rejection_count >= 2 in
         Log.Keeper.warn
           "keeper_github hallucination-gate: %s #%d not in %s (keeper=%s, rejection=%d)"
           kind_label number slug meta.name rejection_count;
         (* Escalate the rejection message on repeated attempts.
            First rejection: explain the error + offer alternatives.
            Second+: mandate the suggested command and explicitly tell
            the LLM to stop retrying the same number. Without this,
            poe retried issue #7036 three times in a row (#7199). *)
         let reason =
           if is_repeat then
             Printf.sprintf
               "ALREADY REJECTED (attempt %d). \
                %s #%d does NOT exist — you already tried this. \
                STOP retrying this number. \
                Use EXACTLY this command instead: %s"
               rejection_count kind_label number suggested
           else
             Printf.sprintf
               "WRONG NUMBER (not a repo problem). \
                %s #%d does not exist. \
                The repo %s is correct. \
                Pick from these valid %s numbers: [%s]."
               kind_label number slug kind_label valid_str
         in
         let hint =
           if is_repeat then
             Printf.sprintf "MANDATORY: %s" suggested
           else
             Printf.sprintf "Try: %s" suggested
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool false
               ; "error", `String (if is_repeat then "number_already_rejected" else "number_not_found")
               ; "reason", `String reason
               ; "valid_numbers", `List (List.map (fun n -> `Int n) shown)
               ; "suggested_command", `String suggested
               ; "hint", `String hint
               ; "rejection_count", `Int rejection_count
               ; "cmd", `String ("gh " ^ gh_raw)
               ])
       | None ->
      let preset_allows_workflow =
        match Keeper_types.tool_access_preset meta.tool_access with
        | Some preset -> Keeper_tool_policy.allows_workflow_for_preset preset
        | None -> false
      in
      if Worker_dev_tools.is_gh_dangerous_operation gh_raw
      then (
        Log.Keeper.info "keeper_github dangerous-gate: %s (keeper=%s)" gh_raw meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "dangerous_operation_gated"
              ; ( "reason"
                , `String
                    "This gh command performs an irreversible operation \
                     (delete/archive/transfer). Request operator approval." )
              ; "cmd", `String ("gh " ^ gh_raw)
              ]))
      else if (not preset_allows_workflow)
              && Worker_dev_tools.is_gh_workflow_operation gh_raw
      then (
        Log.Keeper.info "keeper_github workflow-gate: %s (keeper=%s, preset not coding/full)"
          gh_raw meta.name;
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "error", `String "workflow_operation_gated"
              ; ( "reason"
                , `String
                    "This gh command performs a workflow mutation \
                     (merge/close). Upgrade to coding or full preset, \
                     or request operator approval." )
              ; "cmd", `String ("gh " ^ gh_raw)
              ]))
      (* Pre-merge review gate: verify PR has at least one non-dismissed review
         before allowing gh pr merge. Prevents agents from self-merging without
         cross-agent review. Ref: #5906 *)
      else if Worker_dev_tools.is_gh_pr_merge gh_raw then (
        let root = Keeper_alerting_path.project_root_of_config config in
        let review_check =
          let merge_target = Worker_dev_tools.gh_pr_merge_target gh_raw in
          let target_arg =
            match merge_target with
            | Some target -> " " ^ Filename.quote target
            | None -> ""
          in
          let check_cmd = Printf.sprintf
            "cd %s && gh pr view%s --json reviews --jq '.reviews | map(select(.state != \"DISMISSED\")) | length' 2>&1"
            (Filename.quote root) target_arg
          in
          let st, out = Process_eio.run_argv_with_status ~timeout_sec:10.0
            [ "/bin/zsh"; "-lc"; check_cmd ]
          in
          if st = Unix.WEXITED 0 then
            let count = String.trim out in
            if count = "0" || count = "" then `Blocked_no_reviews
            else `Allowed
          else
            `Check_failed (String.trim out)
        in
        match review_check with
        | `Blocked_no_reviews ->
          Log.Keeper.warn "keeper_github merge-review-gate: blocked %s (keeper=%s, no reviews)"
            gh_raw meta.name;
          Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool false
                ; "error", `String "merge_blocked_no_reviews"
                ; ( "reason"
                  , `String
                      "Cannot merge: PR has no non-dismissed reviews. \
                       Every PR requires at least one cross-agent review before merge. \
                       Post a review first, then retry." )
                ; "cmd", `String ("gh " ^ gh_raw)
                ])
        | `Check_failed err ->
          Log.Keeper.warn
            "keeper_github merge-review-gate: verification failed %s (keeper=%s, err=%s)"
            gh_raw meta.name (if err = "" then "<empty>" else err);
          Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool false
                ; "error", `String "merge_review_check_failed"
                ; ( "reason"
                  , `String
                      "Cannot verify PR review state for this merge target. \
                       Resolve the gh pr view failure or request operator approval, \
                       then retry." )
                ; "details", `String err
                ; "cmd", `String ("gh " ^ gh_raw)
                ])
        | `Allowed ->
          let scoped_cmd = with_keeper_gh_env config gh_cmd in
          let shell_cmd = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) scoped_cmd in
          let st, raw_out = Process_eio.run_argv_with_status ~timeout_sec [ "/bin/zsh"; "-lc"; shell_cmd ] in
          let out, trunc_fields = truncate_gh_output raw_out in
          (* Invalidate cache on successful mutation so the next validation
             sees the new/removed number. Applies to pr merge explicitly. *)
          (if st = Unix.WEXITED 0 then
             match gh_mutates_entity gh_raw with
             | None -> ()
             | Some kind ->
               let slug =
                 match repo_slug with
                 | Some s -> s
                 | None -> Option.value ~default:"" (project_repo_slug ())
               in
               if slug <> "" then invalidate_cache ~repo_slug:slug ~kind);
          Yojson.Safe.to_string
            (`Assoc
                ([ "ok", `Bool (st = Unix.WEXITED 0)
                 ; "status", Keeper_alerting_path.process_status_to_json st
                 ; "output", `String out
                 ] @ trunc_fields @ gh_not_found_hint ~st ~out)))
      else (
        let scoped_cmd = with_keeper_gh_env config gh_cmd in
        let shell_cmd = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) scoped_cmd in
        let st, raw_out =
          Process_eio.run_argv_with_status ~timeout_sec [ "/bin/zsh"; "-lc"; shell_cmd ]
        in
        let out, trunc_fields = truncate_gh_output raw_out in
        (* See merge-path comment above -- same invalidation rationale. *)
        (if st = Unix.WEXITED 0 then
           match gh_mutates_entity gh_raw with
           | None -> ()
           | Some kind ->
             let slug =
               match repo_slug with
               | Some s -> s
               | None -> Option.value ~default:"" (project_repo_slug ())
             in
             if slug <> "" then invalidate_cache ~repo_slug:slug ~kind);
        Yojson.Safe.to_string
          (`Assoc
              ([ "ok", `Bool (st = Unix.WEXITED 0)
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "output", `String out
               ] @ trunc_fields @ gh_not_found_hint ~st ~out)))))
;;

