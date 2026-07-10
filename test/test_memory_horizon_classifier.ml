(** Tests for the closed keeper-memory kind and horizon policy (#8826).

    Verifies that:
    - wire values parse exactly once into a closed variant,
    - retired, unknown, or non-canonical wire values are rejected,
    - horizon, priority, and caps consume the variant rather than strings. *)

open Alcotest

module Policy = Masc.Keeper_memory_policy

let test_known_kinds_round_trip () =
  let expected =
    [ "decision", Policy.Decision
    ; "goal", Policy.Goal
    ; "progress", Policy.Progress
    ; "open_question", Policy.Open_question
    ; "long_term", Policy.Long_term
    ]
  in
  List.iter
    (fun (wire, kind) ->
       check bool (wire ^ " parses") true (Policy.memory_kind_of_wire wire = Some kind);
       check string (wire ^ " renders") wire (Policy.memory_kind_to_wire kind))
    expected
;;

let test_noncanonical_kinds_are_rejected () =
  [ "goalss"
  ; "hypothesis"
  ; "next"
  ; "constraints"
  ; ""
  ; "   "
  ; "GOAL"
  ; " open_question "
  ]
  |> List.iter (fun wire ->
       check bool
         (Printf.sprintf "%S rejected" wire)
         true
         (Policy.memory_kind_of_wire wire = None))
;;

let test_typed_policy () =
  check string
    "open question horizon"
    Policy.short_term_horizon
    (Policy.memory_horizon_of_kind Policy.Open_question);
  check string
    "progress horizon"
    Policy.short_term_horizon
    (Policy.memory_horizon_of_kind Policy.Progress);
  check string
    "goal horizon"
    Policy.mid_term_horizon
    (Policy.memory_horizon_of_kind Policy.Goal);
  check string
    "decision horizon"
    Policy.mid_term_horizon
    (Policy.memory_horizon_of_kind Policy.Decision);
  check string
    "long-term horizon"
    Policy.long_term_horizon
    (Policy.memory_horizon_of_kind Policy.Long_term);
  check int "decision priority" 86 (Policy.priority_for_kind ~kind:Policy.Decision);
  check int
    "long-term cap"
    4
    (Policy.cap_for_kind (Policy.kind_caps ()) Policy.Long_term);
  check bool
    "long-term is not writable"
    false
    (Policy.memory_kind_is_writable Policy.Long_term);
  check (list string)
    "writable wire kinds"
    [ "decision"; "goal"; "progress"; "open_question" ]
    Policy.writable_memory_kind_strings;
  check (list string)
    "search schema mirror"
    Policy.valid_memory_kind_strings
    Masc.Tool_shard.memory_kind_enum_strings;
  check (list string)
    "write schema mirror"
    Policy.writable_memory_kind_strings
    Masc.Tool_shard.writable_memory_kind_enum_strings
;;

let test_json_strict_classifier () =
  let json_with horizon =
    `Assoc [ "horizon", `String horizon; "kind", `String "progress" ]
  in
  check (option string)
    "JSON short_term -> Some"
    (Some Policy.short_term_horizon)
    (Policy.memory_horizon_of_json_opt (json_with "short_term"));
  check (option string)
    "JSON mid_term -> Some"
    (Some Policy.mid_term_horizon)
    (Policy.memory_horizon_of_json_opt (json_with "mid_term"));
  check (option string)
    "JSON long_term -> Some"
    (Some Policy.long_term_horizon)
    (Policy.memory_horizon_of_json_opt (json_with "long_term"));
  check (option string)
    "JSON unknown -> None"
    None
    (Policy.memory_horizon_of_json_opt (json_with "unrecognised"));
  check (option string)
    "JSON missing horizon -> None"
    None
    (Policy.memory_horizon_of_json_opt (`Assoc [ "kind", `String "progress" ]))
;;

let () =
  Alcotest.run
    "memory_horizon_classifier"
    [ ( "strict classifier"
      , [ test_case "known kinds round trip" `Quick test_known_kinds_round_trip
        ; test_case
            "noncanonical kinds are rejected"
            `Quick
            test_noncanonical_kinds_are_rejected
        ; test_case "typed policy" `Quick test_typed_policy
        ; test_case "JSON strict classifier" `Quick test_json_strict_classifier
        ] )
    ]
;;
