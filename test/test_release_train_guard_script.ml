open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () =
  Filename.concat (source_root ()) "scripts/check-release-train-guard.sh"

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen
    && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

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
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let run_process ~cwd prog argv =
  let out = Filename.temp_file "release-train-guard-out" ".txt" in
  let err = Filename.temp_file "release-train-guard-err" ".txt" in
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

let run_process_ok ~cwd prog argv =
  let code, stdout, stderr = run_process ~cwd prog argv in
  if code <> 0 then
    failf "command failed (%d): %s\nstdout:\n%s\nstderr:\n%s" code prog stdout
      stderr;
  (stdout, stderr)

let git_ok ~cwd args =
  ignore (run_process_ok ~cwd "git" (Array.of_list ("git" :: args)))

let install_script_under_test dir =
  let target = Filename.concat dir "scripts/check-release-train-guard.sh" in
  mkdir_p (Filename.dirname target);
  write_file target (read_file (script_path ()));
  Unix.chmod target 0o755;
  target

let write_dune_project ~dir ~version =
  write_file (Filename.concat dir "dune-project")
    (Printf.sprintf "(lang dune 3.17)\n\n(name masc)\n(version %s)\n" version)

let commit_version ~dir ~version ~message =
  write_dune_project ~dir ~version;
  git_ok ~cwd:dir [ "add"; "dune-project" ];
  git_ok ~cwd:dir
    [ "-c"; "core.hooksPath=/dev/null"; "commit"; "-q"; "-m"; message ]

let init_repo_with_release_tags dir =
  git_ok ~cwd:dir [ "init"; "-q" ];
  git_ok ~cwd:dir [ "config"; "user.email"; "test@example.com" ];
  git_ok ~cwd:dir [ "config"; "user.name"; "tester" ];
  git_ok ~cwd:dir [ "checkout"; "-qb"; "main" ];
  commit_version ~dir ~version:"2.263.0" ~message:"main release";
  git_ok ~cwd:dir [ "tag"; "v2.263.0" ];
  git_ok ~cwd:dir [ "checkout"; "-qb"; "seed/zero-series" ];
  commit_version ~dir ~version:"0.1.1" ~message:"seed zero release";
  git_ok ~cwd:dir [ "tag"; "v0.1.1" ];
  git_ok ~cwd:dir [ "checkout"; "main" ]

let commit_on_branch ~dir ~branch ~version ~message =
  git_ok ~cwd:dir [ "checkout"; "-qb"; branch ];
  commit_version ~dir ~version ~message;
  let stdout, _stderr =
    run_process_ok ~cwd:dir "git" [| "git"; "rev-parse"; "--short"; "HEAD" |]
  in
  String.trim stdout

let test_cross_major_reset_ignores_legacy_2x_tags () =
  with_temp_dir "release-train-reset" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"version-reset" ~version:"0.2.0"
           ~message:"reset active line");
      let code, stdout, stderr =
        run_process ~cwd:dir script
          [| script; "--base"; "main"; "--head"; "version-reset" |]
      in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "uses base major tag lineage" true
        (contains_substring stdout
           "Release train guard OK: base=2.263.0 head=0.2.0 latest_tag_ref=v2.263.0 latest_tag_version=2.263.0"))

let test_cross_major_reset_rejects_older_head_series_version () =
  with_temp_dir "release-train-older-head" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"bad-reset" ~version:"0.1.0"
           ~message:"bad reset");
      let code, _stdout, stderr =
        run_process ~cwd:dir script
          [| script; "--base"; "main"; "--head"; "bad-reset" |]
      in
      check bool "command fails" true (code <> 0);
      check bool "mentions older head series tag" true
        (contains_substring stderr
           "older than latest tag v0.1.1 in major 0"))

let test_train_build_suffix_tag_matches_package_version () =
  with_temp_dir "release-train-build-suffix" (fun dir ->
      git_ok ~cwd:dir [ "init"; "-q" ];
      git_ok ~cwd:dir [ "config"; "user.email"; "test@example.com" ];
      git_ok ~cwd:dir [ "config"; "user.name"; "tester" ];
      git_ok ~cwd:dir [ "checkout"; "-qb"; "main" ];
      commit_version ~dir ~version:"0.19.10" ~message:"main release";
      git_ok ~cwd:dir [ "tag"; "v0.19.10-505" ];
      let script = install_script_under_test dir in
      let code, stdout, stderr =
        run_process ~cwd:dir script
          [| script; "--base"; "main"; "--head"; "main" |]
      in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "normalizes train build tag suffix" true
        (contains_substring stdout
           "Release train guard OK: base=0.19.10 head=0.19.10 latest_tag_ref=v0.19.10-505 latest_tag_version=0.19.10"))

let test_no_base_logs_raw_suffixed_tag_ref () =
  with_temp_dir "release-train-no-base-suffix" (fun dir ->
      git_ok ~cwd:dir [ "init"; "-q" ];
      git_ok ~cwd:dir [ "config"; "user.email"; "test@example.com" ];
      git_ok ~cwd:dir [ "config"; "user.name"; "tester" ];
      git_ok ~cwd:dir [ "checkout"; "-qb"; "main" ];
      commit_version ~dir ~version:"0.19.10" ~message:"main release";
      git_ok ~cwd:dir [ "tag"; "v0.19.10-505" ];
      let script = install_script_under_test dir in
      let code, stdout, stderr =
        run_process ~cwd:dir script [| script; "--head"; "main" |]
      in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "prints raw tag ref and normalized version" true
        (contains_substring stdout
           "Release train guard OK: no base ref provided, head=0.19.10 latest_tag_ref=v0.19.10-505 latest_tag_version=0.19.10"))

let test_pending_bootstrap_series_warns_without_blocking_same_version () =
  with_temp_dir "release-train-bootstrap" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"version-reset" ~version:"0.2.0"
           ~message:"reset active line");
      let code, stdout, stderr =
        run_process ~cwd:dir script
          [| script; "--base"; "version-reset"; "--head"; "version-reset" |]
      in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "warns for pending tag" true
        (contains_substring stdout
           "Release train guard OK (warn): base=0.2.0 head=0.2.0 latest_tag_ref=v0.1.1 latest_tag_version=0.1.1 (pending release)"))

let test_pending_bootstrap_series_blocks_next_train_until_tagged () =
  with_temp_dir "release-train-block-next" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"version-reset" ~version:"0.2.0"
           ~message:"reset active line");
      git_ok ~cwd:dir [ "checkout"; "version-reset" ];
      git_ok ~cwd:dir [ "checkout"; "-qb"; "next-train" ];
      commit_version ~dir ~version:"0.3.0" ~message:"next train";
      let code, _stdout, stderr =
        run_process ~cwd:dir script
          [| script; "--base"; "version-reset"; "--head"; "next-train" |]
      in
      check bool "command fails" true (code <> 0);
      check bool "requires pending tag first" true
        (contains_substring stderr
           "publish/tag v0.2.0 before widening the release train"))

let () =
  run "release_train_guard_script"
    [
      ( "script",
        [
          test_case "cross-major reset ignores legacy 2.x tags" `Quick
            test_cross_major_reset_ignores_legacy_2x_tags;
          test_case "cross-major reset rejects older head series version" `Quick
            test_cross_major_reset_rejects_older_head_series_version;
          test_case "train build suffix tag matches package version" `Quick
            test_train_build_suffix_tag_matches_package_version;
          test_case "no-base run logs raw suffixed tag ref" `Quick
            test_no_base_logs_raw_suffixed_tag_ref;
          test_case "pending bootstrap series warns on same version" `Quick
            test_pending_bootstrap_series_warns_without_blocking_same_version;
          test_case "pending bootstrap series blocks next train" `Quick
            test_pending_bootstrap_series_blocks_next_train_until_tagged;
        ] );
    ]
