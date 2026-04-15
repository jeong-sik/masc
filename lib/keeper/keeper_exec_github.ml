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

let handle_keeper_pr_workflow
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let branch = Safe_ops.json_string ~default:"" "branch" args |> String.trim in
  let file_path = Safe_ops.json_string ~default:"" "file_path" args |> String.trim in
  let file_content = Safe_ops.json_string ~default:"" "file_content" args in
  let commit_message = Safe_ops.json_string ~default:"" "commit_message" args |> String.trim in
  let pr_title = Safe_ops.json_string ~default:"" "pr_title" args |> String.trim in
  let pr_body = Safe_ops.json_string ~default:"" "pr_body" args |> String.trim in
  let base_branch = Safe_ops.json_string ~default:"main" "base_branch" args |> String.trim in
  (* Validate required fields *)
  if branch = "" then error_json "branch is required. Good: branch='fix/typo'. Bad: branch=''."
  else if file_path = "" then error_json "file_path is required. Good: file_path='lib/foo.ml'. Bad: file_path=''."
  else if commit_message = "" then error_json "commit_message is required. Good: commit_message='fix typo in foo'. Bad: commit_message=''."
  else if pr_title = "" then error_json "pr_title is required. Good: pr_title='Fix typo in foo'. Bad: pr_title=''."

  else
    (* Check preset: requires delivery or coding *)
    let preset_ok =
      match Keeper_types.tool_access_preset meta.tool_access with
      | Some (Delivery | Coding | Full) -> true
      | _ -> false
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String "keeper_pr_workflow requires delivery, coding, or full preset"
          ])
    else
      (* Sanitize branch: allow a-z, A-Z, 0-9, hyphen, underscore, slash *)
      let safe_branch s =
        String.to_seq s
        |> Seq.filter (fun c ->
          (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '/')
        |> String.of_seq
      in
      let branch_safe = safe_branch branch in
      if branch_safe <> branch then
        error_json "branch contains invalid chars. Use only a-z, A-Z, 0-9, hyphen, underscore, slash."
      else
      let root = Keeper_alerting_path.project_root_of_config config in
      let steps = Buffer.create 512 in
      let step_ok = ref true in
      let step_error = ref "" in
      let run_step name f =
        if !step_ok then begin
          match f () with
          | Ok msg ->
            Buffer.add_string steps (Printf.sprintf "  %s: ok\n" name);
            Log.Keeper.info "pr_workflow step %s ok (keeper=%s)" name meta.name;
            Some msg
          | Error msg ->
            step_ok := false;
            step_error := Printf.sprintf "%s failed: %s" name msg;
            Buffer.add_string steps (Printf.sprintf "  %s: FAILED — %s\n" name msg);
            Log.Keeper.warn "pr_workflow step %s failed: %s (keeper=%s)" name msg meta.name;
            None
        end else None
      in
      let run_argv ~timeout_sec argv =
        Process_eio.run_argv_with_status ~timeout_sec argv
      in
      let run_sh ~cwd ~timeout_sec cmd =
        let shell = Printf.sprintf "cd %s && %s 2>&1"
          (Filename.quote cwd) cmd in
        Process_eio.run_argv_with_status ~timeout_sec
          [ "/bin/zsh"; "-lc"; shell ]
      in
      let repo_root =
        match Room_git.git_root ~base_path:root with
        | Some path -> path
        | None -> root
      in
      let worktree_id =
        branch
        |> String.to_seq
        |> Seq.map (fun c -> if c = '/' || c = '\\' then '-' else c)
        |> String.of_seq
        |> Printf.sprintf "%s-%s" meta.name
      in
      let worktree_dir = ref "" in
      let resolved_base_branch = ref base_branch in
      let remove_worktree_path worktree_path =
        try
          let st_rm, out_rm = run_sh ~cwd:repo_root ~timeout_sec:10.0
            (Printf.sprintf "git worktree remove --force %s"
              (Filename.quote worktree_path)) in
          if st_rm <> Unix.WEXITED 0 then
            Error (Printf.sprintf "git worktree remove: %s" (String.trim out_rm))
          else begin
            let st_prune, out_prune = run_sh ~cwd:repo_root ~timeout_sec:5.0
              "git worktree prune" in
            if st_prune <> Unix.WEXITED 0 then
              Log.Keeper.warn "pr_workflow: git worktree prune failed after cleaning %s: %s"
                worktree_path (String.trim out_prune);
            Ok ()
          end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error (Printexc.to_string exn)
      in
      let branch_exists_locally branch_name =
        let st, out = run_sh ~cwd:repo_root ~timeout_sec:5.0
          (Printf.sprintf "git show-ref --verify --quiet %s"
            (Filename.quote (Printf.sprintf "refs/heads/%s" branch_name))) in
        match st with
        | Unix.WEXITED 0 -> Ok true
        | Unix.WEXITED 1 -> Ok false
        | _ -> Error (Printf.sprintf "git show-ref: %s" (String.trim out))
      in
      let normalize_worktree_path path =
        let stripped =
          if path <> "" && path.[String.length path - 1] = '/'
          then String.sub path 0 (String.length path - 1)
          else path
        in
        try Fs_compat.realpath stripped
        with Unix.Unix_error _ -> stripped
      in
      let same_worktree_path left right =
        String.equal
          (normalize_worktree_path left)
          (normalize_worktree_path right)
      in
      let find_worktree_path_for_branch branch_name =
        let target_ref = Printf.sprintf "refs/heads/%s" branch_name in
        let st, out = run_sh ~cwd:repo_root ~timeout_sec:5.0
          "git worktree list --porcelain" in
        if st <> Unix.WEXITED 0 then None
        else
          let rec loop current_path = function
            | [] -> None
            | raw_line :: rest ->
              let line = String.trim raw_line in
              if String.starts_with ~prefix:"worktree " line then
                let path =
                  String.sub line 9 (String.length line - 9)
                in
                loop (Some path) rest
              else if line = "" then
                loop None rest
              else if line = Printf.sprintf "branch %s" target_ref then
                current_path
              else
                loop current_path rest
          in
          loop None (String.split_on_char '\n' out)
      in
      let cleanup_worktree () =
        if !worktree_dir <> "" && Fs_compat.file_exists !worktree_dir then begin
          match remove_worktree_path !worktree_dir with
          | Ok () -> ()
          | Error msg ->
            Log.Keeper.warn "pr_workflow: cleanup failed for %s: %s" !worktree_dir msg
        end
      in
      Fun.protect
        ~finally:cleanup_worktree
        (fun () ->
      let _s1 = run_step "worktree_create" (fun () ->
        if not (Room_git.is_git_repo ~base_path:root) then
          Error "Not a git repository. MASC v2 requires .git directory for worktree isolation."
        else
          let worktrees_dir = Filename.concat repo_root ".worktrees" in
          let worktree_path = Filename.concat worktrees_dir worktree_id in
          Fs_compat.mkdir_p worktrees_dir;
          let prepare_result =
            if Fs_compat.file_exists worktree_path then
              match remove_worktree_path worktree_path with
              | Ok () -> Ok ()
              | Error msg ->
                Error (Printf.sprintf "remove existing worktree: %s" msg)
            else Ok ()
          in
          match prepare_result with
          | Error _ as err -> err
          | Ok () ->
            let _ = run_sh ~cwd:repo_root ~timeout_sec:30.0 "git fetch origin" in
            match Room_git.resolve_base_branch repo_root base_branch with
            | Error e -> Error (Types.masc_error_to_string e)
            | Ok (resolved_base, fallback_from) ->
              resolved_base_branch := resolved_base;
              begin match branch_exists_locally branch with
              | Error msg -> Error msg
              | Ok branch_exists ->
                let prepare_existing_branch_result =
                  if not branch_exists then Ok ()
                  else
                    match find_worktree_path_for_branch branch with
                    | Some existing_path when same_worktree_path existing_path worktree_path ->
                      remove_worktree_path existing_path
                    | _ -> Ok ()
                in
                begin match prepare_existing_branch_result with
                | Error msg ->
                  Error (Printf.sprintf "remove existing worktree: %s" msg)
                | Ok () ->
                let add_cmd =
                  if branch_exists then
                    Printf.sprintf "git worktree add %s %s"
                      (Filename.quote worktree_path)
                      (Filename.quote branch)
                  else
                    Printf.sprintf "git worktree add -b %s %s %s"
                      (Filename.quote branch)
                      (Filename.quote worktree_path)
                      (Filename.quote (Printf.sprintf "origin/%s" resolved_base))
                in
                let add_worktree () =
                  let st, out = run_sh ~cwd:repo_root ~timeout_sec:30.0 add_cmd in
                  if st = Unix.WEXITED 0 then Ok ()
                  else
                    match find_worktree_path_for_branch branch with
                    | Some existing_path when same_worktree_path existing_path worktree_path ->
                      begin match remove_worktree_path existing_path with
                      | Error msg ->
                        Error (Printf.sprintf "remove existing worktree: %s" msg)
                      | Ok () ->
                        let st_retry, out_retry =
                          run_sh ~cwd:repo_root ~timeout_sec:30.0 add_cmd
                        in
                        if st_retry = Unix.WEXITED 0 then Ok ()
                        else
                          Error (Printf.sprintf "git worktree add retry: %s" (String.trim out_retry))
                      end
                    | _ ->
                      Error (Printf.sprintf "git worktree add: %s" (String.trim out))
                in
                match add_worktree () with
                | Error _ as err -> err
                | Ok () -> begin
                  let worktree_root =
                    try Fs_compat.realpath worktree_path
                    with Unix.Unix_error _ -> worktree_path
                  in
                  worktree_dir := worktree_root;
                  let fallback_note =
                    match fallback_from with
                    | None -> ""
                    | Some missing ->
                      Printf.sprintf " (origin/%s missing, used origin/%s)"
                        missing resolved_base
                  in
                  let branch_note =
                    if branch_exists then " (reused existing branch)" else ""
                  in
                  Ok (Printf.sprintf "worktree %s on branch %s%s%s"
                    worktree_root branch branch_note fallback_note)
                end
                end
              end
      ) in
      (* Step 2: Write file — with path traversal guard *)
      let _s2 = run_step "file_write" (fun () ->
        if !worktree_dir = "" then Error "no worktree path"
        else begin
          let abs_path = Filename.concat !worktree_dir file_path in
          let canonical =
            try Some (Fs_compat.realpath abs_path)
            with Unix.Unix_error _ ->
              try
                let parent = Fs_compat.realpath (Filename.dirname abs_path) in
                Some (Filename.concat parent (Filename.basename abs_path))
              with Unix.Unix_error _ -> None
          in
          match canonical with
          | None -> Error (Printf.sprintf "cannot resolve path: %s" file_path)
          | Some resolved ->
            if not (String.starts_with ~prefix:(!worktree_dir ^ "/") resolved) then
              Error (Printf.sprintf "path escapes worktree boundary: %s" file_path)
            else begin
              try
                let dir = Filename.dirname resolved in
                Fs_compat.mkdir_p dir;
                Fs_compat.save_file resolved file_content;
                Ok (Printf.sprintf "wrote %d bytes to %s" (String.length file_content) file_path)
              with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Error (Printexc.to_string exn)
            end
        end
      ) in
      (* Pre-commit: Version truth check guard *)
      let _s_ver = run_step "version_truth_check" (fun () ->
        if !worktree_dir = "" then Error "no worktree path"
        else begin
          let check_script = Filename.concat !worktree_dir "scripts/check-version-truth.sh" in
          if not (Fs_compat.file_exists check_script) then
            Error "missing version truth script: scripts/check-version-truth.sh"
          else
          let st, out = run_argv ~timeout_sec:10.0
            [ "/bin/bash"; check_script ] in
          if st <> Unix.WEXITED 0 then
            Error (Printf.sprintf "Version truth check failed: %s" out)
          else Ok "version truth OK"
        end
      ) in
      (* Step 3: Git add + commit + push *)
      let _s3 = run_step "git_commit_push" (fun () ->
        if !worktree_dir = "" then Error "no worktree path"
        else begin
          let run_git cmd = run_sh ~cwd:(!worktree_dir) ~timeout_sec:30.0
            (Printf.sprintf "git %s" cmd) in
          let st_add, out_add = run_git
            (Printf.sprintf "add %s" (Filename.quote file_path)) in
          if st_add <> Unix.WEXITED 0 then
            Error (Printf.sprintf "git add: %s" out_add)
          else begin
            let author = Keeper_identity.keeper_git_author ~keeper_name:meta.name in
            let email = Keeper_identity.keeper_git_email ~keeper_name:meta.name in
            let st_commit, out_commit = run_sh ~cwd:(!worktree_dir) ~timeout_sec:30.0
              (Printf.sprintf "GIT_AUTHOR_NAME=%s GIT_AUTHOR_EMAIL=%s GIT_COMMITTER_NAME=%s GIT_COMMITTER_EMAIL=%s git commit -m %s"
                (Filename.quote author) (Filename.quote email)
                (Filename.quote author) (Filename.quote email)
                (Filename.quote commit_message)) in
            if st_commit <> Unix.WEXITED 0 then
              Error (Printf.sprintf "git commit: %s" out_commit)
            else begin
              let push_timeout = Keeper_tool_policy.push_timeout_sec () in
              let st_push, out_push = run_sh ~cwd:(!worktree_dir) ~timeout_sec:push_timeout
                (Printf.sprintf "git push -u origin %s" (Filename.quote branch)) in
              if st_push <> Unix.WEXITED 0 then
                Error (Printf.sprintf "git push: %s" out_push)
              else
                Ok "committed and pushed"
            end
          end
        end
      ) in
      (* Step 4: Create draft PR *)
      let pr_url = ref "" in
      let _s4 = run_step "gh_pr_create" (fun () ->
        if !worktree_dir = "" then Error "no worktree path"
        else begin
          let body = if pr_body = "" then pr_title else pr_body in
          let gh_cmd = Printf.sprintf
            "gh pr create --draft --title %s --body %s --base %s --head %s"
            (Filename.quote pr_title) (Filename.quote body)
            (Filename.quote !resolved_base_branch) (Filename.quote branch) in
          let pr_timeout = Keeper_tool_policy.pr_create_timeout_sec () in
          let st, out = run_sh ~cwd:(!worktree_dir) ~timeout_sec:pr_timeout gh_cmd in
          if st <> Unix.WEXITED 0 then
            Error (Printf.sprintf "gh pr create: %s" out)
          else begin
            pr_url := String.trim out;
            Ok (Printf.sprintf "PR created: %s" (String.trim out))
          end
        end
      ) in
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool !step_ok
          ; "deprecated", `Bool true
          ; "migration_hint", `String
              "Use masc_worktree_create + masc_code_write/masc_code_edit + keeper_pr_submit for multi-file changes."
          ; "steps", `String (Buffer.contents steps)
          ; "pr_url", `String !pr_url
          ; "error", `String !step_error
          ; "keeper", `String meta.name
          ])
        )
;;

let handle_keeper_pr_submit
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let cwd = Safe_ops.json_string ~default:"" "cwd" args |> String.trim in
  let commit_message = Safe_ops.json_string ~default:"" "commit_message" args |> String.trim in
  let pr_title = Safe_ops.json_string ~default:"" "pr_title" args |> String.trim in
  let pr_body = Safe_ops.json_string ~default:"" "pr_body" args |> String.trim in
  let base_branch = Safe_ops.json_string ~default:"main" "base_branch" args |> String.trim in
  let draft = Safe_ops.json_bool ~default:true "draft" args in
  let files = Safe_ops.json_string_list "files" args in
  (* Validate required fields *)
  if cwd = "" then error_json "cwd is required (worktree or playground repos path)."
  else if commit_message = "" then error_json "commit_message is required."
  else if pr_title = "" then error_json "pr_title is required."
  else
    (* Check preset *)
    let preset_ok =
      match Keeper_types.tool_access_preset meta.tool_access with
      | Some (Delivery | Coding | Full) -> true
      | _ -> false
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String "keeper_pr_submit requires delivery, coding, or full preset"
          ])
    else
      let root = Keeper_alerting_path.project_root_of_config config in
      (* Validate cwd is inside THIS keeper's own playground bundle.
         Before PR #6527 iter 4, the gate accepted any `.worktrees/`
         or any `.masc/playground/*` — i.e. it was not per-keeper, so
         keeper-A could submit a PR from keeper-B's playground or
         from a server-wide worktree. After iter 2 (PR #6542)
         masc_worktree_create always lands the worktree under
         `.masc/playground/<keeper>/repos/<clone>/.worktrees/...`, so
         the only legitimate cwd for pr_submit is this keeper's own
         playground bundle prefix. *)
      let abs_cwd =
        if Filename.is_relative cwd then Filename.concat root cwd
        else cwd
      in
      let keeper_playground_prefix =
        Filename.concat root
          (Keeper_alerting_path.playground_path_of_keeper meta.name)
      in
      (* [playground_path_of_keeper] returns a path with a trailing
         slash, so prefix matching is already boundary-safe — a
         sibling directory with the same stem cannot slip through. *)
      let cwd_ok =
        String.starts_with ~prefix:keeper_playground_prefix abs_cwd
      in
      if not cwd_ok then
        Yojson.Safe.to_string
          (`Assoc
            [ "ok", `Bool false
            ; "error", `String "cwd_outside_playground"
            ; ( "reason"
              , `String
                  "cwd must be inside this keeper's own playground bundle. \
                   Every cwd passed to keeper_pr_submit must start with \
                   .masc/playground/<YOUR_KEEPER_NAME>/repos/<clone>/.worktrees/<name>/. \
                   Other keepers' playgrounds and the MASC server \
                   repository worktrees are not accepted." )
            ; "cwd", `String abs_cwd
            ; "expected_prefix", `String keeper_playground_prefix
            ; ( "hint"
              , `String
                  "Call masc_worktree_create first (it returns a path \
                   inside your playground), then re-call keeper_pr_submit \
                   with cwd set to that returned path." )
            ; "recovery_tool", `String "masc_worktree_create"
            ])
      else
        let steps = Buffer.create 512 in
        let step_ok = ref true in
        let step_error = ref "" in
        let run_step name f =
          if !step_ok then begin
            match f () with
            | Ok msg ->
              Buffer.add_string steps (Printf.sprintf "  %s: ok\n" name);
              Log.Keeper.info "pr_submit step %s ok (keeper=%s)" name meta.name;
              Some msg
            | Error msg ->
              step_ok := false;
              step_error := Printf.sprintf "%s failed: %s" name msg;
              Buffer.add_string steps (Printf.sprintf "  %s: FAILED — %s\n" name msg);
              Log.Keeper.warn "pr_submit step %s failed: %s (keeper=%s)" name msg meta.name;
              None
          end else None
        in
        let run_sh_in_cwd ~timeout_sec cmd =
          let shell = Printf.sprintf "cd %s && %s 2>&1"
            (Filename.quote abs_cwd) cmd in
          Process_eio.run_argv_with_status ~timeout_sec
            [ "/bin/zsh"; "-lc"; shell ]
        in
        (* Step 1: git add *)
        let _s1 = run_step "git_add" (fun () ->
          let add_cmd =
            if files = [] then "git add -A"
            else Printf.sprintf "git add %s"
              (String.concat " " (List.map Filename.quote files))
          in
          let st, out = run_sh_in_cwd ~timeout_sec:15.0 add_cmd in
          if st <> Unix.WEXITED 0 then Error (Printf.sprintf "git add: %s" out)
          else Ok "staged"
        ) in
        (* Step 2: check for changes *)
        let _s2 = run_step "diff_check" (fun () ->
          let st, out = run_sh_in_cwd ~timeout_sec:10.0
            "git diff --cached --stat" in
          if st <> Unix.WEXITED 0 then Error (Printf.sprintf "git diff: %s" out)
          else if String.trim out = "" then Error "no changes staged"
          else Ok out
        ) in
        (* Step 3: commit with keeper identity *)
        let _s3 = run_step "git_commit" (fun () ->
          let author = Keeper_identity.keeper_git_author ~keeper_name:meta.name in
          let email = Keeper_identity.keeper_git_email ~keeper_name:meta.name in
          let commit_cmd = Printf.sprintf
            "GIT_AUTHOR_NAME=%s GIT_AUTHOR_EMAIL=%s GIT_COMMITTER_NAME=%s GIT_COMMITTER_EMAIL=%s git commit -m %s"
            (Filename.quote author) (Filename.quote email)
            (Filename.quote author) (Filename.quote email)
            (Filename.quote commit_message) in
          let st, out = run_sh_in_cwd ~timeout_sec:30.0 commit_cmd in
          if st <> Unix.WEXITED 0 then Error (Printf.sprintf "git commit: %s" out)
          else Ok "committed"
        ) in
        (* Step 4: determine branch and push *)
        let branch_name = ref "" in
        let _s4 = run_step "git_push" (fun () ->
          let st_branch, out_branch = run_sh_in_cwd ~timeout_sec:5.0
            "git rev-parse --abbrev-ref HEAD" in
          if st_branch <> Unix.WEXITED 0 then
            Error (Printf.sprintf "get branch: %s" out_branch)
          else begin
            branch_name := String.trim out_branch;
            let push_timeout = Keeper_tool_policy.push_timeout_sec () in
            let st, out = run_sh_in_cwd ~timeout_sec:push_timeout
              (Printf.sprintf "git push -u origin %s" (Filename.quote !branch_name)) in
            if st <> Unix.WEXITED 0 then Error (Printf.sprintf "git push: %s" out)
            else Ok "pushed"
          end
        ) in
        (* Sanitize PR body: strip control characters (0x00-0x1F except tab/newline) *)
        let sanitize_for_gh body =
          let buf = Buffer.create (String.length body) in
          String.iter (fun ch ->
            let code = Char.code ch in
            if code > 0x1F || ch = '\t' || ch = '\n'
            then Buffer.add_char buf ch
          ) body;
          Buffer.contents buf
        in
        (* Step 5: create PR *)
        let pr_url = ref "" in
        let _s5 = run_step "gh_pr_create" (fun () ->
          let body = if pr_body = "" then pr_title else sanitize_for_gh pr_body in
          let draft_flag = if draft then " --draft" else "" in
          let pr_timeout = Keeper_tool_policy.pr_create_timeout_sec () in
          let gh_cmd = Printf.sprintf
            "gh pr create%s --title %s --body %s --base %s"
            draft_flag
            (Filename.quote (sanitize_for_gh pr_title))
            (Filename.quote body)
            (Filename.quote base_branch) in
          let st, out = run_sh_in_cwd ~timeout_sec:pr_timeout gh_cmd in
          if st <> Unix.WEXITED 0 then Error (Printf.sprintf "gh pr create (exit %d): %s"
            (match st with Unix.WEXITED n -> n | Unix.WSIGNALED n -> -(n) | Unix.WSTOPPED n -> -(n)) out)
          else begin
            (* Extract PR URL from potentially multi-line output (stdout+stderr merged via 2>&1).
               Search all lines for the first matching https://github.com/.../pull/N pattern. *)
            let url_re =
              Re.Pcre.re {|https://github\.com/[^ \t\r\n'"\\]+/pull/[0-9]+|}
              |> Re.compile
            in
            let lines = String.split_on_char '\n' out in
            let found_url = ref "" in
            (try
               List.iter (fun line ->
                 let trimmed = String.trim line in
                 if !found_url = "" then
                   match Re.exec_opt url_re trimmed with
                   | Some groups -> found_url := Re.Group.get groups 0
                   | None -> ()
               ) lines
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | _ -> ());
            if !found_url <> "" then begin
              pr_url := !found_url;
              Ok (Printf.sprintf "PR created: %s" !found_url)
            end else
              let out_preview =
                let trimmed = String.trim out in
                let len = String.length trimmed in
                if len <= 200 then trimmed else String.sub trimmed 0 200
              in
              Error (Printf.sprintf
                "gh pr create returned exit 0 but no PR URL found in output: %s"
                out_preview)
          end
        ) in
        (* Step 6: verify PR actually exists on remote *)
        let _s6 = run_step "pr_verify" (fun () ->
          if !pr_url = "" then Error "pr_url is empty — skipping verify"
          else
            let verify_timeout = 15.0 in
            let verify_cmd = Printf.sprintf
              "gh pr view %s --json number,url --jq .url 2>/dev/null"
              (Filename.quote !pr_url) in
            let st, out = run_sh_in_cwd ~timeout_sec:verify_timeout verify_cmd in
            if st <> Unix.WEXITED 0 then
              Error (Printf.sprintf "PR verify failed — PR may not exist: %s"
                (String.trim out))
            else
              let verified = String.trim out in
              if verified = "" then
                Error "PR verify returned empty — PR may not exist"
              else
                Ok (Printf.sprintf "PR verified: %s" verified)
        ) in
        (* Invalidate the PR cache on success so that a keeper issuing
           [gh pr view <new-number>] on the next turn validates against
           the refreshed list instead of rejecting the just-created PR. *)
        if !step_ok then begin
          let slug = Option.value ~default:"" (project_repo_slug ()) in
          if slug <> "" then
            invalidate_cache ~repo_slug:slug ~kind:PR
        end;
        (* Record PR in playground history (best-effort, JSONL append) *)
        if !step_ok && !pr_url <> "" then begin
          try
            let playground_dir = Filename.concat root
              (Keeper_alerting_path.playground_path_of_keeper meta.name) in
            Fs_compat.mkdir_p playground_dir;
            let history_path = Filename.concat playground_dir
              ".playground_pr_history.jsonl" in
            let entry = `Assoc [
              "pr_url", `String !pr_url;
              "branch", `String !branch_name;
              "title", `String pr_title;
              "draft", `Bool draft;
              "base", `String base_branch;
              "cwd", `String cwd;
              "created_at", `String (Printf.sprintf "%.0f" (Unix.gettimeofday ()));
            ] in
            Fs_compat.append_jsonl history_path entry
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Log.Keeper.warn "pr_history append failed: %s (keeper=%s)"
                (Printexc.to_string exn) meta.name
        end;
        Yojson.Safe.to_string
          (`Assoc
            [ "ok", `Bool !step_ok
            ; "steps", `String (Buffer.contents steps)
            ; "pr_url", `String !pr_url
            ; "branch", `String !branch_name
            ; "error", `String !step_error
            ; "keeper", `String meta.name
            ])
;;

let handle_keeper_pr_review_read
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  ignore meta;
  let pr_number = Safe_ops.json_int ~default:0 "pr_number" args in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required. Good: pr_number=123."
  else
    let root = Keeper_alerting_path.project_root_of_config config in
    let repo_flag = if repo <> "" then Printf.sprintf " -R %s" (Filename.quote repo) else "" in
    (* Get PR metadata *)
    let meta_cmd = Printf.sprintf
      "cd %s && gh pr view %d%s --json title,body,state,files,reviews,comments,additions,deletions 2>&1"
      (Filename.quote root) pr_number repo_flag in
    let st_meta, out_meta =
      Process_eio.run_argv_with_status ~timeout_sec:15.0
        [ "/bin/zsh"; "-lc"; meta_cmd ] in
    (* Get PR diff (truncated) *)
    let diff_cmd = Printf.sprintf
      "cd %s && gh pr diff %d%s 2>&1 | head -c %d"
      (Filename.quote root) pr_number repo_flag Common.max_tool_output_bytes in
    let st_diff, out_diff =
      Process_eio.run_argv_with_status ~timeout_sec:15.0
        [ "/bin/zsh"; "-lc"; diff_cmd ] in
    let diff_truncated = String.length out_diff >= Common.max_tool_output_bytes in
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool (st_meta = Unix.WEXITED 0)
          ; "pr_number", `Int pr_number
          ; "metadata", `String out_meta
          ; "diff", `String out_diff
          ; "diff_truncated", `Bool diff_truncated
          ; "diff_status", `Bool (st_diff = Unix.WEXITED 0)
          ])
;;

let handle_keeper_pr_review_comment
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let pr_number = Safe_ops.json_int ~default:0 "pr_number" args in
  let body = Safe_ops.json_string ~default:"" "body" args |> String.trim in
  let event = Safe_ops.json_string ~default:"COMMENT" "event" args |> String.trim |> String.uppercase_ascii in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required."
  else if body = "" then
    error_json "body is required."
  else if not (List.mem event ["COMMENT"; "APPROVE"; "REQUEST_CHANGES"]) then
    error_json "event must be COMMENT, APPROVE, or REQUEST_CHANGES."
  else
    (* Check preset: requires delivery/coding/full for mutations *)
    let preset_ok =
      match Keeper_types.tool_access_preset meta.tool_access with
      | Some (Delivery | Coding | Full) -> true
      | _ -> false
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String "keeper_pr_review_comment requires delivery, coding, or full preset"
          ])
    else
      let root = Keeper_alerting_path.project_root_of_config config in
      let repo_flag = if repo <> "" then Printf.sprintf " -R %s" (Filename.quote repo) else "" in
      (* Use gh pr review to create a review *)
      let cmd = Printf.sprintf
        "cd %s && gh pr review %d%s --body %s %s 2>&1"
        (Filename.quote root) pr_number repo_flag
        (Filename.quote body)
        (match event with
         | "APPROVE" -> "--approve"
         | "REQUEST_CHANGES" -> "--request-changes"
         | _ -> "--comment") in
      let st, out =
        Process_eio.run_argv_with_status ~timeout_sec:30.0
          [ "/bin/zsh"; "-lc"; cmd ] in
      Log.Keeper.info "pr_review_comment: pr=%d event=%s keeper=%s ok=%b"
        pr_number event meta.name (st = Unix.WEXITED 0);
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool (st = Unix.WEXITED 0)
            ; "pr_number", `Int pr_number
            ; "event", `String event
            ; "output", `String out
            ; "keeper", `String meta.name
            ])
;;

let handle_keeper_pr_review_reply
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let pr_number = Safe_ops.json_int ~default:0 "pr_number" args in
  let comment_id = Safe_ops.json_int ~default:0 "comment_id" args in
  let body = Safe_ops.json_string ~default:"" "body" args |> String.trim in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required."
  else if comment_id = 0 then
    error_json "comment_id is required."
  else if body = "" then
    error_json "body is required."
  else
    let preset_ok =
      match Keeper_types.tool_access_preset meta.tool_access with
      | Some (Delivery | Coding | Full) -> true
      | _ -> false
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String "keeper_pr_review_reply requires delivery, coding, or full preset"
          ])
    else
      let root = Keeper_alerting_path.project_root_of_config config in
      (* Determine owner/repo *)
      let owner_repo =
        if repo <> "" then repo
        else
          let st, out =
            Process_eio.run_argv_with_status ~timeout_sec:5.0
              [ "/bin/zsh"; "-lc";
                Printf.sprintf "cd %s && gh repo view --json nameWithOwner -q .nameWithOwner 2>&1"
                  (Filename.quote root) ] in
          if st = Unix.WEXITED 0 then String.trim out else ""
      in
      if owner_repo = "" then
        error_json "Could not determine repository. Provide repo parameter."
      else
        let cmd = Printf.sprintf
          "cd %s && gh api repos/%s/pulls/comments/%d/replies -f body=%s 2>&1"
          (Filename.quote root)
          owner_repo comment_id
          (Filename.quote body) in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec:15.0
            [ "/bin/zsh"; "-lc"; cmd ] in
        Log.Keeper.info "pr_review_reply: pr=%d comment=%d keeper=%s ok=%b"
          pr_number comment_id meta.name (st = Unix.WEXITED 0);
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (st = Unix.WEXITED 0)
              ; "pr_number", `Int pr_number
              ; "comment_id", `Int comment_id
              ; "output", `String out
              ; "keeper", `String meta.name
              ])
;;
