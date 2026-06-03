open Masc

let test_standard_labels () =
  let cases =
    [ Timeout_origin.Slot_wait, "slot_wait"
    ; Timeout_origin.Spawn, "spawn"
    ; Timeout_origin.Command, "command"
    ; Timeout_origin.Llm_response, "llm_response"
    ; Timeout_origin.Dashboard_refresh, "dashboard_refresh"
    ; Timeout_origin.Health_probe, "health_probe"
    ; Timeout_origin.Other "Provider/Read Timeout", "other_provider_read_timeout"
    ]
  in
  List.iter
    (fun (origin, expected) ->
      Alcotest.(check string) expected expected (Timeout_origin.to_label origin))
    cases
;;

let test_process_origin_subset () =
  Alcotest.(check bool)
    "slot wait is process"
    true
    (Timeout_origin.is_process_origin Timeout_origin.Slot_wait);
  Alcotest.(check bool)
    "spawn is process"
    true
    (Timeout_origin.is_process_origin Timeout_origin.Spawn);
  Alcotest.(check bool)
    "command is process"
    true
    (Timeout_origin.is_process_origin Timeout_origin.Command);
  Alcotest.(check bool)
    "llm is not process"
    false
    (Timeout_origin.is_process_origin Timeout_origin.Llm_response)
;;

let test_other_label_sanitization () =
  Alcotest.(check string)
    "empty other stays bounded"
    "other"
    (Timeout_origin.to_label (Timeout_origin.Other " "));
  Alcotest.(check string)
    "punctuation removed"
    "other_provider_timeout_1"
    (Timeout_origin.to_label (Timeout_origin.Other "Provider Timeout #1"))
;;

let () =
  Alcotest.run
    "timeout_origin"
    [ ( "typed origins"
      , [ Alcotest.test_case "standard labels" `Quick test_standard_labels
        ; Alcotest.test_case "process subset" `Quick test_process_origin_subset
        ; Alcotest.test_case "other sanitization" `Quick test_other_label_sanitization
        ] )
    ]
;;
