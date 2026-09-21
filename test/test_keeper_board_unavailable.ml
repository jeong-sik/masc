(* Board-unavailable-result — keeper_world_observation_board_signal's
   [Board_unavailable] exception (and [raise_unavailable]) were removed in
   favor of an explicit [(_, board_unavailable) result] contract.

   Incident this replaces: [Board_dispatch.get_post] returning
   [Post_not_found] (a post swept from the in-memory store — permanent) was
   modeled as a transient exception. Nothing on the stimulus-intake path
   caught it, so it crashed the keeper heartbeat cycle via the generic
   handler in [keeper_heartbeat_loop.ml], the lease was requeued as
   [Cycle_crashed], and the SAME poisoned stimulus re-crashed every
   heartbeat forever.

   These tests pin:
   1. [disposition_of_error] classifies every [Board.board_error] variant —
      the compiler enforces exhaustiveness, this test pins the actual table.
   2. the incident's exact shape (a stimulus naming a post_id that was never
      created) no longer raises, is reported as [Error unavailable]
      classified [Permanent], and the stimulus-intake layer consumes it
      without crashing — stable across a second pass, unlike the old
      exception-based loop.
   3. a transient read failure is not collapsed into the permanent-consume
      path: the exact queue selection remains pending and provider dispatch
      is blocked until a later intake can render it.
   4. a queued comment keeps its own author and body after later replies.
   5. Board replay routes exact replies instead of historical participation. *)

open Alcotest
open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

(** Temp directory for test isolation — set before any Board.global call
    (mirrors test_board_dispatch.ml's [fresh_test_base_path]). *)
let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-unavailable-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let with_eio f () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  f ()
;;

let test_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "trace_id", `String ("trace-" ^ name)
         ])
  with
  | Ok meta -> meta
  | Error message -> Alcotest.failf "test meta failed: %s" message
;;

(* (1) Exhaustive classification, pinned. A future new [Board.board_error]
   variant forces [disposition_of_error] to grow (compiler-enforced); this
   test pins today's actual poison/transient split so a change to the table
   is a deliberate, reviewed diff rather than a silent behavior change. *)
let test_disposition_of_error_classifies_every_variant () =
  let module BS = Keeper_world_observation_board_signal in
  let is_permanent err = BS.disposition_of_error err = BS.Permanent in
  let is_transient err = BS.disposition_of_error err = BS.Transient in
  check bool "Post_not_found is permanent (post swept, never resolves on retry)" true
    (is_permanent (Board.Post_not_found "p"));
  check bool "Comment_not_found is permanent (same argument, for a comment id)" true
    (is_permanent (Board.Comment_not_found "c"));
  check bool "Invalid_id is permanent (malformed id string never becomes valid)" true
    (is_permanent (Board.Invalid_id "bad id"));
  check bool "Io_error is transient (store/disk hiccup, retry may succeed)" true
    (is_transient (Board.Io_error "disk hiccup"));
  check bool "Validation_error is permanent (deterministic input-validation failure)" true
    (is_permanent (Board.Validation_error "x"));
  check bool "Already_voted is permanent (deterministic action conflict)" true
    (is_permanent (Board.Already_voted "x"));
  check bool "Already_exists is permanent (deterministic conflict)" true
    (is_permanent (Board.Already_exists "x"));
  check bool "Unauthorized is permanent (deterministic identity rejection)" true
    (is_permanent (Board.Unauthorized "x"))
;;

let poison_post_id = "nonexistent-post-poison-test"

let transient_unavailable post_id :
  Keeper_world_observation_board_signal.board_unavailable
  =
  { operation = Keeper_world_observation_board_signal.Get_post
  ; post_id
  ; error = Board.Io_error "forced transient board read failure"
  }
;;

(* A [Board_signal] stimulus naming a post_id that was never created in this
   test's isolated JSONL store — the exact shape of the reported incident
   (post swept from the store between the signal firing and the keeper
   consuming it). *)
let poison_board_signal_stimulus () : Keeper_event_queue.stimulus =
  { Keeper_event_queue.post_id = poison_post_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = Time_compat.now ()
  ; payload =
      Keeper_event_queue.Board_signal
        { kind = Keeper_event_queue.Post_created
        ; author = "external-author"
        ; title = "poison stimulus"
        ; content = "references a post_id that was never created"
        ; hearth = None
        ; updated_at = Some (Time_compat.now ())
        }
  }
;;

(* (2) [pending_board_event_of_stimulus] must report the failed board read
   as [Error unavailable] — never raise — and it must classify [Permanent],
   the dominant real crash-loop cause. *)
let test_poison_stimulus_reports_permanent_error () =
  let meta = test_meta "poison-report" in
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta
      (poison_board_signal_stimulus ())
  with
  | Ok _ -> fail "a stimulus naming a nonexistent post must not resolve to Ok"
  | Error unavailable ->
    check
      bool
      "post_id names the missing post"
      true
      (String.equal
         unavailable.Keeper_world_observation_board_signal.post_id
         poison_post_id);
    check
      bool
      "classifies Permanent (masc keeper-cycle-exception incident cause)"
      true
      (Keeper_world_observation_board_signal.disposition_of_unavailable unavailable
       = Keeper_world_observation_board_signal.Permanent)
;;

(* (3) The stimulus-intake layer is where the crash actually happened:
   [Board_signal.raise_unavailable] propagated past every catch site up to
   [keeper_heartbeat_loop.ml]'s generic exception handler, which requeued
   the lease as [Cycle_crashed] — so the SAME poisoned stimulus re-crashed
   the keeper heartbeat every cycle forever. This pins the fix: the intake
   helper must not raise, must return [], and a second pass over the same
   stimulus (simulating the next heartbeat cycle re-leasing the same
   durable stimulus) must ALSO return [] — the counterfactual for the old
   loop, which would have crashed again here instead. *)
let test_poison_stimulus_intake_does_not_crash_and_stays_dropped () =
  let meta = test_meta "poison-intake" in
  let stim = poison_board_signal_stimulus () in
  let first_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result
      ~meta_after_triage:meta
      stim
  in
  (match first_pass with
   | Keeper_heartbeat_stimulus_intake.Stimulus_consumed events ->
     check
       int
       "first pass produces no pending_board_event (consumed, not crashed)"
       0
       (List.length events)
   | Keeper_heartbeat_stimulus_intake.Stimulus_retry_later unavailable ->
     failf
       "permanent poison stimulus was incorrectly retained: %s"
       (Keeper_world_observation_board_signal.unavailable_to_string unavailable));
  let second_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result
      ~meta_after_triage:meta
      stim
  in
  match second_pass with
  | Keeper_heartbeat_stimulus_intake.Stimulus_consumed events ->
    check
      int
      "second pass over the same stimulus stays empty (no crash-loop resurgence)"
      0
      (List.length events)
  | Keeper_heartbeat_stimulus_intake.Stimulus_retry_later unavailable ->
    failf
      "permanent poison stimulus was incorrectly retained on repeat: %s"
      (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
;;

let test_poison_durable_source_is_retired_during_intake () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = fresh_test_base_path () in
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let meta = test_meta "poison-durable" in
  let config = Workspace.default_config base_path in
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "board-unavailable-test"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
  let stimulus = poison_board_signal_stimulus () in
  (match
     Keeper_registry_event_queue.enqueue_durable_result
       ~base_path
       meta.name
       stimulus
   with
   | Ok () -> ()
   | Error message -> failf "failed to seed durable poison: %s" message);
  let intake =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  check int "no empty source is offered to a provider turn" 0
    (Keeper_heartbeat_source_batch.count intake.source_batch);
  check int "no fabricated Board observation is returned" 0
    (List.length intake.pending_board_events);
  check bool "permanent retirement is not an intake error" true
    (Option.is_none intake.event_queue_intake_error);
  let queued =
    match Keeper_registry_event_queue.snapshot_result ~base_path meta.name with
    | Ok queue -> queue
    | Error message -> failf "failed to reload durable queue: %s" message
  in
  check int "the permanently unavailable durable source is acknowledged" 0
    (Keeper_event_queue.length queued)
;;

let test_transient_result_is_retryable () =
  let unavailable = transient_unavailable "transient-classification" in
  match
    Keeper_heartbeat_stimulus_intake.classify_pending_board_event_result
      (Error unavailable)
  with
  | Keeper_heartbeat_stimulus_intake.Stimulus_retry_later actual ->
    check
      string
      "retry retains exact post id"
      unavailable.post_id
      actual.post_id
  | Keeper_heartbeat_stimulus_intake.Stimulus_consumed _ ->
    fail "transient board read was collapsed into consumed"
;;

let test_transient_intake_retains_pending_source_and_blocks_dispatch () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = fresh_test_base_path () in
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 0;
      Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let meta = test_meta "transient-intake" in
  let config = Workspace.default_config base_path in
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "board-unavailable-test"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  ignore
    (Keeper_registry.For_testing.register
       ~base_path
       meta.name
       meta);
  let post =
    match
      Board_dispatch.create_post
        ~author:"external-author"
        ~content:"transient source remains available after retry"
        ~post_kind:Board.Human_post
        ~visibility:Board.Internal
        ()
    with
    | Ok post -> post
    | Error error ->
      failf "failed to create retryable Board source: %s" (Board.show_board_error error)
  in
  let stimulus =
    { (poison_board_signal_stimulus ()) with
      post_id = Board.Post_id.to_string post.id
    }
  in
  (match
     Keeper_registry_event_queue.enqueue_durable_result
       ~base_path
       meta.name
       stimulus
   with
   | Ok () -> ()
   | Error message -> failf "failed to seed durable stimulus: %s" message);
  Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 1;
  let intake =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  check int "transient source is not counted consumed" 0 (Keeper_heartbeat_source_batch.count intake.source_batch);
  check int "transient source is not exposed as consumed" 0
    (List.length (Keeper_heartbeat_source_batch.stimuli intake.source_batch));
  check bool "exact pending selection remains attached" true
    (Option.is_some intake.diagnostic_selection);
  let diagnostic_input = Keeper_heartbeat_source_batch.for_turn ~reactive:true intake.source_batch in
  check bool "diagnostic is not transported as admitted work" true
    (Keeper_heartbeat_source_batch.selections
       (Keeper_heartbeat_source_batch.sources diagnostic_input) = []);
  (match Keeper_heartbeat_source_batch.wake diagnostic_input with
   | Keeper_registry.Woken [] -> ()
   | _ -> fail "withdrawn diagnostic became an admitted wake payload");
  (match Keeper_heartbeat_source_batch.wake
           (Keeper_heartbeat_source_batch.for_turn ~reactive:false intake.source_batch) with
   | Keeper_registry.Proactive_tick -> ()
   | _ -> fail "empty cadence input became reactive");
  (match intake.event_queue_intake_error with
   | Some
       (Keeper_heartbeat_stimulus_intake.Transient_board_read unavailable) ->
     check string "retry retains the exact source post id" stimulus.post_id
       unavailable.post_id;
     check bool "transient retry is not a crashed cycle" false
       (Keeper_heartbeat_stimulus_intake
        .event_queue_intake_error_counts_as_cycle_failure
          (Keeper_heartbeat_stimulus_intake.Transient_board_read unavailable))
   | Some error ->
     failf
       "expected transient Board retry, got %s"
       (Keeper_heartbeat_stimulus_intake.event_queue_intake_error_to_string
          error)
   | None -> fail "transient intake error was lost");
  check
    bool
    "provider dispatch is blocked while source rendering is transiently unavailable"
    false
    (Keeper_heartbeat_loop.should_run_turn_after_event_intake
       ~scheduled:true
       ~consumed_stimulus_count:(Keeper_heartbeat_source_batch.count intake.source_batch)
       ~event_queue_intake_error:intake.event_queue_intake_error);
  let queued =
    match Keeper_registry_event_queue.snapshot_result ~base_path meta.name with
    | Ok queue -> queue
    | Error message -> failf "failed to reload durable queue: %s" message
  in
  check int "durable source remains pending for the next heartbeat" 1
    (Keeper_event_queue.length queued);
  let retry_intake =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  check int "later successful read consumes the retained source" 1
    (Keeper_heartbeat_source_batch.count retry_intake.source_batch);
  check int "later successful read renders the exact Board event" 1
    (List.length retry_intake.pending_board_events);
  check bool "retry clears the typed intake error" true
    (Option.is_none retry_intake.event_queue_intake_error);
  (match Keeper_heartbeat_source_batch.first retry_intake.source_batch with
   | None -> fail "successful retry lost its exact pending selection"
   | Some selection ->
     (match
        Keeper_registry_event_queue.ack_pending_result
          ~base_path
          meta.name
          ~selection
      with
      | Ok () -> ()
      | Error message -> failf "failed to acknowledge successful retry: %s" message));
  let settled =
    match Keeper_registry_event_queue.snapshot_result ~base_path meta.name with
    | Ok queue -> queue
    | Error message -> failf "failed to reload settled queue: %s" message
  in
  check int "successful retry can settle the exact source" 0
    (Keeper_event_queue.length settled)
;;

(* Actual Board and durable queue stores, with only transient reads controlled.
   The configured admission limit bounds the sources carried by one turn. Explicit
   ACKs below settle the selected source between ticks; these cases do not run
   a provider or claim that a full Keeper turn completed. *)
let with_intake_sources ~max_events f =
  Masc_test_deps.with_process_env "MASC_KEEPER_ADMISSION_MAX_EVENTS"
    (Some (string_of_int max_events))
  @@ fun () ->
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run
  @@ fun sw ->
  let base_path = fresh_test_base_path () in
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ();
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 0;
      Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let meta = test_meta "transient-head" in
  let config = Workspace.default_config base_path in
  let ctx : _ Keeper_types_profile.context =
    { config
    ; agent_name = "board-unavailable-test"
    ; sw
    ; clock = Eio.Stdenv.clock env
    ; proc_mgr = None
    ; net = None
    ; publication_recovery_provider =
        Masc_test_deps.non_runtime_publication_recovery_provider
    }
  in
  ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
  let create_source label =
    match
      Board_dispatch.create_post ~author:"external-author" ~content:label
        ~post_kind:Board.Human_post ~visibility:Board.Internal ()
    with
    | Ok post -> Board.Post_id.to_string post.id
    | Error error -> failf "failed to create Board source: %s" (Board.show_board_error error)
  in
  let seed stimulus =
    match Keeper_registry_event_queue.enqueue_durable_result ~base_path meta.name stimulus with
    | Ok () -> ()
    | Error message -> failf "failed to seed durable stimulus: %s" message
  in
  let seed_board label =
    let post_id = create_source label in
    seed { (poison_board_signal_stimulus ()) with post_id };
    post_id
  in
  let intake () =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx ~meta_after_triage:meta ~pending_board_events:[]
  in
  let pending () =
    match Keeper_registry_event_queue.pending_selections_result ~base_path meta.name with
    | Ok selections -> selections
    | Error message -> failf "failed to reload durable selections: %s" message
  in
  let ack selection =
    match Keeper_registry_event_queue.ack_pending_result ~base_path meta.name ~selection with
    | Ok () -> ()
    | Error message -> failf "failed to acknowledge selected source: %s" message
  in
  f ~seed ~seed_board ~intake ~pending ~ack
;;

let admitted_ids intake =
  Keeper_heartbeat_source_batch.stimuli intake.Keeper_heartbeat_stimulus_intake.source_batch
  |> List.map (fun (stimulus : Keeper_event_queue.stimulus) -> stimulus.post_id)
;;

let check_withdrawn_head expected intake =
  match intake.Keeper_heartbeat_stimulus_intake.event_queue_intake_error with
  | Some (Keeper_heartbeat_stimulus_intake.Transient_board_read unavailable) ->
    check string "the first transient source stays diagnostic" expected unavailable.post_id
  | Some error ->
    failf "expected transient Board retry, got %s"
      (Keeper_heartbeat_stimulus_intake.event_queue_intake_error_to_string error)
  | None -> fail "the transient head error disappeared"
;;

let test_transient_head_does_not_block_the_entry_behind_it () =
  with_intake_sources ~max_events:1 @@ fun ~seed:_ ~seed_board ~intake ~pending ~ack ->
  let head = seed_board "head source, read fails transiently" in
  let second = seed_board "second source, read succeeds" in
  let third = seed_board "third source waits for the next admission" in
  let read_behind_head expected =
    Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 1;
    let selected = intake () in
    check (list string) "only the next readable source is admitted under limit1"
      [ expected ] (admitted_ids selected);
    check (list string) "unadmitted sources are not projected"
      [ expected ]
      (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.post_id)
         selected.pending_board_events);
    check_withdrawn_head head selected;
    check bool "the readable source permits provider dispatch" true
      (Keeper_heartbeat_loop.should_run_turn_after_event_intake ~scheduled:true
         ~consumed_stimulus_count:(Keeper_heartbeat_source_batch.count selected.source_batch)
         ~event_queue_intake_error:selected.event_queue_intake_error);
    selected
  in
  let first_tick = read_behind_head second in
  check int "intake leaves every source durable" 3 (List.length (pending ()));
  List.iter ack (Keeper_heartbeat_source_batch.selections first_tick.source_batch);
  let second_tick = read_behind_head third in
  check int "only the explicit first ACK removed a source" 2 (List.length (pending ()));
  List.iter ack (Keeper_heartbeat_source_batch.selections second_tick.source_batch);
  let third_tick = intake () in
  check (list string) "the recovered head is still available on the next tick"
    [ head ] (admitted_ids third_tick);
  check bool "recovery clears the diagnostic" true
    (Option.is_none third_tick.event_queue_intake_error)
;;

let test_all_transient_reads_finish_without_changing_pending () =
  with_intake_sources ~max_events:1 @@ fun ~seed:_ ~seed_board ~intake ~pending ~ack:_ ->
  let first = seed_board "first unavailable source" in
  let (_ : string) = seed_board "second unavailable source" in
  let (_ : string) = seed_board "third unavailable source" in
  let before = pending () in
  Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 3;
  let failed = intake () in
  check (list string) "all unavailable sources return without admission" [] (admitted_ids failed);
  check_withdrawn_head first failed;
  check bool "every exact pending selection is unchanged" true (before = pending ());
  (* All three forced failures were consumed by one finite snapshot walk.
     The next call can render the first source, without resetting the hook. *)
  let recovered = intake () in
  check (list string) "a later tick starts again at the retained head"
    [ first ] (admitted_ids recovered);
  check bool "the later tick has no remaining forced failure" true
    (Option.is_none recovered.event_queue_intake_error)
;;

let test_transient_sources_do_not_spend_the_admission_limit () =
  with_intake_sources ~max_events:2 @@ fun ~seed:_ ~seed_board ~intake ~pending ~ack:_ ->
  let first = seed_board "first source unavailable" in
  let second = seed_board "second source readable" in
  let third = seed_board "third source readable" in
  let (_ : string) = seed_board "fourth source waits for the next admission" in
  Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 1;
  let selected = intake () in
  check (list string) "readable sources fill the existing admission limit"
    [ second; third ] (admitted_ids selected);
  check (list string) "only admitted sources are projected"
    [ second; third ]
    (List.map (fun (event : Keeper_world_observation.pending_board_event) -> event.post_id)
       selected.pending_board_events);
  check_withdrawn_head first selected;
  check int "all four sources remain pending until their own ACK" 4 (List.length (pending ()))
;;

let test_empty_observation_source_still_spends_an_admission_slot () =
  with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board ~intake ~pending:_ ~ack:_ ->
  let bootstrap =
    { (poison_board_signal_stimulus ()) with
      post_id = "bootstrap-limit"; payload = Keeper_event_queue.Bootstrap }
  in
  seed bootstrap;
  let (_ : string) = seed_board "must not join the Bootstrap turn at limit1" in
  let selected = intake () in
  check (list string) "Bootstrap is admitted despite producing no Board observation"
    [ bootstrap.post_id ] (admitted_ids selected);
  check int "the later source was not rendered" 0 (List.length selected.pending_board_events)
;;

let test_permanent_absence_does_not_spend_an_admission_slot () =
  with_intake_sources ~max_events:1 @@ fun ~seed ~seed_board ~intake ~pending ~ack:_ ->
  seed (poison_board_signal_stimulus ());
  let readable = seed_board "readable source after permanently absent post" in
  let selected = intake () in
  check (list string) "a retired poison does not block a readable source"
    [ readable ] (admitted_ids selected);
  check int "only permanent absence is ACKed during intake" 1 (List.length (pending ()))
;;

(* Comments are ordered by [created_at], and by random id when two share it,
   so each post and comment lands strictly after the one before to keep the
   thread in the order this test writes it. *)
let write_spacing_seconds = 0.01

let create_thread ~title content =
  Unix.sleepf write_spacing_seconds;
  match
    Board_dispatch.create_post
      ~author:"external-author"
      ~content
      ~title
      ~post_kind:Board.Human_post
      ()
  with
  | Ok post -> Board.Post_id.to_string post.id
  | Error error -> failf "post: %s" (Board.show_board_error error)
;;

let add_comment ~post_id ~author content =
  Unix.sleepf write_spacing_seconds;
  match Board_dispatch.add_comment ~post_id ~author ~content () with
  | Ok comment -> Board.Comment_id.to_string comment.id
  | Error error -> failf "comment: %s" (Board.show_board_error error)
;;

let comment_event ~meta ~post_id ~comment_id ~author content =
  let stimulus : Keeper_event_queue.stimulus =
    { Keeper_event_queue.post_id
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = Time_compat.now ()
    ; payload =
        Keeper_event_queue.Board_signal
          { kind = Keeper_event_queue.Comment_added { comment_id; parent_id = None }
          ; author
          ; title = "thread"
          ; content
          ; hearth = None
          ; updated_at = Some (Time_compat.now ())
          }
    }
  in
  match Keeper_world_observation.pending_board_event_of_stimulus ~meta stimulus with
  | Error unavailable ->
    failf
      "comment event read failed: %s"
      (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
  | Ok None -> fail "a comment stimulus produced no event"
  | Ok (Some event) -> event
;;

let test_queued_comment_keeps_its_author_and_body () =
  let meta = test_meta "queued-reader" in
  let post_id = create_thread ~title:"thread" "thread topic" in
  ignore (add_comment ~post_id ~author:meta.name "earlier participation" : string);
  let first = add_comment ~post_id ~author:"first-author" "first reply" in
  ignore (add_comment ~post_id ~author:"later-author" "later reply" : string);
  let event = comment_event ~meta ~post_id ~comment_id:first ~author:"first-author" "first reply" in
  check (option string) "queued author" (Some "first-author") event.latest_external_author;
  check (option string) "queued body" (Some "first reply") event.latest_external_preview;
  check bool "unrelated later replies are not attached" true
    (Option.is_none event.replies_after_own_comment)
;;

let test_board_replay_routes_exact_replies () =
  let base_path = Sys.getenv "MASC_BASE_PATH" in
  let poster = test_meta "reply-poster" in
  let parent_author = test_meta "reply-parent" in
  let bystander = test_meta "reply-bystander" in
  Keeper_registry.For_testing.clear ();
  Fun.protect ~finally:(fun () -> Keeper_registry.For_testing.clear ())
  @@ fun () ->
  let post_id =
    match Board_dispatch.create_post ~author:poster.name ~content:"thread topic"
            ~title:"thread" ~post_kind:Board.Human_post () with
    | Ok post -> Board.Post_id.to_string post.id
    | Error error -> fail (Board.show_board_error error)
  in
  let parent_id = add_comment ~post_id ~author:parent_author.name "parent comment" in
  ignore (add_comment ~post_id ~author:bystander.name "past participation" : string);
  let metas = [poster; parent_author; bystander] in
  List.iter (fun (meta : Keeper_meta_contract.keeper_meta) ->
    ignore (Keeper_registry.For_testing.register ~base_path meta.name meta);
    ignore (Keeper_world_observation.collect_board_events ~base_path ~meta)) metas;
  let collect meta =
    let events, _, _ = Keeper_world_observation.collect_board_events ~base_path ~meta in events
  in
  ignore (add_comment ~post_id ~author:"external" "top-level comment" : string);
  check int "post author receives top-level reply on own post" 1 (List.length (collect poster));
  check int "past parent author does not receive unrelated reply" 0 (List.length (collect parent_author));
  check int "past participant does not receive unrelated reply" 0 (List.length (collect bystander));
  Unix.sleepf write_spacing_seconds;
  (match Board_dispatch.add_comment ~post_id ~parent_id ~author:"external"
           ~content:"direct answer" () with
   | Ok _ -> () | Error error -> fail (Board.show_board_error error));
  List.iter (fun meta ->
    match collect meta with
    | [event] ->
      check (option string) "actual nested reply body" (Some "direct answer")
        event.Keeper_world_observation.latest_external_preview;
      check bool "comment event" true (match event.event_kind with Board_comment_added _ -> true | _ -> false)
    | events -> failf "expected one direct reply, got %d" (List.length events))
    [poster; parent_author];
  check int "unrelated participant still excluded" 0 (List.length (collect bystander));
  List.iter (fun meta -> check int "next tick has no repeated reply" 0
    (List.length (collect meta))) metas;
  ignore (add_comment ~post_id ~author:"external" "@reply-bystander explicit answer" : string);
  check int "explicit comment mention replays without prior-parent match" 1
    (List.length (collect bystander));
  check int "explicit audience does not turn into post-author delivery" 0
    (List.length (collect poster));
  Unix.sleepf write_spacing_seconds;
  (match Board_dispatch.update_post ~post_id ~editor:poster.name
           ~content:"@reply-bystander mention added by editing" () with
   | Ok _ -> () | Error error -> fail (Board.show_board_error error));
  check int "mention added by editing an old post replays" 1
    (List.length (collect bystander));
  ignore (add_comment ~post_id ~author:"external" "unrelated later comment" : string);
  check int "later comment does not repeat inherited post mention" 0
    (List.length (collect bystander))
;;

let test_accepted_comment_identity_survives_queue_projection () =
  let module Signal = Keeper_world_observation_board_signal in
  let post_id = create_thread ~title:"queued identity" "thread topic" in
  let parent_id = add_comment ~post_id ~author:"parent-author" "parent" in
  let captured = ref None in
  Board_dispatch.set_board_signal_hook (fun addressed -> captured := Some addressed);
  Fun.protect ~finally:(fun () -> Board_dispatch.set_board_signal_hook (fun _ -> ()))
  @@ fun () ->
  let accepted =
    match Board_dispatch.add_comment ~post_id ~parent_id ~author:"reply-author"
            ~content:"the queued reply" () with
    | Ok comment -> comment
    | Error error -> fail (Board.show_board_error error)
  in
  let signal =
    match !captured with
    | Some addressed -> addressed.Board_dispatch.signal
    | None -> fail "accepted comment did not emit a signal"
  in
  let stimulus : Keeper_event_queue.stimulus =
    { post_id; urgency = Normal; arrived_at = Time_compat.now ()
    ; payload = Board_signal (Signal.board_stimulus_of_board_signal signal)
    }
  in
  let restored =
    match Keeper_event_queue.stimulus_of_yojson
            (Keeper_event_queue.stimulus_to_yojson stimulus) with
    | Ok restored -> restored
    | Error detail -> fail detail
  in
  ignore (add_comment ~post_id ~author:"later-author" "a later reply" : string);
  let observation =
    match restored.payload with
    | Keeper_event_queue.Board_signal board ->
      Signal.board_observation_of_board_stimulus ~post_id board
    | _ -> fail "restored queue payload is not a Board signal"
  in
  (match observation.kind with
   | Signal.Observed_comment_added identity ->
     check string "accepted comment ID" (Board.Comment_id.to_string accepted.id)
       identity.comment_id;
     check (option string) "accepted parent ID" (Some parent_id) identity.parent_id
   | _ -> fail "restored signal is not a comment");
  check string "queued author does not become the later author"
    "reply-author" observation.author;
  check string "queued body does not become the later body"
    "the queued reply" observation.content
;;

let () =
  run
    "keeper_board_unavailable"
    [ ( "disposition"
      , [ test_case
            "disposition_of_error classifies every board_error variant"
            `Quick
            test_disposition_of_error_classifies_every_variant
        ] )
    ; ( "poison stimulus (masc keeper-cycle-exception incident)"
      , [ test_case
            "pending_board_event_of_stimulus reports Permanent, does not raise"
            `Quick
            (with_eio test_poison_stimulus_reports_permanent_error)
        ; test_case
            "stimulus intake consumes without crash, stable on repeat"
            `Quick
            (with_eio test_poison_stimulus_intake_does_not_crash_and_stays_dropped)
        ; test_case
            "durable poison is acknowledged during intake"
            `Quick
            test_poison_durable_source_is_retired_during_intake
        ] )
    ; ( "transient stimulus"
      , [ test_case
            "Io_error is a typed retry, not consumed"
            `Quick
            test_transient_result_is_retryable
        ; test_case
            "pending source is retained and provider dispatch is blocked"
            `Quick
            test_transient_intake_retains_pending_source_and_blocks_dispatch
        ; test_case
            "a transient head does not block the entry behind it"
            `Quick
            test_transient_head_does_not_block_the_entry_behind_it
        ; test_case "all transient reads finish and retain exact pending sources" `Quick
            test_all_transient_reads_finish_without_changing_pending
        ; test_case "transient sources do not spend the admission limit" `Quick
            test_transient_sources_do_not_spend_the_admission_limit
        ; test_case "an empty-observation source still spends an admission slot" `Quick
            test_empty_observation_source_still_spends_an_admission_slot
        ; test_case "permanent absence does not spend an admission slot" `Quick
            test_permanent_absence_does_not_spend_an_admission_slot
        ] )
    ; ( "replies after own comment"
      , [ test_case
            "accepted comment identity survives queue projection"
            `Quick
            (with_eio test_accepted_comment_identity_survives_queue_projection)
        ; test_case
            "queued comment keeps its author and body"
            `Quick
            (with_eio test_queued_comment_keeps_its_author_and_body)
        ; test_case
            "Board replay routes exact replies"
            `Quick
            (with_eio test_board_replay_routes_exact_replies)
        ] )
    ]
;;
