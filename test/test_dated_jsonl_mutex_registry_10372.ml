(** #10372 — pin the file-scope mutex registry contract.

    Pre-fix [Dated_jsonl.create] minted a fresh [Eio.Mutex.t]
    per call.  When two instances pointed at the same JSONL
    directory, their mutexes did not coordinate and concurrent
    [append] could interleave.  Real-world trigger:
    [oas_event_bridge.ml] re-creates the store on every relay
    error while another fiber still holds the previous instance,
    producing 1.52% line corruption (16/1056) on day 25 — all
    [masc:oas_worker:build] payloads in the 4-8 KB range past
    POSIX [PIPE_BUF].

    The registry forces every store rooted at the same canonical
    [base_dir] to share one mutex.  An explicit [?mutex] argument
    still overrides, preserving test isolation patterns.

    Tests pin:

    1. Same [base_dir] → physically identical mutex.
    2. Different [base_dir] → distinct mutexes.
    3. Explicit [?mutex] bypasses the registry.
    4. Trailing-slash variants normalize to the same mutex.
    5. Behavioural: concurrent appends through two store
       instances at the same dir produce all-parseable lines,
       even with payloads larger than [PIPE_BUF]. *)

open Alcotest

module D = Dated_jsonl

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir

(* --- 1. same base_dir → identical mutex ---------------- *)

let test_same_base_dir_shares_mutex () =
  let dir = tmpdir "djmr_same" in
  let a = D.create ~base_dir:dir () in
  let b = D.create ~base_dir:dir () in
  check bool "same base_dir → physically identical mutex" true
    (D.For_testing.mutex a == D.For_testing.mutex b)

(* --- 2. different base_dir → distinct mutexes ---------- *)

let test_different_base_dir_distinct_mutex () =
  let dir_a = tmpdir "djmr_diff_a" in
  let dir_b = tmpdir "djmr_diff_b" in
  let a = D.create ~base_dir:dir_a () in
  let b = D.create ~base_dir:dir_b () in
  check bool "distinct base_dir → distinct mutex" false
    (D.For_testing.mutex a == D.For_testing.mutex b)

(* --- 3. explicit ?mutex bypasses the registry --------- *)

let test_explicit_mutex_overrides_registry () =
  let dir = tmpdir "djmr_explicit" in
  let registry_mutex = D.For_testing.mutex_for_base_dir dir in
  let injected = Eio.Mutex.create () in
  let store = D.create ~base_dir:dir ~mutex:injected () in
  check bool "explicit mutex used verbatim" true
    (D.For_testing.mutex store == injected);
  check bool "explicit mutex differs from registry entry" false
    (D.For_testing.mutex store == registry_mutex)

(* --- 4. trailing-slash variants share the mutex -------- *)

let test_trailing_slash_normalizes () =
  let dir = tmpdir "djmr_slash" in
  let a = D.create ~base_dir:dir () in
  let b = D.create ~base_dir:(dir ^ "/") () in
  check bool "trailing slash normalises to same mutex" true
    (D.For_testing.mutex a == D.For_testing.mutex b)

(* --- 5. concurrent appends produce all-parseable lines  *)

(* Payload large enough to exercise the buffered [output_string]
   path that previously split into multiple [write(2)] calls past
   [PIPE_BUF].  We don't depend on the writer's exact threshold;
   we only assert that NO line is truncated or interleaved
   regardless of how many fibers append concurrently. *)
let big_payload tag =
  let body = String.make 6000 '.' in
  `Assoc
    [
      ("tag", `String tag);
      ("body", `String body);
      ("ts", `Float (Unix.gettimeofday ()));
    ]

let read_today_lines dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month =
    Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)
  in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let path = Filename.concat (Filename.concat dir month) day in
  if not (Sys.file_exists path) then []
  else
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun l -> String.trim l <> "")

let test_concurrent_two_instances_no_corruption () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "djmr_concurrent" in
  (* Two instances at the same dir — pre-fix this would mint
     two distinct mutexes; post-fix the registry forces sharing. *)
  let store_a = D.create ~base_dir:dir () in
  let store_b = D.create ~base_dir:dir () in
  check bool "registry shares mutex across instances" true
    (D.For_testing.mutex store_a == D.For_testing.mutex store_b);
  let n = 40 in
  Eio.Fiber.both
    (fun () ->
      for i = 0 to n - 1 do
        D.append store_a (big_payload (Printf.sprintf "a-%d" i))
      done)
    (fun () ->
      for i = 0 to n - 1 do
        D.append store_b (big_payload (Printf.sprintf "b-%d" i))
      done);
  let lines = read_today_lines dir in
  check int "all 80 lines present" (2 * n) (List.length lines);
  let parsed_count =
    List.fold_left
      (fun acc line ->
        match Yojson.Safe.from_string line with
        | _ -> acc + 1
        | exception Yojson.Json_error _ -> acc)
      0 lines
  in
  check int "every line parses as JSON" (2 * n) parsed_count

let test_append_failure_does_not_poison_registry_mutex () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "djmr_retry" in
  let base_dir = Filename.concat dir "blocked" in
  Out_channel.with_open_text base_dir (fun oc -> output_string oc "blocked");
  let store = D.create ~base_dir () in
  let failed =
    try
      D.append store (`Assoc [ ("phase", `String "initial") ]);
      false
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> true
  in
  check bool "initial append failed" true failed;
  Sys.remove base_dir;
  Unix.mkdir base_dir 0o755;
  let retry_store = D.create ~base_dir () in
  D.append retry_store (`Assoc [ ("phase", `String "retry") ]);
  let records = D.read_recent retry_store 1 in
  check int "retry append persisted" 1 (List.length records)

let () =
  run "dated_jsonl_mutex_registry_10372"
    [
      ( "registry-identity",
        [
          test_case "same base_dir shares mutex" `Quick
            test_same_base_dir_shares_mutex;
          test_case "different base_dir distinct mutex" `Quick
            test_different_base_dir_distinct_mutex;
          test_case "explicit ?mutex bypasses registry" `Quick
            test_explicit_mutex_overrides_registry;
          test_case "trailing slash normalises" `Quick
            test_trailing_slash_normalizes;
        ] );
      ( "concurrent-append",
        [
          test_case "two instances at same dir do not corrupt" `Quick
            test_concurrent_two_instances_no_corruption;
          test_case "append failure does not poison registry mutex" `Quick
            test_append_failure_does_not_poison_registry_mutex;
        ] );
    ]
