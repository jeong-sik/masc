open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let script_path () =
  Filename.concat (source_root ()) "scripts/pr-open.sh"

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

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
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
    if env_prefix = "" then
      Printf.sprintf "cd %s && %s" (quote cwd) cmd
    else
      Printf.sprintf "cd %s && %s %s" (quote cwd) env_prefix cmd
  in
  let out = Filename.temp_file "pr-open-out" ".txt" in
  let err = Filename.temp_file "pr-open-err" ".txt" in
  let wrapped =
    Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err)
  in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  (code, stdout, stderr)

let run_shell_ok ?(env = []) ~cwd cmd =
  let code, stdout, stderr = run_shell ~env ~cwd cmd in
  if code <> 0 then
    failf "command failed (%d): %s\nstdout:\n%s\nstderr:\n%s" code cmd stdout
      stderr;
  (stdout, stderr)

let make_fake_gh dir =
  let bin_dir = Filename.concat dir "bin" in
  Unix.mkdir bin_dir 0o755;
  let gh_path = Filename.concat bin_dir "gh" in
  write_file gh_path
    {|
#!/bin/sh
set -eu
log_file="${FAKE_GH_LOG:?}"
labels_file="${FAKE_GH_LABELS:?}"
cmd1="${1:-}"
cmd2="${2:-}"
printf '%s %s\n' "$cmd1" "$cmd2" >>"$log_file"
case "${cmd1}:${cmd2}" in
  pr:list)
    exit 0
    ;;
  pr:create)
    printf 'https://github.com/example/test/pull/42\n'
    ;;
  pr:view)
    args="$*"
    case "$args" in
      *"state,isDraft,mergeStateStatus,headRefOid,url"*)
        printf 'state=OPEN draft=true mergeState=CLEAN head=abc123\nurl=https://github.com/example/test/pull/42\n'
        ;;
      *)
        if [ "${3:-}" = "https://github.com/example/test/pull/42" ]; then
          printf '42\n'
        else
          printf 'https://github.com/example/test/pull/42\n'
        fi
        ;;
    esac
    ;;
  api:*)
    cat >"$labels_file"
    ;;
  label:list)
    printf '[]\n'
    ;;
  label:create)
    exit 0
    ;;
  pr:checks)
    if [ "${FAKE_GH_ALLOW_CHECKS:-}" = "1" ]; then
      printf 'checks ok\n'
    else
      printf 'unexpected pr checks invocation\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'unexpected gh invocation: %s %s\n' "$cmd1" "$cmd2" >&2
    exit 1
    ;;
esac
|}
  ;
  Unix.chmod gh_path 0o755;
  bin_dir

let init_repo_with_remote dir =
  let remote_dir = Filename.concat dir "remote.git" in
  ignore (run_shell_ok ~cwd:dir "git init -q");
  ignore (run_shell_ok ~cwd:dir "git config user.email test@example.com");
  ignore (run_shell_ok ~cwd:dir "git config user.name tester");
  ignore (run_shell_ok ~cwd:dir "git checkout -qb main");
  mkdir_p (Filename.concat dir "docs");
  mkdir_p (Filename.concat dir "lib");
  write_file (Filename.concat dir "README.md") "# temp\n";
  ignore
    (run_shell_ok ~cwd:dir
       "git add README.md && git -c core.hooksPath=/dev/null commit -q -m base");
  ignore
    (run_shell_ok ~cwd:dir
       (Printf.sprintf "git init --bare -q %s" (quote remote_dir)));
  ignore
    (run_shell_ok ~cwd:dir
       (Printf.sprintf "git remote add origin %s" (quote remote_dir)));
  ignore (run_shell_ok ~cwd:dir "git push -u origin main");
  ignore (run_shell_ok ~cwd:dir "git checkout -qb feature/macos-pr-open");
  write_file (Filename.concat dir "lib/example.ml") "let value = 1\n";
  ignore
    (run_shell_ok ~cwd:dir
       "git add lib/example.ml && git -c core.hooksPath=/dev/null commit -q -m feature");
  ignore (run_shell_ok ~cwd:dir "git push -u origin feature/macos-pr-open")

let test_source_avoids_mapfile_only_bash4_features () =
  let content = read_file (script_path ()) in
  check bool "script no longer uses mapfile" false
    (contains_substring content "mapfile ");
  check bool "script no longer uses readarray" false
    (contains_substring content "readarray ");
  check bool "script has bash-compatible changed file loader" true
    (contains_substring content "load_changed_files()")

let test_script_runs_under_system_bash_without_watch () =
  with_temp_dir "pr-open-script" (fun dir ->
      init_repo_with_remote dir;
      let fake_gh_dir = make_fake_gh dir in
      let gh_log = Filename.concat dir "gh.log" in
      let gh_labels = Filename.concat dir "gh-labels.json" in
      let body_file = Filename.concat dir "body.md" in
      write_file body_file
        "## Summary\nTest body\n\n## Product impact\n- Promise affected: `none/internal`\n- User-visible change: none\n\n## Evidence\n- local script test\n\n## Review evidence\n- not applicable for script test\n\n## Linked issue\n- Refs #1234\n";
      let path =
        Printf.sprintf "%s:%s" fake_gh_dir
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env =
        [
          ("PATH", path);
          ("FAKE_GH_LOG", gh_log);
          ("FAKE_GH_LABELS", gh_labels);
        ]
      in
      let cmd =
        Printf.sprintf "/bin/bash %s --repo %s --title %s --body-file %s --no-watch"
          (quote (script_path ()))
          (quote "example/test")
          (quote "fix: macOS bash compatibility")
          (quote body_file)
      in
      let code, stdout, stderr = run_shell ~cwd:dir ~env cmd in
      if code <> 0 then
        failf "pr-open failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "prints PR url" true
        (contains_substring stdout "PR: https://github.com/example/test/pull/42");
      check bool "does not mention mapfile failure" false
        (contains_substring stderr "mapfile: command not found");
      let log = read_file gh_log in
      check bool "creates draft PR" true (contains_substring log "pr create");
      check bool "skips watched checks with --no-watch" false
        (contains_substring log "pr checks");
      let labels = read_file gh_labels in
      check bool "adds enhancement label for code changes" true
        (contains_substring labels "\"enhancement\"");
      check bool "adds agent-pr label for draft guard classification" true
        (contains_substring labels "\"agent-pr\"");
      check bool "does not add docs label for code-only change" false
        (contains_substring labels "\"docs\"");
      check bool "ensures agent-pr label exists" true
        (contains_substring log "label create"))

let test_script_prints_final_status_after_watch () =
  with_temp_dir "pr-open-script-watch-status" (fun dir ->
      init_repo_with_remote dir;
      let fake_gh_dir = make_fake_gh dir in
      let gh_log = Filename.concat dir "gh.log" in
      let gh_labels = Filename.concat dir "gh-labels.json" in
      let body_file = Filename.concat dir "body.md" in
      write_file body_file
        "## Summary\nTest body\n\n## Product impact\n- Promise affected: `none/internal`\n- User-visible change: none\n\n## Evidence\n- local script test\n\n## Review evidence\n- not applicable for script test\n\n## Linked issue\n- Refs #1234\n";
      let path =
        Printf.sprintf "%s:%s" fake_gh_dir
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env =
        [
          ("PATH", path);
          ("FAKE_GH_LOG", gh_log);
          ("FAKE_GH_LABELS", gh_labels);
          ("FAKE_GH_ALLOW_CHECKS", "1");
        ]
      in
      let cmd =
        Printf.sprintf "/bin/bash %s --repo %s --title %s --body-file %s"
          (quote (script_path ()))
          (quote "example/test")
          (quote "fix: print final status")
          (quote body_file)
      in
      let code, stdout, stderr = run_shell ~cwd:dir ~env cmd in
      if code <> 0 then
        failf "pr-open failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
      check bool "runs watched checks" true
        (contains_substring (read_file gh_log) "pr checks");
      check bool "prints final status heading" true
        (contains_substring stdout "PR status:");
      check bool "prints final draft state" true
        (contains_substring stdout "draft=true");
      check bool "prints final merge state" true
        (contains_substring stdout "mergeState=CLEAN"))

let test_script_rejects_body_missing_required_sections () =
  with_temp_dir "pr-open-script-missing-sections" (fun dir ->
      init_repo_with_remote dir;
      let fake_gh_dir = make_fake_gh dir in
      let gh_log = Filename.concat dir "gh.log" in
      let gh_labels = Filename.concat dir "gh-labels.json" in
      let body_file = Filename.concat dir "body.md" in
      write_file body_file "## Summary\nOnly summary present\n";
      let path =
        Printf.sprintf "%s:%s" fake_gh_dir
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env =
        [
          ("PATH", path);
          ("FAKE_GH_LOG", gh_log);
          ("FAKE_GH_LABELS", gh_labels);
        ]
      in
      let cmd =
        Printf.sprintf "/bin/bash %s --repo %s --title %s --body-file %s --no-watch"
          (quote (script_path ()))
          (quote "example/test")
          (quote "fix: reject incomplete PR body")
          (quote body_file)
      in
      let code, stdout, stderr = run_shell ~cwd:dir ~env cmd in
      check bool "command fails" true (code <> 0);
      check bool "stdout empty" true (String.trim stdout = "");
      check bool "mentions hygiene failure" true
        (contains_substring stderr "body file is missing required PR hygiene sections:");
      check bool "mentions product impact heading" true
        (contains_substring stderr "## Product impact");
      check bool "mentions linked issue heading" true
        (contains_substring stderr "## Linked issue");
      check bool "gh never invoked before validation" false
        (Sys.file_exists gh_log))

let test_script_rejects_staged_changes_before_push () =
  with_temp_dir "pr-open-script-staged-changes" (fun dir ->
      init_repo_with_remote dir;
      let fake_gh_dir = make_fake_gh dir in
      let gh_log = Filename.concat dir "gh.log" in
      let gh_labels = Filename.concat dir "gh-labels.json" in
      let body_file = Filename.concat dir "body.md" in
      write_file body_file
        "## Summary\nTest body\n\n## Product impact\n- Promise affected: `none/internal`\n- User-visible change: none\n\n## Evidence\n- local script test\n\n## Review evidence\n- not applicable for script test\n\n## Linked issue\n- Refs #1234\n";
      write_file (Filename.concat dir "lib/staged.ml") "let staged = true\n";
      ignore (run_shell_ok ~cwd:dir "git add lib/staged.ml");
      let path =
        Printf.sprintf "%s:%s" fake_gh_dir
          (match Sys.getenv_opt "PATH" with Some p -> p | None -> "")
      in
      let env =
        [
          ("PATH", path);
          ("FAKE_GH_LOG", gh_log);
          ("FAKE_GH_LABELS", gh_labels);
        ]
      in
      let cmd =
        Printf.sprintf "/bin/bash %s --repo %s --title %s --body-file %s --no-watch"
          (quote (script_path ()))
          (quote "example/test")
          (quote "fix: reject staged changes")
          (quote body_file)
      in
      let code, stdout, stderr = run_shell ~cwd:dir ~env cmd in
      check bool "command fails" true (code <> 0);
      check bool "stdout empty" true (String.trim stdout = "");
      check bool "mentions staged changes" true
        (contains_substring stderr "staged changes detected");
      check bool "mentions staged path" true
        (contains_substring stderr "lib/staged.ml");
      check bool "gh never invoked before staged validation" false
        (Sys.file_exists gh_log))

let () =
  run "pr_open_script"
    [
      ( "script",
        [
          test_case "source avoids mapfile-only bash4 features" `Quick
            test_source_avoids_mapfile_only_bash4_features;
          test_case "runs under system bash without watch" `Quick
            test_script_runs_under_system_bash_without_watch;
          test_case "prints final status after watch" `Quick
            test_script_prints_final_status_after_watch;
          test_case "rejects body missing required sections" `Quick
            test_script_rejects_body_missing_required_sections;
          test_case "rejects staged changes before push" `Quick
            test_script_rejects_staged_changes_before_push;
        ] );
    ]
