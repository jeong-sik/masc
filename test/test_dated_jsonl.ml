(** Tests for Dated_jsonl date-split JSONL storage. *)

open Alcotest

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p dir;
  dir

let make_json i =
  `Assoc [("i", `Int i); ("ts", `Float (Unix.gettimeofday ()))]

let json_i json = Yojson.Safe.Util.(json |> member "i" |> to_int)

(* ── append creates YYYY-MM/DD.jsonl ──────────────────── *)

let test_append_creates_dated_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_append" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  Dated_jsonl.append store (make_json 1);
  Dated_jsonl.append store (make_json 2);
  (* Verify directory structure exists *)
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let month_dir = Filename.concat dir month in
  let file = Filename.concat month_dir day in
  check bool "month dir exists" true (Sys.file_exists month_dir);
  check bool "day file exists" true (Sys.file_exists file);
  (* Verify file content *)
  let content = Fs_compat.load_file file in
  let lines = String.split_on_char '\n' content
    |> List.filter (fun l -> String.trim l <> "") in
  check int "two lines" 2 (List.length lines)

(* ── read_recent returns newest N in chronological order ─ *)

let test_read_recent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_recent" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  for i = 1 to 5 do
    Dated_jsonl.append store (make_json i)
  done;
  let result = Dated_jsonl.read_recent store 3 in
  check int "returns 3" 3 (List.length result);
  (* Should be chronological: 3, 4, 5 *)
  let values = List.map (fun j ->
    Yojson.Safe.Util.(j |> member "i" |> to_int)
  ) result in
  check (list int) "newest 3 chronological" [3; 4; 5] values

let test_read_recent_zero () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_zero" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  Dated_jsonl.append store (make_json 1);
  let result = Dated_jsonl.read_recent store 0 in
  check int "returns 0" 0 (List.length result)

let test_read_recent_more_than_exists () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_overflow" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  Dated_jsonl.append store (make_json 1);
  Dated_jsonl.append store (make_json 2);
  let result = Dated_jsonl.read_recent store 100 in
  check int "returns all 2" 2 (List.length result)

let write_dated_file dir month day lines =
  let month_dir = Filename.concat dir month in
  Fs_compat.mkdir_p month_dir;
  Fs_compat.append_file
    (Filename.concat month_dir (day ^ ".jsonl"))
    (String.concat "\n" lines ^ "\n")

let test_read_recent_skips_malformed_lines () =
  let dir = tmpdir "dated_jsonl_recent_malformed" in
  write_dated_file dir "2026-01" "01"
    [ {|{"i":1}|}; "not-json"; {|{"i":2}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let values = Dated_jsonl.read_recent store 10 |> List.map json_i in
  check (list int) "read_recent skips malformed rows" [ 1; 2 ] values

let test_load_tail_lines_drops_partial_chunk_prefix () =
  let dir = tmpdir "dated_jsonl_partial_tail" in
  let path = Filename.concat dir "tail.jsonl" in
  let expected = List.init 5 (fun i -> Printf.sprintf "{\"i\":%d}" (i + 1)) in
  let content =
    String.make 9000 'x' ^ "\n"
    ^ String.make 31 '\n'
    ^ String.concat "\n" expected
    ^ "\n"
  in
  Fs_compat.append_file path content;
  let lines = Dated_jsonl.load_tail_lines path ~max_lines:10 in
  check (list string) "drops partial chunk prefix" expected lines

let test_load_tail_lines_keeps_first_data_after_blank_prefix () =
  let dir = tmpdir "dated_jsonl_blank_partial_tail" in
  let path = Filename.concat dir "tail.jsonl" in
  let first = Printf.sprintf "{\"payload\":\"%s\"}" (String.make 8120 'a') in
  let rest = List.init 4 (fun i -> Printf.sprintf "{\"i\":%d}" (i + 1)) in
  let expected = first :: rest in
  let content =
    String.make 256 'x' ^ "\n"
    ^ String.make 40 '\n'
    ^ String.concat "\n" expected
    ^ "\n"
  in
  Fs_compat.append_file path content;
  let lines = Dated_jsonl.load_tail_lines path ~max_lines:5 in
  check (list string) "keeps first data row after blank partial prefix" expected lines

let test_load_tail_lines_keeps_first_when_full_file_spans_chunks () =
  let dir = tmpdir "dated_jsonl_full_file_tail" in
  let path = Filename.concat dir "tail.jsonl" in
  let first = Printf.sprintf "{\"payload\":\"%s\"}" (String.make 9000 'a') in
  let rest = List.init 2 (fun i -> Printf.sprintf "{\"i\":%d}" (i + 1)) in
  let expected = first :: rest in
  Fs_compat.append_file path (String.concat "\n" expected ^ "\n");
  let lines = Dated_jsonl.load_tail_lines path ~max_lines:10 in
  check (list string) "keeps first row when full file spans chunks" expected lines

(* ── read_recent_lines returns raw strings ─────────────── *)

let test_read_recent_lines () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_lines" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  for i = 1 to 4 do
    Dated_jsonl.append store (make_json i)
  done;
  let lines = Dated_jsonl.read_recent_lines store 2 in
  check int "returns 2 lines" 2 (List.length lines);
  (* Lines should be valid JSON *)
  List.iter (fun line ->
    check bool "parseable json" true
      (try ignore (Yojson.Safe.from_string line); true
       with Yojson.Json_error _ -> false)
  ) lines

let test_count_entries () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_count" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  for i = 1 to 3 do
    Dated_jsonl.append store (make_json i)
  done;
  let old_month = Filename.concat dir "2020-01" in
  Fs_compat.mkdir_p old_month;
  Fs_compat.append_file (Filename.concat old_month "15.jsonl")
    "{\"i\":4}\n\n{\"i\":5}\n";
  check int "counts non-empty rows across dated files" 5
    (Dated_jsonl.count_entries store)

(* ── read_range filters by date ────────────────────────── *)

let test_read_range () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_range" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  Dated_jsonl.append store (make_json 1);
  (* Read today's range *)
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let today = Printf.sprintf "%04d-%02d-%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday in
  let result = Dated_jsonl.read_range store ~since:today ~until:today in
  check bool "non-empty for today" true (List.length result > 0);
  (* Far future range should be empty *)
  let result2 = Dated_jsonl.read_range store ~since:"2099-01-01" ~until:"2099-12-31" in
  check int "empty for future" 0 (List.length result2)

let test_read_range_malformed () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_badrange" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let result = Dated_jsonl.read_range store ~since:"bad" ~until:"dates" in
  check int "malformed dates return empty" 0 (List.length result)

let test_read_range_recent () =
  let dir = tmpdir "dated_jsonl_range_recent" in
  write_dated_file dir "2026-01" "01" [ {|{"i":1}|}; {|{"i":2}|}; {|{"i":3}|} ];
  write_dated_file dir "2026-01" "02" [ {|{"i":4}|}; {|{"i":5}|}; {|{"i":6}|} ];
  write_dated_file dir "2026-02" "01" [ {|{"i":7}|}; {|{"i":8}|}; {|{"i":9}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let ints r = List.map json_i r in
  (* newest 2 in window come from the tail of the newest in-range day-file *)
  check
    (list int)
    "newest 2 in window"
    [ 8; 9 ]
    (ints (Dated_jsonl.read_range_recent store ~since:"2026-01-02" ~until:"2026-02-01" 2));
  (* newest 5, spanning two in-range day-files, oldest-first within result *)
  check
    (list int)
    "newest 5 across range"
    [ 5; 6; 7; 8; 9 ]
    (ints (Dated_jsonl.read_range_recent store ~since:"2026-01-01" ~until:"2026-02-01" 5));
  (* a day outside the window is excluded; n larger than available returns all *)
  check
    (list int)
    "single in-range day returns its entries"
    [ 4; 5; 6 ]
    (ints (Dated_jsonl.read_range_recent store ~since:"2026-01-02" ~until:"2026-01-02" 100));
  check
    int
    "n=0 returns empty"
    0
    (List.length
       (Dated_jsonl.read_range_recent store ~since:"2026-01-01" ~until:"2026-02-01" 0))
;;

let test_iter_all_chronological_skips_malformed () =
  let dir = tmpdir "dated_jsonl_iter_all" in
  write_dated_file dir "2026-01" "01" [ {|{"i":1}|}; "not-json" ];
  write_dated_file dir "2026-01" "02" [ {|{"i":2}|} ];
  write_dated_file dir "2026-02" "01" [ {|{"i":3}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let seen = ref [] in
  Dated_jsonl.iter_all store (fun json -> seen := json_i json :: !seen);
  check (list int) "iter_all chronological" [ 1; 2; 3 ] (List.rev !seen)

let test_iter_all_result_rejects_malformed () =
  let dir = tmpdir "dated_jsonl_iter_all_result" in
  write_dated_file dir "2026-01" "01" [ {|{"i":1}|}; "not-json" ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  match Dated_jsonl.iter_all_result store ignore with
  | Ok () -> fail "strict iteration silently skipped malformed JSON"
  | Error _ -> ()

let test_iter_range_chronological () =
  let dir = tmpdir "dated_jsonl_iter_range" in
  write_dated_file dir "2026-01" "01" [ {|{"i":1}|} ];
  write_dated_file dir "2026-01" "02" [ {|{"i":2}|} ];
  write_dated_file dir "2026-02" "01" [ {|{"i":3}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let seen = ref [] in
  Dated_jsonl.iter_range store ~since:"2026-01-02" ~until:"2026-02-01"
    (fun json -> seen := json_i json :: !seen);
  check (list int) "iter_range chronological" [ 2; 3 ] (List.rev !seen)

(* ── prune removes old files ───────────────────────────── *)

let test_prune () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_prune" in
  (* Create a fake old month dir with a day file *)
  let old_month = Filename.concat dir "2020-01" in
  Fs_compat.mkdir_p old_month;
  Fs_compat.append_file (Filename.concat old_month "15.jsonl")
    "{\"old\":true}\n";
  (* Also add today's data *)
  let store = Dated_jsonl.create ~base_dir:dir () in
  Dated_jsonl.append store (make_json 1);
  (* Prune data older than 30 days *)
  let deleted = Dated_jsonl.prune store ~days:30 in
  check bool "deleted at least 1" true (deleted >= 1);
  check bool "old file removed" false
    (Sys.file_exists (Filename.concat old_month "15.jsonl"));
  (* Today's data should survive *)
  let result = Dated_jsonl.read_recent store 10 in
  check bool "today survives prune" true (List.length result > 0)

let test_prune_zero_days () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_prune0" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let deleted = Dated_jsonl.prune store ~days:0 in
  check int "zero days prunes nothing" 0 deleted

let test_max_bytes_prunes_oldest_completed_day_files () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_max_bytes" in
  let old_file_1 = Filename.concat (Filename.concat dir "2020-01") "01.jsonl" in
  let old_file_2 = Filename.concat (Filename.concat dir "2020-01") "02.jsonl" in
  write_dated_file dir "2020-01" "01"
    [ Printf.sprintf {|{"payload":"%s"}|} (String.make 80 'a') ];
  write_dated_file dir "2020-01" "02"
    [ Printf.sprintf {|{"payload":"%s"}|} (String.make 80 'b') ];
  let store = Dated_jsonl.create ~base_dir:dir ~max_bytes:120 () in
  Dated_jsonl.append store (make_json 1);
  check bool "oldest file removed" false (Sys.file_exists old_file_1);
  check bool "second old file removed" false (Sys.file_exists old_file_2);
  check (list int) "current day survives" [ 1 ]
    (Dated_jsonl.read_recent store 10 |> List.map json_i)

let test_max_bytes_preserves_current_day_file () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_max_bytes_current" in
  let store = Dated_jsonl.create ~base_dir:dir ~max_bytes:1 () in
  Dated_jsonl.append store
    (`Assoc [ ("payload", `String (String.make 128 'x')) ]);
  check int "current file row survives tiny cap" 1
    (List.length (Dated_jsonl.read_recent store 10))

(* ── concurrent append safety ──────────────────────────── *)

let test_concurrent_append () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_concurrent" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let n = 50 in
  Eio.Fiber.all (
    List.init n (fun i ->
      fun () ->
        Dated_jsonl.append store (make_json i)
    )
  );
  let result = Dated_jsonl.read_recent store n in
  check int "all entries written" n (List.length result)

(* ── empty store ───────────────────────────────────────── *)

let test_empty_store () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_empty" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let result = Dated_jsonl.read_recent store 10 in
  check int "empty read" 0 (List.length result);
  let lines = Dated_jsonl.read_recent_lines store 10 in
  check int "empty lines" 0 (List.length lines)

(* ── Test Suite ───────────────────────────────────────── *)

let () =
  run "Dated_jsonl"
    [
      ( "append",
        [
          test_case "creates dated file" `Quick test_append_creates_dated_file;
        ] );
      ( "read_recent",
        [
          test_case "returns newest N chronological" `Quick test_read_recent;
          test_case "returns 0 for n=0" `Quick test_read_recent_zero;
          test_case "returns all when n > count" `Quick test_read_recent_more_than_exists;
          test_case "skips malformed rows" `Quick
            test_read_recent_skips_malformed_lines;
          test_case "drops partial chunk prefix" `Quick test_load_tail_lines_drops_partial_chunk_prefix;
          test_case "keeps first data row after blank partial prefix" `Quick
            test_load_tail_lines_keeps_first_data_after_blank_prefix;
          test_case "keeps first row when full file spans chunks" `Quick
            test_load_tail_lines_keeps_first_when_full_file_spans_chunks;
        ] );
      ( "read_recent_lines",
        [
          test_case "returns raw strings" `Quick test_read_recent_lines;
          test_case "counts non-empty rows across files" `Quick test_count_entries;
        ] );
      ( "read_range",
        [
          test_case "today range non-empty" `Quick test_read_range;
          test_case "malformed dates safe" `Quick test_read_range_malformed;
          test_case "range_recent returns newest n in window" `Quick test_read_range_recent;
          test_case "iter_all chronological" `Quick
            test_iter_all_chronological_skips_malformed;
          test_case "iter_all result rejects malformed" `Quick
            test_iter_all_result_rejects_malformed;
          test_case "iter_range chronological" `Quick test_iter_range_chronological;
        ] );
      ( "prune",
        [
          test_case "removes old files" `Quick test_prune;
          test_case "zero days safe" `Quick test_prune_zero_days;
          test_case "max bytes prunes oldest completed day-files" `Quick
            test_max_bytes_prunes_oldest_completed_day_files;
          test_case "max bytes preserves current day-file" `Quick
            test_max_bytes_preserves_current_day_file;
        ] );
      ( "concurrent",
        [
          test_case "concurrent append" `Quick test_concurrent_append;
        ] );
      ( "empty",
        [
          test_case "empty store" `Quick test_empty_store;
        ] );
    ]
