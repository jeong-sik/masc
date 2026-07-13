(* RFC-0230: keeper mention reactivity.

   Two pure cores are tested here:
   - the boundary mention parse + match (RFC-0232 P4: parse at append,
     match persisted ids; the substring bug that made "@alicex" /
     "email@alice.com" false-match "@alice" must not recur).
   - pending message acknowledgement: stable row ids advance only through the
     exact source range injected into a completed turn. *)

open Alcotest

module MS = Masc.Keeper_world_observation_message_scope
module Store = Masc.Keeper_chat_store
module Lane = Masc.Keeper_lane_mentions

let targets = [ "alice" ]

(* Boundary-parse-then-match: the P4 equivalent of the deleted
   read-time [line_mentions]. *)
let lm content =
  Lane.ids_match
    ~target_ids:(Lane.target_ids_of targets)
    (Lane.mention_ids_of_content content)

let test_plain_mention () = check bool "@alice by another" true (lm "hey @alice look")

let test_alicex_not_matched () =
  check bool "@alicex is a different token" false (lm "ping @alicex now")
;;

let test_email_not_matched () =
  check bool "email@alice.com is one token" false (lm "send to email@alice.com")
;;

let test_case_insensitive () = check bool "@ALICE" true (lm "PING @ALICE NOW")
let test_trailing_punct () = check bool "@alice, comma" true (lm "ok @alice, thanks")
let test_no_mention () = check bool "no @target" false (lm "just chatting here")

let test_empty_targets () =
  check bool "no targets to match" false
    (Lane.ids_match
       ~target_ids:(Lane.target_ids_of [])
       (Lane.mention_ids_of_content "@alice"))
;;

let msg ~role ?(id = "test-msg") ?(ts = Some 1.0) ?(source = None) ?(speaker = None)
    ?(audio = None)
    ?(kind = Store.Row_kind.Utterance) ?(turn_ref = None) content
  : Store.chat_message
  =
  { id
  ; role
  ; content
  ; ts
  ; attachments = None
  ; tool_call_id = None
  ; tool_call_name = None
  ; source
  ; surface = None
  ; conversation_id = None
  ; external_message_id = None
  ; speaker
  ; audio
  ; blocks = None
  ; mentions = Masc.Keeper_lane_mentions.mention_ids_of_content content
  ; kind
  ; turn_ref
  ; stream_lifecycle = None
  }
;;

let contents pms = List.map snd pms

let turn_ref n = Some (Ids.Turn_ref.make ~trace_id:"trace-scope" ~absolute_turn:n)

let test_unanswered_mention_is_pending () =
  let messages = [ msg ~role:Store.Role.User ~ts:(Some 10.0) "@alice please look" ] in
  check (list string) "no later own line -> pending" [ "@alice please look" ]
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_answered_mention_is_cleared () =
  let turn_ref = turn_ref 1 in
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~turn_ref "@alice please look"
    ; msg ~role:Store.Role.Assistant ~ts:(Some 11.0) ~turn_ref "on it"
    ]
  in
  check (list string) "own line after mention -> cleared" []
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_rementioned_after_reply_is_pending () =
  let turn_ref = turn_ref 2 in
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~turn_ref "@alice first"
    ; msg ~role:Store.Role.Assistant ~ts:(Some 11.0) ~turn_ref "done"
    ; msg ~role:Store.Role.User ~ts:(Some 12.0) "@alice again"
    ]
  in
  check (list string) "new mention after reply -> pending" [ "@alice again" ]
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_assistant_self_mention_ignored () =
  let messages = [ msg ~role:Store.Role.Assistant ~ts:(Some 10.0) "@alice note to self" ] in
  check (list string) "own assistant line is never a pending mention" []
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let speaker_with authority : Store.speaker option =
  Some { speaker_id = None; speaker_name = None; speaker_authority = authority }
;;

let owner = speaker_with Store.Owner
let external_ = speaker_with Store.External

let test_owner_unmentioned_line_is_scope () =
  let messages = [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~speaker:owner "can you check the deploy" ] in
  check (list string) "operator without @ -> scope" [ "can you check the deploy" ]
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

let test_owner_mention_is_not_scope () =
  (* an owner line that mentions is a mention, not a scope message (disjoint) *)
  let messages = [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~speaker:owner "@alice check it" ] in
  check (list string) "owner mention excluded from scope" []
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

let test_external_unmentioned_is_not_scope () =
  let messages = [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~speaker:external_ "random channel chatter" ] in
  check (list string) "external without @ -> ignored" []
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

let test_answered_owner_line_is_cleared () =
  let turn_ref = turn_ref 3 in
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~speaker:owner ~turn_ref "please check"
    ; msg ~role:Store.Role.Assistant ~ts:(Some 11.0) ~turn_ref "done"
    ]
  in
  check (list string) "answered owner line -> cleared" []
    (contents (MS.pending_scope_of_messages ~targets messages))
;;

(* Exact causal acknowledgement properties. Stable lane ids and typed
   [turn_ref] joins decide consumption; wall-clock timestamps do not. *)

let test_skewed_clock_cannot_unanswer () =
  (* The reply's wall clock is *behind* the mention's (NTP step, skewed
     writer). The shared typed [turn_ref] still proves that it answers the
     user row. *)
  let turn_ref = turn_ref 4 in
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 100.0) ~turn_ref "@alice please look"
    ; msg ~role:Store.Role.Assistant ~ts:(Some 5.0) ~turn_ref "on it"
    ]
  in
  check (list string) "skewed reply ts still clears" []
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_ts_fuzz_does_not_change_pending () =
  (* Same lane, three ts assignments (ordered, reversed, absent): the
     pending set depends on lane order alone. *)
  let lane ts_of =
    let turn_ref = turn_ref 5 in
    [ msg ~role:Store.Role.User ~ts:(ts_of 0) ~turn_ref "@alice first"
    ; msg ~role:Store.Role.Assistant ~ts:(ts_of 1) ~turn_ref "done"
    ; msg ~role:Store.Role.User ~ts:(ts_of 2) "@alice again"
    ]
  in
  let expected = [ "@alice again" ] in
  List.iter
    (fun (label, ts_of) ->
      check (list string) label expected
        (contents (MS.pending_mentions_of_messages ~targets (lane ts_of))))
    [ ("ordered ts", fun i -> Some (float_of_int (10 + i)))
    ; ("reversed ts", fun i -> Some (float_of_int (10 - i)))
    ; ("absent ts", fun _ -> None)
    ]
;;

let test_none_ts_assistant_still_clears () =
  (* A paired assistant line without a timestamp still acknowledges the
     user row because the typed [turn_ref] is the causal join. *)
  let turn_ref = turn_ref 6 in
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~turn_ref "@alice please look"
    ; msg ~role:Store.Role.Assistant ~ts:None ~turn_ref "on it"
    ]
  in
  check (list string) "ts-less reply clears" []
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let tool_line : Store.chat_message =
  { id = "test-tool"
  ; role = Store.Role.Tool
  ; content = "{}"
  ; ts = Some 10.5
  ; attachments = None
  ; tool_call_id = Some "tc-0"
  ; tool_call_name = Some "Read"
  ; source = None
  ; surface = None
  ; conversation_id = None
  ; external_message_id = None
  ; speaker = None
  ; audio = None
  ; blocks = None
  ; mentions = []
  ; kind = Store.Row_kind.Utterance
  ; turn_ref = None
  ; stream_lifecycle = None
  }
;;

let test_tool_lines_do_not_clear () =
  (* Tool lines are the keeper *working*, not a causal acknowledgement. *)
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 10.0) "@alice please look"; tool_line ]
  in
  check (list string) "tool line is not an answer" [ "@alice please look" ]
    (contents (MS.pending_mentions_of_messages ~targets messages))
;;

let test_transport_failure_does_not_clear () =
  (* A transport-failure marker is the server recording a failed request
     terminal ("Keeper request failed: ..."), not the keeper answering;
     the user line stays pending so the keeper revisits it on its next
     turn. A real utterance afterwards still clears. *)
  let turn_ref = turn_ref 7 in
  let failure =
    msg ~role:Store.Role.Assistant ~ts:(Some 10.5)
      ~turn_ref
      ~kind:Store.Row_kind.Transport_failure
      "Keeper request failed: Idle detected"
  in
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 10.0) ~turn_ref "@alice please look"; failure ]
  in
  check (list string) "failure marker is not an answer" [ "@alice please look" ]
    (contents (MS.pending_mentions_of_messages ~targets messages));
  let answered =
    messages @ [ msg ~role:Store.Role.Assistant ~ts:(Some 11.0) ~turn_ref "done" ]
  in
  check (list string) "a real utterance still clears" []
    (contents (MS.pending_mentions_of_messages ~targets answered))
;;

let test_voice_audio_self_output_is_not_recent_context () =
  let audio =
    Some
      { Store.token = "voice-token-1"
      ; audio_url = None
      ; mime = "audio/mpeg"
      ; duration_sec = None
      ; message_text = "saying this out loud"
      ; device_id = None
      ; expired = false
      }
  in
  let messages =
    [ msg ~role:Store.Role.User ~ts:(Some 10.0) "please say it out loud"
    ; msg ~role:Store.Role.Assistant ~ts:(Some 11.0) ~audio
        "saying this out loud"
    ; msg ~role:Store.Role.Assistant ~ts:(Some 12.0) "text follow-up"
    ]
  in
  let lines = MS.recent_direct_conversation_of_messages messages in
  check (list string) "voice audio assistant row omitted from prompt context"
    [ "user"; "assistant" ]
    (List.map
       (fun (line : MS.recent_direct_line) ->
         MS.direct_line_role_to_label line.role)
       lines);
  check (list string) "spoken text is not quoted back"
    [ "please say it out loud"; "text follow-up" ]
    (List.map (fun (line : MS.recent_direct_line) -> line.content) lines)
;;

let test_unrelated_assistant_does_not_clear_pending () =
  let lane =
    [ msg ~id:"m1" ~role:Store.Role.User "@alice a"
    ; msg ~id:"m2" ~role:Store.Role.User ~speaker:owner "status?"
    ; msg ~id:"a1" ~role:Store.Role.Assistant "unrelated output"
    ]
  in
  check (list string) "unrelated assistant keeps mention pending" [ "@alice a" ]
    (contents (MS.pending_mentions_of_messages ~targets lane));
  check (list string) "unrelated assistant keeps scope pending" [ "status?" ]
    (contents (MS.pending_scope_of_messages ~targets lane))
;;

let test_ack_clears_only_injected_prefix () =
  let lane =
    [ msg ~id:"m1" ~role:Store.Role.User "@alice first"
    ; msg ~id:"m2" ~role:Store.Role.User ~speaker:owner "second"
    ; msg ~id:"m3" ~role:Store.Role.User "@alice arrived during turn"
    ]
  in
  let pending = MS.pending_messages_of_messages ~ack_id:"m2" ~targets lane in
  check (list string) "only rows after exact ack remain"
    [ "@alice arrived during turn" ]
    (List.map (fun (message : MS.pending_message) -> message.content) pending)
;;

let test_all_pending_rows_preserve_source_order_without_cap () =
  let lane =
    List.init 20 (fun index ->
      msg
        ~id:(Printf.sprintf "m%d" index)
        ~role:Store.Role.User
        (Printf.sprintf "@alice message-%d" index))
  in
  let pending = MS.pending_messages_of_messages ~targets lane in
  check int "no fixed pending cap" 20 (List.length pending);
  check (list string) "source order preserved"
    (List.init 20 (fun index -> Printf.sprintf "message-%d" index))
    (List.map
       (fun (message : MS.pending_message) ->
          String.sub message.content 7 (String.length message.content - 7))
       pending)
;;

let () =
  run "keeper_mention_scope"
    [ ( "boundary_mention_match"
      , [ test_case "plain" `Quick test_plain_mention
        ; test_case "alicex_not_matched" `Quick test_alicex_not_matched
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
    ; ( "causal_acknowledgement"
      , [ test_case "skewed_clock_cannot_unanswer" `Quick test_skewed_clock_cannot_unanswer
        ; test_case "ts_fuzz_invariant" `Quick test_ts_fuzz_does_not_change_pending
        ; test_case "none_ts_assistant_clears" `Quick test_none_ts_assistant_still_clears
        ; test_case "tool_lines_do_not_clear" `Quick test_tool_lines_do_not_clear
        ; test_case "transport_failure_does_not_clear" `Quick
            test_transport_failure_does_not_clear
        ; test_case "voice_audio_self_output_not_recent_context" `Quick
            test_voice_audio_self_output_is_not_recent_context
        ; test_case "unrelated_assistant_does_not_clear" `Quick
            test_unrelated_assistant_does_not_clear_pending
        ; test_case "ack_clears_only_injected_prefix" `Quick
            test_ack_clears_only_injected_prefix
        ; test_case "all_rows_source_order_no_cap" `Quick
            test_all_pending_rows_preserve_source_order_without_cap
        ] )
    ]
;;
