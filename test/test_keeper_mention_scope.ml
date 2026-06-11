(* RFC-0230: keeper mention reactivity.

   Two pure cores are tested here:
   - line_mentions: token-equality @-mention match (the substring bug that made
     "@dreamerx" / "email@dreamer.com" false-match "@dreamer" must not recur).
   - pending_mentions_of_messages: the lane-is-the-state watermark — a mention
     is pending iff it arrives after the keeper's own last line. *)

open Alcotest

module MS = Masc.Keeper_world_observation_message_scope
module Store = Masc.Keeper_chat_store

let targets = [ "dreamer" ]
let lm content = MS.line_mentions ~targets content

let test_plain_mention () = check bool "@dreamer by another" true (lm "hey @dreamer look")

let test_dreamerx_not_matched () =
  check bool "@dreamerx is a different token" false (lm "ping @dreamerx now")
;;

let test_email_not_matched () =
  check bool "email@dreamer.com is one token" false (lm "send to email@dreamer.com")
;;

let test_case_insensitive () = check bool "@DREAMER" true (lm "PING @DREAMER NOW")
let test_trailing_punct () = check bool "@dreamer, comma" true (lm "ok @dreamer, thanks")
let test_no_mention () = check bool "no @target" false (lm "just chatting here")

let test_empty_targets () =
  check bool "no targets to match" false (MS.line_mentions ~targets:[] "@dreamer")
;;

let msg ~role ?(ts = Some 1.0) ?(source = None) ?(speaker = None) content
  : Store.chat_message
  =
  { role
  ; content
  ; ts
  ; attachments = None
  ; tool_call_id = None
  ; tool_call_name = None
  ; source
  ; conversation_id = None
  ; external_message_id = None
  ; speaker
  }
;;

let contents pms = List.map snd pms

let test_unanswered_mention_is_pending () =
  let messages = [ msg ~role:"user" ~ts:(Some 10.0) "@dreamer please look" ] in
  check (list string) "no later own line -> pending" [ "@dreamer please look" ]
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_answered_mention_is_cleared () =
  let messages =
    [ msg ~role:"user" ~ts:(Some 10.0) "@dreamer please look"
    ; msg ~role:"assistant" ~ts:(Some 11.0) "on it"
    ]
  in
  check (list string) "own line after mention -> cleared" []
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_rementioned_after_reply_is_pending () =
  let messages =
    [ msg ~role:"user" ~ts:(Some 10.0) "@dreamer first"
    ; msg ~role:"assistant" ~ts:(Some 11.0) "done"
    ; msg ~role:"user" ~ts:(Some 12.0) "@dreamer again"
    ]
  in
  check (list string) "new mention after reply -> pending" [ "@dreamer again" ]
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_assistant_self_mention_ignored () =
  let messages = [ msg ~role:"assistant" ~ts:(Some 10.0) "@dreamer note to self" ] in
  check (list string) "own assistant line is never a pending mention" []
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let speaker_with authority : Store.speaker option =
  Some { speaker_id = None; speaker_name = None; speaker_authority = authority }
;;

let owner = speaker_with Store.Owner
let external_ = speaker_with Store.External

let test_owner_unmentioned_line_is_scope () =
  let messages = [ msg ~role:"user" ~ts:(Some 10.0) ~speaker:owner "can you check the deploy" ] in
  check (list string) "operator without @ -> scope" [ "can you check the deploy" ]
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

let test_owner_mention_is_not_scope () =
  (* an owner line that mentions is a mention, not a scope message (disjoint) *)
  let messages = [ msg ~role:"user" ~ts:(Some 10.0) ~speaker:owner "@dreamer check it" ] in
  check (list string) "owner mention excluded from scope" []
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

let test_external_unmentioned_is_not_scope () =
  let messages = [ msg ~role:"user" ~ts:(Some 10.0) ~speaker:external_ "random channel chatter" ] in
  check (list string) "external without @ -> ignored" []
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

let test_answered_owner_line_is_cleared () =
  let messages =
    [ msg ~role:"user" ~ts:(Some 10.0) ~speaker:owner "please check"
    ; msg ~role:"assistant" ~ts:(Some 11.0) "done"
    ]
  in
  check (list string) "answered owner line -> cleared" []
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

let () =
  run "keeper_mention_scope"
    [ ( "line_mentions"
      , [ test_case "plain" `Quick test_plain_mention
        ; test_case "dreamerx_not_matched" `Quick test_dreamerx_not_matched
        ; test_case "email_not_matched" `Quick test_email_not_matched
        ; test_case "case_insensitive" `Quick test_case_insensitive
        ; test_case "trailing_punct" `Quick test_trailing_punct
        ; test_case "no_mention" `Quick test_no_mention
        ; test_case "empty_targets" `Quick test_empty_targets
        ] )
    ; ( "pending_mentions_of_messages"
      , [ test_case "unanswered_pending" `Quick test_unanswered_mention_is_pending
        ; test_case "answered_cleared" `Quick test_answered_mention_is_cleared
        ; test_case "rementioned_pending" `Quick test_rementioned_after_reply_is_pending
        ; test_case "assistant_self_ignored" `Quick test_assistant_self_mention_ignored
        ] )
    ; ( "pending_scope_of_messages"
      , [ test_case "owner_unmentioned_is_scope" `Quick test_owner_unmentioned_line_is_scope
        ; test_case "owner_mention_not_scope" `Quick test_owner_mention_is_not_scope
        ; test_case "external_unmentioned_ignored" `Quick test_external_unmentioned_is_not_scope
        ; test_case "answered_owner_cleared" `Quick test_answered_owner_line_is_cleared
        ] )
    ]
;;
