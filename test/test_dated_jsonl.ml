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
          test_case "drops partial chunk prefix" `Quick test_load_tail_lines_drops_partial_chunk_prefix;
          test_case "keeps first data row after blank partial prefix" `Quick
            test_load_tail_lines_keeps_first_data_after_blank_prefix;
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
        ] );
      ( "prune",
        [
          test_case "removes old files" `Quick test_prune;
          test_case "zero days safe" `Quick test_prune_zero_days;
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
