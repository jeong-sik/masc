(* test/test_board_metrics_labels.ml

   Pins the Otel_metric_store label strings emitted for the typed metric-label
   closed sums on [Board_metrics_hooks.observer]. The refactor replaced
   bare [string] label params with closed sums; the [variant -> string]
   mapping lives only in the Otel_metric_store adapter
   ([Board_metric_hooks_adapter.*_to_label]).

   These strings are wire contracts: dashboards and alerts are keyed on
   them. The expected values below are the exact strings the pre-typed
   string hooks passed, so this test fails if any future variant change
   drifts a Otel_metric_store label. *)

module BPH = Masc.Board_metric_hooks_adapter
module BMH = Masc.Board_metrics_hooks
module BCC = Masc.Board_core_classify
module RDR = Read_drop_reason

let check_label name expected actual =
  Alcotest.(check string) name expected actual

(* surface label for masc_persistence_read_drops_total. Old code passed
   the literal "board_post_meta_json". *)
let test_board_persist_surface_to_label () =
  check_label "Board_post_meta_json" "board_post_meta_json"
    (BPH.board_persist_surface_to_label BMH.Board_post_meta_json)

(* outcome label for masc_board_dispatch_flusher_start_outcomes_total.
   Old code passed "switch_finished" / "cas_exhausted". *)
let test_flusher_outcome_to_label () =
  check_label "Switch_finished" "switch_finished"
    (BPH.flusher_outcome_to_label BMH.Switch_finished);
  check_label "Cas_exhausted" "cas_exhausted"
    (BPH.flusher_outcome_to_label BMH.Cas_exhausted)

(* automation_label label for masc_board_legacy_migrate_post_kind_total.
   Old [automation_label_token] produced exactly these strings; the table
   below mirrors it constructor-for-constructor. *)
let test_automation_label_to_label () =
  let cases =
    [ (BCC.Auto_prefixed, "auto-prefix")
    ; (BCC.Qa_prefixed, "qa-prefix")
    ; (BCC.Researcher_named, "researcher")
    ; (BCC.Harness_named, "harness")
    ; (BCC.Smoke_named, "smoke")
    ; (BCC.Probe_named, "probe")
    ]
  in
  List.iter
    (fun (variant, expected) ->
      check_label expected expected (BPH.automation_label_to_label variant))
    cases

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
        ; Alcotest.test_case "flusher_outcome" `Quick
            test_flusher_outcome_to_label
        ; Alcotest.test_case "automation_label" `Quick
            test_automation_label_to_label
        ; Alcotest.test_case "read_drop_reason" `Quick
            test_read_drop_reason_to_label
        ] )
    ]
