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
      exception-based loop. *)

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
    Keeper_meta_json_parse.meta_of_json
      (`Assoc
         [ "name", `String name
         ; "agent_name", `String ("keeper-" ^ name ^ "-agent")
         ; "trace_id", `String ("trace-" ^ name)
         ; "sandbox_profile", `String "local"
         ; "network_mode", `String "inherit"
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
        ; routing_event_id = None
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
  check
    int
    "first pass produces no pending_board_event (consumed, not crashed)"
    0
    (List.length first_pass);
  let second_pass =
    Keeper_heartbeat_stimulus_intake.pending_board_events_of_stimulus_result
      ~meta_after_triage:meta
      stim
  in
  check
    int
    "second pass over the same stimulus stays empty (no crash-loop resurgence)"
    0
    (List.length second_pass)
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
    ]
;;
