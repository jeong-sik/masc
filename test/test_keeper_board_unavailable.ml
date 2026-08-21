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
   1. [read_failure_kind_of_error] classifies every [Board.board_error] variant —
      the compiler enforces exhaustiveness, this test pins the actual table.
   2. the incident's exact shape (a stimulus naming a post_id that was never
      created) no longer raises, is reported as [Error unavailable]
      classified [Source_rejected], and the stimulus-intake layer consumes it
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
   variant forces [read_failure_kind_of_error] to grow (compiler-enforced); this
   test pins today's actual poison/transient split so a change to the table
   is a deliberate, reviewed diff rather than a silent behavior change. *)
let test_read_failure_kind_of_error_classifies_every_variant () =
  let module BS = Keeper_world_observation_board_signal in
  let is_source_rejected err = BS.read_failure_kind_of_error err = BS.Source_rejected in
  let is_store_io_failed err = BS.read_failure_kind_of_error err = BS.Store_io_failed in
  check bool "Post_not_found is permanent (post swept, never resolves on retry)" true
    (is_source_rejected (Board.Post_not_found "p"));
  check bool "Comment_not_found is permanent (same argument, for a comment id)" true
    (is_source_rejected (Board.Comment_not_found "c"));
  check bool "Invalid_id is permanent (malformed id string never becomes valid)" true
    (is_source_rejected (Board.Invalid_id "bad id"));
  check bool "Io_error is transient (store/disk hiccup, retry may succeed)" true
    (is_store_io_failed (Board.Io_error "disk hiccup"));
  check bool "Validation_error is permanent (deterministic input-validation failure)" true
    (is_source_rejected (Board.Validation_error "x"));
  check bool "Already_voted is permanent (deterministic action conflict)" true
    (is_source_rejected (Board.Already_voted "x"));
  check bool "Already_exists is permanent (deterministic conflict)" true
    (is_source_rejected (Board.Already_exists "x"));
  check bool "Unauthorized is permanent (deterministic identity rejection)" true
    (is_source_rejected (Board.Unauthorized "x"))
;;

let poison_post_id = "nonexistent-post-poison-test"

let transient_unavailable post_id :
  Keeper_world_observation_board_signal.board_unavailable
  =
  { operation = Keeper_world_observation_board_signal.Get_post
  ; post_id
  ; error = Board.Io_error "forced board read IO failure"
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
   as [Error unavailable] — never raise — and it must classify [Source_rejected],
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
      "classifies Source_rejected (masc keeper-cycle-exception incident cause)"
      true
      (Keeper_world_observation_board_signal.read_failure_kind_of_unavailable unavailable
       = Keeper_world_observation_board_signal.Source_rejected)
;;

let test_poison_stimulus_intake_returns_exact_failure () =
  let meta = test_meta "poison-intake" in
  let stim = poison_board_signal_stimulus () in
  let first_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result
      ~meta_after_triage:meta
      stim
  in
  (match first_pass with
   | Keeper_heartbeat_stimulus_intake.Stimulus_read_failed unavailable ->
     check string "failure preserves source id" stim.post_id unavailable.post_id
   | Keeper_heartbeat_stimulus_intake.Stimulus_consumed _ ->
     fail "missing source was incorrectly consumed as an empty event");
  let second_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result
      ~meta_after_triage:meta
      stim
  in
  match second_pass with
  | Keeper_heartbeat_stimulus_intake.Stimulus_read_failed unavailable ->
    check string "repeat preserves source id" stim.post_id unavailable.post_id
  | Keeper_heartbeat_stimulus_intake.Stimulus_consumed _ ->
    fail "repeat missing source was incorrectly consumed"
;;

let test_io_error_is_exact_read_failure () =
  let unavailable = transient_unavailable "transient-classification" in
  match
    Keeper_heartbeat_stimulus_intake.classify_pending_board_event_result
      (Error unavailable)
  with
  | Keeper_heartbeat_stimulus_intake.Stimulus_read_failed actual ->
    check
      string
      "failure retains exact post id"
      unavailable.post_id
      actual.post_id
  | Keeper_heartbeat_stimulus_intake.Stimulus_consumed _ ->
    fail "board I/O failure was collapsed into consumed"
;;

let test_io_failure_surfaces_exact_source_and_blocks_dispatch () =
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
      Keeper_heartbeat_stimulus_intake.For_testing.force_board_io_failures 0;
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
      failf "failed to create Board source: %s" (Board.show_board_error error)
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
  Keeper_heartbeat_stimulus_intake.For_testing.force_board_io_failures 1;
  let intake =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  check int "failed source is not counted consumed" 0 intake.consumed_stimulus_count;
  check int "failed source is not exposed as consumed" 0
    (List.length intake.consumed_stimuli);
  check bool "exact pending selection remains attached" true
    (Option.is_some intake.pending_selection);
  (match intake.event_queue_intake_error with
   | Some
       (Keeper_heartbeat_stimulus_intake.Board_read_failed unavailable) ->
     check string "failure retains the exact source post id" stimulus.post_id
       unavailable.post_id;
     check bool "board read failure is a crashed cycle" true
       (Keeper_heartbeat_stimulus_intake
        .event_queue_intake_error_counts_as_cycle_failure
          (Keeper_heartbeat_stimulus_intake.Board_read_failed unavailable))
   | Some error ->
     failf
       "expected Board read failure, got %s"
       (Keeper_heartbeat_stimulus_intake.event_queue_intake_error_to_string
          error)
   | None -> fail "Board intake error was lost");
  check
    bool
    "provider dispatch is blocked after source read failure"
    false
    (Keeper_heartbeat_loop.should_run_turn_after_event_intake
       ~scheduled:true
       ~event_queue_intake_error:intake.event_queue_intake_error);
  let queued =
    match Keeper_registry_event_queue.snapshot_result ~base_path meta.name with
    | Ok queue -> queue
    | Error message -> failf "failed to reload durable queue: %s" message
  in
  check int "direct intake does not mutate the durable source" 1
    (Keeper_event_queue.length queued);
  ()
;;

(* (4) A transiently unavailable entry must not hold the cycle for the entries
   behind it. The test above seeds one stimulus, so withdrawal has nothing to
   fall through to and the blocked-dispatch contract is unchanged. This one
   seeds two: the head read fails transiently, and the cycle must still render
   and consume the entry behind it.

   Against the pre-fix intake this fails at the first assertion — a transient
   head returned [consumed_stimuli = []] and every entry behind it waited for
   the head to become readable, for as long as that took. *)
let test_failed_head_stops_before_trailing_entry () =
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
      Keeper_heartbeat_stimulus_intake.For_testing.force_board_io_failures 0;
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
  Keeper_heartbeat_stimulus_intake.For_testing.force_board_io_failures 1;
  let intake =
    Keeper_heartbeat_stimulus_intake.heartbeat_event_intake
      ~ctx
      ~meta_after_triage:meta
      ~pending_board_events:[]
  in
  check int "no entry is consumed past the failed head" 0
    intake.consumed_stimulus_count;
  (match intake.consumed_stimuli with
   | [] -> ()
   | other -> failf "expected no consumed stimulus, got %d" (List.length other));
  check bool "failed head reports an intake error" true
    (Option.is_some intake.event_queue_intake_error);
  check
    bool
    "provider dispatch does not skip past the failed source"
    false
    (Keeper_heartbeat_loop.should_run_turn_after_event_intake
       ~scheduled:true
       ~event_queue_intake_error:intake.event_queue_intake_error);
  let queued =
    match Keeper_registry_event_queue.snapshot_result ~base_path meta.name with
    | Ok queue -> queue
    | Error message -> failf "failed to reload durable queue: %s" message
  in
  check int "direct intake leaves both entries durable" 2
    (Keeper_event_queue.length queued)
;;

let () =
  run
    "keeper_board_unavailable"
    [ ( "read_failure_kind"
      , [ test_case
            "read_failure_kind_of_error classifies every board_error variant"
            `Quick
            test_read_failure_kind_of_error_classifies_every_variant
        ] )
    ; ( "poison stimulus (masc keeper-cycle-exception incident)"
      , [ test_case
            "pending_board_event_of_stimulus reports Source_rejected, does not raise"
            `Quick
            (with_eio test_poison_stimulus_reports_permanent_error)
        ; test_case
            "stimulus intake returns exact failure, stable on repeat"
            `Quick
            (with_eio test_poison_stimulus_intake_returns_exact_failure)
        ] )
    ; ( "board IO failure"
      , [ test_case
            "Io_error is an exact read failure"
            `Quick
            test_io_error_is_exact_read_failure
        ; test_case
            "exact source failure blocks provider dispatch"
            `Quick
            test_io_failure_surfaces_exact_source_and_blocks_dispatch
        ; test_case
            "a failed head does not skip to the entry behind it"
            `Quick
            test_failed_head_stops_before_trailing_entry
        ] )
    ]
;;
