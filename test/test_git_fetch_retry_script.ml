open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

let script_path () = Filename.concat (source_root ()) "scripts/ci/git-fetch-retry.sh"
let quote = Filename.quote

let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec loop idx =
    idx + nlen <= hlen && (String.sub haystack idx nlen = needle || loop (idx + 1))
  in
  nlen = 0 || loop 0
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

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
  let out = Filename.temp_file "git-fetch-retry-out" ".txt" in
  let err = Filename.temp_file "git-fetch-retry-err" ".txt" in
  let wrapped = Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err) in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  code, stdout, stderr
;;

let make_fake_git dir =
  let bin_dir = Filename.concat dir "bin" in
  Unix.mkdir bin_dir 0o755;
  let git_path = Filename.concat bin_dir "git" in
  write_file
    git_path
    {|
#!/bin/sh
set -eu
log_file="${FAKE_GIT_LOG:?}"
state_file="${FAKE_GIT_STATE:?}"
fail_count="${FAKE_GIT_FAIL_COUNT:-0}"
attempt=0
if [ -f "$state_file" ]; then
  attempt=$(cat "$state_file")
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" >"$state_file"
printf '%s\n' "$*" >>"$log_file"
if [ "${1:-}" != "fetch" ]; then
  printf 'unexpected git subcommand: %s\n' "${1:-}" >&2
  exit 91
fi
if [ "$attempt" -le "$fail_count" ]; then
  printf 'remote: Internal Server Error\n' >&2
  printf 'fatal: unable to access https://github.com/example/repo: The requested URL returned error: 500\n' >&2
  exit 128
fi
printf 'fetch ok on attempt %s\n' "$attempt"
|};
  Unix.chmod git_path 0o755;
  bin_dir
;;

let nonempty_lines contents =
  contents
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")
;;

let test_retries_until_fetch_succeeds () =
  with_temp_dir "git-fetch-retry-success" (fun dir ->
    let fake_git_dir = make_fake_git dir in
    let fake_git_log = Filename.concat dir "git.log" in
    let fake_git_state = Filename.concat dir "git.state" in
    let path =
      Printf.sprintf
        "%s:%s"
        fake_git_dir
        (match Sys.getenv_opt "PATH" with
         | Some p -> p
         | None -> "")
    in
    let env =
      [ "PATH", path
      ; "FAKE_GIT_LOG", fake_git_log
      ; "FAKE_GIT_STATE", fake_git_state
      ; "FAKE_GIT_FAIL_COUNT", "2"
      ; "GIT_FETCH_RETRY_ATTEMPTS", "3"
      ; "GIT_FETCH_RETRY_DELAY_SECONDS", "0"
      ; "GIT_FETCH_RETRY_MAX_DELAY_SECONDS", "0"
      ]
    in
    let cmd =
      Printf.sprintf "/bin/bash %s origin main --depth=1" (quote (script_path ()))
    in
    let code, stdout, stderr = run_shell ~cwd:dir ~env cmd in
    if code <> 0
    then failf "git-fetch-retry failed (%d)\nstdout:\n%s\nstderr:\n%s" code stdout stderr;
    check
      bool
      "reports eventual success"
      true
      (contains_substring stdout "fetch ok on attempt 3");
    check
      bool
      "first retry warning emitted"
      true
      (contains_substring
         stderr
         "::warning::git fetch attempt 1/3 failed with exit 128; retrying in 0s");
    check
      bool
      "second retry warning emitted"
      true
      (contains_substring
         stderr
         "::warning::git fetch attempt 2/3 failed with exit 128; retrying in 0s");
    let git_calls = nonempty_lines (read_file fake_git_log) in
    check
      (list string)
      "fetch retried three times"
      [ "fetch origin main --depth=1"
      ; "fetch origin main --depth=1"
      ; "fetch origin main --depth=1"
      ]
      git_calls)
;;

let test_reports_failure_after_last_attempt () =
  with_temp_dir "git-fetch-retry-fail" (fun dir ->
    let fake_git_dir = make_fake_git dir in
    let fake_git_log = Filename.concat dir "git.log" in
    let fake_git_state = Filename.concat dir "git.state" in
    let path =
      Printf.sprintf
        "%s:%s"
        fake_git_dir
        (match Sys.getenv_opt "PATH" with
         | Some p -> p
         | None -> "")
    in
    let env =
      [ "PATH", path
      ; "FAKE_GIT_LOG", fake_git_log
      ; "FAKE_GIT_STATE", fake_git_state
      ; "FAKE_GIT_FAIL_COUNT", "5"
      ; "GIT_FETCH_RETRY_ATTEMPTS", "3"
      ; "GIT_FETCH_RETRY_DELAY_SECONDS", "0"
      ; "GIT_FETCH_RETRY_MAX_DELAY_SECONDS", "0"
      ]
    in
    let cmd =
      Printf.sprintf "/bin/bash %s origin main --depth=1" (quote (script_path ()))
    in
    let code, _stdout, stderr = run_shell ~cwd:dir ~env cmd in
    check bool "command fails after attempts exhausted" true (code <> 0);
    check
      bool
      "final failure message emitted"
      true
      (contains_substring stderr "git fetch failed after 3 attempt(s)");
    let git_calls = nonempty_lines (read_file fake_git_log) in
    check
      (list string)
      "fetch attempted exactly three times"
      [ "fetch origin main --depth=1"
      ; "fetch origin main --depth=1"
      ; "fetch origin main --depth=1"
      ]
      git_calls)
;;

let () =
  run
    "git_fetch_retry_script"
    [ ( "script"
      , [ test_case
            "retries transient 500s until fetch succeeds"
            `Quick
            test_retries_until_fetch_succeeds
        ; test_case
            "fails after exhausting retry budget"
            `Quick
            test_reports_failure_after_last_attempt
        ] )
    ]
;;
