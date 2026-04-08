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
  then error_json "cmd is required. \
                   Good: cmd='pr list --state open'. Bad: cmd=''. \
                   Single gh subcommand only, no chaining."
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
              ; "output", `String out
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
      let run_sh ~cwd ~timeout_sec cmd =
        let shell = Printf.sprintf "cd %s && %s 2>&1"
          (Filename.quote cwd) cmd in
        Process_eio.run_argv_with_status ~timeout_sec
          [ "/bin/zsh"; "-lc"; shell ]
      in
      (* Step 1: Shallow clone into keeper playground.
         Fully isolated from main repo — no shared git index. *)
      let clone_dir = ref "" in
      let _s1 = run_step "playground_clone" (fun () ->
        let playground = Filename.concat root
          (Keeper_alerting_path.playground_path_of_keeper meta.name) in
        Fs_compat.mkdir_p playground;
        let repo_name = Filename.basename root in
        let clone_path = Filename.concat playground repo_name in
        (* Clean up any previous clone *)
        if Sys.file_exists clone_path then begin
          let st, _ = run_sh ~cwd:playground ~timeout_sec:10.0
            (Printf.sprintf "rm -rf %s" (Filename.quote repo_name)) in
          if st <> Unix.WEXITED 0 then
            Log.Keeper.warn "pr_workflow: failed to clean previous clone at %s" clone_path
        end;
        (* Shallow clone with single branch for speed *)
        let origin_url =
          let st, out = run_sh ~cwd:root ~timeout_sec:5.0
            "git remote get-url origin" in
          if st = Unix.WEXITED 0 then String.trim out
          else root (* fallback to local path *)
        in
        let st, out = run_sh ~cwd:playground ~timeout_sec:120.0
          (Printf.sprintf "git clone --depth 1 --branch %s %s %s"
            (Filename.quote base_branch)
            (Filename.quote origin_url)
            (Filename.quote repo_name)) in
        if st <> Unix.WEXITED 0 then
          Error (Printf.sprintf "git clone: %s" out)
        else begin
          clone_dir := clone_path;
          (* Create the feature branch *)
          let st2, out2 = run_sh ~cwd:clone_path ~timeout_sec:5.0
            (Printf.sprintf "git checkout -b %s" (Filename.quote branch)) in
          if st2 <> Unix.WEXITED 0 then
            Error (Printf.sprintf "git checkout -b: %s" out2)
          else
            Ok (Printf.sprintf "cloned to %s, branch %s" clone_path branch)
        end
      ) in
      (* Step 2: Write file — with path traversal guard *)
      let _s2 = run_step "file_write" (fun () ->
        if !clone_dir = "" then Error "no clone path"
        else begin
          let abs_path = Filename.concat !clone_dir file_path in
          let canonical =
            try Some (Unix.realpath abs_path)
            with Unix.Unix_error _ ->
              try
                let parent = Unix.realpath (Filename.dirname abs_path) in
                Some (Filename.concat parent (Filename.basename abs_path))
              with Unix.Unix_error _ -> None
          in
          match canonical with
          | None -> Error (Printf.sprintf "cannot resolve path: %s" file_path)
          | Some resolved ->
            if not (String.starts_with ~prefix:(!clone_dir ^ "/") resolved) then
              Error (Printf.sprintf "path escapes clone boundary: %s" file_path)
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
        if !clone_dir = "" then Error "no clone path"
        else begin
          let check_cmd = Printf.sprintf "cd %s && ./scripts/check-version-truth.sh 2>&1"
            (Filename.quote !clone_dir) in
          let st, out = Process_eio.run_argv_with_status ~timeout_sec:10.0
            [ "/bin/zsh"; "-lc"; check_cmd ] in
          if st <> Unix.WEXITED 0 then
            Error (Printf.sprintf "Version truth check failed: %s" out)
          else Ok "version truth OK"
        end
      ) in
      (* Step 3: Git add + commit + push *)
      let _s3 = run_step "git_commit_push" (fun () ->
        if !clone_dir = "" then Error "no clone path"
        else begin
          let run_git cmd = run_sh ~cwd:(!clone_dir) ~timeout_sec:30.0
            (Printf.sprintf "git %s" cmd) in
          let st_add, out_add = run_git
            (Printf.sprintf "add %s" (Filename.quote file_path)) in
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
      (* Step 4: Create draft PR *)
      let pr_url = ref "" in
      let _s4 = run_step "gh_pr_create" (fun () ->
        if !clone_dir = "" then Error "no clone path"
        else begin
          let body = if pr_body = "" then pr_title else pr_body in
          let gh_cmd = Printf.sprintf
            "cd %s && gh pr create --draft --title %s --body %s --base %s 2>&1"
            (Filename.quote !clone_dir) (Filename.quote pr_title) (Filename.quote body)
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
        end
      ) in
      (* Step 5: Clean up clone *)
      (if !clone_dir <> "" && Sys.file_exists !clone_dir then begin
        let st, _ = run_sh ~cwd:(Filename.dirname !clone_dir) ~timeout_sec:10.0
          (Printf.sprintf "rm -rf %s" (Filename.quote (Filename.basename !clone_dir))) in
        if st <> Unix.WEXITED 0 then
          Log.Keeper.warn "pr_workflow: failed to clean clone at %s" !clone_dir
      end);
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool !step_ok
          ; "steps", `String (Buffer.contents steps)
          ; "pr_url", `String !pr_url
          ; "error", `String !step_error
          ; "keeper", `String meta.name
          ])
;;

