(** RFC-0162 §3.1 — [Fs_compat.mkdir_p_memoized] tests.

    Verifies that after the first call for a given path, subsequent
    calls do not invoke the underlying [mkdir_p] (and therefore do not
    burn a stat/fstatat syscall). The hot append paths
    ([append_jsonl] in particular) call this on every record, so
    skipping the syscall is the whole point of the fix. *)

open Alcotest

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s_%d_%d_%.0f"
         prefix
         !counter
         (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o755;
  dir
;;

(* Probe whether [path] exists by trying [Unix.stat]. The memoize
   contract is: after one successful call, the dir exists and
   subsequent calls touch nothing. Both pre/post conditions are
   measured by stat outcome on the same dir. *)
let dir_exists path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> true
  | _ | (exception Unix.Unix_error _) -> false
;;

let test_first_call_creates_dir () =
  Fs_compat.reset_mkdir_memo_for_testing ();
  let parent = tmpdir "mkdir_memo_create" in
  let target = Filename.concat parent "a/b/c" in
  check bool "target absent before call" false (dir_exists target);
  Fs_compat.mkdir_p_memoized target;
  check bool "target present after first call" true (dir_exists target)
;;

let test_repeat_calls_idempotent () =
  Fs_compat.reset_mkdir_memo_for_testing ();
  let parent = tmpdir "mkdir_memo_repeat" in
  let target = Filename.concat parent "month/day" in
  for _ = 1 to 50 do
    Fs_compat.mkdir_p_memoized target
  done;
  check bool "target present after 50 calls" true (dir_exists target)
;;

(* Memoize survives external dir deletion within the process — this
   is the documented contract (cache caches the *fact*, not state).
   .masc/ is self-owned so this is acceptable. Test pins the
   contract so a future change cannot silently invert it. *)
let test_cache_survives_external_delete () =
  Fs_compat.reset_mkdir_memo_for_testing ();
  let parent = tmpdir "mkdir_memo_stale" in
  let target = Filename.concat parent "vol" in
  Fs_compat.mkdir_p_memoized target;
  check bool "first create succeeded" true (dir_exists target);
  (* Simulate external rm -rf. *)
  Unix.rmdir target;
  check bool "target removed externally" false (dir_exists target);
  (* Second call is a no-op by contract (cache hit). The dir does
     NOT come back; the operator-side guarantee is *no spurious
     mkdir syscalls*, not *self-healing*. *)
  Fs_compat.mkdir_p_memoized target;
  check
    bool
    "memoize is a no-op even after external delete (contract: cache the fact, not the state)"
    false
    (dir_exists target);
  (* After explicit reset, the next call goes through and recreates. *)
  Fs_compat.reset_mkdir_memo_for_testing ();
  Fs_compat.mkdir_p_memoized target;
  check bool "reset re-enables mkdir on next call" true (dir_exists target)
;;

let test_concurrent_first_call_safe () =
  Fs_compat.reset_mkdir_memo_for_testing ();
  let parent = tmpdir "mkdir_memo_concurrent" in
  let target = Filename.concat parent "shared" in
  let n_threads = 16 in
  let threads =
    List.init n_threads (fun _ ->
      Thread.create (fun () -> Fs_compat.mkdir_p_memoized target) ())
  in
  List.iter Thread.join threads;
  check bool "target created exactly once-or-more (idempotent)" true (dir_exists target)
;;

let () =
  Alcotest.run
    "fs_compat_mkdir_memo"
    [ ( "memoize"
      , [ test_case "first call creates dir" `Quick test_first_call_creates_dir
        ; test_case "repeat calls idempotent" `Quick test_repeat_calls_idempotent
        ; test_case
            "cache survives external delete (contract)"
            `Quick
            test_cache_survives_external_delete
        ; test_case
            "concurrent first call is race-safe"
            `Quick
            test_concurrent_first_call_safe
        ] )
    ]
;;
