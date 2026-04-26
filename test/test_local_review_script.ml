open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

let script_path () = Filename.concat (source_root ()) "scripts/review/local-review.sh"
let quote = Filename.quote
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

let rec mkdir_p path =
  if path = "" || path = "." || path = "/"
  then ()
  else if Sys.file_exists path
  then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)
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
  let out = Filename.temp_file "local-review-out" ".txt" in
  let err = Filename.temp_file "local-review-err" ".txt" in
  let wrapped = Printf.sprintf "%s > %s 2> %s" full (quote out) (quote err) in
  let code = Sys.command wrapped in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  code, stdout, stderr
;;

let run_shell_ok ?(env = []) ~cwd cmd =
  let code, stdout, stderr = run_shell ~env ~cwd cmd in
  if code <> 0 then failf "command failed (%d): %s\n%s" code cmd stderr;
  stdout, stderr
;;

let spawn_shell ?(env = []) ~cwd cmd =
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
  let out = Filename.temp_file "local-review-out" ".txt" in
  let err = Filename.temp_file "local-review-err" ".txt" in
  let out_fd = Unix.openfile out [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o644 in
  let err_fd = Unix.openfile err [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o644 in
  let pid =
    Unix.create_process "/bin/sh" [| "/bin/sh"; "-lc"; full |] Unix.stdin out_fd err_fd
  in
  Unix.close out_fd;
  Unix.close err_fd;
  pid, out, err
;;

let wait_process (pid, out, err) =
  let _, status = Unix.waitpid [] pid in
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
  in
  let stdout = read_file out in
  let stderr = read_file err in
  Sys.remove out;
  Sys.remove err;
  code, stdout, stderr
;;

let command_output ~cwd cmd =
  let stdout, _stderr = run_shell_ok ~cwd cmd in
  String.trim stdout
;;

let init_repo dir =
  ignore (run_shell_ok ~cwd:dir "git init -q");
  ignore (run_shell_ok ~cwd:dir "git config user.email test@example.com");
  ignore (run_shell_ok ~cwd:dir "git config user.name tester");
  write_file (Filename.concat dir "alpha.txt") "alpha base\n";
  write_file (Filename.concat dir "beta.txt") "beta base\n";
  ignore
    (run_shell_ok
       ~cwd:dir
       "git add alpha.txt beta.txt && git -c core.hooksPath=/dev/null commit -q -m base");
  let base_sha = command_output ~cwd:dir "git rev-parse HEAD" in
  write_file (Filename.concat dir "alpha.txt") "alpha changed once\nalpha changed twice\n";
  write_file (Filename.concat dir "beta.txt") "beta changed once\nbeta changed twice\n";
  ignore
    (run_shell_ok
       ~cwd:dir
       "git add alpha.txt beta.txt && git -c core.hooksPath=/dev/null commit -q -m head");
  let head_sha = command_output ~cwd:dir "git rev-parse HEAD" in
  base_sha, head_sha
;;

let make_fake_reviewer dir =
  let path = Filename.concat dir "fake-reviewer.sh" in
  write_file
    path
    {|
#!/usr/bin/env bash
set -euo pipefail
count_file="${COUNT_FILE:?}"
sleep_secs="${SLEEP_SECS:-0}"
if [ "$sleep_secs" != "0" ]; then
  sleep "$sleep_secs"
fi
count=0
if [ -f "$count_file" ]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s' "$count" > "$count_file"
cat >/dev/null
printf '%s\n' "${FAKE_REVIEW_OUTPUT:-No findings.}"
|};
  Unix.chmod path 0o755;
  path
;;

let parse_json_output stdout = Yojson.Safe.from_string stdout

let review_cmd script base_sha head_sha =
  String.concat
    " "
    [ quote script
    ; "--base"
    ; quote base_sha
    ; "--head"
    ; quote head_sha
    ; "--format"
    ; "json"
    ]
;;

let test_cache_hit_and_chunking () =
  with_temp_dir "local-review-cache-test" (fun dir ->
    let base_sha, head_sha = init_repo dir in
    let fake = make_fake_reviewer dir in
    let count_file = Filename.concat dir "count.txt" in
    let cache_dir = Filename.concat dir ".masc/review-cache/local-review" in
    let env =
      [ "MASC_LOCAL_REVIEW_COMMAND", fake
      ; "COUNT_FILE", count_file
      ; "MASC_LOCAL_REVIEW_CACHE_DIR", cache_dir
      ; "MASC_LOCAL_REVIEW_CHUNK_BYTES", "20"
      ]
    in
    let code1, stdout1, stderr1 =
      run_shell ~cwd:dir ~env (review_cmd (script_path ()) base_sha head_sha)
    in
    if code1 <> 0 then failf "first run failed (%d): %s" code1 stderr1;
    check string "first run stderr empty" "" stderr1;
    let json1 = parse_json_output stdout1 in
    let open Yojson.Safe.Util in
    let chunk_count = json1 |> member "chunk_count" |> to_int in
    check bool "first run is cache miss" false (json1 |> member "cache_hit" |> to_bool);
    check bool "chunking happened" true (chunk_count >= 2);
    check string "first result" "No findings." (json1 |> member "result" |> to_string);
    check
      string
      "first run reviewer calls match chunk count"
      (string_of_int chunk_count)
      (read_file count_file);
    let code2, stdout2, stderr2 =
      run_shell ~cwd:dir ~env (review_cmd (script_path ()) base_sha head_sha)
    in
    if code2 <> 0 then failf "second run failed (%d): %s" code2 stderr2;
    check string "second run stderr empty" "" stderr2;
    let json2 = parse_json_output stdout2 in
    check bool "second run is cache hit" true (json2 |> member "cache_hit" |> to_bool);
    check
      string
      "second run reuses cached result"
      (string_of_int chunk_count)
      (read_file count_file))
;;

let test_single_flight_reuses_pending_worker () =
  with_temp_dir "local-review-single-flight" (fun dir ->
    let base_sha, head_sha = init_repo dir in
    let fake = make_fake_reviewer dir in
    let count_file = Filename.concat dir "count.txt" in
    let cache_dir = Filename.concat dir ".masc/review-cache/local-review" in
    let env =
      [ "MASC_LOCAL_REVIEW_COMMAND", fake
      ; "COUNT_FILE", count_file
      ; "SLEEP_SECS", "2"
      ; "MASC_LOCAL_REVIEW_CACHE_DIR", cache_dir
      ; "MASC_LOCAL_REVIEW_STALE_SECS", "30"
      ]
    in
    let cmd = review_cmd (script_path ()) base_sha head_sha in
    let p1 = spawn_shell ~cwd:dir ~env cmd in
    ignore (Unix.select [] [] [] 0.2);
    let p2 = spawn_shell ~cwd:dir ~env cmd in
    let code1, stdout1, stderr1 = wait_process p1 in
    let code2, stdout2, stderr2 = wait_process p2 in
    if code1 <> 0 then failf "first process failed (%d): %s" code1 stderr1;
    if code2 <> 0 then failf "second process failed (%d): %s" code2 stderr2;
    let open Yojson.Safe.Util in
    let json1 = parse_json_output stdout1 in
    let json2 = parse_json_output stdout2 in
    check string "single-flight count" "1" (read_file count_file);
    check
      bool
      "one cache miss exists"
      true
      ((not (json1 |> member "cache_hit" |> to_bool))
       || not (json2 |> member "cache_hit" |> to_bool));
    check
      bool
      "one cache hit exists"
      true
      (json1 |> member "cache_hit" |> to_bool || json2 |> member "cache_hit" |> to_bool))
;;

let test_stale_pending_is_reaped () =
  with_temp_dir "local-review-stale" (fun dir ->
    let base_sha, head_sha = init_repo dir in
    let fake = make_fake_reviewer dir in
    let count_file = Filename.concat dir "count.txt" in
    let cache_dir = Filename.concat dir ".masc/review-cache/local-review" in
    let env =
      [ "MASC_LOCAL_REVIEW_COMMAND", fake
      ; "COUNT_FILE", count_file
      ; "MASC_LOCAL_REVIEW_CACHE_DIR", cache_dir
      ; "MASC_LOCAL_REVIEW_STALE_SECS", "1"
      ]
    in
    let key_cmd =
      String.concat
        " "
        [ quote (script_path ())
        ; "--base"
        ; quote base_sha
        ; "--head"
        ; quote head_sha
        ; "--print-cache-key"
        ]
    in
    let cache_key = command_output ~cwd:dir key_cmd in
    let lock_dir =
      Filename.concat cache_dir (Filename.concat "locks" (cache_key ^ ".lock"))
    in
    let pending_file =
      Filename.concat cache_dir (Filename.concat "index" (cache_key ^ ".pending.json"))
    in
    mkdir_p (Filename.concat cache_dir "locks");
    mkdir_p (Filename.concat cache_dir "index");
    mkdir_p (Filename.concat cache_dir "results");
    Unix.mkdir lock_dir 0o755;
    write_file
      pending_file
      {|{"pid":999999,"started_at_epoch":1,"started_at":"1970-01-01T00:00:01Z"}|};
    let code, stdout, stderr =
      run_shell ~cwd:dir ~env (review_cmd (script_path ()) base_sha head_sha)
    in
    if code <> 0 then failf "stale reap run failed (%d): %s" code stderr;
    let open Yojson.Safe.Util in
    let json = parse_json_output stdout in
    check string "stale run result" "No findings." (json |> member "result" |> to_string);
    check string "review command executed once after reap" "1" (read_file count_file);
    check bool "pending file removed" false (Sys.file_exists pending_file))
;;

let test_default_cache_dir_shared_across_worktrees () =
  with_temp_dir "local-review-worktree-cache" (fun dir ->
    let base_sha, head_sha = init_repo dir in
    let fake = make_fake_reviewer dir in
    let count_file = Filename.concat dir "count.txt" in
    let worktree_dir = Filename.concat dir "wt-review" in
    ignore
      (run_shell_ok
         ~cwd:dir
         (Printf.sprintf
            "git worktree add -q %s -b review-cache-branch"
            (quote worktree_dir)));
    let env =
      [ "MASC_LOCAL_REVIEW_COMMAND", fake
      ; "COUNT_FILE", count_file
      ; "MASC_LOCAL_REVIEW_CHUNK_BYTES", "20"
      ]
    in
    let cmd = review_cmd (script_path ()) base_sha head_sha in
    let code1, stdout1, stderr1 = run_shell ~cwd:dir ~env cmd in
    if code1 <> 0 then failf "root run failed (%d): %s" code1 stderr1;
    let json1 = parse_json_output stdout1 in
    let open Yojson.Safe.Util in
    let chunk_count = json1 |> member "chunk_count" |> to_int in
    check bool "root run cache miss" false (json1 |> member "cache_hit" |> to_bool);
    check
      string
      "root run reviewer calls"
      (string_of_int chunk_count)
      (read_file count_file);
    let code2, stdout2, stderr2 = run_shell ~cwd:worktree_dir ~env cmd in
    if code2 <> 0 then failf "worktree run failed (%d): %s" code2 stderr2;
    let json2 = parse_json_output stdout2 in
    check bool "worktree run cache hit" true (json2 |> member "cache_hit" |> to_bool);
    check
      string
      "shared cache prevents second reviewer run"
      (string_of_int chunk_count)
      (read_file count_file))
;;

let () =
  run
    "local_review_script"
    [ ( "script"
      , [ test_case "cache hit and chunking" `Quick test_cache_hit_and_chunking
        ; test_case
            "single flight reuses pending worker"
            `Quick
            test_single_flight_reuses_pending_worker
        ; test_case "stale pending is reaped" `Quick test_stale_pending_is_reaped
        ; test_case
            "default cache dir shared across worktrees"
            `Quick
            test_default_cache_dir_shared_across_worktrees
        ] )
    ]
;;
