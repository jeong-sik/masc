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

let test_directory_recreation_forgets_old_file_identity () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_incr_recreated" in
  seed_store base 2;
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "old file counts 2" 2 (Dated_jsonl.count_entries t);
  Dated_jsonl.prepare_for_directory_removal t;
  Fs_compat.remove_tree base;
  Dated_jsonl.append
    t
    (`Assoc
      [ "payload", `String "new file is larger than the old cached byte boundary" ]);
  check
    int
    "recreated file count starts from zero"
    (Dated_jsonl.count_entries_uncached t)
    (Dated_jsonl.count_entries t);
  check int "recreated file counts 1" 1 (Dated_jsonl.count_entries t)
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


(* The cache was process-memory only, so a restart re-counted every retained
   line of every dated store. Measured 2026-08-29: 24 bootstraps that day, and
   23 of 28 telemetry_summary "heavy refresh" warnings inside five minutes of
   one, worst 225.70s / 5,704MB. Persisting it makes a restart resume the
   incremental read. [reset_count_cache_for_testing] stands in for the
   restart: it is exactly the state a fresh process has. *)
let test_saved_cache_survives_a_restart () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_persist" in
  seed_store base 12;
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "warm count" 12 (Dated_jsonl.count_entries t);
  let cache_file = Filename.concat (tmpdir "count_cache_file") "counts.json" in
  (match Dated_jsonl.save_count_cache ~path:cache_file with
   | Ok () -> ()
   | Error detail -> failf "save failed: %s" detail);
  Dated_jsonl.reset_count_cache_for_testing ();
  (match Dated_jsonl.load_count_cache ~path:cache_file with
   | Ok rows -> check bool "at least the seeded file was restored" true (rows >= 1)
   | Error detail -> failf "load failed: %s" detail);
  check int "the restored count is the same count" 12 (Dated_jsonl.count_entries t)
;;

(* The restored entry is still only a boundary claim. Growth behind it has to
   show up, or the cache would serve a number the store no longer has. *)
let test_a_restored_entry_still_sees_growth () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_growth" in
  seed_store base 4;
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "warm count" 4 (Dated_jsonl.count_entries t);
  let cache_file = Filename.concat (tmpdir "count_cache_file2") "counts.json" in
  (match Dated_jsonl.save_count_cache ~path:cache_file with
   | Ok () -> () | Error detail -> failf "save failed: %s" detail);
  Dated_jsonl.reset_count_cache_for_testing ();
  seed_store base 3;
  (match Dated_jsonl.load_count_cache ~path:cache_file with
   | Ok _ -> () | Error detail -> failf "load failed: %s" detail);
  check int "growth behind a restored boundary is counted" 7
    (Dated_jsonl.count_entries t);
  check int "and it agrees with an uncached count"
    (Dated_jsonl.count_entries_uncached t)
    (Dated_jsonl.count_entries t)
;;

(* A restored boundary past the file's current size is the shrink case, which
   the existing rescan path already handles. It must not survive as a count. *)
let test_a_restored_entry_rescans_a_shrunk_file () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_shrink" in
  seed_store base 9;
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "warm count" 9 (Dated_jsonl.count_entries t);
  let cache_file = Filename.concat (tmpdir "count_cache_file3") "counts.json" in
  (match Dated_jsonl.save_count_cache ~path:cache_file with
   | Ok () -> () | Error detail -> failf "save failed: %s" detail);
  Dated_jsonl.reset_count_cache_for_testing ();
  let path = today_day_path base in
  let oc = open_out path in
  output_string oc "{\"seq\":1}\n";
  close_out oc;
  (match Dated_jsonl.load_count_cache ~path:cache_file with
   | Ok _ -> () | Error detail -> failf "load failed: %s" detail);
  check int "a shrunk file is rescanned, not trusted" 1
    (Dated_jsonl.count_entries t)
;;

(* Absent and unreadable cache files are the cold-start path, which is
   correct -- just slower. Neither may fail a count. *)
let test_missing_and_corrupt_cache_files_are_survivable () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_absent" in
  seed_store base 5;
  let t = Dated_jsonl.create ~base_dir:base () in
  let missing = Filename.concat (tmpdir "count_cache_file4") "absent.json" in
  (match Dated_jsonl.load_count_cache ~path:missing with
   | Ok rows -> check int "a missing cache restores nothing" 0 rows
   | Error detail -> failf "a missing cache must not be an error: %s" detail);
  check int "and the count is still exact" 5 (Dated_jsonl.count_entries t);
  let corrupt = Filename.concat (tmpdir "count_cache_file5") "corrupt.json" in
  write_raw corrupt "{not json";
  (match Dated_jsonl.load_count_cache ~path:corrupt with
   | Ok _ -> fail "a corrupt cache must report the failure"
   | Error _ -> ());
  Dated_jsonl.reset_count_cache_for_testing ();
  check int "a corrupt cache leaves counting correct" 5
    (Dated_jsonl.count_entries t)
;;


(* The three tests above would pass even if [load_count_cache] installed
   nothing: recounting from scratch returns the same number. This one pins
   that the restored entry is actually consumed. The saved count is edited to
   a value the file cannot produce while its boundary is left alone, so a
   count that still matches the file proves the load did nothing. This is also
   the honest shape of the cache's risk: a boundary that matches is trusted,
   and the size check is the only thing standing between a stale row and a
   wrong number. *)
let test_a_restored_entry_is_actually_used () =
  Dated_jsonl.reset_count_cache_for_testing ();
  let base = tmpdir "count_cache_consumed" in
  seed_store base 6;
  let t = Dated_jsonl.create ~base_dir:base () in
  check int "warm count" 6 (Dated_jsonl.count_entries t);
  let cache_file = Filename.concat (tmpdir "count_cache_file6") "counts.json" in
  (match Dated_jsonl.save_count_cache ~path:cache_file with
   | Ok () -> () | Error detail -> failf "save failed: %s" detail);
  let saved =
    let ic = open_in cache_file in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic))
  in
  let replace_first ~needle ~replacement haystack =
    let nlen = String.length needle and hlen = String.length haystack in
    let rec scan i =
      if i + nlen > hlen
      then haystack
      else if String.equal (String.sub haystack i nlen) needle
      then
        String.sub haystack 0 i
        ^ replacement
        ^ String.sub haystack (i + nlen) (hlen - i - nlen)
      else scan (i + 1)
    in
    scan 0
  in
  let tampered =
    replace_first ~needle:"\"count\":6" ~replacement:"\"count\":4242" saved
  in
  check bool "the fixture edited the saved count" true
    (not (String.equal tampered saved));
  let oc = open_out cache_file in
  output_string oc tampered;
  close_out oc;
  Dated_jsonl.reset_count_cache_for_testing ();
  (match Dated_jsonl.load_count_cache ~path:cache_file with
   | Ok _ -> () | Error detail -> failf "load failed: %s" detail);
  check int "the restored row is the one that answers" 4242
    (Dated_jsonl.count_entries t)
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
        ; test_case "a saved cache survives a restart" `Quick
            test_saved_cache_survives_a_restart
        ; test_case "a restored entry still sees growth" `Quick
            test_a_restored_entry_still_sees_growth
        ; test_case "a restored entry rescans a shrunk file" `Quick
            test_a_restored_entry_rescans_a_shrunk_file
        ; test_case "missing and corrupt cache files are survivable" `Quick
            test_missing_and_corrupt_cache_files_are_survivable
        ; test_case "a restored entry is actually used" `Quick
            test_a_restored_entry_is_actually_used
        ; test_case
            "directory recreation forgets old file identity"
            `Quick
            test_directory_recreation_forgets_old_file_identity
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
