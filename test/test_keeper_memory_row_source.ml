(** RFC-0020 surface: [Keeper_memory_bank.memory_row_source] carrier.

    Pins the typed provenance carrier that replaced the [source : string]
    field classified by literal in three consumers (priority bonus,
    consolidation metric label, voice self-echo filter):

    - [of_string] maps every known wire literal to its constructor and any
      out-of-band value to [Other s] (total, never raises).
    - [to_string] is the wire inverse; [to_string (of_string s) = s] for all s
      so persisted rows round-trip through the type.
    - the literals the producers/consumers depend on ("voice_output",
      "progress_consolidation", "cross_trace_recurrence", "tool_result") parse
      to the constructors the exhaustive matches branch on — drift would now be
      a compile error, but this pins the wire spelling itself. Explicit tool
      writes use their own constructor rather than an untyped source string. *)

module Keeper_memory_bank = Masc.Keeper_memory_bank
open Keeper_memory_bank

let source_testable =
  Alcotest.testable
    (fun ppf s -> Format.pp_print_string ppf (memory_row_source_to_string s))
    ( = )

let test_of_string_known () =
  Alcotest.check source_testable "progress_consolidation" Progress_consolidation
    (memory_row_source_of_string "progress_consolidation");
  Alcotest.check source_testable "cross_trace_recurrence" Cross_trace_recurrence
    (memory_row_source_of_string "cross_trace_recurrence");
  Alcotest.check source_testable "explicit_memory_write" Explicit_memory_write
    (memory_row_source_of_string "explicit_memory_write");
  Alcotest.check source_testable "tool_result" Tool_result
    (memory_row_source_of_string "tool_result");
  Alcotest.check source_testable "voice_output" Voice_output
    (memory_row_source_of_string "voice_output")

let test_of_string_unknown_is_other () =
  Alcotest.check source_testable "unknown provenance -> Other"
    (Other "operator_note")
    (memory_row_source_of_string "operator_note");
  (* Empty is rejected by parse_memory_bank_row's guard, but of_string itself
     stays total and carries it as Other. *)
  Alcotest.check source_testable "empty -> Other" (Other "")
    (memory_row_source_of_string "")

let test_to_string_inverse () =
  List.iter
    (fun s ->
      Alcotest.check source_testable
        ("to_string round-trips " ^ memory_row_source_to_string s)
        s
        (memory_row_source_of_string (memory_row_source_to_string s)))
    [ Progress_consolidation
    ; Cross_trace_recurrence
    ; Explicit_memory_write
    ; Tool_result
    ; Voice_output
    ; Other "external_producer"
    ]

let test_of_string_to_string_invariant () =
  List.iter
    (fun s ->
      Alcotest.(check string)
        ("to_string (of_string " ^ s ^ ") = " ^ s)
        s
        (memory_row_source_to_string (memory_row_source_of_string s)))
    [ "progress_consolidation"
    ; "cross_trace_recurrence"
    ; "explicit_memory_write"
    ; "tool_result"
    ; "voice_output"
    ; "anything_else"
    ; ""
    ]

let () =
  Alcotest.run "keeper_memory_row_source"
    [ ( "carrier"
      , [ Alcotest.test_case "of_string known literals" `Quick test_of_string_known
        ; Alcotest.test_case "of_string unknown -> Other" `Quick
            test_of_string_unknown_is_other
        ; Alcotest.test_case "to_string is parse inverse" `Quick test_to_string_inverse
        ; Alcotest.test_case "to_string (of_string s) = s" `Quick
            test_of_string_to_string_invariant
        ] )
    ]
