(** Unit tests for lib/runtime_store.ml.

    Targets 106 uncovered lines (55.08% coverage).
    Uses temp directories for filesystem operations.

    Functions tested:
    - save_text / load_text: roundtrip
    - ensure_dir: nested creation, idempotency
    - save_session / load_session: JSON roundtrip with normalization
    - append_event / read_events: JSONL append and seq filtering
    - snapshot_path: path generation with label sanitization
    - save_artifact_text: artifact file creation *)

open Agent_sdk

(* ── Temp dir helper ─────────────────────────────────────────── *)

let with_temp_dir f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oas-test-%d-%06x" (Unix.getpid ()) (Random.int 0xFFFFFF))
  in
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" dir)))
    (fun () -> f dir)
;;

(* ── save_text / load_text tests ─────────────────────────────── *)

let test_save_load_roundtrip () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "test.txt" in
    let content = "hello world\nline 2" in
    (match Runtime_store.save_text path content with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    match Runtime_store.load_text path with
    | Ok loaded -> Alcotest.(check string) "roundtrip" content loaded
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_save_load_empty () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "empty.txt" in
    (match Runtime_store.save_text path "" with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    match Runtime_store.load_text path with
    | Ok loaded -> Alcotest.(check string) "empty" "" loaded
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_save_load_unicode () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "unicode.txt" in
    let content =
      "Korean: \xed\x95\x9c\xea\xb5\xad\xec\x96\xb4 Emoji: \xf0\x9f\x92\xbb"
    in
    (match Runtime_store.save_text path content with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    match Runtime_store.load_text path with
    | Ok loaded -> Alcotest.(check string) "unicode roundtrip" content loaded
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_load_missing_file () =
  with_temp_dir (fun dir ->
    let path = Filename.concat dir "nonexistent.txt" in
    match Runtime_store.load_text path with
    | Ok _ -> Alcotest.fail "expected error"
    | Error _ -> ())
;;

(* ── ensure_dir tests ────────────────────────────────────────── *)

let test_ensure_dir_creates () =
  with_temp_dir (fun dir ->
    let sub = Filename.concat dir "new_sub" in
    (match Runtime_store.ensure_dir sub with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    Alcotest.(check bool) "dir exists" true (Sys.file_exists sub))
;;

let test_ensure_dir_idempotent () =
  with_temp_dir (fun dir ->
    let sub = Filename.concat dir "idem" in
    (match Runtime_store.ensure_dir sub with
     | Ok () -> ()
     | Error e -> Alcotest.fail (Error.to_string e));
    (* Call again -- should not fail *)
    match Runtime_store.ensure_dir sub with
    | Ok () -> ()
    | Error e -> Alcotest.fail (Error.to_string e))
;;

(* ── Runtime_store.create tests ──────────────────────────────── *)

let test_store_create () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Ok store ->
      ignore store;
      Alcotest.(check bool) "root exists" true (Sys.file_exists root);
      Alcotest.(check bool)
        "sessions dir exists"
        true
        (Sys.file_exists (Filename.concat root "sessions"))
    | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_store_create_requires_explicit_root () =
  match Runtime_store.create () with
  | Ok _ -> Alcotest.fail "expected missing session_root error"
  | Error (Error.Config (InvalidConfig { field = "session_root"; detail })) ->
    Alcotest.(check string)
      "detail"
      "missing runtime session root; pass an explicit ~root/session_root"
      detail
  | Error e -> Alcotest.failf "unexpected error: %s" (Error.to_string e)
;;

let test_store_create_rejects_relative_root () =
  match Runtime_store.create ~root:"relative/.oas-runtime" () with
  | Ok _ -> Alcotest.fail "expected relative session_root rejection"
  | Error (Error.Config (InvalidConfig { field = "session_root"; detail })) ->
    Alcotest.(check string)
      "detail"
      "runtime session root must be an absolute path"
      detail
  | Error e -> Alcotest.failf "unexpected error: %s" (Error.to_string e)
;;

(* ── save_session / load_session tests ───────────────────────── *)

let mk_session ?(session_id = "test-sess") ?(updated_at = 1001.0) () : Runtime.session =
  { session_id
  ; goal = "test goal"
  ; title = None
  ; tag = None
  ; phase = Running
  ; created_at = 1000.0
  ; updated_at
  ; provider = Some "anthropic"
  ; model = Some "test-model"
  ; system_prompt = None
  ; workdir = None
  ; planned_participants = [ "agent-1" ]
  ; participants = []
  ; artifacts = []
  ; pending_input = None
  ; turn_count = 0
  ; last_seq = 0
  ; outcome = None
  }
;;

let test_save_load_session () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      let session = mk_session () in
      (match Runtime_store.save_session store session with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Error.to_string e));
      (match Runtime_store.load_session store "test-sess" with
       | Ok loaded ->
         Alcotest.(check string) "session_id" "test-sess" loaded.session_id;
         Alcotest.(check string) "goal" "test goal" loaded.goal
       | Error e -> Alcotest.fail (Error.to_string e)))
;;

let test_load_session_missing () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      (match Runtime_store.load_session store "nonexistent" with
       | Ok _ -> Alcotest.fail "expected error"
       | Error _ -> ()))
;;

let test_load_session_corrupt () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      (* Write corrupt JSON to session file *)
      let sess_dir = Filename.concat (Filename.concat root "sessions") "bad-sess" in
      Unix.mkdir sess_dir 0o755;
      let path = Filename.concat sess_dir "session.json" in
      let oc = open_out path in
      output_string oc "not valid json!!!";
      close_out oc;
      (match Runtime_store.load_session store "bad-sess" with
       | Ok _ -> Alcotest.fail "expected parse error"
       | Error _ -> ()))
;;

let mk_event seq =
  { Runtime.seq
  ; ts = float_of_int seq
  ; kind = Turn_recorded { actor = Some "agent"; message = Printf.sprintf "turn %d" seq }
  }
;;

let save_run store session_id updated_at =
  let session = mk_session ~session_id ~updated_at () in
  match Runtime_store.save_session store session with
  | Ok () -> session
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let corrupt_run store session_id =
  let sess_dir = Runtime_store.session_dir store session_id in
  (match Runtime_store.ensure_dir sess_dir with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Error.to_string e));
  let oc = open_out (Runtime_store.session_path store session_id) in
  output_string oc "{not-json";
  close_out oc
;;

let test_list_runs_stable_updated_at_order () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      ignore (save_run store "run-c" 30.0);
      ignore (save_run store "run-a" 10.0);
      ignore (save_run store "run-b" 20.0);
      (match Runtime_store.list_runs store with
       | Error e -> Alcotest.fail (Error.to_string e)
       | Ok listing ->
         Alcotest.(check (list string))
           "updated_at ordering"
           [ "run-a"; "run-b"; "run-c" ]
           (List.map
              (fun (run : Runtime_store.run_record) -> run.session.session_id)
              listing.runs);
         Alcotest.(check int) "no failures" 0 (List.length listing.failures)))
;;

let test_list_runs_reports_corrupt_without_dropping_valid_runs () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      ignore (save_run store "run-ok" 10.0);
      corrupt_run store "run-bad";
      (match Runtime_store.list_runs store with
       | Error e -> Alcotest.fail (Error.to_string e)
       | Ok listing ->
         Alcotest.(check (list string))
           "valid runs"
           [ "run-ok" ]
           (List.map
              (fun (run : Runtime_store.run_record) -> run.session.session_id)
              listing.runs);
         Alcotest.(check int) "one partial failure" 1 (List.length listing.failures);
         (match listing.failures with
          | [ failure ] ->
            Alcotest.(check string) "failure session" "run-bad" failure.session_id
          | _ -> Alcotest.fail "expected one failure")))
;;

let test_select_run_windows_variants () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      ignore (save_run store "run-a" 10.0);
      ignore (save_run store "run-b" 20.0);
      ignore (save_run store "run-c" 30.0);
      let ids (listing : Runtime_store.run_listing) =
        List.map
          (fun (run : Runtime_store.run_record) -> run.session.session_id)
          listing.Runtime_store.runs
      in
      (match Runtime_store.select_run_windows store [ Runtime_store.Last_n_runs 2 ] with
       | Ok listing ->
         Alcotest.(check (list string)) "last n" [ "run-b"; "run-c" ] (ids listing)
       | Error e -> Alcotest.fail (Error.to_string e));
      (match Runtime_store.select_run_windows store [ Runtime_store.Session "run-a" ] with
       | Ok listing -> Alcotest.(check (list string)) "session" [ "run-a" ] (ids listing)
       | Error e -> Alcotest.fail (Error.to_string e));
      (match
         Runtime_store.select_run_windows store [ Runtime_store.Rolling_seconds 15.0 ]
       with
       | Ok listing ->
         Alcotest.(check (list string))
           "rolling seconds"
           [ "run-b"; "run-c" ]
           (ids listing)
       | Error e -> Alcotest.fail (Error.to_string e)))
;;

let test_select_run_windows_corrupt_session_is_single_partial_failure () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      ignore (save_run store "run-ok" 10.0);
      corrupt_run store "run-bad";
      (match
         Runtime_store.select_run_windows store [ Runtime_store.Session "run-bad" ]
       with
       | Error e -> Alcotest.fail (Error.to_string e)
       | Ok listing ->
         Alcotest.(check int) "no selected corrupt run" 0 (List.length listing.runs);
         Alcotest.(check int) "single failure" 1 (List.length listing.failures);
         (match listing.failures with
          | [ failure ] ->
            Alcotest.(check string) "failure session" "run-bad" failure.session_id
          | _ -> Alcotest.fail "expected one failure")))
;;

let test_read_window_events_dedupes_overlapping_windows () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      ignore (save_run store "run-a" 10.0);
      ignore (save_run store "run-b" 20.0);
      let append session_id seq =
        match Runtime_store.append_event store session_id (mk_event seq) with
        | Ok () -> ()
        | Error e -> Alcotest.fail (Error.to_string e)
      in
      append "run-a" 1;
      append "run-b" 1;
      append "run-b" 2;
      (match
         Runtime_store.read_window_events
           store
           [ Runtime_store.Last_n_runs 2
           ; Runtime_store.Session "run-b"
           ; Runtime_store.Rolling_seconds 5.0
           ]
       with
       | Error e -> Alcotest.fail (Error.to_string e)
       | Ok window ->
         let event_ids =
           List.map
             (fun (record : Runtime_store.run_event_record) -> record.event_id)
             window.events
         in
         let unique_ids = List.sort_uniq String.compare event_ids in
         Alcotest.(check (list string))
           "event order"
           [ "run-a#1"; "run-b#1"; "run-b#2" ]
           event_ids;
         Alcotest.(check int)
           "0 duplicate event ids"
           (List.length event_ids)
           (List.length unique_ids);
         Alcotest.(check int) "no failures" 0 (List.length window.failures)))
;;

(* ── append_event / read_events tests ────────────────────────── *)

let test_append_and_read_events () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      let sid = "event-test" in
      let e1 = mk_event 1 in
      let e2 = mk_event 2 in
      let e3 = mk_event 3 in
      (match Runtime_store.append_event store sid e1 with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Error.to_string e));
      (match Runtime_store.append_event store sid e2 with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Error.to_string e));
      (match Runtime_store.append_event store sid e3 with
       | Ok () -> ()
       | Error e -> Alcotest.fail (Error.to_string e));
      (match Runtime_store.read_events store sid () with
       | Error e -> Alcotest.fail (Error.to_string e)
       | Ok events -> Alcotest.(check int) "3 events" 3 (List.length events)))
;;

let test_read_events_with_filter () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      let sid = "filter-test" in
      for i = 1 to 5 do
        match Runtime_store.append_event store sid (mk_event i) with
        | Ok () -> ()
        | Error e -> Alcotest.fail (Error.to_string e)
      done;
      (match Runtime_store.read_events store sid ~after_seq:3 () with
       | Error e -> Alcotest.fail (Error.to_string e)
       | Ok events ->
         Alcotest.(check int) "2 events after seq 3" 2 (List.length events);
         List.iter
           (fun (ev : Runtime.event) -> Alcotest.(check bool) "seq > 3" true (ev.seq > 3))
           events))
;;

let test_read_events_no_file () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      (match Runtime_store.read_events store "no-such-session" () with
       | Ok events -> Alcotest.(check int) "empty" 0 (List.length events)
       | Error e -> Alcotest.fail (Error.to_string e)))
;;

(* ── snapshot_path tests ─────────────────────────────────────── *)

let test_snapshot_path_with_label () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      let path = Runtime_store.snapshot_path store "s1" ~seq:5 ~label:(Some "my label") in
      (* Should contain sanitized label: spaces -> _ *)
      Alcotest.(check bool) "has seq" true (String.length (Filename.basename path) > 0);
      let base = Filename.basename path in
      Alcotest.(check bool)
        "contains 0005"
        true
        (String.length base >= 4 && String.sub base 0 4 = "0005");
      Alcotest.(check bool) "no spaces" true (not (String.contains base ' ')))
;;

let test_snapshot_path_no_label () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      let path = Runtime_store.snapshot_path store "s1" ~seq:1 ~label:None in
      let base = Filename.basename path in
      Alcotest.(check string) "just seq" "0001.json" base)
;;

let test_snapshot_path_slash_in_label () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      let path = Runtime_store.snapshot_path store "s1" ~seq:2 ~label:(Some "a/b") in
      let base = Filename.basename path in
      (* Slash should be sanitized to _ *)
      Alcotest.(check bool) "no slash in basename" true (not (String.contains base '/')))
;;

(* ── save_artifact_text tests ────────────────────────────────── *)

let test_save_artifact_text () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      (match
         Runtime_store.save_artifact_text
           store
           "art-sess"
           ~name:"report"
           ~kind:"markdown"
           ~content:"# Title"
       with
       | Ok path ->
         Alcotest.(check bool)
           "path ends with .md"
           true
           (Filename.check_suffix path ".md");
         (match Runtime_store.load_text path with
          | Ok loaded -> Alcotest.(check string) "content" "# Title" loaded
          | Error e -> Alcotest.fail (Error.to_string e))
       | Error e -> Alcotest.fail (Error.to_string e)))
;;

let test_save_artifact_text_empty_name () =
  with_temp_dir (fun dir ->
    let root = Filename.concat dir "store" in
    match Runtime_store.create ~root () with
    | Error e -> Alcotest.fail (Error.to_string e)
    | Ok store ->
      (match
         Runtime_store.save_artifact_text
           store
           "art-sess"
           ~name:""
           ~kind:"json"
           ~content:"{}"
       with
       | Ok path ->
         (* Empty name should default to "artifact" *)
         let base = Filename.basename path in
         Alcotest.(check bool)
           "starts with artifact"
           true
           (String.length base >= 8 && String.sub base 0 8 = "artifact")
       | Error e -> Alcotest.fail (Error.to_string e)))
;;

(* ── Runner ───────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Runtime Store Unit"
    [ ( "save_load_text"
      , [ Alcotest.test_case "roundtrip" `Quick test_save_load_roundtrip
        ; Alcotest.test_case "empty file" `Quick test_save_load_empty
        ; Alcotest.test_case "unicode" `Quick test_save_load_unicode
        ; Alcotest.test_case "missing file" `Quick test_load_missing_file
        ] )
    ; ( "ensure_dir"
      , [ Alcotest.test_case "creates" `Quick test_ensure_dir_creates
        ; Alcotest.test_case "idempotent" `Quick test_ensure_dir_idempotent
        ] )
    ; ( "store_create"
      , [ Alcotest.test_case "create" `Quick test_store_create
        ; Alcotest.test_case
            "requires explicit root"
            `Quick
            test_store_create_requires_explicit_root
        ; Alcotest.test_case
            "rejects relative root"
            `Quick
            test_store_create_rejects_relative_root
        ] )
    ; ( "session"
      , [ Alcotest.test_case "save and load" `Quick test_save_load_session
        ; Alcotest.test_case "missing" `Quick test_load_session_missing
        ; Alcotest.test_case "corrupt" `Quick test_load_session_corrupt
        ] )
    ; ( "runs"
      , [ Alcotest.test_case
            "stable updated_at ordering"
            `Quick
            test_list_runs_stable_updated_at_order
        ; Alcotest.test_case
            "corrupt run is partial failure"
            `Quick
            test_list_runs_reports_corrupt_without_dropping_valid_runs
        ; Alcotest.test_case "window selectors" `Quick test_select_run_windows_variants
        ; Alcotest.test_case
            "corrupt selected run is one partial failure"
            `Quick
            test_select_run_windows_corrupt_session_is_single_partial_failure
        ; Alcotest.test_case
            "overlapping windows dedupe events"
            `Quick
            test_read_window_events_dedupes_overlapping_windows
        ] )
    ; ( "events"
      , [ Alcotest.test_case "append and read" `Quick test_append_and_read_events
        ; Alcotest.test_case "filter by seq" `Quick test_read_events_with_filter
        ; Alcotest.test_case "no file" `Quick test_read_events_no_file
        ] )
    ; ( "snapshot_path"
      , [ Alcotest.test_case "with label" `Quick test_snapshot_path_with_label
        ; Alcotest.test_case "no label" `Quick test_snapshot_path_no_label
        ; Alcotest.test_case "slash in label" `Quick test_snapshot_path_slash_in_label
        ] )
    ; ( "artifacts"
      , [ Alcotest.test_case "save text" `Quick test_save_artifact_text
        ; Alcotest.test_case "empty name" `Quick test_save_artifact_text_empty_name
        ] )
    ]
;;
