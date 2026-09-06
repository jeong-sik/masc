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

let require_recent_result label = function
  | Ok entries -> entries
  | Error error ->
    failf "%s: %s" label (Dated_jsonl.read_error_to_string error)
;;

let test_read_recent_skips_malformed_lines () =
  let dir = tmpdir "dated_jsonl_recent_malformed" in
  write_dated_file dir "2026-01" "01"
    [ {|{"i":1}|}; "not-json"; {|{"i":2}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let values = Dated_jsonl.read_recent store 10 |> List.map json_i in
  check (list int) "read_recent skips malformed rows" [ 1; 2 ] values

(* ── filter_map_recent ───────────────────────────────────
   [read_recent] is now [filter_map_recent] with an identity projection, so
   comparing the two proves nothing. Every expectation below is absolute. *)

let test_filter_map_recent_is_chronological_across_day_files () =
  let dir = tmpdir "dated_jsonl_filter_map_order" in
  write_dated_file dir "2026-01" "31" [ {|{"i":1}|}; {|{"i":2}|} ];
  write_dated_file dir "2026-02" "01" [ {|{"i":3}|}; {|{"i":4}|} ];
  write_dated_file dir "2026-02" "02" [ {|{"i":5}|}; {|{"i":6}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let values = Dated_jsonl.filter_map_recent store 6 ~f:(fun j -> Some (json_i j)) in
  check (list int) "oldest first across months" [ 1; 2; 3; 4; 5; 6 ] values

let test_filter_map_recent_limit_counts_rows_read_not_rows_kept () =
  let dir = tmpdir "dated_jsonl_filter_map_limit" in
  write_dated_file dir "2026-01" "01"
    [ {|{"i":1}|}; {|{"i":2}|}; {|{"i":3}|}; {|{"i":4}|}; {|{"i":5}|}; {|{"i":6}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  (* The newest 4 rows are 3..6; the evens among *those* are 4 and 6. A reader
     that kept scanning until it had 4 selected rows would return [2;4;6]. *)
  let values =
    Dated_jsonl.filter_map_recent store 4 ~f:(fun j ->
      let i = json_i j in
      if i mod 2 = 0 then Some i else None)
  in
  check (list int) "n bounds rows read" [ 4; 6 ] values

let test_filter_map_recent_offset_skips_newest_rows () =
  let dir = tmpdir "dated_jsonl_filter_map_offset" in
  write_dated_file dir "2026-01" "01"
    [ {|{"i":1}|}; {|{"i":2}|}; {|{"i":3}|}; {|{"i":4}|}; {|{"i":5}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let values =
    Dated_jsonl.filter_map_recent ~offset:2 store 2 ~f:(fun j -> Some (json_i j))
  in
  check (list int) "offset drops the two newest" [ 2; 3 ] values

let test_filter_map_recent_skips_malformed_rows () =
  let dir = tmpdir "dated_jsonl_filter_map_malformed" in
  write_dated_file dir "2026-01" "01"
    [ {|{"i":1}|}; "not-json"; {|{"i":2}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let values = Dated_jsonl.filter_map_recent store 10 ~f:(fun j -> Some (json_i j)) in
  check (list int) "malformed row skipped" [ 1; 2 ] values

let test_filter_map_recent_calls_the_projection_newest_first () =
  (* The result is chronological, but the scan runs newest-first and prepends.
     A projection whose side effects depend on call order is therefore *not*
     interchangeable with [read_recent |> List.filter_map f]. Pinned because
     the remaining migration targets (rate-limited decode-error logging, drop
     reporting) are exactly that kind of projection. *)
  let dir = tmpdir "dated_jsonl_filter_map_visit_order" in
  write_dated_file dir "2026-01" "01" [ {|{"i":1}|}; {|{"i":2}|} ];
  write_dated_file dir "2026-01" "02" [ {|{"i":3}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let visited = ref [] in
  let values =
    Dated_jsonl.filter_map_recent store 3 ~f:(fun j ->
      let i = json_i j in
      visited := i :: !visited;
      Some i)
  in
  check (list int) "result is chronological" [ 1; 2; 3 ] values;
  check (list int) "projection saw rows newest first" [ 3; 2; 1 ]
    (List.rev !visited)

let test_filter_map_recent_does_not_swallow_callback_failure () =
  (* The reader swallows [Yojson.Json_error] to skip malformed rows. A decoder
     that raises the same exception must still reach the caller, or a broken
     decoder reads as an empty store. Guards the [try] scope in the reader. *)
  let dir = tmpdir "dated_jsonl_filter_map_callback_raise" in
  write_dated_file dir "2026-01" "01" [ {|{"i":1}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  check_raises "decoder failure reaches the caller"
    (Yojson.Json_error "decoder rejected the row")
    (fun () ->
      ignore
        (Dated_jsonl.filter_map_recent store 10 ~f:(fun _ ->
           raise (Yojson.Json_error "decoder rejected the row"))))

let test_collect_matching_counts_selected_rows () =
  let dir = tmpdir "dated_jsonl_collect_matching" in
  write_dated_file
    dir
    "2026-01"
    "01"
    [ {|{"i":1}|}; {|{"i":2}|}; {|{"i":3}|}; {|{"i":4}|}; {|{"i":5}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let values =
    Dated_jsonl.collect_matching store 2 ~f:(fun json ->
      let value = json_i json in
      if value mod 2 = 0 then Some value else None)
  in
  check (list int) "newest two matches stay chronological" [ 2; 4 ] values
;;

let test_collect_matching_range_skips_out_of_range_files () =
  let dir = tmpdir "dated_jsonl_collect_matching_range" in
  write_dated_file dir "2026-01" "31" [ {|{"i":1}|} ];
  write_dated_file dir "2026-02" "01" [ {|{"i":2}|} ];
  write_dated_file dir "2026-02" "02" [ {|{"i":3}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  let visited = ref [] in
  let values =
    Dated_jsonl.collect_matching_range
      store
      ~since:"2026-02-01"
      ~until:"2026-02-01"
      10
      ~f:(fun json ->
        let value = json_i json in
        visited := value :: !visited;
        Some value)
  in
  check (list int) "only the requested day contributes" [ 2 ] values;
  check (list int) "out-of-range files were never parsed" [ 2 ] !visited
;;

let test_collect_matching_stops_without_loading_the_day () =
  let dir = tmpdir "dated_jsonl_collect_matching_bounded" in
  let month_dir = Filename.concat dir "2026-01" in
  Fs_compat.mkdir_p month_dir;
  let path = Filename.concat month_dir "01.jsonl" in
  let descriptor =
    Unix.openfile path [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
      let sparse_prefix_bytes = 64 * 1024 * 1024 in
      Unix.ftruncate descriptor sparse_prefix_bytes;
      ignore (Unix.lseek descriptor sparse_prefix_bytes Unix.SEEK_SET);
      let suffix = "\n{\"i\":2}\n" in
      ignore (Unix.write_substring descriptor suffix 0 (String.length suffix)));
  let store = Dated_jsonl.create ~base_dir:dir () in
  let allocated_before = Gc.allocated_bytes () in
  let values =
    Dated_jsonl.collect_matching store 1 ~f:(fun json -> Some (json_i json))
  in
  let allocated = Gc.allocated_bytes () -. allocated_before in
  check (list int) "the newest match is returned" [ 2 ] values;
  check bool "reverse scan allocation stays below one whole-day load" true
    (allocated < Float.of_int (4 * 1024 * 1024))
;;

let test_read_recent_result_counts_malformed_physical_row () =
  let dir = tmpdir "dated_jsonl_recent_result_malformed" in
  write_dated_file
    dir
    "2026-01"
    "01"
    [ {|{"i":1}|}; {|{"i":2}|}; "not-json"; {|{"i":3}|} ];
  let path = Filename.concat (Filename.concat dir "2026-01") "01.jsonl" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  match
    Dated_jsonl.read_recent_result store 2
    |> require_recent_result "strict malformed recent read"
  with
  | [ Dated_jsonl.Malformed_json { path = malformed_path; line_number = None; _ }
    ; Dated_jsonl.Parsed json
    ] ->
    check string "malformed row path" path malformed_path;
    check int "newest parsed row" 3 (json_i json)
  | entries ->
    failf "expected malformed + parsed physical tail, got %d entries" (List.length entries)
;;

let test_read_recent_result_offset_counts_malformed_physical_row () =
  let dir = tmpdir "dated_jsonl_recent_result_offset" in
  write_dated_file
    dir
    "2026-01"
    "01"
    [ {|{"i":1}|}; {|{"i":2}|}; "not-json"; {|{"i":3}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  match
    Dated_jsonl.read_recent_result ~offset:1 store 2
    |> require_recent_result "strict offset recent read"
  with
  | [ Dated_jsonl.Parsed json; Dated_jsonl.Malformed_json _ ] ->
    check int "oldest selected parsed row" 2 (json_i json)
  | entries ->
    failf "expected parsed + malformed offset window, got %d entries" (List.length entries)
;;

let test_read_recent_result_rejects_negative_offset () =
  let store = Dated_jsonl.create ~base_dir:(tmpdir "dated_jsonl_negative_offset") () in
  match Dated_jsonl.read_recent_result ~offset:(-1) store 1 with
  | Error (Dated_jsonl.Invalid_offset { offset = -1 }) -> ()
  | Error error ->
    failf "unexpected negative-offset error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "negative strict recent-read offset was accepted"
;;

let test_read_recent_result_missing_store_is_empty () =
  let base_dir = Filename.concat (tmpdir "dated_jsonl_missing_store") "absent" in
  let store = Dated_jsonl.create ~base_dir () in
  let entries =
    Dated_jsonl.read_recent_result store 4
    |> require_recent_result "missing strict store"
  in
  check int "missing store is empty" 0 (List.length entries)
;;

let test_read_recent_result_rejects_base_file () =
  let dir = tmpdir "dated_jsonl_base_file" in
  let base_dir = Filename.concat dir "ledger" in
  Fs_compat.append_file base_dir "not-a-directory";
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.read_recent_result store 1 with
  | Error (Dated_jsonl.Not_a_directory { path }) ->
    check string "base file path" base_dir path
  | Error error ->
    failf "unexpected base-file error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "base file was treated as an empty strict store"
;;

let test_read_recent_result_rejects_month_file () =
  let base_dir = tmpdir "dated_jsonl_month_file" in
  let month_path = Filename.concat base_dir "2026-01" in
  Fs_compat.append_file month_path "not-a-directory";
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.read_recent_result store 1 with
  | Error (Dated_jsonl.Not_a_directory { path }) ->
    check string "month file path" month_path path
  | Error error ->
    failf "unexpected month-file error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "month file was treated as an empty strict store"
;;

let test_read_recent_result_rejects_month_symlink () =
  let dir = tmpdir "dated_jsonl_month_symlink" in
  let base_dir = Filename.concat dir "ledger" in
  let external_dir = Filename.concat dir "external" in
  Fs_compat.mkdir_p base_dir;
  write_dated_file external_dir "2026-01" "01" [ {|{"outside":true}|} ];
  let month_path = Filename.concat base_dir "2026-01" in
  Unix.symlink (Filename.concat external_dir "2026-01") month_path;
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.read_recent_result store 1 with
  | Error
      (Dated_jsonl.Non_regular_file
        { path = error_path; kind = Dated_jsonl.Symbolic_link }) ->
    check string "month symlink path" month_path error_path
  | Error error ->
    failf
      "unexpected month-symlink error: %s"
      (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "month symlink escaped the strict store boundary"
;;

let test_read_recent_result_rejects_day_symlink () =
  let base_dir = tmpdir "dated_jsonl_day_symlink" in
  let month_path = Filename.concat base_dir "2026-01" in
  Fs_compat.mkdir_p month_path;
  let path = Filename.concat month_path "01.jsonl" in
  Unix.symlink (Filename.concat base_dir "missing-target") path;
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.read_recent_result store 1 with
  | Error
      (Dated_jsonl.Non_regular_file
        { path = error_path; kind = Dated_jsonl.Symbolic_link }) ->
    check string "day symlink path" path error_path
  | Error error ->
    failf "unexpected day-symlink error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "day symlink was accepted as a strict store file"
;;

let test_read_recent_result_rejects_base_symlink () =
  let dir = tmpdir "dated_jsonl_dangling_base" in
  let base_dir = Filename.concat dir "ledger" in
  Unix.symlink (Filename.concat dir "missing-target") base_dir;
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.read_recent_result store 1 with
  | Error
      (Dated_jsonl.Non_regular_file
        { path = error_path; kind = Dated_jsonl.Symbolic_link }) ->
    check string "base symlink path" base_dir error_path
  | Error error ->
    failf
      "unexpected base-symlink error: %s"
      (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "base symlink was treated as an empty store"
;;

(* The environment writes dotfiles into any directory it touches — macOS puts
   .DS_Store beside the month directories. Failing the read on one of those
   would hide every row in the store, so they are skipped. A real layout
   violation still fails: that means a writer is wrong (see the test below). *)
let test_read_recent_result_skips_dot_entries () =
  let base_dir = tmpdir "dated_jsonl_dot_entries" in
  write_dated_file base_dir "2026-02" "01" [ {|{"i":1}|} ];
  Fs_compat.append_file (Filename.concat base_dir ".DS_Store") "not dated";
  Fs_compat.append_file
    (Filename.concat (Filename.concat base_dir "2026-02") ".DS_Store")
    "not dated";
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.read_recent_result store 10 with
  | Ok rows -> check int "the row is still readable" 1 (List.length rows)
  | Error error ->
    failf
      "a stray dotfile hid the whole store: %s"
      (Dated_jsonl.read_error_to_string error)
;;

let test_read_recent_result_rejects_invalid_layout () =
  let base_dir = tmpdir "dated_jsonl_invalid_layout" in
  let invalid_month = "2026-aa" in
  Fs_compat.mkdir_p (Filename.concat base_dir invalid_month);
  let store = Dated_jsonl.create ~base_dir () in
  (match Dated_jsonl.read_recent_result store 1 with
   | Error
       (Dated_jsonl.Invalid_layout_entry
         { parent; entry; expected = Dated_jsonl.Month_directory }) ->
     check string "invalid layout parent" base_dir parent;
     check string "invalid month entry" invalid_month entry
   | Error error ->
     failf "unexpected layout error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "invalid month layout was silently ignored");
  let day_base_dir = tmpdir "dated_jsonl_invalid_day_layout" in
  let month_path = Filename.concat day_base_dir "2026-02" in
  Fs_compat.mkdir_p month_path;
  let invalid_day = "29.jsonl" in
  Fs_compat.append_file (Filename.concat month_path invalid_day) "{}\n";
  let day_store = Dated_jsonl.create ~base_dir:day_base_dir () in
  match Dated_jsonl.read_recent_result day_store 1 with
  | Error
      (Dated_jsonl.Invalid_layout_entry
        { parent; entry; expected = Dated_jsonl.Day_file }) ->
    check string "invalid day parent" month_path parent;
    check string "invalid day entry" invalid_day entry
  | Error error ->
    failf "unexpected day layout error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "invalid day layout was silently ignored"
;;

let test_read_recent_result_accepts_leap_day () =
  let base_dir = tmpdir "dated_jsonl_leap_day" in
  write_dated_file base_dir "2024-02" "29" [ {|{"i":29}|} ];
  let store = Dated_jsonl.create ~base_dir () in
  match
    Dated_jsonl.read_recent_result store 1
    |> require_recent_result "leap-day strict read"
  with
  | [ Dated_jsonl.Parsed row ] -> check int "leap day row" 29 (json_i row)
  | entries -> failf "unexpected leap-day entries: %d" (List.length entries)
;;

let test_read_recent_result_rejects_fifo_without_blocking () =
  let base_dir = tmpdir "dated_jsonl_fifo" in
  let month_path = Filename.concat base_dir "2026-01" in
  Fs_compat.mkdir_p month_path;
  let path = Filename.concat month_path "01.jsonl" in
  Unix.mkfifo path 0o600;
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.read_recent_result store 1 with
  | Error
      (Dated_jsonl.Non_regular_file
        { path = error_path; kind = Dated_jsonl.Fifo }) ->
    check string "FIFO path" path error_path
  | Error error ->
    failf "unexpected FIFO error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok _ -> fail "FIFO day entry was accepted as a regular JSONL file"
;;

let test_read_recent_result_spans_months_and_physical_offset () =
  let dir = tmpdir "dated_jsonl_recent_result_cross_month" in
  write_dated_file dir "2026-01" "31" [ {|{"i":1}|}; {|{"i":2}|} ];
  write_dated_file dir "2026-02" "01" [ "not-json"; {|{"i":3}|} ];
  write_dated_file dir "2026-02" "02" [ {|{"i":4}|}; {|{"i":5}|} ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  match
    Dated_jsonl.read_recent_result ~offset:1 store 4
    |> require_recent_result "cross-month strict recent read"
  with
  | [ Dated_jsonl.Parsed oldest
    ; Dated_jsonl.Malformed_json _
    ; Dated_jsonl.Parsed middle
    ; Dated_jsonl.Parsed newest
    ] ->
    check int "cross-month oldest selected row" 2 (json_i oldest);
    check int "cross-month middle selected row" 3 (json_i middle);
    check int "cross-month newest selected row" 4 (json_i newest)
  | entries ->
    failf "unexpected cross-month strict window: %d entries" (List.length entries)
;;

let test_read_recent_result_keeps_unterminated_tail_row () =
  let base_dir = tmpdir "dated_jsonl_unterminated_tail" in
  let month_path = Filename.concat base_dir "2026-01" in
  Fs_compat.mkdir_p month_path;
  Fs_compat.append_file
    (Filename.concat month_path "01.jsonl")
    {|{"i":1}
{"i":2}|};
  let store = Dated_jsonl.create ~base_dir () in
  match
    Dated_jsonl.read_recent_result store 1
    |> require_recent_result "unterminated strict tail"
  with
  | [ Dated_jsonl.Parsed json ] -> check int "unterminated newest row" 2 (json_i json)
  | entries -> failf "unexpected unterminated tail: %d entries" (List.length entries)
;;

let test_find_latest_entry_result_scans_backwards_across_chunks () =
  let dir = tmpdir "dated_jsonl_find_latest" in
  let padding = String.make 9000 'x' in
  write_dated_file
    dir
    "2026-01"
    "01"
    [ {|{"kind":"turn","value":1}|}
    ; Printf.sprintf {|{"kind":"heartbeat","padding":"%s"}|} padding
    ; {|{"kind":"heartbeat","value":2}|}
    ];
  let store = Dated_jsonl.create ~base_dir:dir () in
  match
    Dated_jsonl.find_latest_entry_result store (function
      | Dated_jsonl.Parsed json
        when Yojson.Safe.Util.(json |> member "kind" |> to_string) = "turn" ->
        Some Yojson.Safe.Util.(json |> member "value" |> to_int)
      | Dated_jsonl.Parsed _ | Dated_jsonl.Malformed_json _ -> None)
  with
  | Ok (Some value) -> check int "finds earlier typed row" 1 value
  | Ok None -> fail "latest typed row was not found"
  | Error error ->
    failf
      "latest typed row scan failed: %s"
      (Dated_jsonl.read_error_to_string error)
;;

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
  let lines = Dated_jsonl.load_tail_lines path ~max_lines:5 in
  check (list string) "drops partial chunk prefix" expected lines

(* Differential test for the single-pass rewrite of the tail cutter.

   [load_tail_lines] used to build its result as
   [Bytes.to_string |> String.split_on_char |> List.filter |> List.filteri].
   That reference is reproduced here and compared against the live
   implementation over generated inputs, so the rewrite is held to producing the
   same list rather than to a handful of hand-picked cases. The generator mixes
   blank lines, whitespace-only lines, a missing trailing newline, and contents
   that straddle the 8KB chunk boundary, because those are where the two shapes
   could diverge.

   Seeded so a failure reproduces. *)
let reference_tail_lines content ~max_lines =
  if max_lines <= 0 then []
  else
    let is_blank character =
      match character with ' ' | '\012' | '\n' | '\r' | '\t' -> true | _ -> false
    in
    let lines =
      content
      |> String.split_on_char '\n'
      |> List.filter (fun line ->
           String.exists (fun character -> not (is_blank character)) line)
    in
    let count = List.length lines in
    if count <= max_lines then lines
    else List.filteri (fun index _ -> index >= count - max_lines) lines

let test_load_tail_lines_matches_reference () =
  let dir = tmpdir "dated_jsonl_tail_differential" in
  let state = Random.State.make [| 0x7A11 |] in
  for case = 0 to 199 do
    let row_count = Random.State.int state 40 in
    let rows =
      List.init row_count (fun index ->
        match Random.State.int state 6 with
        | 0 -> ""
        | 1 -> "   "
        | 2 -> "\t \r"
        | 3 ->
          (* straddle the 8KB chunk boundary *)
          Printf.sprintf {|{"i":%d,"pad":"%s"}|} index
            (String.make (Random.State.int state 3000) 'x')
        | _ -> Printf.sprintf {|{"i":%d}|} index)
    in
    let content =
      String.concat "\n" rows
      ^ if Random.State.bool state then "\n" else ""
    in
    let path = Filename.concat dir (Printf.sprintf "case%d.jsonl" case) in
    Fs_compat.append_file path content;
    let max_lines = 1 + Random.State.int state 12 in
    check (list string)
      (Printf.sprintf "case %d (rows=%d, max_lines=%d)" case row_count max_lines)
      (reference_tail_lines content ~max_lines)
      (Dated_jsonl.load_tail_lines path ~max_lines)
  done

let test_load_tail_lines_missing_file_is_empty () =
  let path = Filename.concat (tmpdir "dated_jsonl_missing_tail") "missing.jsonl" in
  check
    (list string)
    "missing tail is empty"
    []
    (Dated_jsonl.load_tail_lines path ~max_lines:5)
;;

let test_load_tail_lines_counts_nonempty_rows_exactly () =
  let dir = tmpdir "dated_jsonl_exact_nonempty_tail" in
  let path = Filename.concat dir "tail.jsonl" in
  let blanks = List.init 40 (fun _ -> "") in
  let expected = [ {|{"i":1}|}; {|{"i":2}|}; {|{"i":3}|} ] in
  let lines =
    [ List.nth expected 0 ]
    @ blanks
    @ [ List.nth expected 1 ]
    @ blanks
    @ [ List.nth expected 2 ]
  in
  Fs_compat.append_file path (String.concat "\n" lines ^ "\n");
  check (list string)
    "blank rows do not terminate the exact tail scan"
    expected
    (Dated_jsonl.load_tail_lines path ~max_lines:3)
;;

let test_load_tail_lines_counts_vertical_tab_as_physical_row () =
  let dir = tmpdir "dated_jsonl_vertical_tab_tail" in
  let path = Filename.concat dir "tail.jsonl" in
  let vertical_tab_row = String.make 9000 '\011' in
  Fs_compat.append_file path ({|{"i":1}|} ^ "\n" ^ vertical_tab_row ^ "\n");
  check
    (list string)
    "vertical-tab row uses the same non-empty predicate as final selection"
    [ vertical_tab_row ]
    (Dated_jsonl.load_tail_lines path ~max_lines:1)
;;

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

(* ── fold_range_appended reads only what was appended ──── *)

let today_utc () =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
;;

(* The whole point is that the second call does not re-read the first call's
   rows. A fold that returns the right total by reading everything again would
   pass a total-only check, so the accumulator counts rows and the check is
   what the second fold saw, not what the store holds. *)
let test_fold_range_appended_sees_only_new_rows () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_fold_appended" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let today = today_utc () in
  List.iter (fun i -> Dated_jsonl.append store (make_json i)) [ 1; 2; 3 ];
  let seen, cursors =
    Dated_jsonl.fold_range_appended store ~since:today ~until:today ~cursors:[]
      ~init:[] ~f:(fun acc json -> json_i json :: acc)
  in
  check (list int) "a first fold reads the file whole" [ 3; 2; 1 ] seen;
  let seen_again, cursors_again =
    Dated_jsonl.fold_range_appended store ~since:today ~until:today ~cursors
      ~init:[] ~f:(fun acc json -> json_i json :: acc)
  in
  check (list int) "nothing appended, nothing read" [] seen_again;
  check bool "the cursor did not move" true (cursors_again = cursors);
  List.iter (fun i -> Dated_jsonl.append store (make_json i)) [ 4; 5 ];
  let appended, cursors_after =
    Dated_jsonl.fold_range_appended store ~since:today ~until:today
      ~cursors:cursors_again ~init:[] ~f:(fun acc json -> json_i json :: acc)
  in
  check (list int) "only the rows appended since" [ 5; 4 ] appended;
  check bool "the cursor advanced" true (cursors_after <> cursors_again);
  let outside, _ =
    Dated_jsonl.fold_range_appended store ~since:"2099-01-01" ~until:"2099-12-31"
      ~cursors:[] ~init:[] ~f:(fun acc json -> json_i json :: acc)
  in
  check (list int) "a range with no files reads nothing" [] outside
;;

(* [range_day_file_paths] names files without opening them, and it must name
   exactly the files [iter_range] would read -- a path it omits is a row an
   incremental caller would never see again. *)
let test_range_day_file_paths_matches_iter_range () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_range_paths" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let today = today_utc () in
  Dated_jsonl.append store (make_json 1);
  let paths = Dated_jsonl.range_day_file_paths store ~since:today ~until:today in
  check int "today names one file" 1 (List.length paths);
  check bool "and it exists" true (List.for_all Sys.file_exists paths);
  let rows = ref 0 in
  Dated_jsonl.iter_range store ~since:today ~until:today (fun _ -> incr rows);
  check bool "the file iter_range read" true (!rows > 0);
  check (list string) "a future range names none" []
    (Dated_jsonl.range_day_file_paths store ~since:"2099-01-01" ~until:"2099-12-31");
  check (list string) "invalid dates name none" []
    (Dated_jsonl.range_day_file_paths store ~since:"bad" ~until:"dates")
;;

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

let test_iter_all_entries_result_continues_after_malformed () =
  let dir = tmpdir "dated_jsonl_iter_all_entries_result" in
  write_dated_file dir "2026-01" "31" [ {|{"i":1}|} ];
  write_dated_file
    dir
    "2026-02"
    "01"
    [ "not-json"; {|{"i":2}|} ];
  write_dated_file dir "2026-02" "02" [ {|{"i":3}|} ];
  Fs_compat.append_file (Filename.concat dir ".DS_Store") "not dated";
  Fs_compat.append_file
    (Filename.concat (Filename.concat dir "2026-02") ".DS_Store")
    "not dated";
  let path = Filename.concat (Filename.concat dir "2026-02") "01.jsonl" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let seen = ref [] in
  (match
     Dated_jsonl.iter_all_entries_result store (fun entry -> seen := entry :: !seen)
   with
   | Ok () -> ()
   | Error error ->
     failf "strict entry iteration failed: %s" (Dated_jsonl.read_error_to_string error));
  match List.rev !seen with
  | [ Dated_jsonl.Parsed first
    ; Dated_jsonl.Malformed_json
        { path = malformed_path; line_number = Some 1; _ }
    ; Dated_jsonl.Parsed second
    ; Dated_jsonl.Parsed third
    ] ->
    check int "first parsed entry" 1 (json_i first);
    check string "stream malformed path" path malformed_path;
    check int "iteration continued after malformed" 2 (json_i second);
    check int "cross-month/day chronology" 3 (json_i third)
  | entries ->
    failf "expected parsed/malformed/parsed stream, got %d entries" (List.length entries)
;;

let test_iter_all_entries_result_surfaces_typed_io_error () =
  let dir = tmpdir "dated_jsonl_iter_entries_io" in
  let base_dir = Filename.concat dir "ledger" in
  Fs_compat.append_file base_dir "not-a-directory";
  let store = Dated_jsonl.create ~base_dir () in
  match Dated_jsonl.iter_all_entries_result store ignore with
  | Error (Dated_jsonl.Not_a_directory { path }) ->
    check string "stream base file path" base_dir path
  | Error error ->
    failf "unexpected strict stream error: %s" (Dated_jsonl.read_error_to_string error)
  | Ok () -> fail "strict stream treated base file as an empty store"
;;

let test_iter_range_entries_result_reads_only_requested_days () =
  let dir = tmpdir "dated_jsonl_iter_range_entries_result" in
  write_dated_file dir "2026-01" "31" [ {|{"i":1}|} ];
  write_dated_file
    dir
    "2026-02"
    "01"
    [ "not-json"; {|{"i":2}|} ];
  write_dated_file dir "2026-02" "02" [ {|{"i":3}|} ];
  let path = Filename.concat (Filename.concat dir "2026-02") "01.jsonl" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let seen = ref [] in
  (match
     Dated_jsonl.iter_range_entries_result
       store
       ~since:"2026-02-01"
       ~until:"2026-02-01"
       (fun entry -> seen := entry :: !seen)
   with
   | Ok () -> ()
   | Error error ->
     failf
       "strict range iteration failed: %s"
       (Dated_jsonl.read_error_to_string error));
  match List.rev !seen with
  | [ Dated_jsonl.Malformed_json
        { path = malformed_path; line_number = Some 1; _ }
    ; Dated_jsonl.Parsed json
    ] ->
    check string "range malformed path" path malformed_path;
    check int "only requested day parsed" 2 (json_i json)
  | entries ->
    failf
      "expected malformed + parsed requested-day stream, got %d entries"
      (List.length entries)
;;

let test_iter_range_entries_result_rejects_invalid_range () =
  let store =
    Dated_jsonl.create
      ~base_dir:(tmpdir "dated_jsonl_iter_range_invalid")
      ()
  in
  let rejects ~name ~since ~until =
    match Dated_jsonl.iter_range_entries_result store ~since ~until ignore with
    | Error (Dated_jsonl.Invalid_date_range _) -> ()
    | Error error ->
      failf
        "%s: unexpected strict range error: %s"
        name
        (Dated_jsonl.read_error_to_string error)
    | Ok () -> failf "%s: strict range accepted invalid dates" name
  in
  rejects
    ~name:"reversed"
    ~since:"2026-02-02"
    ~until:"2026-02-01";
  rejects
    ~name:"invalid calendar day"
    ~since:"2026-02-30"
    ~until:"2026-02-30"
;;

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

(* The cutoff month and day used to be formatted here rather than asked of
   the writer, and the existing case only separates 2020 from today -- six
   years of slack hides any disagreement. These put a file on each side of
   the boundary and name the boundary through Jsonl_writer, the module that
   decides where rows land (#27143). *)
let test_prune_boundary_follows_the_writer_layout () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_prune_boundary" in
  let day = 86_400.0 in
  let now = Unix.gettimeofday () in
  let write_day ~ts =
    let dated = Jsonl_writer.dated_path ~base_dir:dir ~ts in
    Fs_compat.mkdir_p (Filename.concat dir dated.Jsonl_writer.month_dir);
    Fs_compat.append_file dated.Jsonl_writer.path "{\"probe\":true}\n";
    dated.Jsonl_writer.path
  in
  (* One day past the cutoff and one day inside it. *)
  let outside = write_day ~ts:(now -. (31.0 *. day)) in
  let inside = write_day ~ts:(now -. (29.0 *. day)) in
  let store = Dated_jsonl.create ~base_dir:dir () in
  ignore (Dated_jsonl.prune store ~days:30);
  check bool "the day past the cutoff is gone" false (Sys.file_exists outside);
  check bool "the day inside the cutoff is kept" true (Sys.file_exists inside)
;;

let test_prune_keeps_the_cutoff_day_itself () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_prune_cutoff_day" in
  let day = 86_400.0 in
  let now = Unix.gettimeofday () in
  let dated = Jsonl_writer.dated_path ~base_dir:dir ~ts:(now -. (30.0 *. day)) in
  Fs_compat.mkdir_p (Filename.concat dir dated.Jsonl_writer.month_dir);
  Fs_compat.append_file dated.Jsonl_writer.path "{\"probe\":true}\n";
  let store = Dated_jsonl.create ~base_dir:dir () in
  ignore (Dated_jsonl.prune store ~days:30);
  check
    bool
    "the cutoff day is retained, not deleted"
    true
    (Sys.file_exists dated.Jsonl_writer.path)
;;

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

(* ── append_rotating: size-capped ring over intra-day segments ────
   (#29009) The previous cap contract dropped every row for the rest of
   the day once the current file was full. These pin the replacement:
   the full file rotates to [DD.NNN.jsonl], new rows keep landing, the
   store byte budget sheds the oldest segment first, and every reader
   sees segments as ordinary day files. *)

(* Fixed-size row: {"i":N} + newline = 8 bytes for single-digit N, so
   the caps below are exact row multiples. *)
let tiny_json i = `Assoc [ ("i", `Int i) ]
let tiny_row_bytes = String.length (Yojson.Safe.to_string (tiny_json 1)) + 1

let today_parts () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) in
  let day = Printf.sprintf "%02d" tm.Unix.tm_mday in
  (month, day)

let segment_path dir ~sequence =
  let month, day = today_parts () in
  Filename.concat (Filename.concat dir month)
    (Printf.sprintf "%s.%03d.jsonl" day sequence)

let current_path dir =
  let month, day = today_parts () in
  Filename.concat (Filename.concat dir month) (day ^ ".jsonl")

let non_empty_lines file =
  Fs_compat.load_file file
  |> String.split_on_char '\n'
  |> List.filter (fun l -> String.trim l <> "")

let test_append_rotating_rotates_at_cap () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_rotate" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  (match
     Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
       (tiny_json 1)
   with
   | Dated_jsonl.Appended_to_current -> ()
   | _ -> fail "first row must land in the current file");
  (match
     Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
       (tiny_json 2)
   with
   | Dated_jsonl.Appended_after_rotation { segment } ->
     let _, day = today_parts () in
     check string "segment name" (Printf.sprintf "%s.001.jsonl" day) segment
   | _ -> fail "second row must rotate the full current file");
  check int "segment holds the first row" 1
    (List.length (non_empty_lines (segment_path dir ~sequence:1)));
  check int "current holds the second row" 1
    (List.length (non_empty_lines (current_path dir)));
  let values = List.map json_i (Dated_jsonl.read_recent store 10) in
  check (list int) "readers see both rows across the rotation" [ 1; 2 ] values

let test_append_rotating_range_reads_cross_segments () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_rotate_range" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  for i = 1 to 3 do
    ignore
      (Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
         (tiny_json i)
        : Dated_jsonl.append_outcome)
  done;
  let month, day = today_parts () in
  let today = month ^ "-" ^ day in
  let values =
    Dated_jsonl.read_range store ~since:today ~until:today |> List.map json_i
  in
  check (list int) "range read includes rotated segments" [ 1; 2; 3 ] values

let test_append_rotating_ring_prunes_oldest_segment () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_rotate_ring" in
  let store =
    Dated_jsonl.create ~base_dir:dir ~max_bytes:(2 * tiny_row_bytes) ()
  in
  for i = 1 to 3 do
    ignore
      (Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
         (tiny_json i)
        : Dated_jsonl.append_outcome)
  done;
  (* Three rows at a two-row budget: the oldest completed segment is
     shed, the newest segment and the current file survive. *)
  check bool "oldest segment pruned" false
    (Sys.file_exists (segment_path dir ~sequence:1));
  check bool "newest segment survives" true
    (Sys.file_exists (segment_path dir ~sequence:2));
  let values = List.map json_i (Dated_jsonl.read_recent store 10) in
  check (list int) "ring keeps the newest rows" [ 2; 3 ] values

let test_append_rotating_oversized_row_lands_in_empty_current () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_rotate_oversized" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  let oversized = `Assoc [ ("i", `Int 1); ("pad", `String (String.make 64 'x')) ] in
  (match
     Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
       oversized
   with
   | Dated_jsonl.Appended_to_current -> ()
   | _ -> fail "an oversized row must land in an empty current file");
  (match
     Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
       (tiny_json 2)
   with
   | Dated_jsonl.Appended_after_rotation { segment = _ } -> ()
   | _ -> fail "the next row must rotate the oversized file out");
  let values = List.map json_i (Dated_jsonl.read_recent store 10) in
  check (list int) "both rows readable" [ 1; 2 ] values

let test_append_rotating_sequence_survives_restart () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = tmpdir "dated_jsonl_rotate_restart" in
  let store = Dated_jsonl.create ~base_dir:dir () in
  ignore
    (Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
       (tiny_json 1)
      : Dated_jsonl.append_outcome);
  ignore
    (Dated_jsonl.append_rotating store ~max_current_file_bytes:tiny_row_bytes
       (tiny_json 2)
      : Dated_jsonl.append_outcome);
  (* A fresh handle over the same directory derives the next sequence
     from the names on disk, not from in-process state. *)
  let reopened = Dated_jsonl.create ~base_dir:dir () in
  (match
     Dated_jsonl.append_rotating reopened ~max_current_file_bytes:tiny_row_bytes
       (tiny_json 3)
   with
   | Dated_jsonl.Appended_after_rotation { segment } ->
     let _, day = today_parts () in
     check string "sequence continues after reopen"
       (Printf.sprintf "%s.002.jsonl" day) segment
   | _ -> fail "reopened store must rotate with the next sequence");
  check bool "first segment still present" true
    (Sys.file_exists (segment_path dir ~sequence:1))

let () =
  run "Dated_jsonl"
    [
      ( "append",
        [
          test_case "creates dated file" `Quick test_append_creates_dated_file;
        ] );
      ( "append_rotating",
        [
          test_case "rotates the full current file at the cap" `Quick
            test_append_rotating_rotates_at_cap;
          test_case "range reads cross rotated segments" `Quick
            test_append_rotating_range_reads_cross_segments;
          test_case "byte budget sheds the oldest segment first" `Quick
            test_append_rotating_ring_prunes_oldest_segment;
          test_case "oversized single row lands in an empty file" `Quick
            test_append_rotating_oversized_row_lands_in_empty_current;
          test_case "rotation sequence survives a reopen" `Quick
            test_append_rotating_sequence_survives_restart;
        ] );
      ( "read_recent",
        [
          test_case "returns newest N chronological" `Quick test_read_recent;
          test_case "returns 0 for n=0" `Quick test_read_recent_zero;
          test_case "returns all when n > count" `Quick test_read_recent_more_than_exists;
          test_case "skips malformed rows" `Quick
            test_read_recent_skips_malformed_lines;
          test_case "strict read counts malformed physical row" `Quick
            test_read_recent_result_counts_malformed_physical_row;
          test_case "strict offset counts malformed physical row" `Quick
            test_read_recent_result_offset_counts_malformed_physical_row;
          test_case "strict read rejects negative offset" `Quick
            test_read_recent_result_rejects_negative_offset;
          test_case "strict missing store is empty" `Quick
            test_read_recent_result_missing_store_is_empty;
          test_case "strict read rejects base file" `Quick
            test_read_recent_result_rejects_base_file;
          test_case "strict read rejects month file" `Quick
            test_read_recent_result_rejects_month_file;
          test_case "strict read rejects month symlink" `Quick
            test_read_recent_result_rejects_month_symlink;
          test_case "strict read rejects day symlink" `Quick
            test_read_recent_result_rejects_day_symlink;
          test_case "strict read rejects base symlink" `Quick
            test_read_recent_result_rejects_base_symlink;
          test_case "strict read rejects invalid layout" `Quick
            test_read_recent_result_rejects_invalid_layout;
          test_case "strict read skips dot entries" `Quick
            test_read_recent_result_skips_dot_entries;
          test_case "strict read accepts leap day" `Quick
            test_read_recent_result_accepts_leap_day;
          test_case "strict read rejects FIFO without blocking" `Quick
            test_read_recent_result_rejects_fifo_without_blocking;
          test_case "strict read spans months and physical offset" `Quick
            test_read_recent_result_spans_months_and_physical_offset;
          test_case "strict read keeps unterminated tail row" `Quick
            test_read_recent_result_keeps_unterminated_tail_row;
          test_case "strict latest scan crosses chunks" `Quick
            test_find_latest_entry_result_scans_backwards_across_chunks;
          test_case "drops partial chunk prefix" `Quick test_load_tail_lines_drops_partial_chunk_prefix;
          test_case "matches the pre-rewrite reference" `Quick
            test_load_tail_lines_matches_reference;
          test_case "missing tail is empty" `Quick
            test_load_tail_lines_missing_file_is_empty;
          test_case "counts nonempty tail rows exactly" `Quick
            test_load_tail_lines_counts_nonempty_rows_exactly;
          test_case "vertical tab is a physical tail row" `Quick
            test_load_tail_lines_counts_vertical_tab_as_physical_row;
          test_case "keeps first data row after blank partial prefix" `Quick
            test_load_tail_lines_keeps_first_data_after_blank_prefix;
          test_case "keeps first row when full file spans chunks" `Quick
            test_load_tail_lines_keeps_first_when_full_file_spans_chunks;
        ] );
      ( "filter_map_recent",
        [
          test_case "chronological across day files" `Quick
            test_filter_map_recent_is_chronological_across_day_files;
          test_case "n bounds rows read not rows kept" `Quick
            test_filter_map_recent_limit_counts_rows_read_not_rows_kept;
          test_case "offset skips newest rows" `Quick
            test_filter_map_recent_offset_skips_newest_rows;
          test_case "skips malformed rows" `Quick
            test_filter_map_recent_skips_malformed_rows;
          test_case "projection is called newest first" `Quick
            test_filter_map_recent_calls_the_projection_newest_first;
          test_case "callback failure is not swallowed" `Quick
            test_filter_map_recent_does_not_swallow_callback_failure;
        ] );
      ( "collect_matching",
        [ test_case "n counts selected rows" `Quick
            test_collect_matching_counts_selected_rows;
          test_case "range skips out-of-range files" `Quick
            test_collect_matching_range_skips_out_of_range_files;
          test_case "reverse scan keeps day-file allocation bounded" `Quick
            test_collect_matching_stops_without_loading_the_day;
        ] );
      ( "read_recent_lines",
        [
          test_case "returns raw strings" `Quick test_read_recent_lines;
          test_case "counts non-empty rows across files" `Quick test_count_entries;
        ] );
      ( "read_range",
        [
          test_case "today range non-empty" `Quick test_read_range;
          test_case "fold_range_appended sees only new rows" `Quick
            test_fold_range_appended_sees_only_new_rows;
          test_case "range_day_file_paths matches iter_range" `Quick
            test_range_day_file_paths_matches_iter_range;
          test_case "malformed dates safe" `Quick test_read_range_malformed;
          test_case "range_recent returns newest n in window" `Quick test_read_range_recent;
          test_case "iter_all chronological" `Quick
            test_iter_all_chronological_skips_malformed;
          test_case "strict entry iteration continues after malformed" `Quick
            test_iter_all_entries_result_continues_after_malformed;
          test_case "strict entry iteration surfaces typed I/O" `Quick
            test_iter_all_entries_result_surfaces_typed_io_error;
          test_case "strict range reads only requested days" `Quick
            test_iter_range_entries_result_reads_only_requested_days;
          test_case "strict range rejects invalid range" `Quick
            test_iter_range_entries_result_rejects_invalid_range;
          test_case "iter_range chronological" `Quick test_iter_range_chronological;
        ] );
      ( "prune",
        [
          test_case "removes old files" `Quick test_prune;
          test_case "zero days safe" `Quick test_prune_zero_days;
          test_case "boundary follows the writer layout" `Quick
            test_prune_boundary_follows_the_writer_layout;
          test_case "cutoff day itself is kept" `Quick
            test_prune_keeps_the_cutoff_day_itself;
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
