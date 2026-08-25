open Alcotest

module Decode = Masc.Tui_decode
module Keeper_chat = Masc_tui_keeper_chat_projection
module Tail = Masc_tui_metrics_tail

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ())
         (Unix.gettimeofday ()))
  in
  Fs_compat.mkdir_p path;
  path

let heartbeat ?(timestamp = "2026-08-21T12:00:00Z")
    ?(name = "keeper-main") count =
  `Assoc
    [ "schema", `String Masc.Keeper_metrics_record.schema
    ; "record_kind", `String "heartbeat"
    ; "ts", `String timestamp
    ; "ts_unix", `Float 1787313600.0
    ; "channel", `String "heartbeat"
    ; "name", `String name
    ; "agent_name", `String "codex"
    ; "trace_id", `String "trace-current"
    ; "message_count", `Int count
    ]

let message_counts entries =
  List.map (fun (entry : Decode.log_entry) -> entry.le_message_count) entries

let test_resolve_is_physical_bounded_and_chronological () =
  let seen_limit = ref None in
  let rows =
    [ Dated_jsonl.Parsed (heartbeat 1)
    ; Dated_jsonl.Malformed_json
        { path = "/tmp/metrics/21.jsonl";
          line_number = None;
          detail = "invalid JSON";
        }
    ; Dated_jsonl.Parsed (`Assoc [])
    ; Dated_jsonl.Parsed (heartbeat 2)
    ]
  in
  let snapshot =
    Tail.resolve_with ~expected_keeper:"keeper-main" ~limit:4
      ~read_recent:(fun limit ->
        seen_limit := Some limit;
        Ok rows)
  in
  check (option int) "physical limit forwarded" (Some 4) !seen_limit;
  check (list (option int)) "valid rows remain chronological"
    [ Some 1; Some 2 ] (message_counts snapshot.entries);
  match snapshot.error with
  | Some (Tail.Row_errors { physical_rows = 4; errors = [ first; second ] }) ->
      (match first, second with
       | ( Tail.Malformed_json _,
           Tail.Invalid_metrics_row { physical_index = 3; _ } ) ->
           ()
       | _ -> fail "row failures changed kind or chronological position")
  | Some (Tail.Row_errors { physical_rows; errors }) ->
      failf "unexpected row error summary: rows=%d errors=%d" physical_rows
        (List.length errors)
  | Some (Tail.Storage_error _) -> fail "row failures became a storage error"
  | None -> fail "row failures were silently discarded"

let test_storage_error_and_empty_selection_are_explicit () =
  let read_error =
    Dated_jsonl.Io_error
      { operation = Dated_jsonl.Read_file;
        path = "/tmp/metrics/2026-08/21.jsonl";
        detail = "injected read failure";
      }
  in
  let failed =
    Tail.resolve_with ~expected_keeper:"keeper-main" ~limit:200
      ~read_recent:(fun _ -> Error read_error)
  in
  check int "storage failure has no stale entries" 0
    (List.length failed.entries);
  (match failed.error with
   | Some
       (Tail.Storage_error
         (Dated_jsonl.Io_error
           { operation = Dated_jsonl.Read_file;
             path = "/tmp/metrics/2026-08/21.jsonl";
             detail = "injected read failure";
           })) ->
       ()
   | Some (Tail.Storage_error _) -> fail "wrong typed storage error"
   | Some (Tail.Row_errors _) | None -> fail "storage failure was flattened");
  let calls = ref 0 in
  let cleared =
    Tail.for_selection
      ~load:(fun _ ->
        incr calls;
        failed)
      None
  in
  check int "empty selection does not read storage" 0 !calls;
  check int "empty selection clears entries" 0 (List.length cleared.entries);
  check bool "empty selection clears error" true (Option.is_none cleared.error);
  let retained =
    Tail.reconcile_selection ~current:failed
      ~previous_keeper:(Some "keeper-a") ~selected_keeper:(Some "keeper-a")
  in
  check bool "metadata refresh retains same Keeper logs" true
    (Option.is_some retained.error);
  let cleared_after_replacement =
    Tail.reconcile_selection ~current:failed
      ~previous_keeper:(Some "keeper-a") ~selected_keeper:(Some "keeper-b")
  in
  check int "replacement Keeper clears entries" 0
    (List.length cleared_after_replacement.entries);
  check bool "replacement Keeper clears error" true
    (Option.is_none cleared_after_replacement.error);
  let cleared_after_empty_roster =
    Tail.reconcile_selection ~current:failed
      ~previous_keeper:(Some "keeper-a") ~selected_keeper:None
  in
  check int "empty refreshed roster clears entries" 0
    (List.length cleared_after_empty_roster.entries);
  check bool "empty refreshed roster clears error" true
    (Option.is_none cleared_after_empty_roster.error)

let test_diagnostic_controls_are_terminal_safe () =
  let unsafe_error =
    Tail.Storage_error
      (Dated_jsonl.Io_error
         { operation = Dated_jsonl.Read_file;
           path = "/tmp/metrics\nnext-row";
           detail = "failed\027]8;;https://example.invalid\007link";
         })
  in
  let safe =
    Tail.error_to_string unsafe_error |> Keeper_chat.terminal_safe_text
  in
  check bool "diagnostic removes newline" false (String.contains safe '\n');
  check bool "diagnostic removes escape" false (String.contains safe '\027');
  check bool "diagnostic removes bell" false (String.contains safe '\007')

let test_selected_keeper_rejects_misfiled_current_row () =
  let snapshot =
    Tail.resolve_with ~expected_keeper:"keeper-main" ~limit:1
      ~read_recent:(fun _ -> Ok [ Dated_jsonl.Parsed (heartbeat ~name:"keeper-other" 1) ])
  in
  check int "misfiled row is not rendered" 0 (List.length snapshot.entries);
  match snapshot.error with
  | Some
      (Tail.Row_errors
        { physical_rows = 1;
          errors = [ Tail.Invalid_metrics_row { physical_index = 1; detail } ];
        }) ->
      check bool "mismatch names selected Keeper" true
        (String.starts_with
           ~prefix:
             "metrics Keeper name \"keeper-other\" does not match selected Keeper \"keeper-main\""
           detail)
  | Some (Tail.Row_errors { physical_rows; errors }) ->
      failf "unexpected mismatch summary: rows=%d errors=%d" physical_rows
        (List.length errors)
  | Some (Tail.Storage_error _) | None -> fail "misfiled row was not rejected"

let test_scroll_and_empty_copy_follow_viewport_state () =
  let normal_height = Tail.content_height ~terminal_rows:24 ~error:None in
  check int "normal viewport content rows" 16 normal_height;
  check int "entry-index scroll normalizes to viewport" 184
    (Tail.normalize_scroll ~entry_count:200 ~content_height:normal_height 199);
  check int "up moves immediately after normalization" 183
    (Tail.scroll_up ~entry_count:200 ~content_height:normal_height 199);
  check int "down stops at the normal viewport end" 184
    (Tail.scroll_down ~entry_count:200 ~content_height:normal_height 184);
  let row_error =
    Tail.Row_errors
      { physical_rows = 1;
        errors =
          [ Tail.Invalid_metrics_row
              { physical_index = 1; detail = "invalid row" }
          ];
      }
  in
  let warning_height =
    Tail.content_height ~terminal_rows:24 ~error:(Some row_error)
  in
  check int "diagnostic banner reduces viewport" 14 warning_height;
  check int "down uses the warning viewport immediately" 185
    (Tail.scroll_down ~entry_count:200 ~content_height:warning_height 184);
  check int "removed warning clamps the prior offset" 184
    (Tail.normalize_scroll ~entry_count:200 ~content_height:normal_height 186);
  check string "true empty copy" "(no log entries found)"
    (Tail.empty_message None);
  check string "all-rejected copy"
    "(no valid rows in newest physical window)"
    (Tail.empty_message (Some row_error));
  let storage_error =
    Tail.Storage_error (Dated_jsonl.Not_a_directory { path = "/tmp/metrics" })
  in
  check string "storage failure copy" "(log entries unavailable)"
    (Tail.empty_message (Some storage_error))

let write_rows base_dir month filename rows ~terminate =
  let month_dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p month_dir;
  let content = String.concat "\n" (List.map Yojson.Safe.to_string rows) in
  let content = if terminate then content ^ "\n" else content in
  Fs_compat.append_file (Filename.concat month_dir filename) content

let write_raw_lines base_dir month filename lines =
  let month_dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p month_dir;
  Fs_compat.append_file (Filename.concat month_dir filename)
    (String.concat "\n" lines ^ "\n")

let test_load_does_not_backfill_rejected_rows () =
  let base_dir = tmpdir "tui_metrics_tail_physical_bound" in
  write_raw_lines base_dir "2026-01" "31.jsonl"
    [ Yojson.Safe.to_string (heartbeat 0)
    ; Yojson.Safe.to_string (heartbeat 1)
    ; "{}"
    ; "not-json"
    ; Yojson.Safe.to_string (heartbeat 2)
    ];
  let snapshot =
    Dated_jsonl.create ~base_dir ()
    |> fun store ->
    Tail.load ~store ~expected_keeper:"keeper-main" ~limit:4
  in
  check (list (option int)) "older row is not used to backfill rejects"
    [ Some 1; Some 2 ] (message_counts snapshot.entries);
  match snapshot.error with
  | Some (Tail.Row_errors { physical_rows = 4; errors = [ first; second ] }) ->
      (match first, second with
       | ( Tail.Invalid_metrics_row { physical_index = 2; _ },
           Tail.Malformed_json _ ) ->
           ()
       | _ -> fail "physical row failure positions changed")
  | Some (Tail.Row_errors { physical_rows; errors }) ->
      failf "unexpected physical window: rows=%d errors=%d" physical_rows
        (List.length errors)
  | Some (Tail.Storage_error _) | None -> fail "physical row errors were hidden"

let test_load_surfaces_malformed_newest_without_backfill () =
  let base_dir = tmpdir "tui_metrics_tail_malformed_newest" in
  write_raw_lines base_dir "2026-01" "31.jsonl"
    [ Yojson.Safe.to_string (heartbeat 1); "not-json" ];
  let snapshot =
    Dated_jsonl.create ~base_dir ()
    |> fun store ->
    Tail.load ~store ~expected_keeper:"keeper-main" ~limit:1
  in
  check int "malformed newest row does not backfill" 0
    (List.length snapshot.entries);
  match snapshot.error with
  | Some
      (Tail.Row_errors
        { physical_rows = 1; errors = [ Tail.Malformed_json _ ] }) ->
      ()
  | Some (Tail.Row_errors { physical_rows; errors }) ->
      failf "unexpected malformed window: rows=%d errors=%d" physical_rows
        (List.length errors)
  | Some (Tail.Storage_error _) | None -> fail "malformed newest row was hidden"

let test_load_spans_months_and_rotations () =
  let base_dir = tmpdir "tui_metrics_tail_order" in
  write_rows base_dir "2026-01" "31.jsonl" [ heartbeat 1; heartbeat 2 ]
    ~terminate:true;
  write_rows base_dir "2026-02" "01.001.jsonl" [ heartbeat 3 ]
    ~terminate:true;
  write_rows base_dir "2026-02" "01.002.jsonl" [ heartbeat 4 ]
    ~terminate:true;
  write_rows base_dir "2026-02" "01.jsonl" [ heartbeat 5; heartbeat 6 ]
    ~terminate:true;
  let store = Dated_jsonl.create ~base_dir () in
  let snapshot =
    Tail.load ~store ~expected_keeper:"keeper-main" ~limit:5
  in
  check (list (option int)) "newest physical rows are chronological"
    [ Some 2; Some 3; Some 4; Some 5; Some 6 ]
    (message_counts snapshot.entries);
  check bool "valid rotated tail has no error" true (Option.is_none snapshot.error)

let test_load_keeps_unterminated_newest_row () =
  let base_dir = tmpdir "tui_metrics_tail_unterminated" in
  write_rows base_dir "2026-02" "02.jsonl" [ heartbeat 8; heartbeat 9 ]
    ~terminate:false;
  let snapshot =
    Dated_jsonl.create ~base_dir ()
    |> fun store ->
    Tail.load ~store ~expected_keeper:"keeper-main" ~limit:1
  in
  check (list (option int)) "unterminated newest row remains visible"
    [ Some 9 ] (message_counts snapshot.entries);
  check bool "unterminated valid row has no error" true
    (Option.is_none snapshot.error)

let test_load_surfaces_invalid_layout () =
  let base_dir = tmpdir "tui_metrics_tail_invalid_layout" in
  Fs_compat.mkdir_p (Filename.concat base_dir "2026-aa");
  let snapshot =
    Dated_jsonl.create ~base_dir ()
    |> fun store ->
    Tail.load ~store ~expected_keeper:"keeper-main" ~limit:1
  in
  check int "invalid layout has no entries" 0 (List.length snapshot.entries);
  match snapshot.error with
  | Some
      (Tail.Storage_error
        (Dated_jsonl.Invalid_layout_entry
          { expected = Dated_jsonl.Month_directory; _ })) ->
      ()
  | Some (Tail.Storage_error error) ->
      failf "unexpected storage error: %s"
        (Dated_jsonl.read_error_to_string error)
  | Some (Tail.Row_errors _) | None -> fail "invalid layout was hidden"

let test_load_is_bounded_by_tail_not_file_size () =
  let base_dir = tmpdir "tui_metrics_tail_sparse" in
  let month_dir = Filename.concat base_dir "2026-02" in
  Fs_compat.mkdir_p month_dir;
  let path = Filename.concat month_dir "03.jsonl" in
  let descriptor =
    Unix.openfile path [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
  in
  let sparse_prefix_bytes = 64 * 1024 * 1024 in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
      Unix.ftruncate descriptor sparse_prefix_bytes;
      ignore (Unix.lseek descriptor sparse_prefix_bytes Unix.SEEK_SET);
      let suffix = "\n" ^ Yojson.Safe.to_string (heartbeat 10) ^ "\n" in
      ignore
        (Unix.write_substring descriptor suffix 0 (String.length suffix)));
  Gc.full_major ();
  let allocated_before = Gc.allocated_bytes () in
  let snapshot =
    Dated_jsonl.create ~base_dir ()
    |> fun store ->
    Tail.load ~store ~expected_keeper:"keeper-main" ~limit:1
  in
  let allocated = Gc.allocated_bytes () -. allocated_before in
  check (list (option int)) "sparse newest row is decoded" [ Some 10 ]
    (message_counts snapshot.entries);
  check bool "tail allocation stays below a whole-file read" true
    (allocated < Float.of_int (4 * 1024 * 1024))

let () =
  run "tui_metrics_tail"
    [ ( "strict tail"
      , [ test_case "physical bound and chronology" `Quick
            test_resolve_is_physical_bounded_and_chronological
        ; test_case "storage and empty selection" `Quick
            test_storage_error_and_empty_selection_are_explicit
        ; test_case "diagnostic control safety" `Quick
            test_diagnostic_controls_are_terminal_safe
        ; test_case "selected Keeper rejects misfiled row" `Quick
            test_selected_keeper_rejects_misfiled_current_row
        ; test_case "viewport scroll and empty copy" `Quick
            test_scroll_and_empty_copy_follow_viewport_state
        ; test_case "rejected rows are not backfilled" `Quick
            test_load_does_not_backfill_rejected_rows
        ; test_case "malformed newest row is explicit" `Quick
            test_load_surfaces_malformed_newest_without_backfill
        ; test_case "cross-month rotation order" `Quick
            test_load_spans_months_and_rotations
        ; test_case "unterminated newest row" `Quick
            test_load_keeps_unterminated_newest_row
        ; test_case "invalid layout" `Quick test_load_surfaces_invalid_layout
        ; test_case "large sparse prefix is bounded" `Quick
            test_load_is_bounded_by_tail_not_file_size
        ] )
    ]
