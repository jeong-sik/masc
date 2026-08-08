(** End-to-end regression guard for the EndTurn + tool-block reconcile fix
    (oas#2728).

    Migrated here from [lib/llm_provider/backend_tool_call_harness.ml] when that
    Internal-declared zero-consumer module was deleted (oas#2690). The pure
    [Stop_reason_wire.reconcile] / [of_finish] unit tests in
    [lib/llm_provider/stop_reason_wire.ml] pin the typed function contract; this
    test exercises the full integration path
    (JSON -> [Backend_anthropic.parse_response] ->
    [stop_reason_of_string] -> [has_tool_blocks] -> [reconcile])
    so a future regression in any of those wiring links — not just the typed
    [reconcile] arm — is still caught. The inline version in the harness
    couldn't move into [stop_reason_wire.ml] because [Backend_anthropic] already
    depends on [Stop_reason_wire], so an inline [let%test] there forms a module
    dependency cycle; this standalone test is the instruction-listed alternative.

    Reverting the EndTurn-with-tool-blocks arm of [reconcile] (or breaking the
    [has_tool_blocks] predicate inside [Backend_anthropic.parse_response]) turns
    this RED: the response would land as [EndTurn] with a [ToolUse] block, so the
    stop_reason check fails. *)

open Alcotest
open Llm_provider

let stop_reason_testable =
  testable (fun fmt r -> Format.pp_print_string fmt (Types.show_stop_reason r)) ( = )
;;

(* A provider that emits a complete tool_use block but labels the turn
   [end_turn] (Anthropic wire) or [stop] (OpenAI/GLM finish_reason) is
   mislabeling a tool-request turn. [Backend_anthropic.parse_response] runs
   [stop_reason_of_string "end_turn" |> reconcile ~has_tool_blocks:true], which
   must upgrade to [StopToolUse] so the executable tool call is not left
   dangling (no tool_result). *)
let test_end_turn_with_tool_use_is_reconciled_to_stop_tool_use () =
  let json =
    `Assoc
      [ "id", `String "msg_bad"
      ; "model", `String "claude-4-sonnet"
      ; "stop_reason", `String "end_turn"
      ; ( "content"
        , `List
            [ `Assoc
                [ "type", `String "tool_use"
                ; "id", `String "tu_003"
                ; "name", `String "test"
                ; "input", `Assoc []
                ]
            ] )
      ; ( "usage"
        , `Assoc
            [ "input_tokens", `Int 10
            ; "output_tokens", `Int 5
            ; "cache_creation_input_tokens", `Int 0
            ; "cache_read_input_tokens", `Int 0
            ] )
      ]
  in
  let resp = Backend_anthropic.parse_response json in
  let tool_use_count =
    List.length
      (List.filter
         (function
           | Types.ToolUse _ -> true
           | _ -> false)
         resp.Types.content)
  in
  check
    stop_reason_testable
    "stop_reason reconciled to StopToolUse"
    Types.StopToolUse
    resp.Types.stop_reason;
  check int "exactly one tool_use block parsed" 1 tool_use_count
;;

let () =
  run
    "anthropic_reconcile_e2e"
    [ ( "end_turn_with_tool_blocks"
      , [ test_case
            "end_turn + tool_use reconciles to StopToolUse via parse_response"
            `Quick
            test_end_turn_with_tool_use_is_reconciled_to_stop_tool_use
        ] )
    ]
;;
