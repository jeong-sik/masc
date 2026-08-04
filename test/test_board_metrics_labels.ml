(** Pins Board metric label strings emitted by the typed hook adapter. *)

module BPH = Masc.Board_metric_hooks_adapter
module BMH = Masc.Board_metrics_hooks

let check_label name expected actual =
  Alcotest.(check string) name expected actual

let test_flusher_outcome_to_label () =
  check_label "Switch_finished" "switch_finished"
    (BPH.flusher_outcome_to_label BMH.Switch_finished);
  check_label "Cas_exhausted" "cas_exhausted"
    (BPH.flusher_outcome_to_label BMH.Cas_exhausted)

let () =
  Alcotest.run "board_metrics_labels"
    [ ( "to_label byte-identity"
      , [ Alcotest.test_case "flusher_outcome" `Quick
            test_flusher_outcome_to_label
        ] )
    ]
