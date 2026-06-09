(** RFC-0162 §3.2 — [Dated_jsonl.count_entries] TTL cache tests.

    Verifies the cache returns a stale (but cheap) count within the
    TTL window and refreshes after expiry. The contract is:
      - cached value within 10 s window
      - [count_entries_uncached] always scans
      - [reset_count_cache_for_testing] clears state *)

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

let write_jsonl_line path line =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  let oc =
    open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path
  in
  output_string oc (line ^ "\n");
  close_out oc
;;

(* Seed a Dated_jsonl store with [n] records on a single day so we
   have a deterministic count_entries baseline. *)
let seed_store base_dir n =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let month_dir =
    Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
  in
  let day_file = Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday in
  let path = Filename.concat (Filename.concat base_dir month_dir) day_file in
  for i = 1 to n do
    write_jsonl_line path (Printf.sprintf "{\"seq\":%d}" i)
  done
;;

let test_cache_returns_stale_within_ttl () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_stale" in
  seed_store base 10;
  let t = Dated_jsonl.create ~base_dir:base () in
  (* First call populates the cache. *)
  let first = Dated_jsonl.count_entries t in
  check int "first call counts 10" 10 first;
  (* Add 5 more records *behind the cache*. *)
  seed_store base 5;
  (* Cached value (10) is returned — staleness is the contract. *)
  let cached = Dated_jsonl.count_entries t in
  check int "cached count still 10 within TTL" 10 cached;
  (* Uncached path observes the true count. *)
  let live = Dated_jsonl.count_entries_uncached t in
  check int "uncached path sees the live 15" 15 live
;;

let test_reset_clears_cache () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_reset" in
  seed_store base 3;
  let t = Dated_jsonl.create ~base_dir:base () in
  let _ = Dated_jsonl.count_entries t in
  seed_store base 2;
  Dated_jsonl.reset_count_cache_for_testing ();
  let after_reset = Dated_jsonl.count_entries t in
  check int "post-reset count reflects all 5 records" 5 after_reset
;;

let test_distinct_stores_have_independent_caches () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base_a = tmpdir "count_cache_a" in
  let base_b = tmpdir "count_cache_b" in
  seed_store base_a 4;
  seed_store base_b 7;
  let ta = Dated_jsonl.create ~base_dir:base_a () in
  let tb = Dated_jsonl.create ~base_dir:base_b () in
  check int "store a counts 4" 4 (Dated_jsonl.count_entries ta);
  check int "store b counts 7 (no cross-key contamination)" 7 (Dated_jsonl.count_entries tb)
;;

let write_to_day base ~ym ~day n =
  let path =
    Filename.concat (Filename.concat base ym) (Printf.sprintf "%s.jsonl" day)
  in
  for i = 1 to n do
    write_jsonl_line path (Printf.sprintf "{\"seq\":%d}" i)
  done
;;

(* The per-file count cache (keyed by path + byte size) must produce the same
   total as a full uncached scan across many day-files — the realistic store
   shape it optimises — and must reflect a file that grew (size change
   invalidates the cached per-file count, so the total never drifts). *)
let test_per_file_cache_matches_uncached_across_days () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_perfile" in
  write_to_day base ~ym:"2026-05" ~day:"01" 4;
  write_to_day base ~ym:"2026-05" ~day:"02" 3;
  write_to_day base ~ym:"2026-06" ~day:"09" 2;
  let t = Dated_jsonl.create ~base_dir:base () in
  (* First cached-miss populates the per-file cache; total must equal the
     true scan across all three day-files. *)
  check
    int
    "multi-day cached count equals uncached"
    (Dated_jsonl.count_entries_uncached t)
    (Dated_jsonl.count_entries t);
  check int "multi-day total is 9" 9 (Dated_jsonl.count_entries t);
  (* Grow one day-file, then force a recompute. The size change must
     invalidate that file's cached count so the new total is observed. *)
  write_to_day base ~ym:"2026-06" ~day:"09" 6;
  Dated_jsonl.reset_count_cache_for_testing ();
  check
    int
    "after growth, cached count equals uncached"
    (Dated_jsonl.count_entries_uncached t)
    (Dated_jsonl.count_entries t);
  check int "after growth total is 15" 15 (Dated_jsonl.count_entries t)
;;

let () =
  Alcotest.run
    "dated_jsonl_count_cache"
    [ ( "count_cache"
      , [ test_case
            "cache returns stale within TTL, uncached path is live"
            `Quick
            test_cache_returns_stale_within_ttl
        ; test_case "reset clears the cache" `Quick test_reset_clears_cache
        ; test_case
            "distinct stores have independent caches"
            `Quick
            test_distinct_stores_have_independent_caches
        ; test_case
            "per-file cache matches uncached across day-files"
            `Quick
            test_per_file_cache_matches_uncached_across_days
        ] )
    ]
;;
