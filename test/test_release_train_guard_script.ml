open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () =
  Filename.concat (source_root ()) "scripts/check-release-train-guard.sh"

let quote = Filename.quote

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

let run_shell ~cwd cmd =
  let out = Filename.temp_file "release-train-guard-out" ".txt" in
  let err = Filename.temp_file "release-train-guard-err" ".txt" in
  let wrapped =
    Printf.sprintf "cd %s && %s > %s 2> %s" (quote cwd) cmd (quote out) (quote err)
  in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let run_shell_ok ~cwd cmd =
  let code, stdout, stderr = run_shell ~cwd cmd in
  if code <> 0 then
    failf "command failed (%d): %s\nstdout:\n%s\nstderr:\n%s" code cmd stdout
      stderr;
  (stdout, stderr)

let install_script_under_test dir =
  let target = Filename.concat dir "scripts/check-release-train-guard.sh" in
  mkdir_p (Filename.dirname target);
  write_file target (read_file (script_path ()));
  Unix.chmod target 0o755;
  target

let write_dune_project ~dir ~version =
  write_file (Filename.concat dir "dune-project")
    (Printf.sprintf "(lang dune 3.17)\n\n(name masc_mcp)\n(version %s)\n" version)

let commit_version ~dir ~version ~message =
  write_dune_project ~dir ~version;
  ignore
    (run_shell_ok ~cwd:dir
       (Printf.sprintf
          "git add dune-project && git -c core.hooksPath=/dev/null commit -q -m %s"
          (quote message)))

let init_repo_with_release_tags dir =
  ignore (run_shell_ok ~cwd:dir "git init -q");
  ignore (run_shell_ok ~cwd:dir "git config user.email test@example.com");
  ignore (run_shell_ok ~cwd:dir "git config user.name tester");
  ignore (run_shell_ok ~cwd:dir "git checkout -qb main");
  commit_version ~dir ~version:"2.263.0" ~message:"main release";
  ignore (run_shell_ok ~cwd:dir "git tag v2.263.0");
  ignore (run_shell_ok ~cwd:dir "git checkout -qb seed/zero-series");
  commit_version ~dir ~version:"0.1.1" ~message:"seed zero release";
  ignore (run_shell_ok ~cwd:dir "git tag v0.1.1");
  ignore (run_shell_ok ~cwd:dir "git checkout main")

let commit_on_branch ~dir ~branch ~version ~message =
  ignore (run_shell_ok ~cwd:dir (Printf.sprintf "git checkout -qb %s" branch));
  commit_version ~dir ~version ~message;
  let stdout, _stderr = run_shell_ok ~cwd:dir "git rev-parse --short HEAD" in
  String.trim stdout

let test_cross_major_reset_ignores_legacy_2x_tags () =
  with_temp_dir "release-train-reset" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"version-reset" ~version:"0.2.0"
           ~message:"reset active line");
      let cmd =
        Printf.sprintf "/bin/bash %s --base main --head version-reset"
          (quote script)
      in
      let code, stdout, stderr = run_shell ~cwd:dir cmd in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "uses base major tag lineage" true
        (contains_substring stdout
           "Release train guard OK: base=2.263.0 head=0.2.0 latest_tag=2.263.0"))

let test_cross_major_reset_rejects_older_head_series_version () =
  with_temp_dir "release-train-older-head" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"bad-reset" ~version:"0.1.0"
           ~message:"bad reset");
      let cmd =
        Printf.sprintf "/bin/bash %s --base main --head bad-reset"
          (quote script)
      in
      let code, _stdout, stderr = run_shell ~cwd:dir cmd in
      check bool "command fails" true (code <> 0);
      check bool "mentions older head series tag" true
        (contains_substring stderr
           "older than latest tag v0.1.1 in major 0"))

let test_pending_bootstrap_series_warns_without_blocking_same_version () =
  with_temp_dir "release-train-bootstrap" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"version-reset" ~version:"0.2.0"
           ~message:"reset active line");
      let cmd =
        Printf.sprintf "/bin/bash %s --base version-reset --head version-reset"
          (quote script)
      in
      let code, stdout, stderr = run_shell ~cwd:dir cmd in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "warns for pending tag" true
        (contains_substring stdout
           "Release train guard OK (warn): base=0.2.0 head=0.2.0 latest_tag=0.1.1 (pending release)"))

let test_pending_bootstrap_series_blocks_next_train_until_tagged () =
  with_temp_dir "release-train-block-next" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"version-reset" ~version:"0.2.0"
           ~message:"reset active line");
      ignore
        (run_shell_ok ~cwd:dir "git checkout version-reset && git checkout -qb next-train");
      commit_version ~dir ~version:"0.3.0" ~message:"next train";
      let cmd =
        Printf.sprintf "/bin/bash %s --base version-reset --head next-train"
          (quote script)
      in
      let code, _stdout, stderr = run_shell ~cwd:dir cmd in
      check bool "command fails" true (code <> 0);
      check bool "requires pending tag first" true
        (contains_substring stderr
           "publish/tag v0.2.0 before widening the release train"))

let test_suffixed_release_tag_uses_tagged_package_version () =
  with_temp_dir "release-train-suffixed-tag" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (commit_on_branch ~dir ~branch:"suffixed-release" ~version:"0.2.0"
           ~message:"reset active line");
      ignore (run_shell_ok ~cwd:dir "git tag v0.2.0-505");
      let cmd =
        Printf.sprintf "/bin/bash %s --base suffixed-release --head suffixed-release"
          (quote script)
      in
      let code, stdout, stderr = run_shell ~cwd:dir cmd in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "uses package version from suffixed tag" true
        (contains_substring stdout
           "Release train guard OK: base=0.2.0 head=0.2.0 latest_tag=0.2.0"))

let test_legacy_tag_without_dune_project_falls_back_to_tag_version () =
  with_temp_dir "release-train-legacy-tag" (fun dir ->
      init_repo_with_release_tags dir;
      let script = install_script_under_test dir in
      ignore
        (run_shell_ok ~cwd:dir
           "git checkout --orphan legacy-no-dune && git rm -qf dune-project && git commit --allow-empty -q -m legacy-no-dune && git tag v0.3.0 && git checkout main");
      ignore
        (commit_on_branch ~dir ~branch:"version-reset" ~version:"0.3.0"
           ~message:"reset active line");
      let cmd =
        Printf.sprintf "/bin/bash %s --base version-reset --head version-reset"
          (quote script)
      in
      let code, stdout, stderr = run_shell ~cwd:dir cmd in
      if code <> 0 then
        failf "guard failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "falls back to raw tag version" true
        (contains_substring stdout
           "Release train guard OK: base=0.3.0 head=0.3.0 latest_tag=0.3.0"))

let () =
  run "release_train_guard_script"
    [
      ( "script",
        [
          test_case "cross-major reset ignores legacy 2.x tags" `Quick
            test_cross_major_reset_ignores_legacy_2x_tags;
          test_case "cross-major reset rejects older head series version" `Quick
            test_cross_major_reset_rejects_older_head_series_version;
          test_case "pending bootstrap series warns on same version" `Quick
            test_pending_bootstrap_series_warns_without_blocking_same_version;
          test_case "pending bootstrap series blocks next train" `Quick
            test_pending_bootstrap_series_blocks_next_train_until_tagged;
          test_case "suffixed release tag uses tagged package version" `Quick
            test_suffixed_release_tag_uses_tagged_package_version;
          test_case "legacy tag without dune-project falls back" `Quick
            test_legacy_tag_without_dune_project_falls_back_to_tag_version;
        ] );
    ]
