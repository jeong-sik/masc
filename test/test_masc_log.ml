let find_entry ~module_name ~message =
  Log.Ring.recent ~limit:50 ~module_filter:module_name ()
  |> List.find_opt (fun (entry : Log.Ring.entry) -> String.equal entry.message message)

let latest_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let test_legacy_traceln_records_metadata () =
  let module_name = "TestLogLegacy" in
  let message =
    Printf.sprintf "[WARN] legacy warning %f" (Unix.gettimeofday ())
  in
  Log.legacy_traceln ~level:Log.Warn ~module_name message;
  match find_entry ~module_name ~message with
  | None -> Alcotest.fail "legacy traceln entry not found"
  | Some (entry : Log.Ring.entry) ->
      Alcotest.(check string)
        "source" "legacy_traceln"
        (Log.source_to_string entry.source);
      Alcotest.(check string)
        "level" "WARN"
        (Log.level_to_string entry.level)

let test_recent_since_seq_returns_only_new_entries () =
  let module_name = "TestLogDelta" in
  let baseline = latest_seq () in
  let info_message =
    Printf.sprintf "delta info %f" (Unix.gettimeofday ())
  in
  let warn_message =
    Printf.sprintf "delta warn %f" (Unix.gettimeofday ())
  in
  Log.info ~ctx:module_name "%s" info_message;
  Log.warn ~ctx:module_name "%s" warn_message;
  let entries =
    Log.Ring.recent ~limit:10 ~module_filter:module_name ~since_seq:baseline ()
  in
  Alcotest.(check (list string)) "delta messages"
    [ warn_message; info_message ]
    (List.map (fun (entry : Log.Ring.entry) -> entry.message) entries)

let test_recent_before_seq_returns_only_older_entries () =
  (* Backward "load older" paging: [before_seq] must return entries strictly
     older than the cursor, newest-first, respecting [limit], and compose with
     [since_seq] into a bounded window. *)
  let module_name = "TestLogBefore" in
  let baseline = latest_seq () in
  let messages =
    List.init 3 (fun i ->
      Printf.sprintf "before page msg %d %f" i (Unix.gettimeofday ()))
  in
  List.iter (fun m -> Log.info ~ctx:module_name "%s" m) messages;
  (* Newest-first within this module: [m2; m1; m0]. *)
  let scoped () =
    Log.Ring.recent ~limit:10 ~module_filter:module_name ~since_seq:baseline ()
  in
  let seqs =
    List.map (fun (entry : Log.Ring.entry) -> entry.seq, entry.message) (scoped ())
  in
  let seq_of message =
    match List.find_opt (fun (_, m) -> String.equal m message) seqs with
    | Some (seq, _) -> seq
    | None -> Alcotest.fail (Printf.sprintf "seq not found for %s" message)
  in
  let m0 = List.nth messages 0 in
  let m1 = List.nth messages 1 in
  let m2 = List.nth messages 2 in
  let names entries =
    List.map (fun (entry : Log.Ring.entry) -> entry.message) entries
  in
  (* Strictly older than m2 → m1, m0 (newest-first). *)
  Alcotest.(check (list string)) "before_seq excludes the cursor entry"
    [ m1; m0 ]
    (names
       (Log.Ring.recent ~limit:10 ~module_filter:module_name
          ~before_seq:(seq_of m2) ()));
  (* limit caps the page, keeping the newest of the older slice. *)
  Alcotest.(check (list string)) "before_seq respects limit"
    [ m1 ]
    (names
       (Log.Ring.recent ~limit:1 ~module_filter:module_name
          ~before_seq:(seq_of m2) ()));
  (* since_seq lower bound + before_seq upper bound → bounded window {m1}. *)
  Alcotest.(check (list string)) "before_seq composes with since_seq"
    [ m1 ]
    (names
       (Log.Ring.recent ~limit:10 ~module_filter:module_name
          ~since_seq:(seq_of m0) ~before_seq:(seq_of m2) ()))

let test_entry_to_json_keeper_name_none_serializes_system () =
  (* #18465: keeper_name=None must serialize as "system", not null *)
  let entry : Log.Ring.entry = {
    seq = 1;
    ts = "2026-05-26T00:00:00Z";
    level = Log.Info;
    source = Log.Structured;
    module_name = "test";
    keeper_name = None;
    turn_id = None;
    message = "test message";
    details = `Null;
    category = None;
  } in
  let json = Log.Ring.entry_to_json entry in
  let keeper_name_val =
    Yojson.Safe.Util.member "keeper_name" json
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "keeper_name None → \"system\"" "system" keeper_name_val

let test_entry_to_json_keeper_name_some_preserves () =
  let entry : Log.Ring.entry = {
    seq = 2;
    ts = "2026-05-26T00:00:00Z";
    level = Log.Info;
    source = Log.Structured;
    module_name = "test";
    keeper_name = Some "my-keeper";
    turn_id = None;
    message = "test message";
    details = `Null;
    category = None;
  } in
  let json = Log.Ring.entry_to_json entry in
  let keeper_name_val =
    Yojson.Safe.Util.member "keeper_name" json
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check string) "keeper_name Some preserved" "my-keeper" keeper_name_val

let () =
  Alcotest.run "Masc_log" [
    ( "ring",
      [
        Alcotest.test_case "legacy traceln records metadata" `Quick
          test_legacy_traceln_records_metadata;
        Alcotest.test_case "recent since_seq returns only new entries" `Quick
          test_recent_since_seq_returns_only_new_entries;
        Alcotest.test_case "recent before_seq returns only older entries" `Quick
          test_recent_before_seq_returns_only_older_entries;
        Alcotest.test_case
          "entry_to_json: keeper_name=None serializes as \"system\" (#18465)"
          `Quick test_entry_to_json_keeper_name_none_serializes_system;
        Alcotest.test_case
          "entry_to_json: keeper_name=Some preserves value"
          `Quick test_entry_to_json_keeper_name_some_preserves;
      ] );
  ]
