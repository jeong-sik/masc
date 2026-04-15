(** Tests for keeper_pr_workflow validation gates.

    Covers:
    1. Required field validation (branch, file_path, commit_message, pr_title)
    2. Preset gate (social/research → rejected, delivery/coding/full → accepted)
    3. Branch name sanitization (reject shell metacharacters)
    4. Worktree step failure propagation (no remote → clean error)

    Does NOT test: actual git push / gh pr create (requires real remote). *)

open Alcotest
open Masc_mcp

let fresh_nonce =
  let counter = ref 0 in
  fun () ->
    incr counter;
    Printf.sprintf "%d-%d-%d"
      (Unix.getpid ())
      (int_of_float (Unix.gettimeofday () *. 1_000_000.))
      !counter

let make_meta_with_preset preset_str =
  match Keeper_types.meta_of_json
    (`Assoc
      [ "name", `String "test-keeper"
      ; "agent_name", `String "test-keeper"
      ; "trace_id", `String "test-trace-pr"
      ; "tool_access", `Assoc
          [ "kind", `String "preset"
          ; "preset", `String preset_str
          ; "also_allow", `List []
          ]
      ]) with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta_with_preset('%s') failed: %s" preset_str e)

let make_ctx_work () =
  Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let write_text_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file path content

let run_cmd_exn argv =
  let cmd = String.concat " " (List.map Filename.quote argv) in
  match Sys.command cmd with
  | 0 -> ()
  | code -> failwith (Printf.sprintf "command failed (%d): %s" code cmd)

let run_cmd argv =
  let cmd = String.concat " " (List.map Filename.quote argv) in
  Sys.command cmd

let policy_init_once = lazy (
  let repo_root = Masc_test_deps.find_project_root () in
  Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path:repo_root)
)

let repo_root = lazy (Masc_test_deps.find_project_root ())

let with_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Lazy.force policy_init_once;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_pr_%s" (fresh_nonce ())) in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Process_eio.reset_for_testing ();
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / dir)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  let saved_pg = Sys.getenv_opt "MASC_POSTGRES_URL" in
  let saved_sb = Sys.getenv_opt "SB_PG_URL" in
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "SB_PG_URL" "";
  Fun.protect
    ~finally:(fun () ->
      (match saved_pg with
       | Some v -> Unix.putenv "MASC_POSTGRES_URL" v
       | None -> (try Unix.putenv "MASC_POSTGRES_URL" "" with _ -> ()));
      (match saved_sb with
       | Some v -> Unix.putenv "SB_PG_URL" v
       | None -> (try Unix.putenv "SB_PG_URL" "" with _ -> ()));
      (match saved_base with
       | Some v -> Unix.putenv "MASC_BASE_PATH" v
       | None -> (try Unix.putenv "MASC_BASE_PATH" "" with _ -> ()));
      Process_eio.reset_for_testing ();
      (try rm_rf dir with _ -> ()))
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" dir;
      let config = Coord.default_config dir in
      let _msg = Coord.init config ~agent_name:(Some "test-keeper") in
      f config)

let call_tool config meta name input =
  let ctx_work = make_ctx_work () in
  Keeper_exec_tools.execute_keeper_tool_call
    ~config ~meta ~ctx_work ~name ~input ()

let parse_json s =
  try Yojson.Safe.from_string s
  with _ -> failwith (Printf.sprintf "invalid JSON: %s" s)

let json_string key json =
  Yojson.Safe.Util.(member key json |> to_string)

let json_bool key json =
  Yojson.Safe.Util.(member key json |> to_bool)

let json_float key json =
  Yojson.Safe.Util.(member key json |> to_float)

(* --- Required field validation --- *)

let valid_pr_args =
  `Assoc
    [ "branch", `String "test-branch"
    ; "file_path", `String "src/test.ml"
    ; "file_content", `String "let x = 1"
    ; "commit_message", `String "test commit"
    ; "pr_title", `String "Test PR"
    ]

let test_missing_branch () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String ""
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions branch"
      true (String_util.contains_substring_ci err "branch"))

let test_missing_file_path () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test-branch"
      ; "file_path", `String ""
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions file_path"
      true (String_util.contains_substring_ci err "file_path"))

let test_missing_commit_message () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test-branch"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String ""
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions commit_message"
      true (String_util.contains_substring_ci err "commit_message"))

let test_missing_pr_title () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test-branch"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String ""
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions pr_title"
      true (String_util.contains_substring_ci err "pr_title"))

(* --- Preset gate --- *)

(* Preset rejection can happen at two layers:
   1. Tool policy layer: tool_not_allowed (tool not in preset's allowed list)
   2. Function-level: preset_insufficient (inside handle_keeper_pr_workflow)
   Either indicates correct rejection. *)
let is_rejected json =
  let error = try json_string "error" json with _ -> "" in
  let ok = try json_bool "ok" json with _ -> false in
  (not ok) && (error = "tool_not_allowed" || error = "preset_insufficient")

let test_social_preset_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "social" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    check bool "social preset rejected" true (is_rejected json))

let test_research_preset_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "research" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    check bool "research preset rejected" true (is_rejected json))

let test_minimal_preset_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "minimal" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    check bool "minimal preset rejected" true (is_rejected json))

let test_delivery_preset_passes_validation () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    (* Delivery passes preset gate. Fails at worktree step since test room
       is not a git repo, but that means validation passed. *)
    let error = json_string "error" json in
    check bool "error is NOT preset_insufficient"
      true (error <> "preset_insufficient"))

let test_coding_preset_passes_validation () =
  with_room (fun config ->
    let meta = make_meta_with_preset "coding" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    let error = json_string "error" json in
    check bool "error is NOT preset_insufficient"
      true (error <> "preset_insufficient"))

let test_full_preset_passes_validation () =
  with_room (fun config ->
    let meta = make_meta_with_preset "full" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    let error = json_string "error" json in
    check bool "error is NOT preset_insufficient"
      true (error <> "preset_insufficient"))

(* --- Branch name sanitization --- *)

let test_branch_with_semicolon_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test;rm -rf /"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions invalid chars"
      true (String_util.contains_substring_ci err "invalid"))

let test_branch_with_pipe_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test|cat /etc/passwd"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions invalid chars"
      true (String_util.contains_substring_ci err "invalid"))

let test_branch_with_backtick_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test`whoami`"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions invalid chars"
      true (String_util.contains_substring_ci err "invalid"))

let test_branch_with_dot_dot_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "../../etc/passwd"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions invalid chars"
      true (String_util.contains_substring_ci err "invalid"))

let test_branch_with_space_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test branch"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions invalid chars"
      true (String_util.contains_substring_ci err "invalid"))

let test_branch_with_dollar_paren_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test$(whoami)"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions invalid chars"
      true (String_util.contains_substring_ci err "invalid"))

let test_branch_with_ampersand_rejected () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "test&&echo pwned"
      ; "file_path", `String "src/test.ml"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let err = json_string "error" json in
    check bool "error mentions invalid chars"
      true (String_util.contains_substring_ci err "invalid"))

let test_valid_branch_with_slash_accepted () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "feature/my-branch_123"
      ; "file_path", `String "src/test.ml"
      ; "file_content", `String "let x = 1"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    let error = json_string "error" json in
    (* Should pass branch validation, fail at worktree step *)
    check bool "error is NOT branch_contains_invalid_chars"
      true (error <> "branch_contains_invalid_chars"))

(* --- Branch slash → worktree id hyphen conversion --- *)

let test_branch_slash_converted_to_hyphen_in_worktree_id () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc
      [ "branch", `String "fix/cascade-glm-auto-model"
      ; "file_path", `String "src/test.ml"
      ; "file_content", `String "let x = 1"
      ; "commit_message", `String "msg"
      ; "pr_title", `String "title"
      ] in
    let result = call_tool config meta "keeper_pr_workflow" args in
    let json = parse_json result in
    (* Branch validation should pass (slash is valid in branch names).
       The derived worktree path should replace slashes with hyphens, so the
       failure (in a non-git room) must happen at worktree_create, not path
       validation. *)
    let error = json_string "error" json in
    check bool "error does NOT mention path separators"
      false (String_util.contains_substring_ci error "path separator"))

(* --- Worktree step failure propagation --- *)

let test_worktree_failure_propagates () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result = call_tool config meta "keeper_pr_workflow" valid_pr_args in
    let json = parse_json result in
    (* Test room is not a git repo, so worktree_create fails.
       The result should be ok=false with a meaningful error. *)
    check bool "ok is false" false (json_bool "ok" json);
    let steps = json_string "steps" json in
    check bool "steps contains worktree_create"
      true (try ignore (Str.search_forward
        (Str.regexp_string "worktree_create") steps 0); true
        with Not_found -> false);
    let error = json_string "error" json in
    check bool "error mentions worktree or git repo"
      true (try ignore (Str.search_forward
        (Str.regexp "worktree\\|git repository") (String.lowercase_ascii error) 0); true
        with Not_found -> false))

(* --- Task lifecycle: claim → done --- *)

let test_task_claim_then_done_lifecycle () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    (* Add a task *)
    let _ = Coord.add_task config ~title:"Lifecycle test" ~priority:1 ~description:"test" in
    (* Claim it — response is {"result": "string"} *)
    let claim_result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let claim_json = parse_json claim_result in
    let result_str = json_string "result" claim_json in
    check bool "claim returns non-empty result" true (String.length result_str > 0);
    (* Extract task_id from result string *)
    let task_id =
      let re_task = Re.(compile (seq [str "task-"; rep1 (alt [digit; char '-'])])) in
      let re_t = Re.(compile (seq [char 'T'; char '-'; rep1 digit])) in
      match Re.exec_opt re_task result_str with
      | Some g -> Re.Group.get g 0
      | None ->
        match Re.exec_opt re_t result_str with
        | Some g -> Re.Group.get g 0
        | None -> failwith (Printf.sprintf "cannot extract task_id from: %s" result_str)
    in
    (* Mark it done — response is {"ok": bool, "result": "string"} *)
    let done_result = call_tool config meta "keeper_task_done"
      (`Assoc [("task_id", `String task_id);
               ("result", `String "completed by lifecycle test")]) in
    let done_json = parse_json done_result in
    let done_ok = try json_bool "ok" done_json with _ -> false in
    check bool "done succeeds" true done_ok)

(* --- Task duplicate claim prevention --- *)

let test_second_claim_on_single_task_returns_no_tasks () =
  with_room (fun config ->
    let meta_a = make_meta_with_preset "delivery" in
    let meta_b =
      match Keeper_types.meta_of_json
        (`Assoc
          [ "name", `String "other-keeper"
          ; "agent_name", `String "other-keeper"
          ; "trace_id", `String "test-trace-other"
          ; "tool_access", `Assoc
              [ "kind", `String "preset"
              ; "preset", `String "delivery"
              ; "also_allow", `List []
              ]
          ]) with
      | Ok m -> m
      | Error e -> failwith e
    in
    (* Add exactly one task *)
    let _ = Coord.add_task config ~title:"Single task" ~priority:1 ~description:"test" in
    (* Keeper A claims it *)
    let _ = call_tool config meta_a "keeper_task_claim" (`Assoc []) in
    (* Keeper B tries to claim — response is {"result": "string"} *)
    let result_b = call_tool config meta_b "keeper_task_claim" (`Assoc []) in
    let json_b = parse_json result_b in
    let result_str = json_string "result" json_b in
    (* The result should indicate no unclaimed tasks available *)
    let lower = String.lowercase_ascii result_str in
    check bool "second claim indicates no unclaimed tasks"
      true (try ignore (Str.search_forward
        (Str.regexp_string "no unclaimed") lower 0); true
        with Not_found ->
          try ignore (Str.search_forward
            (Str.regexp_string "nothing to claim") lower 0); true
          with Not_found ->
            try ignore (Str.search_forward
              (Str.regexp_string "no tasks") lower 0); true
            with Not_found -> false))

(* --- Integration: worktree workflow on real git repo --- *)

(** Run a test using the actual masc-mcp repo root as the room base_path.
    This exercises the real worktree path instead of the temp-dir
    fallback that non-git rooms hit. *)
let with_real_repo_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Lazy.force policy_init_once;
  let repo_root =
    let cwd = Sys.getcwd () in
    if Sys.file_exists (Filename.concat cwd ".git") then cwd
    else
      let rec go d =
        if d = "/" then failwith "cannot find .git repo root"
        else if Sys.file_exists (Filename.concat d ".git") then d
        else go (Filename.dirname d)
      in
      go (Filename.dirname cwd)
  in
  let saved_pg = Sys.getenv_opt "MASC_POSTGRES_URL" in
  let saved_sb = Sys.getenv_opt "SB_PG_URL" in
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "SB_PG_URL" "";
  Fun.protect
    ~finally:(fun () ->
      (match saved_pg with Some v -> Unix.putenv "MASC_POSTGRES_URL" v | None -> ());
      (match saved_sb with Some v -> Unix.putenv "SB_PG_URL" v | None -> ());
      (match saved_base with Some v -> Unix.putenv "MASC_BASE_PATH" v | None -> Unix.putenv "MASC_BASE_PATH" ""))
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" repo_root;
      let config = Coord.default_config repo_root in
      (* Coord may already be initialized in the real repo *)
      (try ignore (Coord.init config ~agent_name:(Some "test-integration")) with _ -> ());
      f config repo_root)

let with_local_git_repo_room f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Lazy.force policy_init_once;
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_keeper_pr_git_%s" (fresh_nonce ())) in
  let remote_dir = Filename.concat dir ".remote.git" in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let saved_pg = Sys.getenv_opt "MASC_POSTGRES_URL" in
  let saved_sb = Sys.getenv_opt "SB_PG_URL" in
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_POSTGRES_URL" "";
  Unix.putenv "SB_PG_URL" "";
  Fun.protect
    ~finally:(fun () ->
      (match saved_pg with Some v -> Unix.putenv "MASC_POSTGRES_URL" v | None -> ());
      (match saved_sb with Some v -> Unix.putenv "SB_PG_URL" v | None -> ());
      (match saved_base with Some v -> Unix.putenv "MASC_BASE_PATH" v | None -> Unix.putenv "MASC_BASE_PATH" "");
      (try rm_rf dir with _ -> ()))
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" dir;
      write_text_file (Filename.concat dir "README.md") "# local keeper_pr_workflow test\n";
      write_text_file (Filename.concat dir "CHANGELOG.md")
        "# Changelog\n\n## [0.1.0] - 2026-04-08\n";
      write_text_file (Filename.concat dir "ROADMAP.md")
        "> Current package version: v0.1.0\n> Latest release: v0.1.0\n";
      write_text_file (Filename.concat dir "dune-project")
        "(lang dune 3.11)\n(name masc_mcp)\n(version 0.1.0)\n(generate_opam_files true)\n";
      write_text_file (Filename.concat dir "masc_mcp.opam")
        "# This file is generated by dune\nversion: \"0.1.0\"\n";
      let truth_script = Filename.concat dir "scripts/check-version-truth.sh" in
      write_text_file truth_script "#!/usr/bin/env bash\nset -euo pipefail\necho 'truth ok'\n";
      Unix.chmod truth_script 0o644;
      run_cmd_exn [ "git"; "init"; "-b"; "main"; dir ];
      run_cmd_exn [ "git"; "-C"; dir; "config"; "user.email"; "keeper-pr@example.test" ];
      run_cmd_exn [ "git"; "-C"; dir; "config"; "user.name"; "Keeper PR Test" ];
      run_cmd_exn [ "git"; "-C"; dir; "add"; "." ];
      run_cmd_exn [ "git"; "-C"; dir; "commit"; "-m"; "init" ];
      run_cmd_exn [ "git"; "init"; "--bare"; remote_dir ];
      run_cmd_exn [ "git"; "-C"; dir; "remote"; "add"; "origin"; remote_dir ];
      run_cmd_exn [ "git"; "-C"; dir; "push"; "-u"; "origin"; "main" ];
      run_cmd_exn [ "git"; "-C"; dir; "fetch"; "origin" ];
      let config = Coord.default_config dir in
      ignore (Coord.init config ~agent_name:(Some "test-local-git"));
      f config dir)

let derive_worktree_id keeper_name branch =
  branch
  |> String.to_seq
  |> Seq.map (fun c -> if c = '/' || c = '\\' then '-' else c)
  |> String.of_seq
  |> Printf.sprintf "%s-%s" keeper_name

let seed_playground_clone config keeper_name source_repo =
  let project_root = Keeper_alerting_path.project_root_of_config config in
  let repos_dir =
    Filename.concat project_root (Keeper_alerting_path.playground_repos_path keeper_name)
  in
  Fs_compat.mkdir_p repos_dir;
  let clone_path = Filename.concat repos_dir (Filename.basename source_repo) in
  if Sys.file_exists clone_path then rm_rf clone_path;
  run_cmd_exn [ "git"; "clone"; source_repo; clone_path ];
  (* Replace origin with a local bare repo so git-push succeeds locally
     but gh-pr-create fails harmlessly — prevents real PRs leaking to GitHub. *)
  let local_bare = clone_path ^ ".bare" in
  if Sys.file_exists local_bare then rm_rf local_bare;
  run_cmd_exn [ "git"; "init"; "--bare"; local_bare ];
  run_cmd_exn [ "git"; "-C"; clone_path; "remote"; "set-url"; "origin"; local_bare ];
  (* Ensure main branch exists (clone from worktree may default to another branch) *)
  ignore (run_cmd [ "git"; "-C"; clone_path; "checkout"; "-B"; "main" ]);
  run_cmd_exn [ "git"; "-C"; clone_path; "push"; "-u"; "origin"; "main" ];
  clone_path

let cleanup_test_branch repo_root branch =
  ignore (Sys.command
    (Printf.sprintf "cd %s && git worktree prune >/dev/null 2>&1 && git branch -D %s >/dev/null 2>&1"
      (Filename.quote repo_root) (Filename.quote branch)));
  ignore (Sys.command
    (Printf.sprintf "cd %s && git push origin --delete %s >/dev/null 2>&1"
      (Filename.quote repo_root) (Filename.quote branch)))

let test_worktree_create_writes_and_cleans_up () =
  with_real_repo_room (fun config repo_root ->
    let meta = make_meta_with_preset "delivery" in
    let workflow_root = seed_playground_clone config meta.name repo_root in
    let test_branch = Printf.sprintf "test/integration-%s" (fresh_nonce ()) in
    let pushed = ref false in
    Fun.protect
      ~finally:(fun () ->
        if !pushed then cleanup_test_branch workflow_root test_branch;
        try rm_rf workflow_root with _ -> ())
      (fun () ->
        let args = `Assoc
          [ "branch", `String test_branch
          ; "file_path", `String "test-integration-verify.txt"
          ; "file_content", `String "integration test content"
          ; "commit_message", `String "test: integration verify worktree workflow"
          ; "pr_title", `String "test: integration verify"
          ] in
        let result = call_tool config meta "keeper_pr_workflow" args in
        let json = parse_json result in
        let steps = json_string "steps" json in
        let error = json_string "error" json in
        check bool "worktree_create step present"
          true (String_util.contains_substring_ci steps "worktree_create");
        check bool "worktree_create ok"
          true (String_util.contains_substring_ci steps "worktree_create: ok");
        check bool "file_write ok"
          true (String_util.contains_substring_ci steps "file_write: ok");
        let reached_post_write_gate =
          String_util.contains_substring_ci steps "version_truth_check: ok"
          || String_util.contains_substring_ci error "version truth check failed"
          || String_util.contains_substring_ci steps "git_commit_push: ok"
          || String_util.contains_substring_ci error "git push"
        in
        check bool "workflow reached post-write gate" true reached_post_write_gate;
        let worktree_id = derive_worktree_id meta.name test_branch in
        let worktree_path =
          Filename.concat workflow_root (Filename.concat ".worktrees" worktree_id)
        in
        check bool "worktree cleaned up"
          false (Sys.file_exists worktree_path);
        if String_util.contains_substring_ci steps "git_commit_push: ok"
        then pushed := true))

let test_existing_worktree_path_is_retried_safely () =
  with_real_repo_room (fun config repo_root ->
    let meta = make_meta_with_preset "delivery" in
    let workflow_root = seed_playground_clone config meta.name repo_root in
    let test_branch = Printf.sprintf "test/retry-%s" (fresh_nonce ()) in
    let worktree_id = derive_worktree_id meta.name test_branch in
    let worktree_path = Filename.concat workflow_root (Filename.concat ".worktrees" worktree_id) in
    Fun.protect
      ~finally:(fun () ->
        ignore (Sys.command
          (Printf.sprintf "cd %s && git worktree remove --force %s >/dev/null 2>&1"
            (Filename.quote workflow_root) (Filename.quote worktree_path)));
        cleanup_test_branch workflow_root test_branch;
        try rm_rf workflow_root with _ -> ())
      (fun () ->
        ignore (run_cmd [ "/usr/bin/git"; "-C"; workflow_root; "worktree"; "remove"; "--force"; worktree_path ]);
        cleanup_test_branch workflow_root test_branch;
        let seed_rc =
          run_cmd
            [ "/usr/bin/git"
            ; "-C"
            ; workflow_root
            ; "worktree"
            ; "add"
            ; "-b"
            ; test_branch
            ; worktree_path
            ; "HEAD"
            ]
        in
        check int "seed worktree created" 0 seed_rc;
        let args = `Assoc
          [ "branch", `String test_branch
          ; "file_path", `String "test-integration-retry.txt"
          ; "file_content", `String "integration retry content"
          ; "commit_message", `String "test: integration retry worktree workflow"
          ; "pr_title", `String "test: integration retry"
          ] in
        let result = call_tool config meta "keeper_pr_workflow" args in
        let json = parse_json result in
        let steps = json_string "steps" json in
        let error = json_string "error" json in
        check bool "worktree_create ok after retry"
          true (String_util.contains_substring_ci steps "worktree_create: ok");
        check bool "file_write ok after retry"
          true (String_util.contains_substring_ci steps "file_write: ok");
        let reached_post_write_gate =
          String_util.contains_substring_ci steps "version_truth_check: ok"
          || String_util.contains_substring_ci error "version truth check failed"
          || String_util.contains_substring_ci steps "git_commit_push: ok"
          || String_util.contains_substring_ci error "git push"
        in
        check bool "retry workflow reached post-write gate" true reached_post_write_gate;
        check bool "retry keeps pre-existing worktree intact"
          true (Sys.file_exists worktree_path)))

let test_local_repo_worktree_runs_truth_via_absolute_bash () =
  with_local_git_repo_room (fun config repo_root ->
    let meta = make_meta_with_preset "delivery" in
    let workflow_root = seed_playground_clone config meta.name repo_root in
    let test_branch = Printf.sprintf "test/local-%s" (fresh_nonce ()) in
    let worktree_id = derive_worktree_id meta.name test_branch in
    let worktree_path = Filename.concat workflow_root (Filename.concat ".worktrees" worktree_id) in
    Fun.protect
      ~finally:(fun () ->
        cleanup_test_branch workflow_root test_branch;
        try rm_rf workflow_root with _ -> ())
      (fun () ->
        let args = `Assoc
          [ "branch", `String test_branch
          ; "file_path", `String "README.md"
          ; "file_content", `String "# updated by keeper_pr_workflow\n"
          ; "commit_message", `String "test: local worktree workflow"
          ; "pr_title", `String "test: local worktree workflow"
          ] in
        let result = call_tool config meta "keeper_pr_workflow" args in
        let json = parse_json result in
        let steps = json_string "steps" json in
        let error = json_string "error" json in
        check bool "worktree_create ok in local repo"
          true (String_util.contains_substring_ci steps "worktree_create: ok");
        check bool "file_write ok in local repo"
          true (String_util.contains_substring_ci steps "file_write: ok");
        check bool "version truth ok via absolute bash"
          true (String_util.contains_substring_ci steps "version_truth_check: ok");
        check bool "git commit push ok in local repo"
          true (String_util.contains_substring_ci steps "git_commit_push: ok");
        check bool "gh pr create becomes terminal failure"
          true (String_util.contains_substring_ci error "gh pr create");
        check bool "local repo worktree cleaned up"
          false (Sys.file_exists worktree_path)))

(* --- keeper_bash branch-switch guard --- *)

let assert_branch_switch_allowed config cmd label =
  let meta = make_meta_with_preset "delivery" in
  let args = `Assoc [ "cmd", `String cmd ] in
  let result = call_tool config meta "keeper_bash" args in
  let json = parse_json result in
  let error = try json_string "error" json with _ -> "" in
  let has_status =
    match json with
    | `Assoc fields -> List.mem_assoc "status" fields
    | _ -> false
  in
  check bool (label ^ " not policy blocked")
    true (error <> "branch_switch_blocked" && has_status)

let assert_branch_switch_blocked config cmd label =
  let shared_repo_rel = "workspace/yousleepwhen/oas" in
  let shared_repo_abs =
    Filename.concat (Keeper_alerting_path.project_root_of_config config) shared_repo_rel
  in
  Fs_compat.mkdir_p shared_repo_abs;
  let meta =
    { (make_meta_with_preset "delivery") with
      allowed_paths = [ shared_repo_rel ^ "/" ] }
  in
  let args =
    `Assoc
      [ "cmd", `String cmd
      ; "cwd", `String shared_repo_abs
      ]
  in
  let result = call_tool config meta "keeper_bash" args in
  let json = parse_json result in
  let error = try json_string "error" json with _ -> "" in
  check string (label ^ " blocked") "branch_switch_blocked" error

let test_bash_git_checkout_blocked () =
  with_room (fun config ->
    assert_branch_switch_blocked config "git checkout refactor/some-branch" "checkout")

let test_bash_git_switch_blocked () =
  with_room (fun config ->
    assert_branch_switch_blocked config "git switch feature/x" "switch")

let test_bash_git_checkout_with_global_opts_blocked () =
  with_room (fun config ->
    assert_branch_switch_blocked config "git -C . checkout refactor/x" "checkout -C")

let test_bash_git_tab_separated_blocked () =
  with_room (fun config ->
    assert_branch_switch_blocked config "git\tcheckout feature/x" "tab checkout")

let test_bash_git_branch_create_blocked () =
  with_room (fun config ->
    assert_branch_switch_blocked config "git branch new-feature" "branch create")

let test_bash_git_branch_rename_blocked () =
  with_room (fun config ->
    assert_branch_switch_blocked config "git branch -m old-name new-name" "branch -m")

let test_bash_git_checkout_allowed_in_default_playground () =
  with_room (fun config ->
    assert_branch_switch_allowed config "git checkout refactor/some-branch"
      "checkout default playground")

let test_bash_git_branch_list_allowed () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc [ "cmd", `String "git branch --list" ] in
    let result = call_tool config meta "keeper_bash" args in
    let json = parse_json result in
    let error = try json_string "error" json with _ -> "" in
    check bool "git branch --list not blocked"
      true (error <> "branch_switch_blocked"))

let test_bash_git_branch_delete_allowed () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc [ "cmd", `String "git branch -d old-branch" ] in
    let result = call_tool config meta "keeper_bash" args in
    let json = parse_json result in
    let error = try json_string "error" json with _ -> "" in
    check bool "git branch -d not blocked as branch_switch"
      true (error <> "branch_switch_blocked"))

let test_bash_git_status_allowed () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let args = `Assoc [ "cmd", `String "git status" ] in
    let result = call_tool config meta "keeper_bash" args in
    let json = parse_json result in
    let has_status = match json with
      | `Assoc fields -> List.mem_assoc "status" fields
      | _ -> false
    in
    check bool "git status returns normal execution shape"
      true has_status)

let test_shell_readonly_pwd_defaults_to_playground () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let expected_cwd =
      Filename.concat
        (Keeper_alerting_path.project_root_of_config config)
        (Keeper_alerting_path.playground_path_of_keeper meta.name)
    in
    Fs_compat.mkdir_p expected_cwd;
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc [ "op", `String "pwd" ])
    in
    let json = parse_json result in
    check bool "pwd ok" true (json_bool "ok" json);
    check string "pwd cwd" expected_cwd (json_string "cwd" json))

let test_shell_readonly_pwd_stays_in_playground_with_explicit_allowed_root () =
  with_room (fun config ->
    let shared_repo_rel = "workspace/yousleepwhen/oas" in
    let shared_repo_abs =
      Filename.concat (Keeper_alerting_path.project_root_of_config config) shared_repo_rel
    in
    Fs_compat.mkdir_p shared_repo_abs;
    let meta =
      { (make_meta_with_preset "delivery") with
        allowed_paths = [ shared_repo_rel ^ "/" ] }
    in
    let expected_cwd =
      Filename.concat
        (Keeper_alerting_path.project_root_of_config config)
        (Keeper_alerting_path.playground_path_of_keeper meta.name)
    in
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc [ "op", `String "pwd" ])
    in
    let json = parse_json result in
    ignore shared_repo_abs;
    check bool "pwd with explicit allowed root ok" true (json_bool "ok" json);
    check string "pwd still defaults to keeper playground" expected_cwd
      (json_string "cwd" json))

let test_shell_readonly_cat_uses_explicit_cwd_for_custom_root () =
  with_room (fun config ->
    let shared_repo_rel = "workspace/yousleepwhen/oas" in
    let shared_repo_abs =
      Filename.concat (Keeper_alerting_path.project_root_of_config config) shared_repo_rel
    in
    let shared_file = Filename.concat shared_repo_abs "lib/approval.ml" in
    write_text_file shared_file "let approval = true\n";
    let meta =
      { (make_meta_with_preset "delivery") with
        allowed_paths = [ shared_repo_rel ^ "/" ] }
    in
    let default_result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "cat"
          ; "path", `String "lib/approval.ml"
          ])
    in
    let default_json = parse_json default_result in
    check bool "default cat stays in playground and misses shared repo" true
      (match default_json with `Assoc fields -> List.mem_assoc "error" fields | _ -> false);
    let explicit_result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "cat"
          ; "cwd", `String (shared_repo_abs ^ "/")
          ; "path", `String "lib/approval.ml"
          ])
    in
    let explicit_json = parse_json explicit_result in
    check bool "cat with explicit cwd ok" true (json_bool "ok" explicit_json);
    check string "cat path resolves from explicit cwd" shared_file
      (json_string "path" explicit_json);
    check string "cat returns shared repo content" "let approval = true\n"
      (json_string "content" explicit_json))

let test_fs_read_blocks_shared_repo_by_default () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let shared_file =
      Filename.concat (Keeper_alerting_path.project_root_of_config config)
        "workspace/yousleepwhen/oas/lib/approval.ml"
    in
    write_text_file shared_file "let approval = true\n";
    let result =
      call_tool config meta "keeper_fs_read"
        (`Assoc [ "path", `String shared_file ])
    in
    let json = parse_json result in
    check bool "returns error payload" true
      (match json with `Assoc fields -> List.mem_assoc "error" fields | _ -> false);
    check bool "reports allowed path boundary" true
      (String.starts_with ~prefix:"path_not_in_allowed_paths" (json_string "error" json)))

let test_fs_read_allows_explicit_custom_path () =
  with_room (fun config ->
    let meta =
      { (make_meta_with_preset "delivery") with
        allowed_paths = [ "workspace/yousleepwhen/oas/" ] }
    in
    let shared_file =
      Filename.concat (Keeper_alerting_path.project_root_of_config config)
        "workspace/yousleepwhen/oas/lib/approval.ml"
    in
    write_text_file shared_file "let approval = true\n";
    let result =
      call_tool config meta "keeper_fs_read"
        (`Assoc [ "path", `String shared_file ])
    in
    let json = parse_json result in
    check bool "explicit custom path read ok" true (json_bool "ok" json);
    check bool "content included" true
      (String.starts_with ~prefix:"let approval" (json_string "content" json)))

let test_bash_blocks_absolute_path_outside_playground () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let shared_file = Filename.concat (Lazy.force repo_root) "dune-project" in
    let result =
      call_tool config meta "keeper_bash"
        (`Assoc [ "cmd", `String (Printf.sprintf "cat %s" shared_file) ])
    in
    let json = parse_json result in
    check bool "returns path blocked error" true
      (match json with `Assoc fields -> List.mem_assoc "error" fields | _ -> false);
    check bool "absolute path blocked" true
      (String.starts_with ~prefix:"Path blocked:" (json_string "error" json)))

let test_bash_blocks_quoted_absolute_path_outside_playground () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let shared_file = Filename.concat (Lazy.force repo_root) "dune-project" in
    let quoted_cmd = Printf.sprintf "cat \"%s\"" shared_file in
    let result =
      call_tool config meta "keeper_bash"
        (`Assoc [ "cmd", `String quoted_cmd ])
    in
    let json = parse_json result in
    check bool "returns path syntax blocked error" true
      (match json with `Assoc fields -> List.mem_assoc "error" fields | _ -> false);
    check bool "quoted absolute path blocked" true
      (String.starts_with ~prefix:"Path syntax blocked:" (json_string "error" json)))

let test_readonly_bash_blocks_quoted_absolute_path_outside_playground () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let shared_file = Filename.concat (Lazy.force repo_root) "dune-project" in
    let quoted_cmd = Printf.sprintf "cat \"%s\"" shared_file in
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc [ "op", `String "bash"; "command", `String quoted_cmd ])
    in
    let json = parse_json result in
    check bool "returns path syntax blocked error" true
      (match json with `Assoc fields -> List.mem_assoc "error" fields | _ -> false);
    check bool "quoted readonly absolute path blocked" true
      (String.starts_with ~prefix:"Path syntax blocked:" (json_string "error" json)))

let test_readonly_bash_allows_masc_mcp_argument () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "bash"
          ; "command", `String "echo masc-mcp remote"
          ])
    in
    let json = parse_json result in
    check bool "command allowed" true (json_bool "ok" json);
    check string "output preserved" "masc-mcp remote\n" (json_string "output" json))

let test_readonly_bash_allows_echo_git_push_text () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "bash"
          ; "command", `String "echo git push"
          ])
    in
    let json = parse_json result in
    check bool "echo git push allowed" true (json_bool "ok" json);
    check string "echo output preserved" "git push\n" (json_string "output" json))

let test_readonly_bash_blocks_git_push_with_global_opts () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "bash"
          ; "command", `String "git -C repo push origin main"
          ])
    in
    let json = parse_json result in
    check bool "returns readonly blocked error" true
      (match json with `Assoc fields -> List.mem_assoc "error" fields | _ -> false);
    check string "git push with global opts blocked" "command_blocked_readonly"
      (json_string "error" json);
    check string "blocked pattern identifies git push" "git push"
      (json_string "blocked_pattern" json))

let test_readonly_bash_surfaces_timeout_error () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "bash"
          ; "command", `String "python3 -c \"import time\ntime.sleep(2)\""
          ; "timeout_sec", `Float 1.0
          ])
    in
    let json = parse_json result in
    check bool "timeout returns failure" false (json_bool "ok" json);
    check string "timeout error surfaced" "command_timed_out" (json_string "error" json);
    check (float 0.001) "timeout echoed" 1.0 (json_float "timeout_sec" json);
    check string "status kind is timeout" "timeout"
      Yojson.Safe.Util.(json |> member "status" |> member "kind" |> to_string))

let test_shell_readonly_ls_defaults_path_to_cwd () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let expected_cwd =
      Filename.concat
        (Keeper_alerting_path.project_root_of_config config)
        (Keeper_alerting_path.playground_path_of_keeper meta.name)
    in
    let file_path = Filename.concat expected_cwd "notes.txt" in
    write_text_file file_path "hello from cwd default\n";
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "ls"
          ; "cwd", `String expected_cwd
          ])
    in
    let json = parse_json result in
    check bool "ls ok" true (json_bool "ok" json);
    check string "ls path uses cwd" expected_cwd (json_string "path" json);
    check bool "ls lists file from cwd" true
      (match Yojson.Safe.Util.member "entries" json with
       | `List entries ->
         List.exists (function
           | `String line -> String_util.contains_substring line "notes.txt"
           | _ -> false) entries
       | _ -> false))

let test_shell_readonly_cat_resolves_relative_path_from_cwd () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let expected_cwd =
      Filename.concat
        (Keeper_alerting_path.project_root_of_config config)
        (Keeper_alerting_path.playground_path_of_keeper meta.name)
    in
    let nested_file = Filename.concat expected_cwd "repo/lib/approval.ml" in
    write_text_file nested_file "let approval = true\n";
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "cat"
          ; "cwd", `String expected_cwd
          ; "path", `String "repo/lib/approval.ml"
          ])
    in
    let json = parse_json result in
    check bool "relative cat ok" true (json_bool "ok" json);
    check string "relative cat path uses cwd" nested_file (json_string "path" json);
    check string "relative cat content" "let approval = true\n" (json_string "content" json))

let test_shell_readonly_rg_resolves_dot_path_from_cwd () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let expected_cwd =
      Filename.concat
        (Keeper_alerting_path.project_root_of_config config)
        (Keeper_alerting_path.playground_path_of_keeper meta.name)
    in
    let nested_file = Filename.concat expected_cwd "repo/lib/approval.ml" in
    write_text_file nested_file "let keeper_path_fix = true\n";
    let result =
      call_tool config meta "keeper_shell"
        (`Assoc
          [ "op", `String "rg"
          ; "cwd", `String expected_cwd
          ; "path", `String "."
          ; "pattern", `String "keeper_path_fix"
          ])
    in
    let json = parse_json result in
    check bool "rg ok" true (json_bool "ok" json);
    check string "rg path uses cwd" (Filename.concat expected_cwd ".")
      (json_string "path" json);
    check bool "rg finds nested file" true
      (match Yojson.Safe.Util.member "matches" json with
       | `List matches ->
         List.exists (function
           | `String line -> String_util.contains_substring line "keeper_path_fix"
           | _ -> false) matches
       | _ -> false))

let with_grep_only_path expected_cwd f =
  let grep_path =
    let st, out =
      Process_eio.run_argv_with_status ~timeout_sec:2.0
        [ "/bin/sh"; "-c"; "command -v grep" ]
    in
    if st <> Unix.WEXITED 0 then failwith "grep not available for fallback test";
    String.trim out
  in
  let fake_bin = Filename.concat expected_cwd "fake-bin" in
  Fs_compat.mkdir_p fake_bin;
  let fake_grep = Filename.concat fake_bin "grep" in
  if Sys.file_exists fake_grep then Sys.remove fake_grep;
  Unix.symlink grep_path fake_grep;
  let saved_path = Sys.getenv_opt "PATH" in
  Fun.protect
    ~finally:(fun () ->
      match saved_path with
      | Some path -> Unix.putenv "PATH" path
      | None -> Unix.putenv "PATH" "")
    (fun () ->
      Unix.putenv "PATH" fake_bin;
      f ())

let test_shell_readonly_rg_falls_back_to_grep_when_rg_missing () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let expected_cwd =
      Filename.concat
        (Keeper_alerting_path.project_root_of_config config)
        (Keeper_alerting_path.playground_path_of_keeper meta.name)
    in
    let nested_file = Filename.concat expected_cwd "repo/lib/approval.ml" in
    write_text_file nested_file "let keeper_path_fix = true\n";
    with_grep_only_path expected_cwd (fun () ->
        let result =
          call_tool config meta "keeper_shell"
            (`Assoc
              [ "op", `String "rg"
              ; "cwd", `String expected_cwd
              ; "path", `String "."
              ; "pattern", `String "keeper_path_fix"
              ])
        in
        let json = parse_json result in
        check bool "rg fallback ok" true (json_bool "ok" json);
        check string "rg fallback path uses cwd" (Filename.concat expected_cwd ".")
          (json_string "path" json);
        check bool "rg fallback finds nested file" true
          (match Yojson.Safe.Util.member "matches" json with
           | `List matches ->
             List.exists (function
               | `String line -> String_util.contains_substring line "keeper_path_fix"
               | _ -> false) matches
           | _ -> false)))

let test_shell_readonly_rg_reports_filter_limit_when_rg_missing () =
  with_room (fun config ->
    let meta = make_meta_with_preset "delivery" in
    let expected_cwd =
      Filename.concat
        (Keeper_alerting_path.project_root_of_config config)
        (Keeper_alerting_path.playground_path_of_keeper meta.name)
    in
    write_text_file (Filename.concat expected_cwd "repo/lib/approval.ml")
      "let keeper_path_fix = true\n";
    with_grep_only_path expected_cwd (fun () ->
        let result =
          call_tool config meta "keeper_shell"
            (`Assoc
              [ "op", `String "rg"
              ; "cwd", `String expected_cwd
              ; "path", `String "."
              ; "pattern", `String "keeper_path_fix"
              ; "type", `String "ml"
              ])
        in
        let json = parse_json result in
        check string "rg fallback filter error"
          "rg executable not found; grep fallback only supports pattern and path"
          (json_string "error" json)))
let () =
  run "keeper_pr_workflow"
    [ "required_fields",
      [ test_case "missing branch" `Quick test_missing_branch
      ; test_case "missing file_path" `Quick test_missing_file_path
      ; test_case "missing commit_message" `Quick test_missing_commit_message
      ; test_case "missing pr_title" `Quick test_missing_pr_title
      ]
    ; "preset_gate",
      [ test_case "social rejected" `Quick test_social_preset_rejected
      ; test_case "research rejected" `Quick test_research_preset_rejected
      ; test_case "minimal rejected" `Quick test_minimal_preset_rejected
      ; test_case "delivery passes" `Quick test_delivery_preset_passes_validation
      ; test_case "coding passes" `Quick test_coding_preset_passes_validation
      ; test_case "full passes" `Quick test_full_preset_passes_validation
      ]
    ; "branch_sanitization",
      [ test_case "semicolon rejected" `Quick test_branch_with_semicolon_rejected
      ; test_case "pipe rejected" `Quick test_branch_with_pipe_rejected
      ; test_case "backtick rejected" `Quick test_branch_with_backtick_rejected
      ; test_case "dot-dot rejected" `Quick test_branch_with_dot_dot_rejected
      ; test_case "space rejected" `Quick test_branch_with_space_rejected
      ; test_case "dollar-paren rejected" `Quick test_branch_with_dollar_paren_rejected
      ; test_case "ampersand rejected" `Quick test_branch_with_ampersand_rejected
      ; test_case "slash accepted" `Quick test_valid_branch_with_slash_accepted
      ]
    ; "worktree_id_derivation",
      [ test_case "slash to hyphen" `Quick test_branch_slash_converted_to_hyphen_in_worktree_id
      ]
    ; "step_propagation",
      [ test_case "worktree failure" `Quick test_worktree_failure_propagates
      ]
    ; "task_lifecycle",
      [ test_case "claim then done" `Quick test_task_claim_then_done_lifecycle
      ]
    ; "task_dedup",
      [ test_case "second claim no tasks" `Quick test_second_claim_on_single_task_returns_no_tasks
      ]
    ; "bash_branch_guard",
      [ test_case "checkout blocked" `Quick test_bash_git_checkout_blocked
      ; test_case "switch blocked" `Quick test_bash_git_switch_blocked
      ; test_case "checkout -C blocked" `Quick test_bash_git_checkout_with_global_opts_blocked
      ; test_case "tab checkout blocked" `Quick test_bash_git_tab_separated_blocked
      ; test_case "branch create blocked" `Quick test_bash_git_branch_create_blocked
      ; test_case "branch rename blocked" `Quick test_bash_git_branch_rename_blocked
      ; test_case "checkout allowed in default playground" `Quick
          test_bash_git_checkout_allowed_in_default_playground
      ; test_case "branch list allowed" `Quick test_bash_git_branch_list_allowed
      ; test_case "branch delete allowed" `Quick test_bash_git_branch_delete_allowed
      ; test_case "status allowed" `Quick test_bash_git_status_allowed
      ; test_case "readonly pwd defaults to playground" `Quick
          test_shell_readonly_pwd_defaults_to_playground
      ; test_case "readonly pwd stays in playground with explicit allowed root" `Quick
          test_shell_readonly_pwd_stays_in_playground_with_explicit_allowed_root
      ; test_case "readonly cat uses explicit cwd for custom root" `Quick
          test_shell_readonly_cat_uses_explicit_cwd_for_custom_root
      ; test_case "fs read blocks shared repo by default" `Quick
          test_fs_read_blocks_shared_repo_by_default
      ; test_case "fs read allows explicit custom path" `Quick
          test_fs_read_allows_explicit_custom_path
      ; test_case "bash blocks absolute path outside playground" `Quick
          test_bash_blocks_absolute_path_outside_playground
      ; test_case "bash blocks quoted absolute path outside playground" `Quick
          test_bash_blocks_quoted_absolute_path_outside_playground
      ; test_case "readonly bash blocks quoted absolute path outside playground" `Quick
          test_readonly_bash_blocks_quoted_absolute_path_outside_playground
      ; test_case "readonly bash allows masc-mcp argument" `Quick
          test_readonly_bash_allows_masc_mcp_argument
      ; test_case "readonly bash allows echo git push text" `Quick
          test_readonly_bash_allows_echo_git_push_text
      ; test_case "readonly bash blocks git push with global opts" `Quick
          test_readonly_bash_blocks_git_push_with_global_opts
      ; test_case "readonly bash surfaces timeout error" `Quick
          test_readonly_bash_surfaces_timeout_error
      ; test_case "readonly ls defaults path to cwd" `Quick
          test_shell_readonly_ls_defaults_path_to_cwd
      ; test_case "readonly cat resolves relative path from cwd" `Quick
          test_shell_readonly_cat_resolves_relative_path_from_cwd
      ; test_case "readonly rg resolves dot path from cwd" `Quick
          test_shell_readonly_rg_resolves_dot_path_from_cwd
      ; test_case "readonly rg falls back to grep when rg missing" `Quick
          test_shell_readonly_rg_falls_back_to_grep_when_rg_missing
      ; test_case "readonly rg rejects filters when rg missing" `Quick
          test_shell_readonly_rg_reports_filter_limit_when_rg_missing
      ]
    ; "integration",
      [ test_case "worktree workflow e2e" `Slow test_worktree_create_writes_and_cleans_up
      ; test_case "existing worktree retried safely" `Slow test_existing_worktree_path_is_retried_safely
      ; test_case "local repo absolute bash truth check" `Slow
          test_local_repo_worktree_runs_truth_via_absolute_bash
      ]
    ]
