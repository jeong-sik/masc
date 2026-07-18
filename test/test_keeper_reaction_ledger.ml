open Alcotest
open Masc
open Yojson.Safe.Util

let with_temp_base f =
  let base_path = Filename.temp_file "masc-reaction-sqlite-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  f base_path
;;

let rec mkdir_p path =
  if Sys.file_exists path
  then ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end
;;

let board_stimulus ?(post_id = "post-42") ?(arrived_at = 1234.5) () =
  Keeper_event_queue.
    { post_id
    ; urgency = Immediate
    ; arrived_at
    ; payload =
        Board_signal
          { kind = Post_created
          ; author = "operator"
          ; title = "Ship the SQLite reaction ledger"
          ; content = "No dual authority"
          ; hearth = None
          ; updated_at = Some arrived_at
          }
    }
;;

let schedule_stimulus index =
  let post_id = Printf.sprintf "occurrence-%02d" index in
  Keeper_event_queue.
    { post_id
    ; urgency = Immediate
    ; arrived_at = 2000. +. float_of_int index
    ; payload =
        Schedule_due
          { schedule_id = Printf.sprintf "schedule-%02d" index
          ; due_at = 1900. +. float_of_int index
          ; payload_digest = Printf.sprintf "digest-%02d" index
          ; title = None
          ; message = "wake"
          }
    }
;;

let fail_ledger_error context error =
  fail (context ^ ": " ^ Keeper_reaction_ledger.ledger_error_to_string error)
;;

let expect_write context = function
  | Ok outcome -> outcome
  | Error error -> fail_ledger_error context error
;;

let expect_evidence context = function
  | Ok evidence -> evidence
  | Error error ->
    fail
      (context
       ^ ": "
       ^ Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
;;

let expect_store context = function
  | Ok value -> value
  | Error error -> fail (context ^ ": " ^ Keeper_reaction_store.error_to_string error)
;;

let database_path ~base_path ~keeper_name =
  expect_store
    "database path"
    (Keeper_reaction_store.database_path ~base_path ~keeper_name)
;;

let with_sqlite path f =
  let db = Sqlite3.db_open ~mode:`NO_CREATE path in
  Fun.protect
    ~finally:(fun () ->
      if not (Sqlite3.db_close db) then fail "SQLite fixture close failed")
    (fun () -> f db)
;;

let exec_sql db sql =
  let rc = Sqlite3.exec db sql in
  if not (Sqlite3.Rc.is_success rc)
  then
    fail
      (Printf.sprintf
         "SQLite fixture exec failed rc=%s detail=%s"
         (Sqlite3.Rc.to_string rc)
         (Sqlite3.errmsg db))
;;

let test_absent_database_is_exact_empty () =
  with_temp_base (fun base_path ->
    let keeper_name = "absent-ledger" in
    let stimulus_id = "never-recorded" in
    let evidence =
      expect_evidence
        "absent evidence"
        (Keeper_reaction_ledger.event_queue_reaction_evidence_result
           ~base_path
           ~keeper_name
           ~stimulus_id)
    in
    check bool "stimulus absent" false evidence.stimulus_seen;
    check bool "turn absent" false evidence.turn_started_seen;
    check bool "ack absent" false evidence.event_queue_ack_seen;
    check int "no matches" 0 evidence.matched_record_count;
    check bool
      "read does not create database"
      false
      (Sys.file_exists (database_path ~base_path ~keeper_name)))
;;

let test_stimulus_turn_and_idempotent_replay () =
  with_temp_base (fun base_path ->
    let keeper_name = "idempotent-ledger" in
    let stimulus = board_stimulus () in
    let first =
      expect_write
        "first stimulus"
        (Keeper_reaction_ledger.record_event_queue_stimulus_result
           ~base_path
           ~keeper_name
           stimulus)
    in
    let replay =
      expect_write
        "stimulus replay"
        (Keeper_reaction_ledger.record_event_queue_stimulus_result
           ~base_path
           ~keeper_name
           stimulus)
    in
    check bool "first inserted" true (first = Keeper_reaction_ledger.Inserted);
    check bool
      "identical replay observed"
      true
      (replay = Keeper_reaction_ledger.Already_recorded);
    ignore
      (expect_write
         "turn started"
         (Keeper_reaction_ledger.record_event_queue_turn_started_result
            ~base_path
            ~keeper_name
            ~lease_sequence:1L
            stimulus));
    let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
    let evidence =
      expect_evidence
        "complete evidence"
        (Keeper_reaction_ledger.event_queue_reaction_evidence_result
           ~base_path
           ~keeper_name
           ~stimulus_id)
    in
    check bool "stimulus seen" true evidence.stimulus_seen;
    check bool "turn seen" true evidence.turn_started_seen;
    check bool "ack not fabricated" false evidence.event_queue_ack_seen;
    check int "deduplicated physical rows" 2 evidence.matched_record_count)
;;

let test_queue_identity_replay_ignores_arrival_observation () =
  with_temp_base (fun base_path ->
    let keeper_name = "arrival-replay" in
    let first = schedule_stimulus 7 in
    let replay = { first with Keeper_event_queue.arrived_at = first.arrived_at +. 60. } in
    check string
      "canonical identity unchanged"
      (Keeper_event_queue.stimulus_identity_id first)
      (Keeper_event_queue.stimulus_identity_id replay);
    check bool
      "identity equality shares canonical projection"
      true
      (Keeper_event_queue.stimulus_identity_equal first replay);
    let board_created = board_stimulus ~post_id:"shared-board-post" () in
    let board_commented =
      { board_created with
        Keeper_event_queue.payload =
          (match board_created.payload with
           | Keeper_event_queue.Board_signal signal ->
             Keeper_event_queue.Board_signal
               { signal with kind = Keeper_event_queue.Comment_added }
           | _ -> fail "board fixture changed payload kind")
      }
    in
    check bool
      "different board signal at one post has a different identity"
      false
      (String.equal
         (Keeper_event_queue.stimulus_identity_id board_created)
         (Keeper_event_queue.stimulus_identity_id board_commented));
    check bool
      "identity equality rejects the different board signal"
      false
      (Keeper_event_queue.stimulus_identity_equal board_created board_commented);
    ignore
      (expect_write
         "arrival seed"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name
            first));
    let outcome =
      expect_write
        "arrival replay"
        (Keeper_reaction_ledger.record_event_queue_stimulus_result
           ~base_path
           ~keeper_name
           replay)
    in
    check bool
      "arrival metadata is first-write-wins"
      true
      (outcome = Keeper_reaction_ledger.Already_recorded))
;;

let store_stimulus_event ~event_id ~stimulus_id ~post_id =
  Keeper_reaction_store.
    { event_id
    ; stimulus_id
    ; recorded_at = 1000.
    ; payload =
        Stimulus_event
          { kind = Board_signal
          ; post_id
          ; urgency = Immediate
          ; arrived_at = 900.
          ; board_updated_at = Some 900.
          }
    }
;;

let test_event_identity_conflict_is_typed () =
  with_temp_base (fun base_path ->
    let keeper_name = "event-conflict" in
    let first = store_stimulus_event ~event_id:"event-1" ~stimulus_id:"s-1" ~post_id:"p-1" in
    let conflicting =
      store_stimulus_event ~event_id:"event-1" ~stimulus_id:"s-1" ~post_id:"p-2"
    in
    ignore
      (expect_store
         "insert event"
         (Keeper_reaction_store.append_event ~base_path ~keeper_name first));
    match Keeper_reaction_store.append_event ~base_path ~keeper_name conflicting with
    | Error (Keeper_reaction_store.Event_identity_conflict { event_id }) ->
      check string "conflicting identity" "event-1" event_id
    | Error error -> fail (Keeper_reaction_store.error_to_string error)
    | Ok _ -> fail "conflicting event was accepted")
;;

let transition ?(transition_id = "transition-1") sources =
  Keeper_reaction_store.
    { transition_id
    ; transition_event_id = transition_id ^ ":event"
    ; lease_id = transition_id ^ ":lease"
    ; lease_sequence = 1L
    ; settled_at = 3000.
    ; settlement_kind = Ack
    ; settlement_identity = {|{"kind":"ack"}|}
    ; external_input_requested = false
    ; sources
    }
;;

let transition_source index stimulus_id =
  Keeper_reaction_store.
    { event_id = Printf.sprintf "transition-1:event:source:%d" index
    ; stimulus_id
    ; stimulus_kind = Schedule_due
    ; post_id = stimulus_id
    }
;;

let test_transition_is_atomic_bound_and_replayable () =
  with_temp_base (fun base_path ->
    let keeper_name = "transition-ledger" in
    let value = transition [ transition_source 0 "s-a"; transition_source 1 "s-b" ] in
    let first =
      expect_store
        "transition insert"
        (Keeper_reaction_store.append_transition ~base_path ~keeper_name value)
    in
    let replay =
      expect_store
        "transition replay"
        (Keeper_reaction_store.append_transition ~base_path ~keeper_name value)
    in
    check bool
      "transition inserted"
      true
      (first = Keeper_reaction_store.Transition_inserted);
    check bool
      "transition replay"
      true
      (replay = Keeper_reaction_store.Transition_already_recorded);
    let evidence =
      expect_store
        "batch transition evidence"
        (Keeper_reaction_store.events_for_stimuli
           ~base_path
           ~keeper_name
           ~stimulus_ids:[ "s-a"; "s-b" ])
    in
    List.iter
      (fun (_, events) ->
        match events with
        | [ { Keeper_reaction_store.payload = Stored_transition_settlement row; _ } ] ->
          check int "source cardinality" 2 row.source_count
        | _ -> fail "transition source did not round-trip exactly")
      evidence)
;;

let test_transition_child_kind_must_match_parent () =
  with_temp_base (fun base_path ->
    let keeper_name = "transition-kind-integrity" in
    let value = transition [ transition_source 0 "source-a" ] in
    ignore
      (expect_store
         "transition kind seed"
         (Keeper_reaction_store.append_transition ~base_path ~keeper_name value));
    with_sqlite (database_path ~base_path ~keeper_name) (fun db ->
      exec_sql
        db
        "UPDATE events SET reaction_kind='event_queue_requeued' WHERE transition_id='transition-1'");
    match
      Keeper_reaction_store.events_for_stimuli
        ~base_path
        ~keeper_name
        ~stimulus_ids:[ "source-a" ]
    with
    | Error (Keeper_reaction_store.Integrity_failure _) -> ()
    | Error error -> fail (Keeper_reaction_store.error_to_string error)
    | Ok _ -> fail "transition child kind disagreement was accepted")
;;

let test_transition_conflict_rolls_back_every_source () =
  with_temp_base (fun base_path ->
    let keeper_name = "transition-rollback" in
    let conflicting_event_id = "preexisting-event" in
    ignore
      (expect_store
         "preexisting event"
         (Keeper_reaction_store.append_event
            ~base_path
            ~keeper_name
            (store_stimulus_event
               ~event_id:conflicting_event_id
               ~stimulus_id:"foreign-source"
               ~post_id:"foreign-source")));
    let sources =
      [ Keeper_reaction_store.
          { event_id = "fresh-source-event"
          ; stimulus_id = "first-source"
          ; stimulus_kind = Schedule_due
          ; post_id = "first-source"
          }
      ; Keeper_reaction_store.
          { event_id = conflicting_event_id
          ; stimulus_id = "second-source"
          ; stimulus_kind = Schedule_due
          ; post_id = "second-source"
          }
      ]
    in
    (match Keeper_reaction_store.append_transition ~base_path ~keeper_name (transition sources) with
     | Error (Keeper_reaction_store.Event_identity_conflict _) -> ()
     | Error error -> fail (Keeper_reaction_store.error_to_string error)
     | Ok _ -> fail "partial-conflict transition was accepted");
    let rows =
      expect_store
        "rollback evidence"
        (Keeper_reaction_store.events_for_stimuli
           ~base_path
           ~keeper_name
           ~stimulus_ids:[ "first-source"; "second-source"; "foreign-source" ])
    in
    (match rows with
     | [ _, first; _, second; _, foreign ] ->
       check int "first source rolled back" 0 (List.length first);
       check int "second source absent" 0 (List.length second);
       check int "preexisting row retained" 1 (List.length foreign)
     | _ -> fail "rollback query did not preserve request cardinality"))
;;

let test_transition_cardinality_conflict () =
  with_temp_base (fun base_path ->
    let keeper_name = "transition-cardinality" in
    let first = transition [ transition_source 0 "source-a" ] in
    ignore
      (expect_store
         "initial transition"
         (Keeper_reaction_store.append_transition ~base_path ~keeper_name first));
    let conflicting =
      transition [ transition_source 0 "source-a"; transition_source 1 "source-b" ]
    in
    match Keeper_reaction_store.append_transition ~base_path ~keeper_name conflicting with
    | Error (Keeper_reaction_store.Transition_identity_conflict _) -> ()
    | Error error -> fail (Keeper_reaction_store.error_to_string error)
    | Ok _ -> fail "changed source cardinality was accepted")
;;

let test_partial_transition_replay_is_rejected_without_healing () =
  with_temp_base (fun base_path ->
    let keeper_name = "partial-transition" in
    let value = transition [ transition_source 0 "source-a"; transition_source 1 "source-b" ] in
    ignore
      (expect_store
         "seed complete transition"
         (Keeper_reaction_store.append_transition ~base_path ~keeper_name value));
    let path = database_path ~base_path ~keeper_name in
    with_sqlite path (fun db ->
      exec_sql db "PRAGMA foreign_keys=OFF";
      exec_sql
        db
        "DELETE FROM events WHERE transition_id='transition-1' AND source_index=1");
    (match Keeper_reaction_store.append_transition ~base_path ~keeper_name value with
     | Error (Keeper_reaction_store.Integrity_failure _)
     | Error (Keeper_reaction_store.Transition_cardinality_violation _) -> ()
     | Error error -> fail (Keeper_reaction_store.error_to_string error)
     | Ok _ -> fail "partial replay was healed or accepted");
    with_sqlite path (fun db ->
      let count = ref None in
      let rc =
        Sqlite3.exec_not_null_no_headers
          db
          ~cb:(fun row -> count := Some (int_of_string row.(0)))
          "SELECT COUNT(*) FROM events WHERE transition_id='transition-1'"
      in
      if not (Sqlite3.Rc.is_success rc) then fail "source count query failed";
      check (option int) "missing source remains missing" (Some 1) !count))
;;

let test_duplicate_transition_source_identity_is_rejected_before_write () =
  with_temp_base (fun base_path ->
    let keeper_name = "duplicate-transition-source" in
    let duplicate =
      transition
        [ transition_source 0 "same-stimulus"
        ; { (transition_source 1 "same-stimulus") with event_id = "other-event" }
        ]
    in
    (match Keeper_reaction_store.append_transition ~base_path ~keeper_name duplicate with
     | Error (Keeper_reaction_store.Invalid_transition _) -> ()
     | Error error -> fail (Keeper_reaction_store.error_to_string error)
     | Ok _ -> fail "duplicate transition source identity was accepted");
    check bool
      "invalid transition does not create its database"
      false
      (Sys.file_exists (database_path ~base_path ~keeper_name)))
;;

let test_batch_evidence_uses_one_keeper_query () =
  with_temp_base (fun base_path ->
    let keeper_name = "batch-ledger" in
    let stimuli = List.init 20 schedule_stimulus in
    List.iter
      (fun stimulus ->
        ignore
          (expect_write
             "batch stimulus"
             (Keeper_reaction_ledger.record_event_queue_stimulus_result
                ~base_path
                ~keeper_name
                stimulus)))
      stimuli;
    let stimulus_ids =
      List.map Keeper_reaction_ledger.stimulus_id_of_event_queue stimuli
    in
    let evidence =
      match
        Keeper_reaction_ledger.event_queue_reaction_evidence_batch_result
          ~base_path
          ~keeper_name
          ~stimulus_ids
      with
      | Ok values -> values
      | Error error ->
        fail
          (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
    in
    check int "all requested identities returned" 20 (List.length evidence);
    List.iter
      (fun (_, (row : Keeper_reaction_ledger.event_queue_reaction_evidence)) ->
        check bool "batch stimulus seen" true row.stimulus_seen;
        check int "one matching row" 1 row.matched_record_count)
      evidence)
;;

let test_schema_index_tamper_fails_closed_per_keeper () =
  with_temp_base (fun base_path ->
    let broken_keeper = "broken-schema" in
    let healthy_keeper = "healthy-schema" in
    let broken_stimulus = board_stimulus ~post_id:"broken" () in
    let healthy_stimulus = board_stimulus ~post_id:"healthy" () in
    ignore
      (expect_write
         "broken seed"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name:broken_keeper
            broken_stimulus));
    ignore
      (expect_write
         "healthy seed"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name:healthy_keeper
            healthy_stimulus));
    with_sqlite (database_path ~base_path ~keeper_name:broken_keeper) (fun db ->
      exec_sql db "DROP INDEX events_stimulus_sequence");
    let broken_id =
      Keeper_reaction_ledger.stimulus_id_of_event_queue broken_stimulus
    in
    (match
       Keeper_reaction_ledger.event_queue_reaction_evidence_result
         ~base_path
         ~keeper_name:broken_keeper
         ~stimulus_id:broken_id
     with
     | Error
         (Keeper_reaction_ledger.Evidence_store_error
           (Keeper_reaction_store.Schema_mismatch _)) -> ()
     | Error error ->
       fail
         (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
     | Ok _ -> fail "schema drift was accepted");
    let healthy_id =
      Keeper_reaction_ledger.stimulus_id_of_event_queue healthy_stimulus
    in
    let healthy =
      expect_evidence
        "other keeper remains readable"
        (Keeper_reaction_ledger.event_queue_reaction_evidence_result
           ~base_path
           ~keeper_name:healthy_keeper
           ~stimulus_id:healthy_id)
    in
    check bool "other lane continued" true healthy.stimulus_seen)
;;

let test_application_id_tamper_is_typed () =
  with_temp_base (fun base_path ->
    let keeper_name = "wrong-application-id" in
    let stimulus = board_stimulus () in
    ignore
      (expect_write
         "seed database"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name
            stimulus));
    with_sqlite (database_path ~base_path ~keeper_name) (fun db ->
      exec_sql db "PRAGMA application_id=0");
    let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
    match
      Keeper_reaction_ledger.event_queue_reaction_evidence_result
        ~base_path
        ~keeper_name
        ~stimulus_id
    with
    | Error
        (Keeper_reaction_ledger.Evidence_store_error
          (Keeper_reaction_store.Application_id_mismatch _)) -> ()
    | Error error ->
      fail
        (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
    | Ok _ -> fail "foreign application id was accepted")
;;

let test_symlinked_database_is_rejected () =
  with_temp_base (fun base_path ->
    let keeper_name = "symlink-ledger" in
    let path = database_path ~base_path ~keeper_name in
    mkdir_p (Filename.dirname path);
    let target = Filename.temp_file "foreign-reaction-db-" ".sqlite3" in
    Unix.symlink target path;
    match
      Keeper_reaction_store.events_for_stimuli
        ~base_path
        ~keeper_name
        ~stimulus_ids:[ "x" ]
    with
    | Error (Keeper_reaction_store.Path_failure _) -> ()
    | Error error -> fail (Keeper_reaction_store.error_to_string error)
    | Ok _ -> fail "symlinked database was accepted")
;;

let test_orphan_database_sidecar_is_rejected () =
  with_temp_base (fun base_path ->
    let keeper_name = "orphan-sidecar" in
    let path = database_path ~base_path ~keeper_name in
    mkdir_p (Filename.dirname path);
    let sidecar = path ^ "-journal" in
    let fd =
      Unix.openfile
        sidecar
        [ Unix.O_CLOEXEC; Unix.O_CREAT; Unix.O_EXCL; Unix.O_RDWR ]
        0o600
    in
    Unix.close fd;
    match
      Keeper_reaction_store.events_for_stimuli
        ~base_path
        ~keeper_name
        ~stimulus_ids:[ "x" ]
    with
    | Error (Keeper_reaction_store.Orphan_database_sidecars { sidecars; _ }) ->
      check (list string) "exact orphan sidecar reported" [ sidecar ] sidecars
    | Error error -> fail (Keeper_reaction_store.error_to_string error)
    | Ok _ -> fail "orphan database sidecar was treated as an empty ledger")
;;

let test_private_staging_publish_and_permissions () =
  with_temp_base (fun base_path ->
    let keeper_name = "private-publish" in
    let path = database_path ~base_path ~keeper_name in
    let staging = path ^ ".initializing" in
    mkdir_p (Filename.dirname path);
    let fd =
      Unix.openfile
        staging
        [ Unix.O_CLOEXEC; Unix.O_CREAT; Unix.O_EXCL; Unix.O_RDWR ]
        0o600
    in
    Unix.close fd;
    ignore
      (expect_write
         "publish after abandoned staging"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name
            (schedule_stimulus 1)));
    check bool "final published" true (Sys.file_exists path);
    check bool "staging retired" false (Sys.file_exists staging);
    check int "database private" 0o600 ((Unix.stat path).Unix.st_perm land 0o777);
    check int
      "lock private"
      0o600
      ((Unix.stat (path ^ ".lock")).Unix.st_perm land 0o777))
;;

let test_interrupted_hardlink_publish_is_recovered_without_loss () =
  with_temp_base (fun base_path ->
    let keeper_name = "interrupted-publish" in
    let stimulus = schedule_stimulus 31 in
    ignore
      (expect_write
         "publish recovery seed"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name
            stimulus));
    let path = database_path ~base_path ~keeper_name in
    let staging = path ^ ".initializing" in
    Unix.link path staging;
    check int "fixture has two links" 2 (Unix.lstat path).Unix.st_nlink;
    let evidence =
      expect_evidence
        "recover interrupted publish"
        (Keeper_reaction_ledger.event_queue_reaction_evidence_result
           ~base_path
           ~keeper_name
           ~stimulus_id:
             (Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus))
    in
    check bool "committed stimulus preserved" true evidence.stimulus_seen;
    check bool "initializing link retired" false (Sys.file_exists staging);
    check int "final link count restored" 1 (Unix.lstat path).Unix.st_nlink)
;;

let test_unsafe_database_permissions_fail_closed () =
  with_temp_base (fun base_path ->
    let keeper_name = "unsafe-permissions" in
    let stimulus = schedule_stimulus 2 in
    ignore
      (expect_write
         "permission seed"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name
            stimulus));
    let path = database_path ~base_path ~keeper_name in
    Unix.chmod path 0o644;
    match
      Keeper_reaction_ledger.event_queue_reaction_evidence_result
        ~base_path
        ~keeper_name
        ~stimulus_id:(Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus)
    with
    | Error
        (Keeper_reaction_ledger.Evidence_store_error
          (Keeper_reaction_store.Path_failure _)) -> ()
    | Error error ->
      fail
        (Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string error)
    | Ok _ -> fail "world-readable reaction database was accepted")
;;

let test_summary_is_typed_and_clears_pending () =
  with_temp_base (fun base_path ->
    let keeper_name = "summary-ledger" in
    let stimulus = board_stimulus () in
    ignore
      (expect_write
         "summary stimulus"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name
            stimulus));
    let before =
      Keeper_reaction_ledger.summary_for_keeper
        ~base_path
        ~keeper_name
        ~pending_id_display_limit:20
    in
    check string "summary schema" "keeper.reaction_ledger.summary.v3" (before |> member "schema" |> to_string);
    check int "pending before turn" 1 (before |> member "pending_stimulus_count" |> to_int);
    ignore
      (expect_write
         "summary turn"
         (Keeper_reaction_ledger.record_event_queue_turn_started_result
            ~base_path
            ~keeper_name
            ~lease_sequence:1L
            stimulus));
    let after =
      Keeper_reaction_ledger.summary_for_keeper
        ~base_path
        ~keeper_name
        ~pending_id_display_limit:20
    in
    check int "pending cleared" 0 (after |> member "pending_stimulus_count" |> to_int);
    check int "turn counted" 1 (after |> member "turn_started_count" |> to_int))
;;

let test_summary_counts_old_pending_beyond_display_window () =
  with_temp_base (fun base_path ->
    let keeper_name = "exact-summary" in
    let stimuli = List.init 25 schedule_stimulus in
    List.iter
      (fun stimulus ->
        ignore
          (expect_write
             "summary stimulus"
             (Keeper_reaction_ledger.record_event_queue_stimulus_result
                ~base_path
                ~keeper_name
                stimulus)))
      stimuli;
    stimuli
    |> List.drop 5
    |> List.iter (fun stimulus ->
      ignore
        (expect_write
           "summary handling"
           (Keeper_reaction_ledger.record_event_queue_turn_started_result
              ~base_path
              ~keeper_name
              ~lease_sequence:1L
              stimulus)));
    let summary =
      Keeper_reaction_ledger.summary_for_keeper
        ~base_path
        ~keeper_name
        ~pending_id_display_limit:3
    in
    check int "all rows counted" 45 (summary |> member "row_count" |> to_int);
    check int
      "old pending exact"
      5
      (summary |> member "pending_stimulus_count" |> to_int);
    check int
      "only display sample limited"
      3
      (summary |> member "pending_stimulus_ids" |> to_list |> List.length);
    check bool
      "sample truncation explicit"
      true
      (summary |> member "pending_ids_truncated" |> to_bool))
;;

let test_keeper_name_discovery_failure_is_explicit () =
  with_temp_base (fun base_path ->
    let summary =
      Keeper_reaction_ledger.fleet_summary_json
        ~base_path
        ~keeper_name_discovery:
          (Keeper_reaction_ledger.Keeper_name_discovery_failed
             "keeper meta store unreadable")
        ~pending_id_display_limit_per_keeper:0
    in
    check string "status unknown" "unknown" (summary |> member "status" |> to_string);
    check bool
      "operator action required"
      true
      (summary |> member "operator_action_required" |> to_bool);
    check bool
      "counts incomplete"
      false
      (summary |> member "counts_complete" |> to_bool);
    check int
      "typed discovery error count"
      1
      (summary |> member "keeper_name_discovery_error_count" |> to_int);
    check
      (list string)
      "typed discovery detail"
      [ "keeper meta store unreadable" ]
      (summary |> member "keeper_name_discovery_errors" |> to_list |> List.map to_string);
    check bool
      "reason retained"
      true
      (summary
       |> member "status_reasons"
       |> to_list
       |> List.map to_string
       |> List.mem "keeper_meta_discovery_error"))
;;

let test_reaction_store_discovery_uses_directory_shape () =
  with_temp_base (fun base_path ->
    let keeper_name = "directory-shaped-store" in
    ignore
      (expect_write
         "create discovered store"
         (Keeper_reaction_ledger.record_event_queue_stimulus_result
            ~base_path
            ~keeper_name
            (board_stimulus ())));
    let metadata_path =
      Filename.concat
        (Common.keepers_runtime_dir_of_base ~base_path)
        "directory-shaped-store.json"
    in
    let channel = open_out_bin metadata_path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel "{}");
    let discovery = Keeper_reaction_store.discover_keeper_names ~base_path in
    check
      (list string)
      "only per-Keeper directory stores are discovered"
      [ keeper_name ]
      discovery.keeper_names;
    check int "regular metadata files are not errors" 0 (List.length discovery.errors))
;;

let ordered_reaction_transition
      ~transition_id
      ~lease_sequence
      ~settled_at
      ~settlement_kind
      ~external_input_requested
      ~stimulus_id
  =
  Keeper_reaction_store.
    { transition_id
    ; transition_event_id = transition_id ^ ":event"
    ; lease_id = transition_id ^ ":lease"
    ; lease_sequence
    ; settled_at
    ; settlement_kind
    ; settlement_identity = transition_id ^ ":settlement"
    ; external_input_requested
    ; sources =
        [ { event_id = transition_id ^ ":source:0"
          ; stimulus_id
          ; stimulus_kind = Schedule_due
          ; post_id = "ordered-post"
          }
        ]
    }
;;

let test_latest_reaction_uses_ledger_sequence_and_preserves_outcome () =
  with_temp_base (fun base_path ->
    let keeper_name = "ordered-reaction" in
    let stimulus_id = "ordered-stimulus" in
    ignore
      (expect_store
         "ordered stimulus"
         (Keeper_reaction_store.append_event
            ~base_path
            ~keeper_name
            (store_stimulus_event
               ~event_id:"ordered-stimulus:event"
               ~stimulus_id
               ~post_id:"ordered-post")));
    ignore
      (expect_store
         "ordered turn start"
         (Keeper_reaction_store.append_event
            ~base_path
            ~keeper_name
            Keeper_reaction_store.
              { event_id = "ordered-turn:event"
              ; stimulus_id
              ; recorded_at = 4000.
              ; payload =
                  Turn_started_event
                    { stimulus_kind = Schedule_due; post_id = "ordered-post" }
              }));
    let latest () =
      (expect_evidence
         "ordered evidence"
         (Keeper_reaction_ledger.event_queue_reaction_evidence_result
            ~base_path
            ~keeper_name
            ~stimulus_id))
        .latest_reaction
    in
    (match latest () with
     | Some (Keeper_reaction_ledger.Latest_turn_started _) -> ()
     | Some _ | None -> fail "turn-start was not the latest typed reaction");
    let append_transition context transition =
      ignore
        (expect_store
           context
           (Keeper_reaction_store.append_transition
              ~base_path
              ~keeper_name
              transition))
    in
    append_transition
      "ordered ack"
      (ordered_reaction_transition
         ~transition_id:"ordered-ack"
         ~lease_sequence:1L
         ~settled_at:3000.
         ~settlement_kind:Keeper_reaction_store.Ack
         ~external_input_requested:false
         ~stimulus_id);
    (match latest () with
     | Some (Keeper_reaction_ledger.Latest_event_queue_ack _) -> ()
     | Some _ | None -> fail "ACK was not the latest typed reaction");
    append_transition
      "ordered requeue"
      (ordered_reaction_transition
         ~transition_id:"ordered-requeue"
         ~lease_sequence:2L
         ~settled_at:2000.
         ~settlement_kind:Keeper_reaction_store.Requeue
         ~external_input_requested:false
         ~stimulus_id);
    (match latest () with
     | Some (Keeper_reaction_ledger.Latest_event_queue_requeued _) -> ()
     | Some _ | None ->
       fail "later requeue lost precedence to an earlier wall-clock timestamp");
    ignore
      (expect_store
         "ordered retry turn start"
         (Keeper_reaction_store.append_event
            ~base_path
            ~keeper_name
            Keeper_reaction_store.
              { event_id = "ordered-turn-retry:event"
              ; stimulus_id
              ; recorded_at = 1500.
              ; payload =
                  Turn_started_event
                    { stimulus_kind = Schedule_due; post_id = "ordered-post" }
              }));
    (match latest () with
     | Some (Keeper_reaction_ledger.Latest_turn_started _) -> ()
     | Some _ | None -> fail "retry turn-start did not supersede its requeue");
    append_transition
      "ordered external-input escalation"
      (ordered_reaction_transition
         ~transition_id:"ordered-escalation"
         ~lease_sequence:3L
         ~settled_at:1000.
         ~settlement_kind:Keeper_reaction_store.Escalate
         ~external_input_requested:true
         ~stimulus_id);
    (match latest () with
     | Some
         (Keeper_reaction_ledger.Latest_event_queue_escalated
           { external_input_requested = true; _ }) -> ()
     | Some _ | None -> fail "external-input escalation outcome was not preserved");
    let summary =
      Keeper_reaction_ledger.summary_for_keeper
        ~base_path
        ~keeper_name
        ~pending_id_display_limit:0
    in
    check string
      "external input is not healthy"
      "degraded"
      (summary |> member "status" |> to_string);
    check int
      "latest external input remains actionable"
      1
      (summary
       |> member "external_input_requested_stimulus_count"
       |> to_int))
;;

let test_materialized_summary_tracks_all_current_states () =
  with_temp_base (fun base_path ->
    let keeper_name = "materialized-summary" in
    let schedule_event stimulus_id =
      Keeper_reaction_store.
        { event_id = stimulus_id ^ ":stimulus"
        ; stimulus_id
        ; recorded_at = 1000.
        ; payload =
            Stimulus_event
              { kind = Schedule_due
              ; post_id = stimulus_id
              ; urgency = Immediate
              ; arrived_at = 900.
              ; board_updated_at = None
              }
        }
    in
    let turn_event stimulus_id =
      Keeper_reaction_store.
        { event_id = stimulus_id ^ ":turn"
        ; stimulus_id
        ; recorded_at = 1100.
        ; payload =
            Turn_started_event
              { stimulus_kind = Schedule_due; post_id = stimulus_id }
        }
    in
    let append_event context event =
      ignore
        (expect_store
           context
           (Keeper_reaction_store.append_event ~base_path ~keeper_name event))
    in
    let stimulus_ids =
      [ "pending"; "in-progress"; "acked"; "requeued"; "escalated"; "external" ]
    in
    List.iter
      (fun stimulus_id -> append_event "state stimulus" (schedule_event stimulus_id))
      stimulus_ids;
    append_event
      "board stimulus"
      (store_stimulus_event
         ~event_id:"cursor-board:stimulus"
         ~stimulus_id:"cursor-board"
         ~post_id:"cursor-board");
    List.iter
      (fun stimulus_id -> append_event "state turn" (turn_event stimulus_id))
      [ "in-progress"; "acked"; "requeued"; "escalated"; "external" ];
    let settle transition_id lease_sequence settlement_kind external_input_requested stimulus_id =
      ignore
        (expect_store
           "state settlement"
           (Keeper_reaction_store.append_transition
              ~base_path
              ~keeper_name
              (ordered_reaction_transition
                 ~transition_id
                 ~lease_sequence
                 ~settled_at:1200.
                 ~settlement_kind
                 ~external_input_requested
                 ~stimulus_id)))
    in
    settle "state-ack" 1L Keeper_reaction_store.Ack false "acked";
    settle "state-requeue" 2L Keeper_reaction_store.Requeue false "requeued";
    settle "state-escalate" 3L Keeper_reaction_store.Escalate false "escalated";
    settle "state-external" 4L Keeper_reaction_store.Escalate true "external";
    append_event
      "cursor sweep"
      Keeper_reaction_store.
        { event_id = "cursor:event"
        ; stimulus_id = "cursor:900:cursor-board"
        ; recorded_at = 1300.
        ; payload = Cursor_ack_event { cursor_ts = 900.; post_id = Some "cursor-board" }
        };
    append_event "orphan turn" (turn_event "orphan-later");
    let orphan =
      expect_store
        "orphan summary"
        (Keeper_reaction_store.exact_summary
           ~base_path
           ~keeper_name
           ~pending_id_display_limit:20)
    in
    check int "one unique orphan identity" 1 orphan.orphan_reaction_stimulus_count;
    append_event "late orphan stimulus" (schedule_event "orphan-later");
    let summary =
      expect_store
        "materialized summary"
        (Keeper_reaction_store.exact_summary
           ~base_path
           ~keeper_name
           ~pending_id_display_limit:20)
    in
    check int "all immutable event rows" 19 summary.row_count;
    check int "all stimuli" 8 summary.stimulus_count;
    check int "all reactions" 11 summary.reaction_count;
    check int "turn starts" 6 summary.turn_started_count;
    check int "acks" 1 summary.event_queue_ack_count;
    check int "requeues" 1 summary.event_queue_requeue_count;
    check int "escalations" 2 summary.event_queue_escalation_count;
    check int "external input events" 1 summary.event_queue_external_input_count;
    check int "cursor acks" 1 summary.cursor_ack_count;
    check int "pending states" 2 summary.pending_stimulus_count;
    check int "swept states" 1 summary.cursor_swept_stimulus_count;
    check int "in-progress states" 2 summary.in_progress_stimulus_count;
    check int "acked states" 1 summary.acked_stimulus_count;
    check int "escalated states" 1 summary.escalated_stimulus_count;
    check int
      "external input states"
      1
      summary.external_input_requested_stimulus_count;
    check int "orphan resolved by canonical stimulus" 0 summary.orphan_reaction_stimulus_count;
    check
      (list string)
      "bounded sample is stable stimulus order"
      [ "pending"; "requeued" ]
      summary.pending_stimulus_ids)
;;

let test_summary_hot_path_uses_projection_and_bounded_index () =
  with_temp_base (fun base_path ->
    let keeper_name = "summary-query-plan" in
    ignore
      (expect_store
         "query-plan seed"
         (Keeper_reaction_store.append_event
            ~base_path
            ~keeper_name
            (store_stimulus_event
               ~event_id:"query-plan:event"
               ~stimulus_id:"query-plan:stimulus"
               ~post_id:"query-plan:post")));
    with_sqlite (database_path ~base_path ~keeper_name) (fun db ->
      let schema_count =
        let stmt =
          Sqlite3.prepare
            db
            "SELECT COUNT(*) FROM sqlite_schema WHERE (type = 'table' AND name IN ('ledger_summary', 'stimulus_state')) OR (type = 'trigger' AND name IN ('events_project_summary', 'events_project_stimulus', 'events_project_handling', 'events_project_cursor', 'stimulus_state_count_insert', 'stimulus_state_count_update'))"
        in
        Fun.protect
          ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
          (fun () ->
            match Sqlite3.step stmt with
            | Sqlite3.Rc.ROW -> Int64.to_int (Sqlite3.column_int64 stmt 0)
            | rc -> fail ("schema evidence query failed: " ^ Sqlite3.Rc.to_string rc))
      in
      check int "projection tables and triggers are exact schema" 8 schema_count;
      let plan_details sql =
        let stmt = Sqlite3.prepare db ("EXPLAIN QUERY PLAN " ^ sql) in
        Fun.protect
          ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
          (fun () ->
            let rec loop reversed =
              match Sqlite3.step stmt with
              | Sqlite3.Rc.DONE -> List.rev reversed
              | Sqlite3.Rc.ROW -> loop (Sqlite3.column_text stmt 3 :: reversed)
              | rc -> fail ("query-plan evidence failed: " ^ Sqlite3.Rc.to_string rc)
            in
            loop [])
      in
      let plans =
        plan_details "SELECT * FROM ledger_summary WHERE singleton = 1"
        @ plan_details
            "SELECT stimulus_id FROM stimulus_state INDEXED BY stimulus_state_pending_order WHERE current_state = 'pending' ORDER BY stimulus_sequence, stimulus_id LIMIT 20"
      in
      check bool
        "summary plans never read immutable event history"
        false
        (List.exists
           (fun detail ->
             let detail = String.lowercase_ascii detail in
             String.starts_with ~prefix:"scan events" detail
             || String.starts_with ~prefix:"search events" detail)
           plans);
      check bool
        "pending sample uses its bounded covering index"
        true
        (List.exists
           (fun detail ->
             String.starts_with
               ~prefix:"SEARCH stimulus_state USING COVERING INDEX stimulus_state_pending_order"
               detail)
           plans)))
;;

let () =
  run
    "keeper reaction SQLite v3"
    [ ( "authority"
      , [ test_case "absent database is exact empty" `Quick test_absent_database_is_exact_empty
        ; test_case "stimulus and turn replay" `Quick test_stimulus_turn_and_idempotent_replay
        ; test_case
            "queue identity arrival replay"
            `Quick
            test_queue_identity_replay_ignores_arrival_observation
        ; test_case "typed event identity conflict" `Quick test_event_identity_conflict_is_typed
        ; test_case "transition atomic replay" `Quick test_transition_is_atomic_bound_and_replayable
        ; test_case
            "transition child kind matches parent"
            `Quick
            test_transition_child_kind_must_match_parent
        ; test_case "transition conflict rolls back" `Quick test_transition_conflict_rolls_back_every_source
        ; test_case "transition cardinality conflict" `Quick test_transition_cardinality_conflict
        ; test_case
            "partial transition replay rejected"
            `Quick
            test_partial_transition_replay_is_rejected_without_healing
        ; test_case
            "duplicate transition source rejected"
            `Quick
            test_duplicate_transition_source_identity_is_rejected_before_write
        ; test_case "batch evidence" `Quick test_batch_evidence_uses_one_keeper_query
        ; test_case "schema drift is lane-local" `Quick test_schema_index_tamper_fails_closed_per_keeper
        ; test_case "application id mismatch" `Quick test_application_id_tamper_is_typed
        ; test_case "symlink database rejected" `Quick test_symlinked_database_is_rejected
        ; test_case "orphan database sidecar rejected" `Quick test_orphan_database_sidecar_is_rejected
        ; test_case
            "private staging publish"
            `Quick
            test_private_staging_publish_and_permissions
        ; test_case
            "interrupted hardlink publish recovery"
            `Quick
            test_interrupted_hardlink_publish_is_recovered_without_loss
        ; test_case
            "unsafe permissions rejected"
            `Quick
            test_unsafe_database_permissions_fail_closed
        ; test_case "typed summary" `Quick test_summary_is_typed_and_clears_pending
        ; test_case
            "exact summary beyond display window"
            `Quick
            test_summary_counts_old_pending_beyond_display_window
        ; test_case
            "keeper name discovery failure is explicit"
            `Quick
            test_keeper_name_discovery_failure_is_explicit
        ; test_case
            "reaction store discovery uses directory shape"
            `Quick
            test_reaction_store_discovery_uses_directory_shape
        ; test_case
            "latest reaction is sequence ordered and typed"
            `Quick
            test_latest_reaction_uses_ledger_sequence_and_preserves_outcome
        ; test_case
            "materialized summary tracks exact current states"
            `Quick
            test_materialized_summary_tracks_all_current_states
        ; test_case
            "summary hot path uses projection and bounded index"
            `Quick
            test_summary_hot_path_uses_projection_and_bounded_index
        ] )
    ]
