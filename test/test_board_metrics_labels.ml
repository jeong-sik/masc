(** Pins Board metric label strings emitted by the hook adapter. *)

module BPH = Masc.Board_metric_hooks_adapter

let check_label name expected actual =
  Alcotest.(check string) name expected actual

let test_flusher_outcome_to_label () =
  check_label "switch_finished" "switch_finished"
    BPH.flusher_switch_finished_label

let () =
  Alcotest.run "board_metrics_labels"
    [ ( "to_label byte-identity"
      , [ Alcotest.test_case "flusher_outcome" `Quick
            test_flusher_outcome_to_label
        ] )
    ]
