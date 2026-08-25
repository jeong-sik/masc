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
      is blocked until a later intake can render it. *)

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
         ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
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
  check int "transient source is not counted consumed" 0 intake.consumed_stimulus_count;
  check int "transient source is not exposed as consumed" 0
    (List.length intake.consumed_stimuli);
  check bool "exact pending selection remains attached" true
    (Option.is_some intake.pending_selection);
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
    retry_intake.consumed_stimulus_count;
  check int "later successful read renders the exact Board event" 1
    (List.length retry_intake.pending_board_events);
  check bool "retry clears the typed intake error" true
    (Option.is_none retry_intake.event_queue_intake_error);
  (match retry_intake.pending_selection with
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

(* (4) A transiently unavailable entry must not hold the cycle for the entries
   behind it. The test above seeds one stimulus, so withdrawal has nothing to
   fall through to and the blocked-dispatch contract is unchanged. This one
   seeds two: the head read fails transiently, and the cycle must still render
   and consume the entry behind it.

   Against the pre-fix intake this fails at the first assertion — a transient
   head returned [consumed_stimuli = []] and every entry behind it waited for
   the head to become readable, for as long as that took. *)
let test_transient_head_does_not_block_the_entry_behind_it () =
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
      Board_dispatch.create_post
        ~author:"external-author"
        ~content:label
        ~post_kind:Board.Human_post
        ~visibility:Board.Internal
        ()
    with
    | Ok post -> Board.Post_id.to_string post.id
    | Error error ->
      failf "failed to create Board source: %s" (Board.show_board_error error)
  in
  let head_post_id = create_source "head source, read fails transiently" in
  let trailing_post_id = create_source "trailing source, read succeeds" in
  let seed post_id =
    match
      Keeper_registry_event_queue.enqueue_durable_result
        ~base_path
        meta.name
        { (poison_board_signal_stimulus ()) with post_id }
    with
    | Ok () -> ()
    | Error message -> failf "failed to seed durable stimulus: %s" message
  in
  seed head_post_id;
  seed trailing_post_id;
  (* Exactly one forced transient read: the head. The entry behind it reads
     normally, so any consumption observed below came from the fall-through
     and not from the forcing hook running out. *)
  Keeper_heartbeat_stimulus_intake.For_testing.force_transient_board_reads 1;
  let intake =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  check int "the entry behind the transient head is consumed" 1
    intake.consumed_stimulus_count;
  (match intake.consumed_stimuli with
   | [ consumed ] ->
     check string "the consumed entry is the trailing one, not the head"
       trailing_post_id consumed.Keeper_event_queue.post_id
   | other ->
     failf "expected exactly one consumed stimulus, got %d" (List.length other));
  check bool "a cycle that consumed an entry reports no intake error" true
    (Option.is_none intake.event_queue_intake_error);
  check
    bool
    "provider dispatch proceeds on the entry that could be rendered"
    true
    (Keeper_heartbeat_loop.should_run_turn_after_event_intake
       ~scheduled:true
       ~event_queue_intake_error:intake.event_queue_intake_error);
  let queued =
    match Keeper_registry_event_queue.snapshot_result ~base_path meta.name with
    | Ok queue -> queue
    | Error message -> failf "failed to reload durable queue: %s" message
  in
  check int "withdrawal drops nothing: both entries are still durable" 2
    (Keeper_event_queue.length queued)
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
        ] )
    ]
;;
