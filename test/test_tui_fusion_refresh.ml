module Types = Masc_tui_types
module Updates = Masc_tui_fusion_updates
module Fetched = Masc_tui_fetched
module Model = Masc_tui_fusion_model
module Launch = Masc_tui_fusion_launch
module Decode = Masc.Tui_decode_fusion

let fresh () = Types.create_state ~workspace:"test" ~port:8935 ()
let require = function Some value -> value | None -> Alcotest.fail "expected a new read"

let empty_snapshot : Decode.fusion_snapshot =
  { fus_generated_at = "2026-11-01T00:00:00Z"
  ; fus_runs = []
  ; fus_replay = Fusion_not_replayed
  ; fus_historical_evidence = []
  }

let reference : Decode.fusion_historical_evidence =
  { fhe_run_id = "a"; fhe_post_id = "post"; fhe_title = "evidence"; fhe_created_at = 1.0 }

let run id stage : Decode.fusion_run =
  { fur_run_id = id; fur_keeper = "analyst"; fur_preset = "trio"
  ; fur_topology = Simple; fur_started_at = 1.; fur_finished_at = None
  ; fur_status = Fusion_running; fur_stage = stage; fur_decision = None; fur_summary = None }

let snapshot runs = { empty_snapshot with Decode.fus_runs = runs }

let detail run : Decode.fusion_detail =
  { fud_generated_at = "now"; fud_run = run
  ; fud_evidence_status = Fusion_evidence_pending; fud_evidence = None }

let historical_detail : Decode.fusion_historical_detail =
  { fhd_reference = reference; fhd_author = "author"; fhd_title = "evidence"
  ; fhd_body = "original"; fhd_observations = Ok (None, None)
  ; fhd_evidence = Error "no structured evidence" }

let check_completion label expected actual =
  let name = function Updates.Applied -> "applied" | Reread -> "reread"
    | Await_observer -> "await observer" | Obsolete -> "obsolete" in
  Alcotest.(check string) label (name expected) (name actual)

let test_batch_preserves_open_run () =
  let changed = Updates.no_changed_runs
    |> fun acc -> Updates.note_run_changed ~open_run_id:(Some "a") acc ~run_id:"a"
    |> fun acc -> Updates.note_run_changed ~open_run_id:(Some "a") acc ~run_id:"b" in
  Alcotest.(check bool) "a later unrelated run cannot hide the open run" true
    (changed.any && changed.open_run);
  let unrelated = Updates.note_run_changed ~open_run_id:(Some "a") Updates.no_changed_runs ~run_id:"b" in
  Alcotest.(check bool) "an unrelated run only invalidates the list" true
    (unrelated.any && not unrelated.open_run)

let test_list_change_during_read () =
  let state = fresh () in
  state.fusion_mode <- Types.Fusion_detail "a";
  let old = require (Updates.begin_runs state ~demand:Share) in
  Alcotest.(check bool) "changes share the pending read" true
    (Option.is_none (Updates.begin_runs state ~demand:After_change)
     && Option.is_none (Updates.begin_runs state ~demand:After_change));
  check_completion "old snapshot requires a follow-up" Reread
    (Updates.runs_loaded state old (Ok empty_snapshot));
  Alcotest.(check bool) "the old empty snapshot did not close the selected run" true
    (state.fusion_mode = Types.Fusion_detail "a");
  Alcotest.(check bool) "the old snapshot is visibly stale" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Stale (_, _) -> true | _ -> false);
  let current = require (Updates.begin_runs state ~demand:Share) in
  check_completion "old completion cannot settle the newer read" Obsolete
    (Updates.runs_loaded state old (Ok empty_snapshot));
  check_completion "one new response settles the coalesced changes" Applied
    (Updates.runs_loaded state current (Error "fresh failure"));
  Alcotest.(check bool) "the actual new response is visible" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Stale (_, "fresh failure") -> true
     | _ -> false)

let test_detail_change_during_read () =
  let state = fresh () in
  state.fusion_mode <- Types.Fusion_detail "a";
  state.fusion_detail <- Some (detail (run "a" Decode.Fusion_stage_accepted));
  state.fusion_detail_error <- Some "held";
  let old = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  ignore (Updates.begin_detail state ~demand:After_change ~run_id:"a");
  ignore (Updates.begin_detail state ~demand:After_change ~run_id:"a");
  Alcotest.(check bool) "retained detail is stale before the old read returns" true state.fusion_detail_stale;
  Alcotest.(check (option string)) "repeated events do not overwrite the previous failure" (Some "held") state.fusion_detail_error;
  check_completion "detail was invalidated while reading" Reread
    (Updates.detail_loaded state ~generation:old ~run_id:"a" (Error "old"));
  Alcotest.(check (option string)) "old failure remains visible" (Some "old") state.fusion_detail_error;
  let current = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  check_completion "late old detail cannot settle new owner" Obsolete
    (Updates.detail_loaded state ~generation:old ~run_id:"a" (Error "late"));
  check_completion "new detail settles" Applied
    (Updates.detail_loaded state ~generation:current ~run_id:"a" (Error "fresh"));
  Alcotest.(check (option string)) "new result is displayed" (Some "fresh") state.fusion_detail_error;
  Alcotest.(check bool) "failed reread keeps retained detail stale" true state.fusion_detail_stale;
  let recovered = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  check_completion "successful retry settles without another demand" Applied
    (Updates.detail_loaded state ~generation:recovered ~run_id:"a" (Ok (detail (run "a" Decode.Fusion_stage_accepted))));
  Alcotest.(check bool) "successful retry makes detail fresh" false state.fusion_detail_stale

let test_historical_change_during_read () =
  let state = fresh () in
  state.fusion_mode <- Types.Fusion_historical_detail reference;
  state.fusion_historical_detail <- Some historical_detail;
  state.fusion_detail_error <- Some "held";
  let old = require (Updates.begin_historical state ~demand:Share ~reference) in
  ignore (Updates.begin_historical state ~demand:After_change ~reference);
  ignore (Updates.begin_historical state ~demand:After_change ~reference);
  Alcotest.(check bool) "Board original is stale before the old read returns" true state.fusion_historical_detail_stale;
  Alcotest.(check (option string)) "previous error is preserved" (Some "held") state.fusion_detail_error;
  check_completion "historical detail was invalidated" Reread
    (Updates.historical_detail_loaded state ~generation:old ~reference (Error "old"));
  Alcotest.(check (option string)) "old failure remains visible" (Some "old") state.fusion_detail_error;
  let current = require (Updates.begin_historical state ~demand:Share ~reference) in
  check_completion "new historical detail settles" Applied
    (Updates.historical_detail_loaded state ~generation:current ~reference (Error "fresh"));
  Alcotest.(check (option string)) "new result is displayed" (Some "fresh") state.fusion_detail_error;
  Alcotest.(check bool) "failure leaves the Board original stale" true state.fusion_historical_detail_stale;
  let recovered = require (Updates.begin_historical state ~demand:Share ~reference) in
  check_completion "Board retry settles without another demand" Applied
    (Updates.historical_detail_loaded state ~generation:recovered ~reference (Ok historical_detail));
  Alcotest.(check bool) "successful retry makes Board original fresh" false state.fusion_historical_detail_stale

let test_list_is_stale_immediately () =
  let state = fresh () in
  let first = require (Updates.begin_runs state ~demand:Share) in
  check_completion "initial list" Applied (Updates.runs_loaded state first (Ok empty_snapshot));
  let old = require (Updates.begin_runs state ~demand:Share) in
  Alcotest.(check bool) "ordinary refresh retains a fresh value" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Ready _ -> true | _ -> false);
  Alcotest.(check bool) "events coalesce with the existing request" true
    (Option.is_none (Updates.begin_runs state ~demand:After_change)
     && Option.is_none (Updates.begin_runs state ~demand:After_change));
  Alcotest.(check bool) "list becomes stale before old request settles" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Stale (_, _) -> true | _ -> false);
  check_completion "old request schedules one reread" Reread
    (Updates.runs_loaded state old (Error "old failure"));
  let current = require (Updates.begin_runs state ~demand:Share) in
  check_completion "failed reread is settled once" Applied
    (Updates.runs_loaded state current (Error "fresh failure"));
  Alcotest.(check bool) "failed reread retains data and cause" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Stale (_, "fresh failure") -> true | _ -> false);
  let retry = require (Updates.begin_runs state ~demand:After_change) in
  Alcotest.(check bool) "starting a new read preserves the previous failure" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Stale (_, "fresh failure") -> true | _ -> false);
  check_completion "successful retry makes the list fresh" Applied
    (Updates.runs_loaded state retry (Ok empty_snapshot));
  Alcotest.(check bool) "no hidden reread remains" false state.fusion_runs_reread_pending;
  let after_change = require (Updates.begin_runs state ~demand:After_change) in
  Alcotest.(check bool) "a newly started post-change read also marks held rows stale" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Stale (_, _) -> true | _ -> false);
  check_completion "the new read settles normally" Applied
    (Updates.runs_loaded state after_change (Ok empty_snapshot));
  Alcotest.(check bool) "no retained value means no invented stale value" true
    (let empty = fresh () in
     let pending = require (Updates.begin_runs empty ~demand:Share) in
     ignore (Updates.begin_runs empty ~demand:After_change);
     let still_loading = match Fetched.view_for ~equal:Unit.equal empty.fusion_runs ~key:() with
       | Fetched.Loading -> true | _ -> false in
     still_loading && Updates.runs_loaded empty pending (Error "unavailable") = Updates.Reread)

let authorize state =
  let path = Masc.Tui_decode.Canonical_path.of_path in
  state.Types.workspace_identity <- Types.Workspace_identity_match;
  state.server_identity <- Some
    { Masc.Tui_decode.sid_version = "test"; sid_binary_commit = "test"; sid_binary_commit_age_s = None
    ; sid_runtime_instance_id = None
    ; sid_base_path = path "/workspace"; sid_masc_root = path "/workspace/.masc"
    ; sid_executable_in_worktree = None; sid_state_ready = Some true; sid_uptime = None
    ; sid_sse_clients = None; sid_gc = None; sid_scheduler = None; sid_operator_action = None }

let test_observer_open_and_authority () =
  let state = fresh () in
  authorize state;
  state.view <- Types.Fusion;
  state.fusion_mode <- Types.Fusion_detail "a";
  let runs = ref 0 and details = ref [] and historical = ref [] in
  let opened () = Updates.revalidate_visible state
    ~runs:(fun () -> incr runs)
    ~detail:(fun id -> details := id :: !details)
    ~historical:(fun value -> historical := value :: !historical) in
  opened ();
  opened ();
  Alcotest.(check int) "each open, including reconnect, revalidates the list" 2 !runs;
  Alcotest.(check (list string)) "each open revalidates the selected run" [ "a"; "a" ] !details;
  state.fusion_mode <- Types.Fusion_historical_detail reference;
  opened ();
  Alcotest.(check bool) "historical detail is also revalidated" true (!historical = [ reference ]);
  state.workspace_identity <- Types.Workspace_identity_match_unconfirmed "probe failed";
  opened ();
  Alcotest.(check int) "unconfirmed workspace cannot start another read" 3 !runs

let test_workspace_withdrawal_retires_requests () =
  let state = fresh () in
  state.fusion_mode <- Types.Fusion_detail "a";
  let old_list = require (Updates.begin_runs state ~demand:Share) in
  let old_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  ignore (Updates.begin_runs state ~demand:After_change);
  ignore (Updates.begin_detail state ~demand:After_change ~run_id:"a");
  Types.withdraw_fusion_workspace state;
  Alcotest.(check bool) "queued reads retired with the workspace" false
    (state.fusion_runs_reread_pending || state.fusion_detail_reread_pending);
  check_completion "old workspace list cannot apply" Obsolete
    (Updates.runs_loaded state old_list (Ok empty_snapshot));
  check_completion "old workspace detail cannot apply" Obsolete
    (Updates.detail_loaded state ~generation:old_detail ~run_id:"a" (Error "old"))

let test_read_settles_before_observer_opened () =
  let trial observer_result =
    let state = fresh () in
    authorize state;
    state.view <- Types.Fusion;
    state.fusion_mode <- Types.Fusion_detail "a";
    let old_list = require (Updates.begin_runs state ~demand:Share) in
    let old_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
    state.observer <- Types.Observer_opening;
    check_completion "list waits for the subscription outcome" Await_observer
      (Updates.runs_loaded state old_list (Ok empty_snapshot));
    check_completion "detail waits for the subscription outcome" Await_observer
      (Updates.detail_loaded state ~generation:old_detail ~run_id:"a" (Error "before open"));
    Alcotest.(check bool) "pre-subscription absence does not close the run" true
      (state.fusion_mode = Types.Fusion_detail "a");
    state.observer <- observer_result;
    let new_list = ref None and new_detail = ref None in
    Updates.revalidate_visible state
      ~runs:(fun () -> new_list := Updates.begin_runs state ~demand:After_change)
      ~detail:(fun id -> new_detail := Updates.begin_detail state ~demand:After_change ~run_id:id)
      ~historical:(fun _ -> Alcotest.fail "unexpected historical read");
    let a = run "a" Decode.Fusion_stage_accepted in
    check_completion "the post-outcome list can settle" Applied
      (Updates.runs_loaded state (require !new_list) (Ok (snapshot [ a ])));
    check_completion "the post-outcome detail can settle" Applied
      (Updates.detail_loaded state ~generation:(require !new_detail) ~run_id:"a" (Ok (detail a)));
    Alcotest.(check bool) "the selected run survives and fresh detail is shown" true
      (state.fusion_mode = Types.Fusion_detail "a" && state.fusion_detail_error = None)
  in
  trial (Types.Observer_live { session_id = "session"; since = 1.; events = 0 });
  trial (Types.Observer_closed_before_answer { reason = "unavailable"; at = 1. })

let test_repeated_observer_failures_do_not_multiply_reads () =
  let state = fresh () in
  authorize state;
  state.view <- Types.Fusion;
  state.fusion_mode <- Types.Fusion_detail "a";
  let a = run "a" Decode.Fusion_stage_accepted in
  let old_list = require (Updates.begin_runs state ~demand:Share) in
  let old_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  state.observer <- Types.Observer_opening;
  state.observer <- Types.Observer_closed_before_answer { reason = "refused"; at = 1. };
  let runs = ref 0 and details = ref 0 and next_list = ref None and next_detail = ref None in
  let failed () = Updates.observer_failed state
    ~runs:(fun () -> incr runs; next_list := Updates.begin_runs state ~demand:Share)
    ~detail:(fun id -> incr details; next_detail := Updates.begin_detail state ~demand:Share ~run_id:id)
    ~historical:(fun _ -> Alcotest.fail "unexpected historical read") in
  List.iter (fun () -> failed ()) [ (); (); () ];
  Alcotest.(check (pair int int)) "failed reconnect shares existing reads" (0, 0) (!runs, !details);
  check_completion "existing list settles" Applied
    (Updates.runs_loaded state old_list (Ok (snapshot [ a ])));
  check_completion "existing detail settles" Applied
    (Updates.detail_loaded state ~generation:old_detail ~run_id:"a" (Ok (detail a)));
  failed ();
  Alcotest.(check (pair int int)) "idle failure alone schedules nothing" (0, 0) (!runs, !details);
  (* A reading that settled while the subscription was opening and carries
     what is open is applied as it arrived, so the subscription failing has
     nothing left to read. *)
  state.observer <- Types.Observer_opening;
  let clean_list = require (Updates.begin_runs state ~demand:Share) in
  let clean_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  check_completion "clean list settled while opening" Applied
    (Updates.runs_loaded state clean_list (Ok (snapshot [ a ])));
  check_completion "clean detail settled while opening" Applied
    (Updates.detail_loaded state ~generation:clean_detail ~run_id:"a" (Ok (detail a)));
  state.observer <- Types.Observer_closed_before_answer { reason = "refused again"; at = 2. };
  List.iter (fun () -> failed ()) [ (); (); () ];
  Alcotest.(check (pair int int)) "clean readings are not read again" (0, 0) (!runs, !details);
  (* A reading that failed while opening cannot be trusted yet: one read per
     such projection once the subscription fails, and no loop after it. *)
  state.observer <- Types.Observer_opening;
  let waiting_list = require (Updates.begin_runs state ~demand:Share) in
  let waiting_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  check_completion "failed list settled while opening" Await_observer
    (Updates.runs_loaded state waiting_list (Error "before open"));
  check_completion "failed detail settled while opening" Await_observer
    (Updates.detail_loaded state ~generation:waiting_detail ~run_id:"a" (Error "before open"));
  state.observer <- Types.Observer_closed_before_answer { reason = "refused once more"; at = 3. };
  List.iter (fun () -> failed ()) [ (); (); () ];
  Alcotest.(check (pair int int)) "one read per actually waiting projection" (1, 1) (!runs, !details);
  check_completion "resumed list settles" Applied
    (Updates.runs_loaded state (require !next_list) (Ok (snapshot [ a ])));
  check_completion "resumed detail settles" Applied
    (Updates.detail_loaded state ~generation:(require !next_detail) ~run_id:"a" (Ok (detail a)));
  failed ();
  Alcotest.(check (pair int int)) "no follow-up loop after settling" (1, 1) (!runs, !details)

let test_superseded_selection () =
  let setup () =
    let state = fresh () in
    state.view <- Types.Fusion;
    state.keepers <- [ { Masc.Tui_decode.k_origin = Persisted_keeper; k_name = "analyst"
                       ; k_paused = false; k_identity = Error (Masc.Tui_decode.Identity_unreadable "fixture"); k_activity = None } ];
    let a = run "a" Decode.Fusion_stage_accepted in
    let b = run "b" Decode.Fusion_stage_accepted in
    let c = run "c" Decode.Fusion_stage_accepted in
    let first = require (Updates.begin_runs state ~demand:Share) in
    check_completion "initial list" Applied
      (Updates.runs_loaded state first (Ok (snapshot [ a; b; c ])));
    state.fusion_cursor <- 0;
    state.keeper_run_cursor <- 1;
    let old = require (Updates.begin_runs state ~demand:Share) in
    ignore (Updates.begin_runs state ~demand:After_change);
    check_completion "missing rows in overtaken list" Reread
      (Updates.runs_loaded state old (Ok (snapshot [ c ])));
    state, a, b, c
  in
  let selected state =
    Option.bind (Model.selected_fusion_entry state) (function
      | Decode.Fusion_retained_run run -> Some run.fur_run_id
      | Decode.Fusion_historical_evidence _ -> None) in
  let selected_keeper state =
    Option.map (fun (_, run) -> run.Decode.fur_run_id) (Model.selected_keeper_run state) in
  let state, a, b, c = setup () in
  Alcotest.(check (option string)) "selected list row retained as stale" (Some "a") (selected state);
  Alcotest.(check (option string)) "selected keeper row retained as stale" (Some "b") (selected_keeper state);
  let current = require (Updates.begin_runs state ~demand:Share) in
  check_completion "fresh list" Applied
    (Updates.runs_loaded state current (Ok (snapshot [ b; a; c ])));
  Alcotest.(check (option string)) "selected list row restored" (Some "a") (selected state);
  Alcotest.(check (option string)) "selected keeper row restored" (Some "b") (selected_keeper state);
  let state, a, b, c = setup () in
  state.fusion_cursor <- 0;
  state.keeper_run_cursor <- 0;
  let current = require (Updates.begin_runs state ~demand:Share) in
  check_completion "fresh list after a deliberate move" Applied
    (Updates.runs_loaded state current (Ok (snapshot [ b; a; c ])));
  Alcotest.(check (option string)) "operator's new list selection wins" (Some "c") (selected state);
  Alcotest.(check (option string)) "operator's new keeper selection wins" (Some "c") (selected_keeper state)

let test_reentry_queues_reads () =
  let state = fresh () in
  authorize state;
  state.view <- Types.Fusion;
  state.fusion_mode <- Types.Fusion_detail "a";
  let old_list = require (Updates.begin_runs state ~demand:Share) in
  let old_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  state.view <- Types.Overview;
  (* Events while hidden are not consumed by the Fusion view. Re-entry asks
     for a post-entry answer even if the old requests are still in flight. *)
  state.view <- Types.Fusion;
  Updates.revalidate_visible state
    ~runs:(fun () -> ignore (Updates.begin_runs state ~demand:After_change))
    ~detail:(fun id -> ignore (Updates.begin_detail state ~demand:After_change ~run_id:id))
    ~historical:(fun _ -> Alcotest.fail "unexpected historical read");
  check_completion "re-entry queues the list" Reread
    (Updates.runs_loaded state old_list (Ok empty_snapshot));
  check_completion "re-entry queues the detail" Reread
    (Updates.detail_loaded state ~generation:old_detail ~run_id:"a" (Error "old"));
  let current = require (Updates.begin_runs state ~demand:Share) in
  state.view <- Types.Keepers Keeper_detail;
  state.detail_tab <- Types.Detail_runs;
  Updates.revalidate_visible state
    ~runs:(fun () -> ignore (Updates.begin_runs state ~demand:After_change))
    ~detail:(fun _ -> Alcotest.fail "unexpected detail read")
    ~historical:(fun _ -> Alcotest.fail "unexpected historical read");
  check_completion "Keeper Runs re-entry also queues the list" Reread
    (Updates.runs_loaded state current (Ok empty_snapshot))

let test_open_detail_after_list_read_starts () =
  let state = fresh () in
  state.view <- Types.Fusion;
  let old = require (Updates.begin_runs state ~demand:Share) in
  state.fusion_mode <- Types.Fusion_detail "a";
  check_completion "older list cannot decide whether the new detail exists" Reread
    (Updates.runs_loaded state old (Ok empty_snapshot));
  Alcotest.(check bool) "newly opened detail stays open" true
    (state.fusion_mode = Types.Fusion_detail "a");
  let current = require (Updates.begin_runs state ~demand:Share) in
  let a = run "a" Decode.Fusion_stage_accepted in
  check_completion "read begun after navigation settles" Applied
    (Updates.runs_loaded state current (Ok (snapshot [ a ])))

let test_launch_queues_follow_up () =
  let state = fresh () in
  let old = require (Updates.begin_runs state ~demand:Share) in
  let options : Decode.fusion_launch_options =
    { flo_enabled = true; flo_default_preset = "trio"; flo_presets = [ "trio" ] } in
  let form = match Launch.open_form ~keepers:[ "analyst" ] ~keeper:None ~options with
    | Ok form -> form | Error detail -> Alcotest.fail detail in
  let editing form key = match Launch.edit ~key form with
    | Launch.Editing form -> form | _ -> Alcotest.fail "expected form editing" in
  let form = List.fold_left editing form [ "tab"; "tab"; "tab" ] in
  let form = Launch.paste ~text:"why" form |> fun form -> editing form "\019" in
  let waiting = match Launch.edit ~key:"enter" form with
    | Launch.Submitted (form, _) -> form | _ -> Alcotest.fail "expected form submission" in
  state.fusion_launch <- Some (Types.Fusion_launch_open waiting);
  state.fusion_launch_generation <- 1;
  Updates.launched state ~generation:1 ~report:ignore
    ~refresh:(fun () -> ignore (Updates.begin_runs state ~demand:After_change)) (Ok "new-run");
  check_completion "a launch after the old read queues a fresh read" Reread
    (Updates.runs_loaded state old (Ok empty_snapshot));
  Alcotest.(check bool) "old list did not consume the started-run wait" true
    (match state.fusion_launch with Some (Types.Fusion_launch_started run) ->
       run.fls_run_id = "new-run" && run.fls_reads_left = Types.fusion_started_list_reads
     | _ -> false)

let test_continuous_multi_run_changes_make_progress () =
  let state = fresh () in
  state.fusion_mode <- Types.Fusion_detail "a";
  let signal events =
    let changes = List.fold_left (fun changed id ->
      Updates.note_run_changed ~open_run_id:(Some "a") changed ~run_id:id)
        Updates.no_changed_runs events in
    if changes.any then ignore (Updates.begin_runs state ~demand:After_change);
    if changes.open_run then ignore (Updates.begin_detail state ~demand:After_change ~run_id:"a") in
  let first_list = require (Updates.begin_runs state ~demand:Share) in
  let first_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  signal [ "a"; "b" ];
  let a1 = run "a" Decode.Fusion_stage_accepted in
  let b1 = run "b" Decode.Fusion_stage_accepted in
  check_completion "first list schedules the newer read" Reread
    (Updates.runs_loaded state first_list (Ok (snapshot [ a1; b1 ])));
  check_completion "a before b still schedules its detail" Reread
    (Updates.detail_loaded state ~generation:first_detail ~run_id:"a" (Ok (detail a1)));
  let next_list = require (Updates.begin_runs state ~demand:Share) in
  let next_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  signal [ "b"; "a" ];
  let a2 = run "a" (Decode.Fusion_stage_panel { frs_expected = 3 }) in
  check_completion "another event does not stop list progress" Reread
    (Updates.runs_loaded state next_list (Ok (snapshot [ b1; a2 ])));
  check_completion "another event does not stop detail progress" Reread
    (Updates.detail_loaded state ~generation:next_detail ~run_id:"a" (Ok (detail a2)));
  Alcotest.(check bool) "newer stage is visible but stale" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:() with
     | Fetched.Stale ({ fus_runs = [ _; run ]; _ }, _) -> run.fur_stage = a2.fur_stage
     | _ -> false);
  Alcotest.(check bool) "detail also progresses and remains marked stale" true
    (match state.fusion_detail, state.fusion_detail_stale with
     | Some detail, true -> detail.fud_run.fur_stage = a2.fur_stage
     | _ -> false);
  Alcotest.(check bool) "reordering preserves the open run and its cursor" true
    (state.fusion_mode = Types.Fusion_detail "a" && state.fusion_cursor = 1);
  let final_list = require (Updates.begin_runs state ~demand:Share) in
  let final_detail = require (Updates.begin_detail state ~demand:Share ~run_id:"a") in
  check_completion "quiescent list is authoritative" Applied
    (Updates.runs_loaded state final_list (Ok (snapshot [ b1; a2 ])));
  check_completion "quiescent detail is authoritative" Applied
    (Updates.detail_loaded state ~generation:final_detail ~run_id:"a" (Ok (detail a2)));
  Alcotest.(check bool) "final list and detail are no longer stale" true
    (match Fetched.view_for ~equal:Unit.equal state.fusion_runs ~key:(), state.fusion_detail_error with
     | Fetched.Ready _, None -> not state.fusion_detail_stale | _ -> false)

let () =
  Alcotest.run "tui_fusion_refresh"
    [ "demand", [
        Alcotest.test_case "batch retains open run" `Quick test_batch_preserves_open_run;
        Alcotest.test_case "list changes during read" `Quick test_list_change_during_read;
        Alcotest.test_case "list becomes stale immediately" `Quick test_list_is_stale_immediately;
        Alcotest.test_case "detail changes during read" `Quick test_detail_change_during_read;
        Alcotest.test_case "historical changes during read" `Quick test_historical_change_during_read;
        Alcotest.test_case "observer opens and authority" `Quick test_observer_open_and_authority;
        Alcotest.test_case "workspace withdrawal" `Quick test_workspace_withdrawal_retires_requests;
        Alcotest.test_case "read before observer outcome" `Quick test_read_settles_before_observer_opened;
        Alcotest.test_case "observer failures coalesce" `Quick test_repeated_observer_failures_do_not_multiply_reads;
        Alcotest.test_case "superseded selection" `Quick test_superseded_selection;
        Alcotest.test_case "surface re-entry" `Quick test_reentry_queues_reads;
        Alcotest.test_case "detail opened during list read" `Quick test_open_detail_after_list_read_starts;
        Alcotest.test_case "launch during list read" `Quick test_launch_queues_follow_up;
        Alcotest.test_case "continuous multi-run changes" `Quick test_continuous_multi_run_changes_make_progress;
      ] ]
