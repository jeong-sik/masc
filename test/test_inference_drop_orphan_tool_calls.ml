(** Unit tests for [Runtime_orphan_tool_calls.drop] (#25278).

    A [ToolUse] persisted without its [ToolResult] (a turn interrupted between
    the call and its result) replays every turn and wedges the keeper: the
    provider rejects "an assistant message with 'tool_calls' must be followed
    by tool messages responding to each 'tool_call_id'". The sanitizer drops
    such orphaned calls at the outgoing-request boundary, is a no-op on
    well-formed lists, and never touches orphaned [ToolResult] blocks (OAS
    preserves those by contract). *)

open Masc
module T = Agent_sdk.Types

let assistant blocks = T.make_message ~role:T.Assistant blocks
let user text = T.make_message ~role:T.User [ T.Text text ]
let tool_use ~id = T.ToolUse { id; name = "some_tool"; input = `Null }

let tool_result_block ~tool_use_id =
  T.ToolResult
    { tool_use_id
    ; content = "ok"
    ; outcome = T.Tool_succeeded
    ; json = None
    ; content_blocks = None
    }
;;

let tool_result ~tool_use_id =
  T.make_message ~role:T.Tool [ tool_result_block ~tool_use_id ]
;;

let tool_use_ids msgs =
  List.concat_map
    (fun (m : T.message) ->
       List.filter_map
         (function
           | T.ToolUse { id; _ } -> Some id
           | _ -> None)
         m.content)
    msgs
;;

let has_text needle msgs =
  List.exists
    (fun (m : T.message) ->
       List.exists
         (function
           | T.Text s -> String.equal s needle
           | _ -> false)
         m.content)
    msgs
;;

(* An unanswered ToolUse is dropped while an answered one and sibling text
   survive. *)
let test_orphan_dropped () =
  let msgs =
    [ user "hi"
    ; assistant [ T.Text "working"; tool_use ~id:"a"; tool_use ~id:"b" ]
    ; tool_result ~tool_use_id:"b"
    ; user "continue"
    ]
  in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check (list string)) "only answered call 'b' remains" [ "b" ] (tool_use_ids out);
  Alcotest.(check bool) "sibling text preserved" true (has_text "working" out)
;;

(* An assistant message left empty by orphan removal is dropped entirely. *)
let test_emptied_assistant_message_dropped () =
  let msgs = [ user "hi"; assistant [ tool_use ~id:"x" ]; user "next" ] in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check int) "emptied assistant turn removed" 2 (List.length out);
  Alcotest.(check (list string)) "no tool_use remains" [] (tool_use_ids out)
;;

(* A well-formed list is returned physically unchanged (no-op fast path). *)
let test_no_orphan_is_identity () =
  let msgs =
    [ user "hi"; assistant [ tool_use ~id:"a" ]; tool_result ~tool_use_id:"a" ]
  in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check bool) "no-op returns the same list" true (out == msgs)
;;

(* An orphaned ToolResult (no preceding ToolUse) is preserved: OAS owns that
   contract, and it does not trigger the assistant-tool_calls invariant. *)
let test_orphan_tool_result_preserved () =
  let msgs = [ user "hi"; tool_result ~tool_use_id:"ghost" ] in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check int) "orphan tool_result untouched" 2 (List.length out)
;;

(* Role scoping: a [ToolUse] on a non-assistant (here User) message is malformed
   but out of scope for the assistant-tool_calls invariant, so it is left
   untouched rather than stripped. *)
let test_tooluse_on_non_assistant_preserved () =
  let msgs = [ T.make_message ~role:T.User [ T.Text "hi"; tool_use ~id:"u" ] ] in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check (list string)) "non-assistant ToolUse kept" [ "u" ] (tool_use_ids out);
  Alcotest.(check bool) "no-op returns the same list" true (out == msgs)
;;

(* Positional matching: a result that *precedes* its call does not answer it —
   the provider requires the result to follow the call — so the call is an
   orphan and is dropped. *)
let test_result_before_call_is_orphan () =
  let msgs = [ tool_result ~tool_use_id:"a"; assistant [ tool_use ~id:"a" ] ] in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check (list string)) "call preceded by its result is orphan" [] (tool_use_ids out)
;;

(* Role scoping: a [ToolResult] on a role that never carries answers (here
   System) does not count, so the matching call stays an orphan and is dropped. *)
let test_result_on_wrong_role_does_not_answer () =
  let msgs =
    [ assistant [ tool_use ~id:"a" ]
    ; T.make_message ~role:T.System [ tool_result_block ~tool_use_id:"a" ]
    ]
  in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check (list string)) "result on System role does not rescue call" [] (tool_use_ids out)
;;

(* Anthropic wire format carries tool_result blocks in a User-role turn. Such a
   result is a legitimate answer and must rescue its call (regression guard: a
   Tool-only answer scope would drop the call as a false orphan). *)
let test_user_role_result_answers_call () =
  let msgs =
    [ assistant [ tool_use ~id:"a" ]
    ; T.make_message ~role:T.User [ tool_result_block ~tool_use_id:"a" ]
    ]
  in
  let out = Runtime_orphan_tool_calls.drop msgs in
  Alcotest.(check bool) "User-role result is answered, no orphan drop" true (out == msgs);
  Alcotest.(check (list string)) "call kept" [ "a" ] (tool_use_ids out)
;;

let () =
  Alcotest.run
    "inference_drop_orphan_tool_calls"
    [ ( "drop_orphan_tool_calls"
      , [ Alcotest.test_case "orphan call dropped, answered kept" `Quick test_orphan_dropped
        ; Alcotest.test_case
            "emptied assistant message dropped"
            `Quick
            test_emptied_assistant_message_dropped
        ; Alcotest.test_case "no orphan is identity" `Quick test_no_orphan_is_identity
        ; Alcotest.test_case
            "orphan tool_result preserved"
            `Quick
            test_orphan_tool_result_preserved
        ; Alcotest.test_case
            "ToolUse on non-assistant role preserved"
            `Quick
            test_tooluse_on_non_assistant_preserved
        ; Alcotest.test_case
            "result before call is orphan"
            `Quick
            test_result_before_call_is_orphan
        ; Alcotest.test_case
            "result on wrong role does not answer"
            `Quick
            test_result_on_wrong_role_does_not_answer
        ; Alcotest.test_case
            "User-role (Anthropic) result answers call"
            `Quick
            test_user_role_result_answers_call
        ] )
    ]
;;
