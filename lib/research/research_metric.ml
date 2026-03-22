(** Research_metric — Collect build/test metrics for code experiments.

    Replaces autoresearch's val_bpb with:
    - build_ok      : did dune build succeed?
    - test_pass_rate : fraction of tests passed
    - loc_delta      : lines added - lines removed (negative = simplification)
    - files_changed  : number of modified files *)

type status = Keep | Discard | Crash

type t = {
  build_ok : bool;
  test_pass_rate : float;
  test_total : int;
  test_passed : int;
  loc_delta : int;
  files_changed : int;
  build_seconds : float;
  test_seconds : float;
  status : status;
  error_message : string;
}

let status_to_string = function
  | Keep -> "keep"
  | Discard -> "discard"
  | Crash -> "crash"

let crash_result ~error_message =
  { build_ok = false; test_pass_rate = 0.0; test_total = 0; test_passed = 0;
    loc_delta = 0; files_changed = 0; build_seconds = 0.0; test_seconds = 0.0;
    status = Crash; error_message }

(** Run a command with timeout. Returns (exit_code, stdout, elapsed_seconds). *)
let run_cmd_timed ~timeout_sec (argv : string list) ~cwd : (int * string * float) =
  let t0 = Unix.gettimeofday () in
  try
    let status, stdout =
      Process_eio.run_argv_with_status ~timeout_sec argv
    in
    let elapsed = Unix.gettimeofday () -. t0 in
    let code = match status with Unix.WEXITED c -> c | _ -> 1 in
    ignore cwd;  (* Process_eio uses global cwd; caller sets up worktree *)
    (code, stdout, elapsed)
  with exn ->
    let elapsed = Unix.gettimeofday () -. t0 in
    (1, Printexc.to_string exn, elapsed)

(** Count ASSERT lines in alcotest/dune test output. *)
let parse_test_counts ~returncode (stdout : string) : int * int =
  let lines = String.split_on_char '\n' stdout in
  let str_contains haystack needle =
    try ignore (Re.Str.search_forward (Re.Str.regexp_string needle) haystack 0); true
    with Not_found -> false
  in
  let assert_lines = List.filter (fun l -> str_contains l "ASSERT") lines in
  let total = List.length assert_lines in
  if total > 0 then
    let passed = if returncode = 0 then total else max 0 (total - 1) in
    (total, passed)
  else if returncode = 0 then (1, 1)
  else (1, 0)

(** Measure LOC delta from git diff --stat HEAD in the given path. *)
let measure_loc_delta ~cwd : int * int =
  try
    let _, stdout =
      Process_eio.run_argv_with_status ~timeout_sec:10.0
        [ "git"; "diff"; "--stat"; "HEAD" ]
    in
    ignore cwd;
    let lines = String.split_on_char '\n' stdout in
    let summary = match List.rev lines with
      | [] -> ""
      | "" :: rest -> (match rest with hd :: _ -> hd | [] -> "")
      | hd :: _ -> hd
    in
    let re_files = Re.Pcre.re "(\\d+) files? changed" |> Re.compile in
    let re_ins = Re.Pcre.re "(\\d+) insertions?" |> Re.compile in
    let re_del = Re.Pcre.re "(\\d+) deletions?" |> Re.compile in
    let get_int re s =
      match Re.exec_opt re s with
      | Some g -> int_of_string (Re.Group.get g 1)
      | None -> 0
    in
    let files = get_int re_files summary in
    let ins = get_int re_ins summary in
    let del = get_int re_del summary in
    (ins - del, files)
  with _ -> (0, 0)

(** Full measurement pipeline: build → test → LOC delta. *)
let collect ~(config : Research_config.repo_config) : t =
  (* Build *)
  let build_code, _build_out, build_sec =
    run_cmd_timed ~timeout_sec:config.build_timeout_sec
      config.build_cmd ~cwd:config.path
  in
  if build_code <> 0 then
    { (crash_result ~error_message:(Printf.sprintf "build failed (exit %d)" build_code))
      with build_seconds = build_sec }
  else
    (* Test *)
    let test_code, test_out, test_sec =
      run_cmd_timed ~timeout_sec:config.test_timeout_sec
        config.test_cmd ~cwd:config.path
    in
    let total, passed = parse_test_counts ~returncode:test_code test_out in
    let pass_rate = if total > 0 then float_of_int passed /. float_of_int total else 0.0 in
    let loc_delta, files_changed = measure_loc_delta ~cwd:config.path in
    let status = if pass_rate >= 1.0 then Keep else Discard in
    let error_message =
      if test_code <> 0 then Printf.sprintf "test exit %d" test_code else ""
    in
    { build_ok = true; test_pass_rate = pass_rate; test_total = total;
      test_passed = passed; loc_delta; files_changed;
      build_seconds = build_sec; test_seconds = test_sec;
      status; error_message }
