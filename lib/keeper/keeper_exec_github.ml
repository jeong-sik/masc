open Keeper_types
open Keeper_exec_shared

let handle_keeper_github
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let cmd = Safe_ops.json_string ~default:"" "cmd" args |> String.trim in
  let gh_args = Safe_ops.json_string_list "args" args in
  let timeout_sec =
    Safe_ops.json_float ~default:30.0 "timeout_sec" args |> fun n -> max 1.0 (min 180.0 n)
  in
  let gh_raw =
    if cmd <> "" then cmd else if gh_args <> [] then String.concat " " gh_args else ""
  in
  if gh_raw = ""
  then error_json "cmd_or_args_required"
  else (
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
      let preset_allows_workflow =
        match Keeper_types.tool_access_preset meta.tool_access with
        | Some (Coding | Full) -> true
        | _ -> false
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
      else (
        let gh_cmd =
          if cmd <> ""
          then "gh " ^ cmd
          else "gh " ^ String.concat " " (List.map Filename.quote gh_args)
        in
        let root = Keeper_alerting_path.project_root_of_config config in
        let shell_cmd = Printf.sprintf "cd %s && %s 2>&1" (Filename.quote root) gh_cmd in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec [ "/bin/zsh"; "-lc"; shell_cmd ]
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (st = Unix.WEXITED 0)
              ; "status", Keeper_alerting_path.process_status_to_json st
              ; "output", `String (Keeper_alerting_path.truncate_tool_output out)
              ])))
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
  if branch = "" then error_json "branch_required"
  else if file_path = "" then error_json "file_path_required"
  else if commit_message = "" then error_json "commit_message_required"
  else if pr_title = "" then error_json "pr_title_required"
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
      (* Sanitize branch/task_id: reject path traversal chars *)
      let safe_name s =
        String.to_seq s
        |> Seq.filter (fun c ->
          (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '/')
        |> String.of_seq
      in
      let branch_safe = safe_name branch in
      if branch_safe <> branch then
        error_json "branch_contains_invalid_chars"
      else
      let root = Keeper_alerting_path.project_root_of_config config in
      let task_id = Printf.sprintf "pr-%s"
        (safe_name (String.sub branch 0 (min 20 (String.length branch)))) in
      let agent_name = Printf.sprintf "keeper-%s"
        (safe_name (strip_keeper_prefix meta.name)) in
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
      (* Step 1: Create worktree *)
      let worktree_path = ref "" in
      let _s1 = run_step "worktree_create" (fun () ->
        match Room.worktree_create_r config ~agent_name ~task_id ~base_branch with
        | Ok msg ->
          (* Derive worktree path from known naming convention, then verify it exists *)
          let wt_dir = Filename.concat root
            (Printf.sprintf ".worktrees/%s-%s" agent_name task_id) in
          if Sys.file_exists wt_dir && Sys.is_directory wt_dir then begin
            worktree_path := wt_dir;
            Ok msg
          end else
            Error (Printf.sprintf "worktree created but path not found: %s" wt_dir)
        | Error e -> Error (Types.masc_error_to_string e)
      ) in
      (* Step 2: Write file — with path traversal guard *)
      let _s2 = run_step "file_write" (fun () ->
        if !worktree_path = "" then Error "no worktree path"
        else begin
          let abs_path = Filename.concat !worktree_path file_path in
          (* Resolve symlinks and normalize to catch ../.. traversal *)
          let canonical =
            try Some (Unix.realpath abs_path)
            with Unix.Unix_error _ ->
              (* File doesn't exist yet: check parent dir *)
              try
                let parent = Unix.realpath (Filename.dirname abs_path) in
                Some (Filename.concat parent (Filename.basename abs_path))
              with Unix.Unix_error _ -> None
          in
          match canonical with
          | None -> Error (Printf.sprintf "cannot resolve path: %s" file_path)
          | Some resolved ->
            if not (String.starts_with ~prefix:(!worktree_path ^ "/") resolved) then
              Error (Printf.sprintf "path escapes worktree boundary: %s" file_path)
            else begin
              try
                let dir = Filename.dirname resolved in
                Fs_compat.mkdir_p dir;
                Fs_compat.save_file resolved file_content;
                Ok (Printf.sprintf "wrote %d bytes to %s" (String.length file_content) file_path)
              with exn -> Error (Printexc.to_string exn)
            end
        end
      ) in
      (* Pre-commit: Version truth check guard *)
      let _s_ver = run_step "version_truth_check" (fun () ->
        if !worktree_path = "" then Error "no worktree path"
        else begin
          let check_cmd = Printf.sprintf "cd %s && ./scripts/check-version-truth.sh 2>&1" (Filename.quote !worktree_path) in
          let st, out = Process_eio.run_argv_with_status ~timeout_sec:10.0 [ "/bin/zsh"; "-lc"; check_cmd ] in
          if st <> Unix.WEXITED 0 then
            Error (Printf.sprintf "Version truth check failed (run scripts/bump-version.sh instead of editing dune-project manually): %s" out)
          else Ok "version truth OK"
        end
      ) in

      (* Step 3: Git add + commit + push *)
      let _s3 = run_step "git_commit_push" (fun () ->
        if !worktree_path = "" then Error "no worktree path"
        else begin
          let run_git cmd =
            let shell = Printf.sprintf "cd %s && git %s 2>&1"
              (Filename.quote !worktree_path) cmd in
            Process_eio.run_argv_with_status ~timeout_sec:30.0
              [ "/bin/zsh"; "-lc"; shell ]
          in
          let st_add, out_add = run_git (Printf.sprintf "add %s" (Filename.quote file_path)) in
          if st_add <> Unix.WEXITED 0 then
            Error (Printf.sprintf "git add: %s" out_add)
          else begin
            let st_commit, out_commit = run_git
              (Printf.sprintf "commit -m %s" (Filename.quote commit_message)) in
            if st_commit <> Unix.WEXITED 0 then
              Error (Printf.sprintf "git commit: %s" out_commit)
            else begin
              let st_push, out_push = run_git
                (Printf.sprintf "push -u origin %s" (Filename.quote branch)) in
              if st_push <> Unix.WEXITED 0 then
                Error (Printf.sprintf "git push: %s" out_push)
              else
                Ok "committed and pushed"
            end
          end
        end
      ) in
      (* Step 4: Create draft PR — run from worktree for correct branch context *)
      let pr_url = ref "" in
      let _s4 = run_step "gh_pr_create" (fun () ->
        let body = if pr_body = "" then pr_title else pr_body in
        let gh_cmd = Printf.sprintf
          "cd %s && gh pr create --draft --title %s --body %s --base %s 2>&1"
          (Filename.quote !worktree_path) (Filename.quote pr_title) (Filename.quote body)
          (Filename.quote base_branch) in
        let st, out =
          Process_eio.run_argv_with_status ~timeout_sec:30.0
            [ "/bin/zsh"; "-lc"; gh_cmd ] in
        if st <> Unix.WEXITED 0 then
          Error (Printf.sprintf "gh pr create: %s" out)
        else begin
          pr_url := String.trim out;
          Ok (Printf.sprintf "PR created: %s" (String.trim out))
        end
      ) in
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool !step_ok
          ; "steps", `String (Buffer.contents steps)
          ; "pr_url", `String !pr_url
          ; "error", `String !step_error
          ; "keeper", `String meta.name
          ])
;;

