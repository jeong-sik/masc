(** [Dated_jsonl.count_entries] incremental per-file cache tests.

    The boundary-keyed cache replaced the RFC-0162 §3.2 TTL layer:
    [count_entries] is exact (no staleness window) and O(appended bytes)
    per call. The contract is:
      - growth behind the cache is visible on the very next call
      - only '\n'-terminated lines are counted; [count_entries_uncached]
        also counts a trailing unterminated line
      - [reset_count_cache_for_testing] clears per-file state *)

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

let write_raw path content =
  let dir = Filename.dirname path in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  let oc =
    open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path
  in
  output_string oc content;
  close_out oc
;;

let today_day_path base_dir =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let month_dir =
    Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
  in
  let day_file = Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday in
  Filename.concat (Filename.concat base_dir month_dir) day_file
;;

(* Seed a Dated_jsonl store with [n] records on a single day so we
   have a deterministic count_entries baseline. *)
let seed_store base_dir n =
  let path = today_day_path base_dir in
  for i = 1 to n do
    write_jsonl_line path (Printf.sprintf "{\"seq\":%d}" i)
  done
;;

let test_growth_is_visible_immediately () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_incr_growth" in
  seed_store base 10;
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "first call counts 10" 10 (Dated_jsonl.count_entries t);
  (* Append behind the populated cache: the incremental scan must pick the
     delta up on the very next call — no TTL staleness window exists. *)
  seed_store base 5;
  check int "growth visible on next call" 15 (Dated_jsonl.count_entries t);
  check
    int
    "cached count equals uncached"
    (Dated_jsonl.count_entries_uncached t)
    (Dated_jsonl.count_entries t)
;;

let test_unterminated_trailing_line () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_incr_partial" in
  seed_store base 2;
  let path = today_day_path base in
  (* Simulate a writer that flushed half a line: no trailing newline. *)
  write_raw path "{\"seq\":3";
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "partial line not counted" 2 (Dated_jsonl.count_entries t);
  check int "uncached counts the partial tail" 3 (Dated_jsonl.count_entries_uncached t);
  (* Writer completes the line: both paths agree again. *)
  write_raw path "}\n";
  check int "completed line now counted" 3 (Dated_jsonl.count_entries t);
  check int "uncached agrees" 3 (Dated_jsonl.count_entries_uncached t)
;;

let test_shrunk_file_rescans () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_incr_shrink" in
  seed_store base 6;
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "baseline 6" 6 (Dated_jsonl.count_entries t);
  (* Rewrite the day-file smaller (prune/rotation shape): the cached
     boundary now exceeds the file size, forcing a full rescan. *)
  let path = today_day_path base in
  Sys.remove path;
  write_jsonl_line path "{\"seq\":1}";
  write_jsonl_line path "{\"seq\":2}";
  check int "shrunk file rescanned from zero" 2 (Dated_jsonl.count_entries t)
;;

let test_reset_clears_cache () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_incr_reset" in
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
  let base_a = tmpdir "count_incr_a" in
  let base_b = tmpdir "count_incr_b" in
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

(* The per-file cache must produce the same total as a full uncached scan
   across many day-files — the realistic store shape it optimises — and a
   grown file must be reflected without any cache reset. *)
let test_per_file_cache_matches_uncached_across_days () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_incr_perfile" in
  write_to_day base ~ym:"2026-05" ~day:"01" 4;
  write_to_day base ~ym:"2026-05" ~day:"02" 3;
  write_to_day base ~ym:"2026-06" ~day:"09" 2;
  let t = Dated_jsonl.create ~base_dir:base () in
  check
    int
    "multi-day cached count equals uncached"
    (Dated_jsonl.count_entries_uncached t)
    (Dated_jsonl.count_entries t);
  check int "multi-day total is 9" 9 (Dated_jsonl.count_entries t);
  write_to_day base ~ym:"2026-06" ~day:"09" 6;
  check
    int
    "after growth, cached count equals uncached without reset"
    (Dated_jsonl.count_entries_uncached t)
    (Dated_jsonl.count_entries t);
  check int "after growth total is 15" 15 (Dated_jsonl.count_entries t)
;;

let () =
  Alcotest.run
    "dated_jsonl_count_cache"
    [ ( "incremental_count"
      , [ test_case
            "growth behind the cache is visible immediately"
            `Quick
            test_growth_is_visible_immediately
        ; test_case
            "unterminated trailing line excluded until newline lands"
            `Quick
            test_unterminated_trailing_line
        ; test_case "shrunk file forces full rescan" `Quick test_shrunk_file_rescans
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
