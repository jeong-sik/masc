(** SSOT regression tests for [Llm_provider.Types.stop_reason_to_string] and
    [stop_reason_to_metric_label].

    These pin the canonical wire vocabulary so the per-module copies that
    previously drifted ("tool_use" vs "stop_tool_use",
    "model_context_window_exceeded" vs "context_window_exceeded") cannot
    re-appear without a failing test. *)

open Alcotest
open Llm_provider

let all_known_variants =
  (* Keep this hand-list in sync with [Types.stop_reason]. OCaml has no native
     constructor enumeration, so this is the round-trip coverage surface. *)
  [ Types.EndTurn
  ; Types.StopToolUse
  ; Types.MaxTokens
  ; Types.StopSequence
  ; Types.Refusal
  ; Types.ContentFilter
  ; Types.RepetitionTruncation
  ; Types.PauseTurn
  ; Types.Compaction
  ; Types.ContextWindowExceeded
  ; Types.UnmatchedToolCalls
  ]
;;

let stop_reason_testable =
  testable (fun fmt r -> Format.pp_print_string fmt (Types.show_stop_reason r)) ( = )
;;

(* of_string ∘ to_string = id for every known constructor. *)
let test_roundtrip_known () =
  List.iter
    (fun r ->
       let s = Types.stop_reason_to_string r in
       check
         stop_reason_testable
         (Printf.sprintf "roundtrip %s -> %S -> back" (Types.show_stop_reason r) s)
         r
         (Types.stop_reason_of_string s))
    all_known_variants
;;

(* Unknown carrying a token that is NOT a known wire string round-trips as
   Unknown (passthrough), preserving the raw provider string. *)
let test_roundtrip_unknown_passthrough () =
  let raw = "some_future_provider_reason" in
  let r = Types.Unknown raw in
  check
    stop_reason_testable
    "unknown passthrough roundtrips"
    r
    (Types.stop_reason_of_string (Types.stop_reason_to_string r));
  check string "unknown serializes to its raw token" raw (Types.stop_reason_to_string r)
;;

(* Pin the two strings that historically drifted across modules. *)
let test_canonical_strings_pinned () =
  check
    string
    "StopToolUse is tool_use (not stop_tool_use)"
    "tool_use"
    (Types.stop_reason_to_string Types.StopToolUse);
  check
    string
    "ContextWindowExceeded keeps the model_ prefix"
    "model_context_window_exceeded"
    (Types.stop_reason_to_string Types.ContextWindowExceeded);
  check string "EndTurn" "end_turn" (Types.stop_reason_to_string Types.EndTurn);
  check
    string
    "StopSequence"
    "stop_sequence"
    (Types.stop_reason_to_string Types.StopSequence)
;;

(* The metric label matches to_string on every known variant and only diverges
   on Unknown, which collapses to the constant "unknown" to bound cardinality. *)
let test_metric_label () =
  List.iter
    (fun r ->
       check
         string
         (Printf.sprintf "metric_label = to_string for %s" (Types.show_stop_reason r))
         (Types.stop_reason_to_string r)
         (Types.stop_reason_to_metric_label r))
    all_known_variants;
  check
    string
    "Unknown collapses to constant label"
    "unknown"
    (Types.stop_reason_to_metric_label (Types.Unknown "anything_at_all"))
;;

let test_dialects_mapped_to_canonical () =
  let cases =
    [ "context_window_exceeded", Types.ContextWindowExceeded
    ; "context_length_exceeded", Types.ContextWindowExceeded
    ; "max_context_length", Types.ContextWindowExceeded
    ; "context_limit_exceeded", Types.ContextWindowExceeded
    ; "length_limit", Types.MaxTokens
    ; "length", Types.MaxTokens
    ]
  in
  List.iter
    (fun (raw, expected) ->
       check
         stop_reason_testable
         (Printf.sprintf "dialect %S maps to %s" raw (Types.show_stop_reason expected))
         expected
         (Types.stop_reason_of_string raw);
       check
         stop_reason_testable
         (Printf.sprintf
            "wire_finish_of_string %S maps to %s"
            raw
            (Types.show_stop_reason expected))
         expected
         (Stop_reason_wire.provisional_of_string raw))
    cases
;;

let () =
  run
    "stop_reason_ssot"
    [ ( "canonical"
      , [ test_case "roundtrip known" `Quick test_roundtrip_known
        ; test_case "roundtrip unknown" `Quick test_roundtrip_unknown_passthrough
        ; test_case "pinned strings" `Quick test_canonical_strings_pinned
        ; test_case "metric label" `Quick test_metric_label
        ; test_case "dialect aliases" `Quick test_dialects_mapped_to_canonical
        ] )
    ]
;;
