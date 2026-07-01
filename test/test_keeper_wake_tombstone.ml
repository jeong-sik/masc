(* test/test_keeper_wake_tombstone.ml

   RFC-0246: wake-cascade recovery tombstone gate. Pins the contract between
   [Keeper_no_progress_loop_detector] (single source of truth for latching)
   and [Keeper_wake_tombstone] (typed wake_decision gate):
   - A latched keeper is Suppressed for Board_reactive / Heartbeat origins.
   - Operator_direct and Mention bypass the tombstone even when latched.
   - A progress turn resets the detector latch, which the gate reads, so wake
     is re-allowed. (Integration: gate has no state of its own.) *)

module T = Masc.Keeper_wake_tombstone
module D = Masc.Keeper_no_progress_loop_detector

(* Detector uses Eio.Mutex, so every entry needs an Eio fiber context. *)
let with_eio f () = Eio_main.run @@ fun _env -> f ()

(* Drive the detector across the threshold so [is_latched] becomes true. *)
let latch keeper =
  let threshold = D.threshold () in
  for _ = 1 to threshold do
    D.record_turn ~keeper_name:keeper ~made_progress:false () |> ignore
  done

let is_suppressed origin keeper =
  match T.decide ~origin ~keeper_name:keeper with
  | T.Suppressed _ -> true
  | T.Wake_allowed -> false

let test_suppresses_automatic_origins_when_latched () =
  D.reset_all_for_test ();
  latch "tombstone-a";
  Alcotest.(check bool) "latched keeper suppressed on board-reactive"
    true (is_suppressed T.Board_reactive "tombstone-a");
  Alcotest.(check bool) "latched keeper suppressed on heartbeat"
    true (is_suppressed T.Heartbeat "tombstone-a")

let test_operator_mention_bypass () =
  D.reset_all_for_test ();
  latch "tombstone-b";
  Alcotest.(check bool) "operator-direct bypasses tombstone"
    false (is_suppressed T.Operator_direct "tombstone-b");
  Alcotest.(check bool) "mention bypasses tombstone"
    false (is_suppressed T.Mention "tombstone-b")

let test_progress_clears_tombstone () =
  D.reset_all_for_test ();
  latch "tombstone-c";
  Alcotest.(check bool) "suppressed before progress"
    true (is_suppressed T.Board_reactive "tombstone-c");
  (* A progress turn resets the detector latch; the gate reads that state, so
     wake is re-allowed without any tombstone-store mutation. *)
  D.record_turn ~keeper_name:"tombstone-c" ~made_progress:true () |> ignore;
  Alcotest.(check bool) "wake re-allowed after progress turn"
    false (is_suppressed T.Board_reactive "tombstone-c")

let test_not_latched_allowed () =
  D.reset_all_for_test ();
  Alcotest.(check bool) "non-latched keeper wake-allowed"
    false (is_suppressed T.Board_reactive "tombstone-d")

let test_per_keeper_isolation () =
  D.reset_all_for_test ();
  latch "tombstone-e";
  Alcotest.(check bool) "latched keeper suppressed"
    true (is_suppressed T.Board_reactive "tombstone-e");
  Alcotest.(check bool) "different keeper not affected"
    false (is_suppressed T.Board_reactive "tombstone-f")

(* RFC-0294 R2b: the keeper's own self-cadence (scheduled-autonomous) clock is an
   automatic origin and must NOT bypass the tombstone — this is the gap RFC-0246
   left open (only Heartbeat/Board_reactive were gated, never the self-clock). A
   latched keeper kept re-waking itself indefinitely. *)
let test_self_cadence_suppressed_when_latched () =
  D.reset_all_for_test ();
  latch "tombstone-self-cadence";
  Alcotest.(check bool)
    "self-cadence does NOT bypass tombstone when latched"
    true (is_suppressed T.Self_cadence "tombstone-self-cadence")

(* RFC-0294 R2b false-positive guard (read-heavy-then-write): a keeper that does
   threshold-1 no-progress turns then makes progress is NOT latched, so its
   self-cadence wake stays allowed — the gate must not pause a keeper that is
   still recovering on its own. *)
let test_self_cadence_not_paused_when_not_latched () =
  D.reset_all_for_test ();
  let threshold = D.threshold () in
  for _ = 1 to threshold - 1 do
    D.record_turn ~keeper_name:"tombstone-recover" ~made_progress:false ()
    |> ignore
  done;
  D.record_turn ~keeper_name:"tombstone-recover" ~made_progress:true () |> ignore;
  Alcotest.(check bool)
    "self-cadence wake allowed for non-latched (recovered) keeper"
    false (is_suppressed T.Self_cadence "tombstone-recover")

(* RFC-0303 Phase 1: stable origin labels for the turn-decision observability
   tag (wake_origin:<label>). Pin every constructor so a new origin cannot ship
   without a label, and so the dashboard/log parser keys stay stable. *)
let test_origin_label_is_stable () =
  Alcotest.(check string) "mention" "mention" (T.origin_label T.Mention);
  Alcotest.(check string)
    "board_reactive" "board_reactive" (T.origin_label T.Board_reactive);
  Alcotest.(check string) "heartbeat" "heartbeat" (T.origin_label T.Heartbeat);
  Alcotest.(check string)
    "operator_direct" "operator_direct" (T.origin_label T.Operator_direct);
  Alcotest.(check string)
    "self_cadence" "self_cadence" (T.origin_label T.Self_cadence)

let () =
  Alcotest.run "keeper_wake_tombstone"
    [
      ( "gate",
        [
          ( "suppresses automatic origins when latched",
            `Quick,
            with_eio test_suppresses_automatic_origins_when_latched );
          ( "operator/mention bypass",
            `Quick,
            with_eio test_operator_mention_bypass );
          ( "progress clears tombstone",
            `Quick,
            with_eio test_progress_clears_tombstone );
          ( "non-latched allowed",
            `Quick,
            with_eio test_not_latched_allowed );
          ( "per-keeper isolation",
            `Quick,
            with_eio test_per_keeper_isolation );
          ( "R2b self-cadence suppressed when latched",
            `Quick,
            with_eio test_self_cadence_suppressed_when_latched );
          ( "R2b self-cadence allowed when not latched (recovered)",
            `Quick,
            with_eio test_self_cadence_not_paused_when_not_latched );
          ( "origin_label is stable per constructor",
            `Quick,
            test_origin_label_is_stable );
        ] );
    ]
