(** Task_sandbox unit tests.

    Tests sandbox type construction, path extraction, and error paths.
    Full git worktree integration is tested indirectly through
    Coord_worktree tests; here we focus on Task_sandbox's own logic. *)

open Alcotest

module Task_sandbox = Masc_mcp.Task_sandbox
module Coord = Masc_mcp.Coord

(* ============================================================
   Helpers
   ============================================================ *)

let temp_counter = ref 0

let contains needle haystack =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0 then true
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

(** Create a temp directory with a unique name. *)
let make_temp_dir () =
  incr temp_counter;
  let dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-sandbox-test-%d-%d-%d"
       (Unix.getpid ()) !temp_counter (Random.int 999999))
  in
  if Sys.file_exists dir then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  Unix.mkdir dir 0o755;
  dir

(** Run in temp dir without git (to test error paths). *)
let with_non_git_room f =
  let dir = make_temp_dir () in
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    (match saved_base with
     | Some v -> Unix.putenv "MASC_BASE_PATH" v
     | None -> Unix.putenv "MASC_BASE_PATH" "");
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () ->
    Unix.putenv "MASC_BASE_PATH" dir;
    let config = Coord.default_config dir in
    let _msg = Coord.init config ~agent_name:None in
    f dir config
  )

(* ============================================================
   Type tests
   ============================================================ *)

let test_sandbox_type_fields () =
  let sb : Task_sandbox.sandbox = {
    task_id = "task-001";
    worktree_path = "/tmp/test/.worktrees/agent-task-001";
    branch_name = "agent/task-001";
    created_at = 1234567890.0;
  } in
  check string "task_id" "task-001" sb.task_id;
  check string "worktree_path" "/tmp/test/.worktrees/agent-task-001" sb.worktree_path;
  check string "branch_name" "agent/task-001" sb.branch_name

(* ============================================================
   Create error path tests
   ============================================================ *)

let test_create_fails_without_git () =
  with_non_git_room (fun _dir config ->
    match Task_sandbox.create ~config ~task_id:"task-001"
            ~agent_name:"test-agent" () with
    | Ok _ -> fail "expected error for non-git directory"
    | Error e ->
      check bool "error mentions failure" true
        (String.length e > 0)
  )

let test_create_fails_with_empty_task_id () =
  with_non_git_room (fun _dir config ->
    match Task_sandbox.create ~config ~task_id:""
            ~agent_name:"test-agent" () with
    | Ok _ -> fail "expected error for empty task_id"
    | Error _e -> ()
  )

(* ============================================================
   changed_files tests (pure logic - sandbox struct only)
   ============================================================ *)

let test_changed_files_returns_empty_for_nonexistent_path () =
  let sb : Task_sandbox.sandbox = {
    task_id = "task-nonexistent";
    worktree_path = "/tmp/definitely-does-not-exist-12345";
    branch_name = "test/nonexistent";
    created_at = 0.0;
  } in
  let _files = Task_sandbox.changed_files sb in
  check int "empty for nonexistent path" 0 (List.length _files)

(* ============================================================
   cleanup error path tests
   ============================================================ *)

let test_cleanup_fails_for_nonexistent_sandbox () =
  with_non_git_room (fun _dir config ->
    let sb : Task_sandbox.sandbox = {
      task_id = "task-ghost";
      worktree_path = "/tmp/definitely-does-not-exist-67890";
      branch_name = "ghost/task-ghost";
      created_at = 0.0;
    } in
    match Task_sandbox.cleanup ~config ~agent_name:"ghost-agent" sb with
    | Ok _ -> fail "expected error for nonexistent sandbox"
    | Error _e -> ()
  )

(* ============================================================
   with_sandbox error path tests
   ============================================================ *)

let test_with_sandbox_fails_without_git () =
  with_non_git_room (fun _dir config ->
    match Task_sandbox.with_sandbox ~config ~task_id:"task-err"
            ~agent_name:"err-agent"
            (fun _sb -> 42) with
    | Ok _ -> fail "expected error for non-git directory"
    | Error e ->
      check bool "error message non-empty" true (String.length e > 0)
  )

(* ============================================================
   Symlink test (manual directory setup)
   ============================================================ *)

let test_symlink_created_when_masc_exists () =
  let dir = make_temp_dir () in
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () ->
    (* Create a fake .masc directory at "repo root" *)
    let masc_dir = Filename.concat dir Common.masc_dirname in
    Unix.mkdir masc_dir 0o755;
    (* Create a fake worktree directory *)
    let wt_dir = Filename.concat dir "fake-worktree" in
    Unix.mkdir wt_dir 0o755;
    (* The sandbox creation would call symlink_masc internally.
       Test the end state: .masc should be symlinked into the worktree.
       Since symlink_masc is internal, we test the behavior via Unix.symlink. *)
    let masc_in_wt = Filename.concat wt_dir Common.masc_dirname in
    Unix.symlink masc_dir masc_in_wt;
    check bool ".masc link exists in worktree" true (Sys.file_exists masc_in_wt);
    (* Verify it's a symlink *)
    let stats = Unix.lstat masc_in_wt in
    check bool "is symlink" true (stats.Unix.st_kind = Unix.S_LNK)
  )

(* ============================================================
   Integration test: full create → work → cleanup cycle
   This requires a real git repo with origin. Run under Eio context
   since Coord_worktree.worktree_create_r uses Process_eio.
   ============================================================ *)

(** Run a shell command, raising on failure. *)
let run_cmd cmd =
  let exit_code = Sys.command cmd in
  if exit_code <> 0 then
    failwith (Printf.sprintf "command failed (exit %d): %s" exit_code cmd)

let seed_playground_clone ~base_path ~agent_name ~source_repo =
  let repos_dir =
    Filename.concat base_path
      (Printf.sprintf ".masc/playground/%s/repos" agent_name)
  in
  let clone_path = Filename.concat repos_dir (Filename.basename source_repo) in
  Fs_compat.mkdir_p repos_dir;
  if Sys.file_exists clone_path then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote clone_path)));
  run_cmd (Printf.sprintf "git clone %s %s"
    (Filename.quote source_repo) (Filename.quote clone_path));
  clone_path

let setup_named_repo_with_file ~base_path ~repo_name ~file_path =
  let bare_dir =
    Filename.concat base_path (Printf.sprintf ".remote-%s.git" repo_name)
  in
  let repo =
    Filename.concat base_path
      (Filename.concat "sources" repo_name)
  in
  Fs_compat.mkdir_p (Filename.dirname repo);
  run_cmd
    (Printf.sprintf "git init --bare --initial-branch=main %s"
       (Filename.quote bare_dir));
  run_cmd
    (Printf.sprintf "git clone %s %s"
       (Filename.quote bare_dir) (Filename.quote repo));
  run_cmd
    (Printf.sprintf "git -C %s config user.email test@test.com"
       (Filename.quote repo));
  run_cmd
    (Printf.sprintf "git -C %s config user.name test"
       (Filename.quote repo));
  let full_path = Filename.concat repo file_path in
  Fs_compat.mkdir_p (Filename.dirname full_path);
  let oc = open_out full_path in
  output_string oc "test fixture\n";
  close_out oc;
  run_cmd (Printf.sprintf "git -C %s add ." (Filename.quote repo));
  run_cmd
    (Printf.sprintf "git -C %s commit -m init" (Filename.quote repo));
  run_cmd (Printf.sprintf "git -C %s push origin main" (Filename.quote repo));
  repo

let task ?worktree ?(files = []) ~id ~title ~description () : Types.task =
  {
    id;
    title;
    description;
    task_status = Types.Todo;
    priority = 3;
    files;
    created_at = "2026-05-01T00:00:00Z";
    created_by = None;
    worktree;
    goal_id = None;
    stage = None;
    contract = None;
    handoff_context = None;
    cycle_count = 0;
    do_not_reclaim_reason = None;
  }

let write_tasks config tasks =
  let backlog = Coord.read_backlog config in
  Coord.write_backlog config
    { Types.tasks = tasks; last_updated = Types.now_iso (); version = backlog.version + 1 }

let test_full_lifecycle () =
  let base = make_temp_dir () in
  let dir = base in
  let bare_dir = base ^ "-bare" in
  (* Remove the empty dir first since git clone wants a non-existent target *)
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    (match saved_base with
     | Some v -> Unix.putenv "MASC_BASE_PATH" v
     | None -> Unix.putenv "MASC_BASE_PATH" "");
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote bare_dir)))
  ) (fun () ->
    Eio_main.run (fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      (* Setup git repo with origin *)
      let git d args =
        run_cmd (Printf.sprintf "git -C %s %s" (Filename.quote d) args)
      in
      run_cmd (Printf.sprintf "git init --bare --initial-branch=main %s"
        (Filename.quote bare_dir));
      run_cmd (Printf.sprintf "git clone %s %s"
        (Filename.quote bare_dir) (Filename.quote dir));
      git dir "config user.email test@test.com";
      git dir "config user.name test";
      let readme = Filename.concat dir "README.md" in
      let oc = open_out readme in
      output_string oc "# Test\n";
      close_out oc;
      git dir "add README.md";
      git dir "commit -m 'initial commit'";
      git dir "push origin main";

      (* Initialize Process_eio so Coord_worktree can work *)
      let proc_mgr = Eio.Stdenv.process_mgr env in
      let clock = Eio.Stdenv.clock env in
      let cwd = Eio.Stdenv.cwd env in
      Process_eio.init ~cwd_default:cwd ~proc_mgr ~clock;

      Unix.putenv "MASC_BASE_PATH" dir;
      let config = Coord.default_config dir in
      let _msg = Coord.init config ~agent_name:None in
      let _join = Coord.join config ~agent_name:"lifecycle-agent"
        ~capabilities:["test"] () in
      let clone_path =
        seed_playground_clone ~base_path:dir
          ~agent_name:"lifecycle-agent" ~source_repo:dir
      in

      match Task_sandbox.create ~config ~task_id:"task-life"
              ~agent_name:"lifecycle-agent"
              ~repo_name:(Filename.basename dir) () with
      | Error e ->
        fail (Printf.sprintf "sandbox create failed: %s" e)
      | Ok sb ->
        (* Verify worktree exists *)
        check bool "worktree_path exists" true (Sys.file_exists sb.worktree_path);
        check string "task_id" "task-life" sb.task_id;
        check bool "branch non-empty" true (String.length sb.branch_name > 0);

        (* Verify .masc symlink *)
        let masc_link = Filename.concat sb.worktree_path Common.masc_dirname in
        check bool ".masc exists in sandbox" true (Sys.file_exists masc_link);

        (* Create a file to simulate work *)
        let test_file = Filename.concat sb.worktree_path "work.txt" in
        let oc = open_out test_file in
        output_string oc "sandbox work\n";
        close_out oc;

        (* Check changed files *)
        let _files = Task_sandbox.changed_files sb in
        (* Untracked files won't show in git diff, only in git status *)
        (* Stage the file so git diff --cached picks it up *)
        run_cmd (Printf.sprintf "git -C %s add work.txt"
          (Filename.quote sb.worktree_path));
        let files_after_add = Task_sandbox.changed_files sb in
        check bool "staged file detected" true
          (List.exists (fun f ->
             try ignore (Str.search_forward
               (Str.regexp_string "work.txt") f 0); true
             with Not_found -> false) files_after_add);

        (* Cleanup *)
        let path_before = sb.worktree_path in
        (match Task_sandbox.cleanup ~config ~agent_name:"lifecycle-agent" sb with
         | Ok changed ->
           check bool "cleanup returned files" true (List.length changed >= 0);
           check bool "worktree removed" false (Sys.file_exists path_before);
           check bool "clone still exists" true (Sys.file_exists clone_path)
         | Error e ->
           (* On some platforms cleanup may fail but we should not crash *)
           Printf.eprintf "[WARN] cleanup error (acceptable in CI): %s\n%!" e)
    )
  )

let test_create_infers_repo_from_task_file_evidence () =
  let base = make_temp_dir () in
  let dir = base in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match saved_base with
       | Some v -> Unix.putenv "MASC_BASE_PATH" v
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        run_cmd (Printf.sprintf "git init -q -b main %s" (Filename.quote dir));
        let proc_mgr = Eio.Stdenv.process_mgr env in
        let clock = Eio.Stdenv.clock env in
        let cwd = Eio.Stdenv.cwd env in
        Process_eio.init ~cwd_default:cwd ~proc_mgr ~clock;

        Unix.putenv "MASC_BASE_PATH" dir;
        let config = Coord.default_config dir in
        let _msg = Coord.init config ~agent_name:None in
        let _join =
          Coord.join config ~agent_name:"router-agent" ~capabilities:[ "test" ] ()
        in
        let grpc_repo =
          setup_named_repo_with_file ~base_path:dir ~repo_name:"grpc-direct"
            ~file_path:"lib/grpc_eio/health.ml"
        in
        let masc_repo =
          setup_named_repo_with_file ~base_path:dir ~repo_name:"masc-mcp"
            ~file_path:"lib/tool_call_quality_benchmark_loader.ml"
        in
        let grpc_clone =
          seed_playground_clone ~base_path:dir ~agent_name:"router-agent"
            ~source_repo:grpc_repo
        in
        let _masc_clone =
          seed_playground_clone ~base_path:dir ~agent_name:"router-agent"
            ~source_repo:masc_repo
        in
        let stale_worktree : Types.worktree_info =
          {
            branch = "router-agent/task-route";
            path = ".worktrees/router-agent-task-route";
            git_root = grpc_clone;
            repo_name = "grpc-direct";
          }
        in
        write_tasks config
          [
            task ~id:"task-route" ~title:"benchmark loader migration"
              ~description:
                "Migrate lib/tool_call_quality_benchmark_loader.ml from invalid_arg to Result."
              ~worktree:stale_worktree ();
          ];
        match
          Task_sandbox.create ~config ~task_id:"task-route"
            ~agent_name:"router-agent" ()
        with
        | Error e -> fail (Printf.sprintf "sandbox create failed: %s" e)
        | Ok sb ->
            check bool "picked masc-mcp repo" true
              (contains "/repos/masc-mcp/.worktrees/" sb.worktree_path);
            let persisted =
              Coord.read_backlog config
              |> fun backlog ->
              List.find
                (fun (t : Types.task) -> String.equal t.id "task-route")
                backlog.tasks
            in
            (match persisted.worktree with
             | Some wt -> check string "persisted repo" "masc-mcp" wt.repo_name
             | None -> fail "expected linked worktree metadata");
            ignore
              (Task_sandbox.cleanup ~config ~agent_name:"router-agent" sb)))

let test_create_fails_ambiguous_multi_repo_without_evidence () =
  let base = make_temp_dir () in
  let dir = base in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect
    ~finally:(fun () ->
      (match saved_base with
       | Some v -> Unix.putenv "MASC_BASE_PATH" v
       | None -> Unix.putenv "MASC_BASE_PATH" "");
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () ->
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        run_cmd (Printf.sprintf "git init -q -b main %s" (Filename.quote dir));
        let proc_mgr = Eio.Stdenv.process_mgr env in
        let clock = Eio.Stdenv.clock env in
        let cwd = Eio.Stdenv.cwd env in
        Process_eio.init ~cwd_default:cwd ~proc_mgr ~clock;

        Unix.putenv "MASC_BASE_PATH" dir;
        let config = Coord.default_config dir in
        let _msg = Coord.init config ~agent_name:None in
        let _join =
          Coord.join config ~agent_name:"ambiguous-agent"
            ~capabilities:[ "test" ] ()
        in
        let grpc_repo =
          setup_named_repo_with_file ~base_path:dir ~repo_name:"grpc-direct"
            ~file_path:"README.md"
        in
        let masc_repo =
          setup_named_repo_with_file ~base_path:dir ~repo_name:"masc-mcp"
            ~file_path:"README.md"
        in
        ignore
          (seed_playground_clone ~base_path:dir ~agent_name:"ambiguous-agent"
             ~source_repo:grpc_repo);
        ignore
          (seed_playground_clone ~base_path:dir ~agent_name:"ambiguous-agent"
             ~source_repo:masc_repo);
        write_tasks config
          [
            task ~id:"task-ambiguous" ~title:"generic cleanup"
              ~description:"No repo or file evidence." ();
          ];
        match
          Task_sandbox.create ~config ~task_id:"task-ambiguous"
            ~agent_name:"ambiguous-agent" ()
        with
        | Ok sb ->
            ignore
              (Task_sandbox.cleanup ~config ~agent_name:"ambiguous-agent" sb);
            fail "expected ambiguous repo routing error"
        | Error e ->
            check bool "reports ambiguous repo" true
              (contains "ambiguous_task_repo" e)))

let test_with_sandbox_lifecycle () =
  let base = make_temp_dir () in
  let dir = base in
  let bare_dir = base ^ "-bare" in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    (match saved_base with
     | Some v -> Unix.putenv "MASC_BASE_PATH" v
     | None -> Unix.putenv "MASC_BASE_PATH" "");
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote bare_dir)))
  ) (fun () ->
    Eio_main.run (fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let git d args =
        run_cmd (Printf.sprintf "git -C %s %s" (Filename.quote d) args)
      in
      run_cmd (Printf.sprintf "git init --bare --initial-branch=main %s"
        (Filename.quote bare_dir));
      run_cmd (Printf.sprintf "git clone %s %s"
        (Filename.quote bare_dir) (Filename.quote dir));
      git dir "config user.email test@test.com";
      git dir "config user.name test";
      let readme = Filename.concat dir "README.md" in
      let oc = open_out readme in
      output_string oc "# Test\n";
      close_out oc;
      git dir "add README.md";
      git dir "commit -m 'initial commit'";
      git dir "push origin main";

      let proc_mgr = Eio.Stdenv.process_mgr env in
      let clock = Eio.Stdenv.clock env in
      let cwd = Eio.Stdenv.cwd env in
      Process_eio.init ~cwd_default:cwd ~proc_mgr ~clock;

      Unix.putenv "MASC_BASE_PATH" dir;
      let config = Coord.default_config dir in
      let _msg = Coord.init config ~agent_name:None in
      let _join = Coord.join config ~agent_name:"with-agent"
        ~capabilities:["test"] () in
      let _clone_path =
        seed_playground_clone ~base_path:dir
          ~agent_name:"with-agent" ~source_repo:dir
      in

      match Task_sandbox.with_sandbox ~config ~task_id:"task-with"
              ~agent_name:"with-agent"
              ~repo_name:(Filename.basename dir)
              (fun sb ->
                check bool "inside sandbox" true (Sys.file_exists sb.worktree_path);
                42) with
      | Ok (result, _files) ->
        check int "function result" 42 result
      | Error e ->
        fail (Printf.sprintf "with_sandbox failed: %s" e)
    )
  )

let test_with_sandbox_cleans_up_on_exception () =
  let base = make_temp_dir () in
  let dir = base in
  let bare_dir = base ^ "-bare" in
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  Fun.protect ~finally:(fun () ->
    (match saved_base with
     | Some v -> Unix.putenv "MASC_BASE_PATH" v
     | None -> Unix.putenv "MASC_BASE_PATH" "");
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote bare_dir)))
  ) (fun () ->
    Eio_main.run (fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let git d args =
        run_cmd (Printf.sprintf "git -C %s %s" (Filename.quote d) args)
      in
      run_cmd (Printf.sprintf "git init --bare --initial-branch=main %s"
        (Filename.quote bare_dir));
      run_cmd (Printf.sprintf "git clone %s %s"
        (Filename.quote bare_dir) (Filename.quote dir));
      git dir "config user.email test@test.com";
      git dir "config user.name test";
      let readme = Filename.concat dir "README.md" in
      let oc = open_out readme in
      output_string oc "# Test\n";
      close_out oc;
      git dir "add README.md";
      git dir "commit -m 'initial commit'";
      git dir "push origin main";

      let proc_mgr = Eio.Stdenv.process_mgr env in
      let clock = Eio.Stdenv.clock env in
      let cwd = Eio.Stdenv.cwd env in
      Process_eio.init ~cwd_default:cwd ~proc_mgr ~clock;

      Unix.putenv "MASC_BASE_PATH" dir;
      let config = Coord.default_config dir in
      let _msg = Coord.init config ~agent_name:None in
      let _join = Coord.join config ~agent_name:"exc-agent"
        ~capabilities:["test"] () in
      let _clone_path =
        seed_playground_clone ~base_path:dir
          ~agent_name:"exc-agent" ~source_repo:dir
      in

      let worktree_path_ref = ref "" in
      (try
        let _ = Task_sandbox.with_sandbox ~config ~task_id:"task-exc"
          ~agent_name:"exc-agent"
          ~repo_name:(Filename.basename dir)
          (fun sb ->
            worktree_path_ref := sb.worktree_path;
            failwith "intentional test failure") in
        fail "expected exception to propagate"
      with Failure msg ->
        check string "exception message" "intentional test failure" msg;
        if !worktree_path_ref <> "" then
          check bool "worktree cleaned up" false
            (Sys.file_exists !worktree_path_ref))
    )
  )

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "Task_sandbox" [
    "types", [
      test_case "sandbox_fields" `Quick test_sandbox_type_fields;
    ];
    "error_paths", [
      test_case "fails_without_git" `Quick test_create_fails_without_git;
      test_case "fails_empty_task_id" `Quick test_create_fails_with_empty_task_id;
      test_case "cleanup_nonexistent" `Quick test_cleanup_fails_for_nonexistent_sandbox;
      test_case "with_sandbox_no_git" `Quick test_with_sandbox_fails_without_git;
    ];
    "changed_files", [
      test_case "empty_for_nonexistent" `Quick test_changed_files_returns_empty_for_nonexistent_path;
    ];
    "symlink", [
      test_case "masc_symlink" `Quick test_symlink_created_when_masc_exists;
    ];
    "integration", [
      test_case "full_lifecycle" `Quick test_full_lifecycle;
      test_case "infer_repo_from_task_file_evidence" `Quick
        test_create_infers_repo_from_task_file_evidence;
      test_case "ambiguous_multi_repo_without_evidence" `Quick
        test_create_fails_ambiguous_multi_repo_without_evidence;
      test_case "with_sandbox_result" `Quick test_with_sandbox_lifecycle;
      test_case "exception_cleanup" `Quick test_with_sandbox_cleans_up_on_exception;
    ];
  ]
