(** OAS message smart-constructor contract (masc axis-1b — under-wired OAS
    consumption).

    Seven MASC sites delegated hand-rolled [Agent_sdk.Types.message] record
    literals to the OAS smart constructors instead of re-spelling the
    [{ role; content; name = None; tool_call_id = None; metadata = [] }] shape:
    [user_msg], [user_msg_blocks], [assistant_msg], [text_message],
    [make_message], [text_block], and [text_of_content] (the last replacing a
    synthetic User message built only to call [text_of_message]).

    These tests pin the exact records/strings those constructors produce, so a
    future OAS change to a default (metadata, a new message field, role mapping)
    surfaces here instead of silently diverging the messages MASC builds. They
    document the byte-identical equivalence each delegation relies on. *)

open Alcotest
module T = Agent_sdk.Types

(* Canonical message shape the delegated sites previously hand-rolled. *)
let msg ?(role = T.User) ?(name = None) ?(tool_call_id = None) ?(metadata = [])
    content : T.message =
  { role; content; name; tool_call_id; metadata }

let test_user_msg () =
  check bool "user_msg = User single-Text record" true
    (T.user_msg "hi" = msg [ T.Text "hi" ])

let test_user_msg_blocks () =
  let blocks = [ T.Text "a"; T.Text "b" ] in
  check bool "user_msg_blocks = User record with given blocks" true
    (T.user_msg_blocks blocks = msg blocks)

let test_assistant_msg () =
  check bool "assistant_msg = Assistant single-Text record" true
    (T.assistant_msg "yo" = msg ~role:T.Assistant [ T.Text "yo" ])

let test_text_message () =
  check bool "text_message role = single-Text record with that role" true
    (T.text_message T.System "s" = msg ~role:T.System [ T.Text "s" ])

let test_make_message () =
  let block = T.Text "b" in
  check bool "make_message ~role content = record, defaults None/None/[]" true
    (T.make_message ~role:T.Tool [ block ] = msg ~role:T.Tool [ block ])

let test_text_block () =
  check bool "text_block = Text constructor" true (T.text_block "x" = T.Text "x")

let test_text_of_content_matches_text_of_message () =
  (* keeper_context_core_message_json drops a synthetic User envelope:
     text_of_message ignores role/name/etc and reads only content. *)
  let blocks = [ T.Text "alpha"; T.Text "beta" ] in
  check string "text_of_content = text_of_message of the wrapping User msg"
    (T.text_of_message (msg blocks))
    (T.text_of_content blocks)

let () =
  run "oas_message_constructor_contract"
    [ ( "contract"
      , [ test_case "user_msg" `Quick test_user_msg
        ; test_case "user_msg_blocks" `Quick test_user_msg_blocks
        ; test_case "assistant_msg" `Quick test_assistant_msg
        ; test_case "text_message" `Quick test_text_message
        ; test_case "make_message" `Quick test_make_message
        ; test_case "text_block" `Quick test_text_block
        ; test_case "text_of_content matches text_of_message" `Quick
            test_text_of_content_matches_text_of_message
        ] )
    ]
