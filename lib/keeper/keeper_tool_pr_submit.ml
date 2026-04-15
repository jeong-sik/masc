(** Keeper PR submit tool — submits an already-prepared PR.

    Extracted from keeper_exec_github.ml (god file decomp Step 3). *)

open Keeper_types
open Keeper_exec_shared
open Keeper_gh_shared
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

