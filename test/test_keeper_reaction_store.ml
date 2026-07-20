(** Standalone contracts for the SQLite reaction store.

    The store is the reaction evidence authority: it is opened per Keeper and
    every observation is selected from SQLite rather than from a value cache.
    These tests exercise the module through its own public API only, with no
    ledger, registry, or dashboard wiring, so they stay valid while the cutover
    that replaces those callers is reviewed separately.

    Two contracts get explicit coverage because their failure mode is silent:
    absent storage must read as exact empty state (not an error, and not a
    fabricated row), and a repeated event identity must report
    [Already_recorded] instead of inserting a second row. *)

module Store = Keeper_reaction_store

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

let with_temp_dir prefix f =
  let base_path = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () -> f base_path)
;;

let require_ok label = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%s: %s" label (Store.error_to_string err)
;;

let keeper_name = "reaction-store-subject"
let other_keeper_name = "reaction-store-bystander"

(* Microsecond-representable so normalize_cursor is the identity on it and the
   round-trip assertion below compares an exact value, not a rounded one. *)
let base_ts = 1_000.0

let stimulus_event ~event_id ~stimulus_id ~post_id : Store.event =
  { event_id
  ; stimulus_id
  ; recorded_at = base_ts
  ; payload =
      Stimulus_event
        { kind = Board_signal
        ; post_id
        ; urgency = Normal
        ; arrived_at = base_ts
        ; board_updated_at = None
        }
  }
;;

let observe ~base_path ~keeper_name =
  Store.read_observation ~base_path ~keeper_name ~pending_id_display_limit:8
  |> require_ok "read_observation"
;;

(* Every stimulus/reaction kind must survive to_string -> of_string. A partial
   codec here would silently reclassify stored rows on read, so the totality is
   asserted over the full variant list rather than a sample. *)
let test_kind_codecs_round_trip () =
  let stimulus_kinds : Store.stimulus_kind list =
    [ Board_signal
    ; Bootstrap
    ; Fusion_completed
    ; Bg_completed
    ; Schedule_due
    ; Connector_attention
    ; Hitl_resolved
    ; Failure_judgment
    ; Manual_compaction
    ; Goal_assigned
    ]
  in
  List.iter
    (fun kind ->
      let encoded = Store.stimulus_kind_to_string kind in
      Alcotest.(check bool)
        (Printf.sprintf "stimulus kind %s round-trips" encoded)
        true
        (Store.stimulus_kind_of_string encoded = Some kind))
    stimulus_kinds;
  let reaction_kinds : Store.reaction_kind list =
    [ Turn_started
    ; Event_queue_ack
    ; Event_queue_requeued
    ; Event_queue_escalated
    ; Cursor_ack
    ]
  in
  List.iter
    (fun kind ->
      let encoded = Store.reaction_kind_to_string kind in
      Alcotest.(check bool)
        (Printf.sprintf "reaction kind %s round-trips" encoded)
        true
        (Store.reaction_kind_of_string encoded = Some kind))
    reaction_kinds;
  Alcotest.(check bool)
    "unknown stimulus kind decodes to None"
    true
    (Store.stimulus_kind_of_string "not-a-stimulus-kind" = None);
  Alcotest.(check bool)
    "unknown reaction kind decodes to None"
    true
    (Store.reaction_kind_of_string "not-a-reaction-kind" = None)
;;

(* Absent storage is exact empty state, not an error and not a fabricated row.
   A Keeper that has never reacted must be distinguishable from one whose store
   failed to open, which is why this asserts Ok with zero counts. *)
let test_absent_storage_reads_as_exact_empty () =
  with_temp_dir "masc-reaction-store-empty" (fun base_path ->
    let observation = observe ~base_path ~keeper_name in
    Alcotest.(check int) "row count" 0 observation.exact_summary.row_count;
    Alcotest.(check int) "stimulus count" 0 observation.exact_summary.stimulus_count;
    Alcotest.(check int) "reaction count" 0 observation.exact_summary.reaction_count;
    Alcotest.(check int)
      "pending stimulus count"
      0
      observation.exact_summary.pending_stimulus_count;
    Alcotest.(check bool) "no cursor" true (Option.is_none observation.cursor);
    Alcotest.(check bool)
      "no latest recorded_at"
      true
      (Option.is_none observation.exact_summary.latest_recorded_at);
    Alcotest.(check bool)
      "current_cursor agrees with observation"
      true
      (Store.current_cursor ~base_path ~keeper_name
       |> require_ok "current_cursor"
       |> Option.is_none))
;;

let test_appended_stimulus_is_observable () =
  with_temp_dir "masc-reaction-store-append" (fun base_path ->
    let event =
      stimulus_event ~event_id:"event-1" ~stimulus_id:"stimulus-1" ~post_id:"post-1"
    in
    Alcotest.(check bool)
      "first append inserts"
      true
      (Store.append_event ~base_path ~keeper_name event
       |> require_ok "append_event"
       = Store.Inserted);
    let observation = observe ~base_path ~keeper_name in
    Alcotest.(check int) "row count" 1 observation.exact_summary.row_count;
    Alcotest.(check int) "stimulus count" 1 observation.exact_summary.stimulus_count;
    Alcotest.(check int)
      "pending stimulus count"
      1
      observation.exact_summary.pending_stimulus_count;
    Alcotest.(check (list string))
      "pending stimulus ids"
      [ "stimulus-1" ]
      observation.exact_summary.pending_stimulus_ids;
    Alcotest.(check bool)
      "latest stimulus id"
      true
      (observation.exact_summary.latest_stimulus_id = Some "stimulus-1"))
;;

(* Replaying the same event identity must not append a second row. Without this
   the store would double-count a retried write and the pending projection would
   drift from the durable rows. *)
let test_repeated_event_identity_is_already_recorded () =
  with_temp_dir "masc-reaction-store-idempotent" (fun base_path ->
    let event =
      stimulus_event ~event_id:"event-1" ~stimulus_id:"stimulus-1" ~post_id:"post-1"
    in
    Alcotest.(check bool)
      "first append inserts"
      true
      (Store.append_event ~base_path ~keeper_name event
       |> require_ok "first append"
       = Store.Inserted);
    Alcotest.(check bool)
      "replayed append is already recorded"
      true
      (Store.append_event ~base_path ~keeper_name event
       |> require_ok "replayed append"
       = Store.Already_recorded);
    let observation = observe ~base_path ~keeper_name in
    Alcotest.(check int) "row count stays one" 1 observation.exact_summary.row_count;
    Alcotest.(check int)
      "stimulus count stays one"
      1
      observation.exact_summary.stimulus_count)
;;

(* Owner identity is (canonical BasePath, Keeper name). Writing under one Keeper
   must leave a sibling Keeper's authority at exact empty rather than exposing
   cross-owner rows. *)
let test_owner_identity_isolates_keepers () =
  with_temp_dir "masc-reaction-store-owner" (fun base_path ->
    let event =
      stimulus_event ~event_id:"event-1" ~stimulus_id:"stimulus-1" ~post_id:"post-1"
    in
    Store.append_event ~base_path ~keeper_name event |> require_ok "append_event" |> ignore;
    let subject = observe ~base_path ~keeper_name in
    let bystander = observe ~base_path ~keeper_name:other_keeper_name in
    Alcotest.(check int) "subject sees its row" 1 subject.exact_summary.row_count;
    Alcotest.(check int)
      "bystander stays empty"
      0
      bystander.exact_summary.row_count;
    let discovered = Store.discover_keeper_names ~base_path in
    Alcotest.(check (list string))
      "discovery reports no errors"
      []
      (List.map Store.error_to_string discovered.errors);
    Alcotest.(check bool)
      "discovery finds the writing keeper"
      true
      (List.mem keeper_name discovered.keeper_names);
    Alcotest.(check bool)
      "discovery omits the keeper that never wrote"
      false
      (List.mem other_keeper_name discovered.keeper_names))
;;

let test_cursor_ack_projects_singleton_cursor () =
  with_temp_dir "masc-reaction-store-cursor" (fun base_path ->
    let cursor : Store.cursor = { cursor_ts = base_ts; post_id = Some "post-1" } in
    let event : Store.event =
      { event_id = "event-cursor-1"
      ; stimulus_id = "stimulus-cursor-1"
      ; recorded_at = base_ts
      ; payload = Cursor_ack_event cursor
      }
    in
    Store.append_event ~base_path ~keeper_name event
    |> require_ok "append cursor ack"
    |> ignore;
    let observed =
      Store.current_cursor ~base_path ~keeper_name |> require_ok "current_cursor"
    in
    match observed with
    | None -> Alcotest.fail "cursor ack did not project a cursor"
    | Some observed ->
      let expected = Store.normalize_cursor cursor |> require_ok "normalize_cursor" in
      Alcotest.(check int)
        "projected cursor equals the normalized token"
        0
        (Store.compare_normalized_cursor observed expected);
      Alcotest.(check int)
        "cursor ack counted once"
        1
        (observe ~base_path ~keeper_name).exact_summary.cursor_ack_count)
;;

let () =
  test_kind_codecs_round_trip ();
  Eio_main.run (fun _env ->
    test_absent_storage_reads_as_exact_empty ();
    test_appended_stimulus_is_observable ();
    test_repeated_event_identity_is_already_recorded ();
    test_owner_identity_isolates_keepers ();
    test_cursor_ack_projects_singleton_cursor ());
  print_endline "test_keeper_reaction_store: OK"
;;
