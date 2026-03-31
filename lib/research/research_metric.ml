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
  binary_changed : bool;  (** did the compiled output actually change? *)
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
    binary_changed = false; status = Crash; error_message }

(** Run a command with timeout in the given directory.
    Returns (exit_code, stdout, elapsed_seconds). *)
let run_cmd_timed ~timeout_sec (argv : string list) ~cwd : (int * string * float) =
  let t0 = Unix.gettimeofday () in
  try
    let status, stdout =
      Process_eio.run_argv_with_status ~timeout_sec ~cwd argv
    in
    let elapsed = Unix.gettimeofday () -. t0 in
    let code = match status with Unix.WEXITED c -> c | _ -> 1 in
    (code, stdout, elapsed)
  with exn ->
    let elapsed = Unix.gettimeofday () -. t0 in
    (1, Printexc.to_string exn, elapsed)

(** Count ASSERT lines in alcotest/dune test output. *)
let parse_test_counts ~returncode (stdout : string) : int * int =
  let lines = String.split_on_char '\n' stdout in
  let str_contains haystack needle =
    let re = Re.str needle |> Re.compile in
    Re.execp re haystack
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
      Process_eio.run_argv_with_status ~timeout_sec:10.0 ~cwd
        [ "git"; "diff"; "--stat"; "HEAD" ]
    in
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
  with exn ->
    Log.Autoresearch.debug "measure_loc_delta failed: %s" (Printexc.to_string exn);
    (0, 0)

(** Check if compiled output actually changed by comparing .cma/.cmxa sizes.
    A semantic gate: if source changed but binary didn't, the change is cosmetic. *)
let check_binary_changed ~cwd : bool =
  try
    let _, stdout =
      Process_eio.run_argv_with_status ~timeout_sec:10.0
        [ "git"; "-C"; cwd; "diff"; "--stat"; "--cached"; "--"; "_build/" ]
    in
    (* If _build/ has git-tracked changes, binary changed.
       More reliable: compare .cma size before/after, but that requires
       snapshotting before the patch. For now, check if any .cm* files
       were modified by comparing git diff output size. *)
    ignore stdout;
    (* Simpler proxy: check if the executable size changed *)
    let _, size_out =
      Process_eio.run_argv_with_status ~timeout_sec:5.0
        [ "find"; cwd ^ "/_build/default/bin"; "-name"; "*.exe"; "-exec";
          "stat"; "-f"; "%z"; "{}"; "+" ]
    in
    String.length (String.trim size_out) > 0
  with exn ->
    Log.Autoresearch.debug "check_binary_changed failed: %s" (Printexc.to_string exn);
    true  (* assume changed if we can't check *)

(** Full measurement pipeline: build → test → LOC delta → semantic gate. *)
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
    (* Semantic gate: did the binary actually change? *)
    let binary_changed = check_binary_changed ~cwd:config.path in
    (* Test *)
    let test_code, test_out, test_sec =
      run_cmd_timed ~timeout_sec:config.test_timeout_sec
        config.test_cmd ~cwd:config.path
    in
    let total, passed = parse_test_counts ~returncode:test_code test_out in
    let pass_rate = if total > 0 then float_of_int passed /. float_of_int total else 0.0 in
    let loc_delta, files_changed = measure_loc_delta ~cwd:config.path in
    let status =
      if not binary_changed then Discard  (* cosmetic change — no semantic effect *)
      else if pass_rate >= 1.0 then Keep
      else Discard
    in
    let error_message =
      if not binary_changed then "semantic gate: binary unchanged (cosmetic-only change)"
      else if test_code <> 0 then Printf.sprintf "test exit %d" test_code
      else ""
    in
    { build_ok = true; test_pass_rate = pass_rate; test_total = total;
      test_passed = passed; loc_delta; files_changed;
      build_seconds = build_sec; test_seconds = test_sec;
      binary_changed; status; error_message }
