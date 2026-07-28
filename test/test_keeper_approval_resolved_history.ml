(** Resolved Gate history: the wall-clock window, the row cap, and the counts
    that keep either bound from truncating silently.

    Before this suite the history was a fixed slice of the newest 1280 physical
    audit rows. Because the store interleaves [resolved] rows with far more
    numerous [summary_updated] rows, the number of decisions that survived that
    slice fell as non-resolved traffic grew, and nothing in the payload said
    so. The tests below pin both bounds and the reporting. *)

open Alcotest

module AQ = Masc.Keeper_approval_queue

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_approval_resolved_history_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let rec cleanup_dir path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> cleanup_dir (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

(* Day file for [ts] computed independently of the module under test, mirroring
   the write path ([Jsonl_writer.dated_path], UTC). Seeding through this rather
   than through [AQ.audit_day_string_of_ts] keeps the reader honest: a reader
   that switched to local time would stop finding rows the writer placed here. *)
let audit_day_file ~base_path ts =
  let tm = Unix.gmtime ts in
  let month = Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) in
  let dir =
    Filename.concat (Filename.concat base_path ".masc") "audit-approvals"
    |> fun d -> Filename.concat d month
  in
  mkdir_p dir;
  Filename.concat dir (Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday)
;;

let append_row ~base_path ~ts (row : Yojson.Safe.t) =
  let path = audit_day_file ~base_path ts in
  let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc (Yojson.Safe.to_string row ^ "\n"))
;;

(* A resolved decision as the audit writer records it. [?ts_field:false] drops
   the timestamp to exercise the undated-row boundary. *)
let seed_resolved ~base_path ~ts ~id ?(keeper = "rondo") ?(tool = "tool_execute")
      ?(decision = "approve") ?(source = "auto_judge") ?(ts_field = true) ()
  =
  let fields =
    [ "event", `String "resolved"
    ; "id", `String id
    ; "keeper", `String keeper
    ; "tool", `String tool
    ; "decision", `String decision
    ; "decision_source", `String source
    ]
  in
  let fields = if ts_field then ("ts", `Float ts) :: fields else fields in
  append_row ~base_path ~ts (`Assoc fields)
;;

(* Bulk [summary_updated] rows, written through one handle so a test can afford
   thousands of them. These are the rows that used to crowd decisions out of a
   row-counted scan. *)
let seed_noise ~base_path ~ts ~count =
  let path = audit_day_file ~base_path ts in
  let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      for i = 1 to count do
        let row : Yojson.Safe.t =
          `Assoc
            [ "event", `String "summary_updated"
            ; "id", `String (Printf.sprintf "noise_%d" i)
            ; "ts", `Float ts
            ; "keeper", `String "rondo"
            ]
        in
        output_string oc (Yojson.Safe.to_string row ^ "\n")
      done)
;;

let with_store f () =
  let base_path = temp_dir () in
  AQ.For_testing.reset_audit_store ();
  Fun.protect
    ~finally:(fun () ->
      AQ.For_testing.reset_audit_store ();
      cleanup_dir base_path)
    (fun () -> f base_path)
;;

let ids (history : AQ.resolved_history) =
  List.map
    (fun row ->
      match row with
      | `Assoc fields ->
        (match List.assoc_opt "id" fields with
         | Some (`String id) -> id
         | _ -> "<no-id>")
      | _ -> "<not-an-object>")
    history.resolved_rows
;;

let minutes n = float_of_int n *. 60.0

(* Fixed clock: 2026-07-28T03:00:00Z. The function under test takes [now_ts]
   instead of reading the clock, so every window boundary below is exact rather
   than relative to whenever the suite happens to run. *)
let now = 1785207600.0

(* The day key follows the audit file layout, which is UTC. 2026-07-27T23:30Z
   is already 2026-07-28 in KST; a local-time key would name the wrong file for
   every such hour. *)
let test_day_key_is_utc () =
  check string "23:30Z stays on the UTC day" "2026-07-27"
    (AQ.audit_day_string_of_ts 1785195000.0);
  check string "00:30Z is the next UTC day" "2026-07-28"
    (AQ.audit_day_string_of_ts 1785198600.0)
;;

(* Seeded newest-first on purpose: file position must not decide the order. The
   audit writer stamps [ts] before it takes the append lock, so concurrent
   resolutions can land out of stamp order. *)
let test_window_excludes_older_decisions base_path =
  seed_resolved ~base_path ~ts:(now -. minutes 10) ~id:"recent" ();
  seed_resolved ~base_path ~ts:(now -. minutes 120) ~id:"two_hours" ();
  seed_resolved ~base_path ~ts:(now -. minutes 1800) ~id:"thirty_hours" ();
  let hour = AQ.list_recent_resolved ~base_path ~now_ts:now ~window_minutes:60 () in
  check (list string) "60m window keeps only the recent decision" [ "recent" ] (ids hour);
  check int "60m matched" 1 hour.resolved_matched;
  let day = AQ.list_recent_resolved ~base_path ~now_ts:now ~window_minutes:1440 () in
  check (list string) "24h window, newest first" [ "recent"; "two_hours" ] (ids day);
  let week = AQ.list_recent_resolved ~base_path ~now_ts:now ~window_minutes:10_080 () in
  check int "7d window reaches all three" 3 week.resolved_matched
;;

(* The regression this suite exists for. The decisions are the OLDEST rows and
   are then buried under 1500 [summary_updated] rows — past the 1280-row slice
   the previous implementation used, so that implementation returned neither
   decision while reporting nothing unusual. The count is chosen to exceed the
   old bound and stay inside the current one. *)
let test_noise_does_not_consume_the_page base_path =
  seed_resolved ~base_path ~ts:(now -. minutes 40) ~id:"decision_a" ();
  seed_resolved ~base_path ~ts:(now -. minutes 30) ~id:"decision_b" ();
  seed_noise ~base_path ~ts:(now -. minutes 20) ~count:1500;
  let history = AQ.list_recent_resolved ~base_path ~now_ts:now ~window_minutes:1440 () in
  check (list string) "both decisions survive 1500 buried noise rows"
    [ "decision_b"; "decision_a" ] (ids history);
  check int "matched counts decisions, not rows" 2 history.resolved_matched;
  check bool "not truncated" false
    (history.resolved_matched > history.resolved_limit);
  check bool "window was fully covered" false history.resolved_scan_exhausted
;;

(* The second bound must report itself. Past the row cap the scan cannot prove
   it reached the window start, so it says so instead of presenting a partial
   page as the whole window. *)
let test_row_cap_reports_itself base_path =
  seed_resolved ~base_path ~ts:(now -. minutes 30) ~id:"decision" ();
  seed_noise ~base_path ~ts:(now -. minutes 20) ~count:2500;
  let history = AQ.list_recent_resolved ~base_path ~now_ts:now ~window_minutes:1440 () in
  check bool "row cap is reported, not hidden" true history.resolved_scan_exhausted
;;

let test_limit_caps_rows_and_matched_reports_the_rest base_path =
  for i = 1 to 30 do
    seed_resolved
      ~base_path
      ~ts:(now -. minutes (60 - i))
      ~id:(Printf.sprintf "d%02d" i)
      ()
  done;
  let history = AQ.list_recent_resolved ~base_path ~now_ts:now ~limit:10 ~window_minutes:1440 () in
  check int "returned is capped" 10 (List.length history.resolved_rows);
  check int "matched sees the whole window" 30 history.resolved_matched;
  check int "limit is echoed" 10 history.resolved_limit;
  check bool "page reports truncation" true
    (history.resolved_matched > history.resolved_limit);
  check string "newest first" "d30" (List.hd (ids history))
;;

let test_limit_zero_returns_empty_page base_path =
  seed_resolved ~base_path ~ts:(now -. minutes 5) ~id:"only" ();
  let history = AQ.list_recent_resolved ~base_path ~now_ts:now ~limit:0 () in
  check (list string) "no rows" [] (ids history);
  check int "matched not claimed" 0 history.resolved_matched;
  check bool "scan not claimed exhausted" false history.resolved_scan_exhausted
;;

(* An undated decision cannot be placed in a wall-clock window. It is excluded
   rather than dated by guesswork, and it must not inflate [matched] either. *)
let test_undated_decision_is_excluded base_path =
  seed_resolved ~base_path ~ts:(now -. minutes 5) ~id:"dated" ();
  seed_resolved ~base_path ~ts:(now -. minutes 5) ~id:"undated" ~ts_field:false ();
  let history = AQ.list_recent_resolved ~base_path ~now_ts:now ~window_minutes:1440 () in
  check (list string) "only the dated decision" [ "dated" ] (ids history);
  check int "matched excludes the undated row" 1 history.resolved_matched
;;

let test_empty_store_is_an_empty_page base_path =
  let history = AQ.list_recent_resolved ~base_path ~now_ts:now () in
  check (list string) "no rows" [] (ids history);
  check int "matched" 0 history.resolved_matched;
  check int "default window is echoed" AQ.recent_resolved_default_window_minutes
    history.resolved_window_minutes;
  check bool "scan not exhausted" false history.resolved_scan_exhausted
;;

let test_bounds_are_clamped base_path =
  let over = AQ.list_recent_resolved ~base_path ~now_ts:now ~limit:100_000 ~window_minutes:999_999 () in
  check int "limit clamped to the max" AQ.recent_resolved_max_limit over.resolved_limit;
  check int "window clamped to the max" AQ.recent_resolved_max_window_minutes
    over.resolved_window_minutes;
  let under = AQ.list_recent_resolved ~base_path ~now_ts:now ~limit:5 ~window_minutes:0 () in
  check int "window clamped to the min" AQ.recent_resolved_min_window_minutes
    under.resolved_window_minutes;
  check int "a limit inside the range is kept" 5 under.resolved_limit
;;

let () =
  run
    "keeper_approval_resolved_history"
    [ ( "day_key"
      , [ test_case "audit day key is UTC" `Quick test_day_key_is_utc ] )
    ; ( "window"
      , [ test_case "older decisions fall outside the window" `Quick
            (with_store test_window_excludes_older_decisions)
        ; test_case "non-resolved rows do not consume the page" `Quick
            (with_store test_noise_does_not_consume_the_page)
        ; test_case "row cap reports itself" `Quick
            (with_store test_row_cap_reports_itself)
        ] )
    ; ( "bounds"
      , [ test_case "limit caps rows and matched reports the rest" `Quick
            (with_store test_limit_caps_rows_and_matched_reports_the_rest)
        ; test_case "limit zero yields an empty page" `Quick
            (with_store test_limit_zero_returns_empty_page)
        ; test_case "limit and window are clamped" `Quick
            (with_store test_bounds_are_clamped)
        ] )
    ; ( "boundaries"
      , [ test_case "undated decision is excluded" `Quick
            (with_store test_undated_decision_is_excluded)
        ; test_case "empty store is an empty page" `Quick
            (with_store test_empty_store_is_an_empty_page)
        ] )
    ]
;;
