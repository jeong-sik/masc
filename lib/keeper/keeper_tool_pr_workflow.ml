(** Keeper PR workflow tool — multi-step PR creation handler.

    Extracted from keeper_exec_github.ml (god file decomp Step 2).
    Depends on Keeper_gh_shared for cache/parsers/output utilities. *)

open Keeper_types
open Keeper_exec_shared
let handle_keeper_pr_workflow
      ~(config : Coord.config)
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
        match Coord_git.git_root ~base_path:root with
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
        if not (Coord_git.is_git_repo ~base_path:root) then
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
            match Coord_git.resolve_base_branch repo_root base_branch with
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

