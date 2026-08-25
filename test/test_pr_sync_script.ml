open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () = Filename.concat (source_root ()) "scripts/check-pr-sync.sh"
let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path content = Out_channel.with_open_bin path (fun oc -> output_string oc content)

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let run_process ~cwd prog argv =
  let out = Filename.temp_file "pr-sync-out" ".txt" in
  let err = Filename.temp_file "pr-sync-err" ".txt" in
  let out_fd = Unix.openfile out [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile err [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let original_cwd = Sys.getcwd () in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir original_cwd;
        Unix.close out_fd;
        Unix.close err_fd)
      (fun () ->
        Sys.chdir cwd;
        Unix.create_process prog argv Unix.stdin out_fd err_fd)
  in
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED code -> code
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let run_ok ~cwd prog args =
  let argv = Array.of_list (prog :: args) in
  let code, stdout, stderr = run_process ~cwd prog argv in
  if code <> 0 then
    failf "command failed (%d): %s\nstdout:\n%s\nstderr:\n%s" code prog stdout stderr;
  String.trim stdout

let git_ok ~cwd args = ignore (run_ok ~cwd "git" args)
let git_output ~cwd args = run_ok ~cwd "git" args

let write_dune_project ~dir ~version =
  write_file (Filename.concat dir "dune-project")
    (Printf.sprintf "(lang dune 3.17)\n\n(name masc)\n(version %s)\n" version)

let commit_all ~dir ~message =
  git_ok ~cwd:dir [ "add"; "." ];
  git_ok ~cwd:dir [ "-c"; "core.hooksPath=/dev/null"; "commit"; "-q"; "-m"; message ]

let install_script_under_test dir =
  let target = Filename.concat dir "scripts/check-pr-sync.sh" in
  mkdir_p (Filename.dirname target);
  write_file target (read_file (script_path ()));
  Unix.chmod target 0o755;
  target

let with_stale_feature_and_merge_result f =
  with_temp_dir "pr-sync" (fun root ->
      let repo = Filename.concat root "repo" in
      let remote = Filename.concat root "remote.git" in
      Unix.mkdir repo 0o755;
      git_ok ~cwd:repo [ "init"; "-q" ];
      git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
      git_ok ~cwd:repo [ "config"; "user.name"; "tester" ];
      git_ok ~cwd:repo [ "checkout"; "-qb"; "main" ];
      write_dune_project ~dir:repo ~version:"0.21.2";
      commit_all ~dir:repo ~message:"old base";
      git_ok ~cwd:repo [ "checkout"; "-qb"; "stale-feature" ];
      write_file (Filename.concat repo "feature.txt") "unrelated change\n";
      commit_all ~dir:repo ~message:"feature";
      let feature_sha = git_output ~cwd:repo [ "rev-parse"; "HEAD" ] in
      git_ok ~cwd:repo [ "checkout"; "main" ];
      write_dune_project ~dir:repo ~version:"0.22.0";
      commit_all ~dir:repo ~message:"new package floor";
      git_ok ~cwd:repo [ "checkout"; "-qb"; "merge-result" ];
      git_ok ~cwd:repo [ "merge"; "--no-edit"; "stale-feature" ];
      git_ok ~cwd:root [ "init"; "--bare"; "-q"; remote ];
      git_ok ~cwd:repo [ "remote"; "add"; "origin"; remote ];
      git_ok ~cwd:repo [ "push"; "-q"; "origin"; "stale-feature" ];
      let script = install_script_under_test repo in
      f ~repo ~script ~feature_sha)

let with_current_base_downgrade_merge_result f =
  with_temp_dir "pr-sync-downgrade" (fun root ->
      let repo = Filename.concat root "repo" in
      let remote = Filename.concat root "remote.git" in
      Unix.mkdir repo 0o755;
      git_ok ~cwd:repo [ "init"; "-q" ];
      git_ok ~cwd:repo [ "config"; "user.email"; "test@example.com" ];
      git_ok ~cwd:repo [ "config"; "user.name"; "tester" ];
      git_ok ~cwd:repo [ "checkout"; "-qb"; "main" ];
      write_dune_project ~dir:repo ~version:"0.22.0";
      commit_all ~dir:repo ~message:"current package floor";
      git_ok ~cwd:repo [ "checkout"; "-qb"; "stale-feature" ];
      write_dune_project ~dir:repo ~version:"0.21.2";
      commit_all ~dir:repo ~message:"downgrade package";
      let feature_sha = git_output ~cwd:repo [ "rev-parse"; "HEAD" ] in
      git_ok ~cwd:repo [ "checkout"; "main" ];
      write_file (Filename.concat repo "base.txt") "new base work\n";
      commit_all ~dir:repo ~message:"advance base";
      git_ok ~cwd:repo [ "checkout"; "-qb"; "merge-result" ];
      git_ok ~cwd:repo [ "merge"; "--no-edit"; "stale-feature" ];
      git_ok ~cwd:root [ "init"; "--bare"; "-q"; remote ];
      git_ok ~cwd:repo [ "remote"; "add"; "origin"; remote ];
      git_ok ~cwd:repo [ "push"; "-q"; "origin"; "stale-feature" ];
      let script = install_script_under_test repo in
      f ~repo ~script ~feature_sha)

let run_guard ~repo ~script ~feature_sha extra_args =
  run_process ~cwd:repo script
    (Array.of_list
       (script
       :: [
            "--head-branch";
            "stale-feature";
            "--expected-head-sha";
            feature_sha;
            "--base-ref";
            "main";
          ]
       @ extra_args))

let test_merge_result_inherits_current_base_version () =
  with_stale_feature_and_merge_result (fun ~repo ~script ~feature_sha ->
      let code, stdout, stderr =
        run_guard ~repo ~script ~feature_sha [ "--version-ref"; "HEAD" ]
      in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "keeps exact remote head identity" true
        (String_util.contains_substring stdout
           ("expected_head_sha=" ^ feature_sha));
      check bool "evaluates checked-out merge result" true
        (String_util.contains_substring stdout "version_ref=HEAD"))

let test_merge_result_preserves_explicit_downgrade_failure () =
  with_current_base_downgrade_merge_result (fun ~repo ~script ~feature_sha ->
      let code, stdout, _stderr =
        run_guard ~repo ~script ~feature_sha [ "--version-ref"; "HEAD" ]
      in
      check bool "downgrade in merge result fails" true (code <> 0);
      check bool "evaluates checked-out merge result" true
        (String_util.contains_substring stdout "version_ref=HEAD");
      check bool "reports current base package floor" true
        (String_util.contains_substring stdout "package 0.22.0");
      check bool "reports downgraded merge-result version" true
        (String_util.contains_substring stdout "0.21.2"))

let test_default_version_ref_still_checks_exact_head () =
  with_stale_feature_and_merge_result (fun ~repo ~script ~feature_sha ->
      let code, stdout, _stderr = run_guard ~repo ~script ~feature_sha [] in
      check bool "stale package truth fails without merge result" true (code <> 0);
      check bool "defaults evaluated version ref to exact head" true
        (String_util.contains_substring stdout ("version_ref=" ^ feature_sha));
      check bool "reports base package floor" true
        (String_util.contains_substring stdout "package 0.22.0");
      check bool "reports evaluated head version" true
        (String_util.contains_substring stdout "0.21.2"))

let () =
  run "pr_sync_script"
    [
      ( "script",
        [
          test_case "merge result inherits current base package version" `Quick
            test_merge_result_inherits_current_base_version;
          test_case "merge result preserves explicit downgrade failure" `Quick
            test_merge_result_preserves_explicit_downgrade_failure;
          test_case "default version ref checks exact head" `Quick
            test_default_version_ref_still_checks_exact_head;
        ] );
    ]
