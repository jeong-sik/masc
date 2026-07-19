(* test/test_board_metrics_labels.ml

   Pins the Otel_metric_store label strings emitted for the typed metric-label
   closed sums on [Board_metrics_hooks.observer]. The refactor replaced
   bare [string] label params with closed sums; the [variant -> string]
   mapping lives only in the Otel_metric_store adapter
   ([Board_metric_hooks_adapter.*_to_label]).

   These strings are wire contracts.  The expected values below pin the
   current typed mappings so a future variant change cannot silently drift an
   Otel_metric_store label. *)

module BPH = Masc.Board_metric_hooks_adapter
module BMH = Masc.Board_metrics_hooks
module RDR = Read_drop_reason

let check_label name expected actual =
  Alcotest.(check string) name expected actual

(* surface label for masc_persistence_read_drops_total. Old code passed
   the literal "board_post_meta_json". *)
let test_board_persist_surface_to_label () =
  check_label "Board_post_meta_json" "board_post_meta_json"
    (BPH.board_persist_surface_to_label BMH.Board_post_meta_json)

(* outcome label for masc_board_dispatch_runtime_actor_start_outcomes_total. *)
let test_runtime_actor_start_outcome_to_label () =
  check_label "Started" "started"
    (BPH.runtime_actor_start_outcome_to_label BMH.Started);
  check_label "Start_failed" "start_failed"
    (BPH.runtime_actor_start_outcome_to_label BMH.Start_failed)

let test_runtime_actor_to_label () =
  check_label "Flusher" "flusher"
    (BPH.runtime_actor_to_label BMH.Flusher);
  check_label "Routing_retry" "routing_retry"
    (BPH.runtime_actor_to_label BMH.Routing_retry)

(* reason label for masc_persistence_read_drops_total. The board only
   emits Invalid_payload; the adapter reuses Read_drop_reason.to_wire,
   which is byte-identical to the old
   Safe_ops.persistence_read_drop_reason_invalid_payload = "invalid_payload". *)
let test_read_drop_reason_to_label () =
  check_label "Invalid_payload" "invalid_payload"
    (BPH.read_drop_reason_to_label RDR.Invalid_payload);
  (* Match the old Safe_ops constant directly to prove no drift. *)
  check_label "matches Safe_ops constant"
    Safe_ops.persistence_read_drop_reason_invalid_payload
    (BPH.read_drop_reason_to_label RDR.Invalid_payload)

let () =
  Alcotest.run "board_metrics_labels"
    [ ( "to_label byte-identity"
      , [ Alcotest.test_case "board_persist_surface" `Quick
            test_board_persist_surface_to_label
        ; Alcotest.test_case "runtime_actor_start_outcome" `Quick
            test_runtime_actor_start_outcome_to_label
        ; Alcotest.test_case "runtime_actor" `Quick test_runtime_actor_to_label
        ; Alcotest.test_case "read_drop_reason" `Quick
            test_read_drop_reason_to_label
        ] )
    ]
