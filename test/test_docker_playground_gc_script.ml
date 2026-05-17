open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let cleanup_script_path () =
  Filename.concat (source_root ()) "scripts/cleanup-docker-playground-worktrees.sh"

let status_script_path () =
  Filename.concat (source_root ()) "scripts/docker-playground-fd-status.sh"

let quote = Filename.quote

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let run_shell ?(env = []) ~cwd cmd =
  let env_prefix =
    env
    |> List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v))
    |> String.concat " "
  in
  let full =
    if env_prefix = ""
    then Printf.sprintf "cd %s && %s" (quote cwd) cmd
    else Printf.sprintf "cd %s && %s %s" (quote cwd) env_prefix cmd
  in
  let out = Filename.temp_file "docker-playground-gc-out" ".txt" in
  let err = Filename.temp_file "docker-playground-gc-err" ".txt" in
  let wrapped = Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err) in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  code, stdout, stderr

let run_shell_ok ?(env = []) ~cwd cmd =
  let code, stdout, stderr = run_shell ~env ~cwd cmd in
  if code <> 0 then failf "command failed (%d): %s\n%s" code cmd stderr;
  stdout, stderr

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let init_repo repo_dir =
  mkdir_p repo_dir;
  ignore (run_shell_ok ~cwd:repo_dir "git init -q");
  ignore (run_shell_ok ~cwd:repo_dir "git config user.email test@example.com");
  ignore (run_shell_ok ~cwd:repo_dir "git config user.name Test");
  write_file (Filename.concat repo_dir "README.md") "base\n";
  ignore (run_shell_ok ~cwd:repo_dir "git add README.md");
  ignore
    (run_shell_ok
       ~env:
         [ "GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"
         ; "GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"
         ]
       ~cwd:repo_dir
       "git commit -q -m init")

let mark_path_old ~cwd path =
  ignore
    (run_shell_ok ~cwd
       (Printf.sprintf "touch -t 200001010000 %s" (quote path)))

let test_scripts_are_syntax_valid () =
  let cmd =
    Printf.sprintf "bash -n %s && bash -n %s" (quote (cleanup_script_path ()))
      (quote (status_script_path ()))
  in
  ignore (run_shell_ok ~cwd:(source_root ()) cmd)

let test_dry_run_lists_stale_clean_worktree () =
  with_temp_dir "docker-playground-gc-dry-run" (fun dir ->
    let root = Filename.concat dir ".masc/playground/docker" in
    let repo_dir = Filename.concat root "keeper-a/repos/masc-mcp" in
    init_repo repo_dir;
    mkdir_p (Filename.concat repo_dir ".worktrees");
    let wt_path = Filename.concat repo_dir ".worktrees/stale-task" in
    ignore
      (run_shell_ok ~cwd:repo_dir
         (Printf.sprintf "git worktree add -q -b stale-task %s" (quote wt_path)));
    mark_path_old ~cwd:repo_dir wt_path;
    let stdout, _ =
      run_shell_ok ~cwd:(source_root ())
        (Printf.sprintf "%s --root %s --days 1 --repo masc-mcp"
           (quote (cleanup_script_path ()))
           (quote root))
    in
    check bool "candidate listed" true (contains_substring stdout "CANDID");
    check bool "dry-run reminder" true (contains_substring stdout "Pass --apply");
    check bool "worktree retained" true (Sys.file_exists wt_path))

let test_recent_checkout_of_old_commit_is_not_candidate () =
  with_temp_dir "docker-playground-gc-recent" (fun dir ->
    let root = Filename.concat dir ".masc/playground/docker" in
    let repo_dir = Filename.concat root "keeper-a/repos/masc-mcp" in
    init_repo repo_dir;
    mkdir_p (Filename.concat repo_dir ".worktrees");
    let wt_path = Filename.concat repo_dir ".worktrees/recent-task" in
    ignore
      (run_shell_ok ~cwd:repo_dir
         (Printf.sprintf "git worktree add -q -b recent-task %s" (quote wt_path)));
    let stdout, _ =
      run_shell_ok ~cwd:(source_root ())
        (Printf.sprintf "%s --root %s --days 1 --repo masc-mcp"
           (quote (cleanup_script_path ()))
           (quote root))
    in
    check bool "candidate not listed" false (contains_substring stdout "CANDID");
    check bool "recent counted" true (contains_substring stdout "recent=1");
    check bool "worktree retained" true (Sys.file_exists wt_path))

let test_apply_removes_stale_clean_worktree () =
  with_temp_dir "docker-playground-gc-apply" (fun dir ->
    let root = Filename.concat dir ".masc/playground/docker" in
    let repo_dir = Filename.concat root "keeper-a/repos/masc-mcp" in
    init_repo repo_dir;
    mkdir_p (Filename.concat repo_dir ".worktrees");
    let wt_path = Filename.concat repo_dir ".worktrees/stale-task" in
    ignore
      (run_shell_ok ~cwd:repo_dir
         (Printf.sprintf "git worktree add -q -b stale-task %s" (quote wt_path)));
    mark_path_old ~cwd:repo_dir wt_path;
    let stdout, _ =
      run_shell_ok ~cwd:(source_root ())
        (Printf.sprintf "%s --root %s --days 1 --repo masc-mcp --apply"
           (quote (cleanup_script_path ()))
           (quote root))
    in
    check bool "removed listed" true (contains_substring stdout "REMOVED");
    check bool "worktree removed" false (Sys.file_exists wt_path))

let test_apply_skips_dirty_worktree () =
  with_temp_dir "docker-playground-gc-dirty" (fun dir ->
    let root = Filename.concat dir ".masc/playground/docker" in
    let repo_dir = Filename.concat root "keeper-a/repos/masc-mcp" in
    init_repo repo_dir;
    mkdir_p (Filename.concat repo_dir ".worktrees");
    let wt_path = Filename.concat repo_dir ".worktrees/dirty-task" in
    ignore
      (run_shell_ok ~cwd:repo_dir
         (Printf.sprintf "git worktree add -q -b dirty-task %s" (quote wt_path)));
    write_file (Filename.concat wt_path "dirty.txt") "keep me\n";
    mark_path_old ~cwd:repo_dir wt_path;
    let stdout, _ =
      run_shell_ok ~cwd:(source_root ())
        (Printf.sprintf "%s --root %s --days 1 --repo masc-mcp --apply"
           (quote (cleanup_script_path ()))
           (quote root))
    in
    check bool "dirty listed" true (contains_substring stdout "DIRTY");
    check bool "dirty worktree retained" true (Sys.file_exists wt_path))

let test_include_broken_removes_old_non_git_directory () =
  with_temp_dir "docker-playground-gc-broken" (fun dir ->
    let root = Filename.concat dir ".masc/playground/docker" in
    let broken_path =
      Filename.concat root "keeper-a/repos/masc-mcp/.worktrees/broken-task"
    in
    mkdir_p broken_path;
    write_file (Filename.concat broken_path "note.txt") "orphan\n";
    mark_path_old ~cwd:dir broken_path;
    let dry_stdout, _ =
      run_shell_ok ~cwd:(source_root ())
        (Printf.sprintf
           "%s --root %s --days 1 --repo masc-mcp --include-broken"
           (quote (cleanup_script_path ()))
           (quote root))
    in
    check bool "broken candidate listed" true
      (contains_substring dry_stdout "BROKEN_CANDID");
    check bool "broken retained after dry-run" true (Sys.file_exists broken_path);
    let apply_stdout, _ =
      run_shell_ok ~cwd:(source_root ())
        (Printf.sprintf
           "%s --root %s --days 1 --repo masc-mcp --include-broken --apply"
           (quote (cleanup_script_path ()))
           (quote root))
    in
    check bool "broken removed listed" true
      (contains_substring apply_stdout "BROKEN_REMOVED");
    check bool "broken removed" false (Sys.file_exists broken_path))

let () =
  run "docker_playground_gc_script"
    [ ( "script"
      , [ test_case "syntax valid" `Quick test_scripts_are_syntax_valid
        ; test_case "dry-run lists stale clean worktree" `Quick
            test_dry_run_lists_stale_clean_worktree
        ; test_case "recent checkout of old commit is not candidate" `Quick
            test_recent_checkout_of_old_commit_is_not_candidate
        ; test_case "apply removes stale clean worktree" `Quick
            test_apply_removes_stale_clean_worktree
        ; test_case "apply skips dirty worktree" `Quick test_apply_skips_dirty_worktree
        ; test_case "include-broken removes old non-git directory" `Quick
            test_include_broken_removes_old_non_git_directory
        ] )
    ]
