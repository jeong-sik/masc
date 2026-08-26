(** The transcript records the provider's tool-call id, or records nothing.

    An empty call_id used to become "tc-<position>" on both the transcript
    field and the delivery slot. The log writer answers the same absence by
    omitting the field, so one execution left two keys and the dashboard join
    — which matches on tool_use_id alone — could never pair them: the step
    stayed pending forever (#21894).

    The two are separate questions now. What the provider called it can be
    unanswered; where the reply goes cannot. The delivery address is a typed
    ordinal, never a provider id disguised as an execution id. *)

let module_path = "lib/keeper/keeper_chat_store.ml"

let test_the_record_half_can_be_absent () =
  let n =
    Ast_grep.count_value_bindings ~module_path ~name:"provider_tool_call_id"
  in
  if n <> 1 then
    Alcotest.failf
      "provider_tool_call_id must exist exactly once (found %d)" n
;;

(* [Tool_invocation_ref] states the rule this used to break: correlation
   identity is never inferred from names, arguments, timestamps, or hashes.
   Position is an inference, so it must not reach the recorded field. *)
let test_the_record_half_never_uses_position () =
  let n =
    Ast_grep.count_calls_in_value_binding ~module_path
      ~binding_name:"provider_tool_call_id" ~callee:"Printf.sprintf"
  in
  if n <> 0 then
    Alcotest.failf
      "provider_tool_call_id must not synthesise an id; it formats %d time(s)" n
;;

(* The delivery slot stays total without minting either identity. *)
let test_the_delivery_half_is_total () =
  let n = Ast_grep.count_value_bindings ~module_path ~name:"tool_transcript_slot" in
  if n <> 1 then
    Alcotest.failf "tool_transcript_slot must exist exactly once (found %d)" n
;;

let test_the_old_string_delivery_slot_is_gone () =
  let n = Ast_grep.count_value_bindings ~module_path ~name:"delivery_slot_id" in
  if n <> 0 then
    Alcotest.failf "delivery_slot_id must not exist (found %d binding(s))" n
;;

let test_no_delivery_id_is_cast_to_execution_id () =
  let n =
    Ast_grep.count_calls_in_value_binding ~module_path
      ~binding_name:"tool_transcript_slot" ~callee:"Ids.Execution_id.of_string"
  in
  if n <> 0 then
    Alcotest.failf
      "tool_transcript_slot must not cast a delivery id to execution identity (%d call(s))"
      n
;;

let test_append_once_uses_the_provider_record_boundary () =
  let n =
    Ast_grep.count_calls_in_value_binding ~module_path
      ~binding_name:"tool_call_append_lines" ~callee:"provider_tool_call_id"
  in
  if n <> 1 then
    Alcotest.failf
      "tool_call_append_lines must use provider_tool_call_id exactly once (found %d)"
      n
;;

let () =
  Alcotest.run "tool_call_id_is_not_invented"
    [ ( "identity split"
      , [ Alcotest.test_case "the record half can be absent" `Quick
            test_the_record_half_can_be_absent
        ; Alcotest.test_case "the record half never uses position" `Quick
            test_the_record_half_never_uses_position
        ; Alcotest.test_case "the delivery half is total" `Quick
            test_the_delivery_half_is_total
        ; Alcotest.test_case "the old string delivery slot is absent" `Quick
            test_the_old_string_delivery_slot_is_gone
        ; Alcotest.test_case "the delivery half never invents execution identity"
            `Quick test_no_delivery_id_is_cast_to_execution_id
        ; Alcotest.test_case "append-once uses the provider record boundary"
            `Quick test_append_once_uses_the_provider_record_boundary
        ] )
    ]
