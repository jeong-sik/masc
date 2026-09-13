(* The terminal half of the wizard: which step it is on, what has been typed,
   and what survives moving between steps. The questions themselves are
   Voice_wizard's and tested there; what these fix is that an operator who goes
   back to change an answer finds the answer they gave, and that switching the
   side or the provider does not leave a draft in a shape its own rules refuse. *)

module T = Masc_tui_types

let session () =
  T.voice_wizard_open ~section:Voice_setup.Tts ~provider:Voice_wizard.Elevenlabs
    ~revision:"rev-1"

let step_name : Voice_wizard.step -> string = function
  | Voice_wizard.Section -> "section"
  | Voice_wizard.Provider -> "provider"
  | Voice_wizard.Name -> "name"
  | Voice_wizard.Address -> "address"
  | Voice_wizard.Credential -> "credential"
  | Voice_wizard.Model -> "model"
  | Voice_wizard.Voice -> "voice"
  | Voice_wizard.Review -> "review"

let test_a_session_opens_on_the_first_question () =
  let opened = session () in
  Alcotest.(check string) "which side, first" "section" (step_name opened.T.vws_step);
  Alcotest.(check string) "carrying the revision it read" "rev-1" opened.T.vws_revision;
  Alcotest.(check bool) "and nothing probed yet" true (opened.T.vws_probe = [])

(* The prefill is a suggestion. Typing over it is what an operator means, so the
   first keystroke replaces rather than appends. *)
let test_the_first_keystroke_replaces_a_prefilled_value () =
  let typing =
    session () |> fun s ->
    T.voice_wizard_go s Voice_wizard.Credential
  in
  Alcotest.(check string) "ElevenLabs arrives with its usual variable"
    "ELEVENLABS_API_KEY" typing.T.vws_input;
  let typed = T.voice_wizard_append typing "M" in
  Alcotest.(check string) "the first key replaced it" "M" typed.T.vws_input;
  let typed = T.voice_wizard_append typed "Y" in
  Alcotest.(check string) "the second appended" "MY" typed.T.vws_input

let test_backspace_drops_one_scalar_not_one_byte () =
  let typing = T.voice_wizard_go (session ()) Voice_wizard.Name in
  let typed = T.voice_wizard_append typing "음성" in
  let cut = T.voice_wizard_backspace typed in
  Alcotest.(check string) "one character, not one byte" "음" cut.T.vws_input

(* Going back to change an answer has to find the answer that was given, or the
   operator retypes it every time they check something earlier. *)
let test_going_back_finds_what_was_typed () =
  let s = T.voice_wizard_go (session ()) Voice_wizard.Name in
  let s = T.voice_wizard_append s "elevenlabs-direct" in
  let s = T.voice_wizard_next s in
  Alcotest.(check string) "moved on" "credential" (step_name s.T.vws_step);
  let back = T.voice_wizard_previous s in
  Alcotest.(check string) "back on the name" "name" (step_name back.T.vws_step);
  Alcotest.(check string) "with the name that was typed" "elevenlabs-direct"
    back.T.vws_input

let test_typing_reaches_the_draft_only_on_leaving_the_step () =
  let s = T.voice_wizard_go (session ()) Voice_wizard.Name in
  let s = T.voice_wizard_append s "half" in
  Alcotest.(check string) "the draft has not taken it yet" ""
    s.T.vws_draft.Voice_wizard.endpoint_id;
  let s = T.voice_wizard_next s in
  Alcotest.(check string) "leaving the step commits it" "half"
    s.T.vws_draft.Voice_wizard.endpoint_id

(* An MCP tool speaks and does not listen. Carrying it to speech in would leave
   a draft whose provider is not in its own offered list. *)
let test_switching_to_speech_in_drops_a_provider_that_cannot_listen () =
  let s =
    T.voice_wizard_open ~section:Voice_setup.Tts ~provider:Voice_wizard.Mcp_tool
      ~revision:"rev-1"
  in
  let s = T.voice_wizard_go s Voice_wizard.Name in
  let s = T.voice_wizard_append s "kept" in
  let s = T.voice_wizard_commit s in
  let switched = T.voice_wizard_cycle_section s in
  Alcotest.(check bool) "now speech in" true
    (switched.T.vws_draft.Voice_wizard.section = Voice_setup.Stt);
  Alcotest.(check bool) "on a provider speech in can use" true
    (List.mem switched.T.vws_draft.Voice_wizard.provider
       (Voice_wizard.providers_for Voice_setup.Stt));
  Alcotest.(check string) "the name survives" "kept"
    switched.T.vws_draft.Voice_wizard.endpoint_id

let test_cycling_the_provider_keeps_the_name_and_drops_the_rest () =
  let s = T.voice_wizard_go (session ()) Voice_wizard.Name in
  let s = T.voice_wizard_commit (T.voice_wizard_append s "named") in
  let cycled = T.voice_wizard_cycle_provider s in
  Alcotest.(check bool) "the provider moved" true
    (cycled.T.vws_draft.Voice_wizard.provider <> Voice_wizard.Elevenlabs);
  Alcotest.(check string) "the name survives" "named"
    cycled.T.vws_draft.Voice_wizard.endpoint_id;
  (* ElevenLabs arrives with a credential variable; an OpenAI-compatible
     endpoint must not inherit it, or it sends a header the local server never
     asked for. *)
  Alcotest.(check string) "the credential variable did not come along" ""
    cycled.T.vws_draft.Voice_wizard.credential_variable

let test_the_last_step_is_review_and_next_stays_there () =
  let rec walk s guard =
    if guard = 0 then s
    else if s.T.vws_step = Voice_wizard.Review then s
    else walk (T.voice_wizard_next s) (guard - 1)
  in
  let ended = walk (session ()) 20 in
  Alcotest.(check string) "walking forward ends on review" "review"
    (step_name ended.T.vws_step);
  let again = T.voice_wizard_next ended in
  Alcotest.(check string) "and next stays there rather than falling off" "review"
    (step_name again.T.vws_step)

let expect what = function
  | Some session -> session
  | None -> Alcotest.failf "%s should have been applied" what

let save_state (session : T.voice_wizard_session) =
  match session.T.vws_save with
  | T.Save_not_sent -> "not sent"
  | T.Save_sending n -> Printf.sprintf "sending %d" n
  | T.Save_probing n -> Printf.sprintf "probing %d" n
  | T.Save_settled -> "settled"
  | T.Save_unanswered { request; revision } -> Printf.sprintf "unanswered %d at %s" request revision
  | T.Save_needs_reopen _ -> "needs reopen"

(* The replies used to carry only their result and were put on whatever session
   was open when they arrived. A save made before esc marked the reopened draft
   saved, and the first of two saves showed its probe under the second. *)
let test_a_reply_for_another_save_is_dropped () =
  let first = T.voice_wizard_sending (session ()) ~request:1 in
  let reopened = T.voice_wizard_sending (session ()) ~request:2 in
  Alcotest.(check bool) "a reopened session ignores the earlier save's answer" true
    (T.voice_wizard_after_save reopened ~request:1 (T.Save_written "rev-2") = None);
  let saved = expect "its own answer" (T.voice_wizard_after_save first ~request:1 (T.Save_written "rev-2")) in
  Alcotest.(check string) "a speech-out save goes on to ask the endpoints" "probing 1"
    (save_state saved);
  Alcotest.(check string) "against the revision the write produced" "rev-2" saved.T.vws_revision;
  let again = T.voice_wizard_sending saved ~request:3 in
  Alcotest.(check bool) "the first probe does not land under the second save" true
    (T.voice_wizard_after_probe again ~request:1 (Ok [ "old" ]) = None);
  let written = expect "the second save" (T.voice_wizard_after_save again ~request:3 (T.Save_written "rev-3")) in
  let answered = expect "its probe" (T.voice_wizard_after_probe written ~request:3 (Ok [ "row" ])) in
  Alcotest.(check (list string)) "only the second save's rows" [ "row" ] answered.T.vws_probe;
  Alcotest.(check string) "and the save is done" "settled" (save_state answered)

(* The rows answered the draft that was saved. Switching the side, or typing,
   makes a different draft, and rows left under it read as answers about it. *)
let test_changing_the_draft_lets_go_of_the_answers () =
  let saved =
    T.voice_wizard_sending (session ()) ~request:1
    |> fun s -> expect "save" (T.voice_wizard_after_save s ~request:1 (T.Save_written "rev-2"))
  in
  let answered = expect "probe" (T.voice_wizard_after_probe saved ~request:1 (Ok [ "tts row" ])) in
  let switched = T.voice_wizard_cycle_section (T.voice_wizard_go answered Voice_wizard.Section) in
  Alcotest.(check (list string)) "switching to speech in clears the speech-out rows" []
    switched.T.vws_probe;
  Alcotest.(check string) "and nothing is counted as saved for the new draft" "not sent"
    (save_state switched);
  let typed = T.voice_wizard_append (T.voice_wizard_go saved Voice_wizard.Name) "x" in
  Alcotest.(check bool) "a probe still on its way is let go once the draft is edited" true
    (T.voice_wizard_after_probe typed ~request:1 (Ok [ "late" ]) = None);
  let stepped = T.voice_wizard_previous answered in
  Alcotest.(check (list string)) "looking back at a step is not an edit" [ "tts row" ]
    stepped.T.vws_probe

(* A dropped connection or a passed deadline after the server commits left the
   session holding the revision from before the write; a retry was refused as a
   conflict and nothing re-read the file. *)
let test_an_unanswered_save_is_read_again_before_it_can_go_twice () =
  let unanswered () =
    let sent = T.voice_wizard_sending (session ()) ~request:1 in
    expect "unanswered" (T.voice_wizard_after_save sent ~request:1 (T.Save_unanswered_reply "timeout"))
  in
  let waiting = unanswered () in
  Alcotest.(check string) "held against the revision it was sent with" "unanswered 1 at rev-1"
    (save_state waiting);
  Alcotest.(check bool) "enter does not send it again yet" true
    (T.voice_wizard_save_held waiting <> None);
  Alcotest.(check string) "and editing does not decide it" "unanswered 1 at rev-1"
    (save_state (T.voice_wizard_append (T.voice_wizard_go waiting Voice_wizard.Name) "x"));
  Alcotest.(check bool) "a read for another save is ignored" true
    (T.voice_wizard_after_reread waiting ~request:2 (Ok "rev-1") = None);
  let unchanged = expect "same revision" (T.voice_wizard_after_reread waiting ~request:1 (Ok "rev-1")) in
  Alcotest.(check string) "the same revision means nothing was written" "not sent"
    (save_state unchanged);
  Alcotest.(check bool) "so it may go again" true (T.voice_wizard_save_held unchanged = None);
  let moved = expect "moved" (T.voice_wizard_after_reread (unanswered ()) ~request:1 (Ok "rev-9")) in
  Alcotest.(check string) "a moved revision cannot be adopted" "needs reopen" (save_state moved);
  Alcotest.(check bool) "and holds the retry" true (T.voice_wizard_save_held moved <> None);
  let unread =
    expect "unread" (T.voice_wizard_after_reread (unanswered ()) ~request:1 (Error "HTTP 500"))
  in
  Alcotest.(check string) "a read that fails rules nothing out" "needs reopen" (save_state unread)

let test_a_refusal_leaves_the_draft_ready_to_send () =
  let sent = T.voice_wizard_sending (session ()) ~request:1 in
  let refused = expect "refusal" (T.voice_wizard_after_save sent ~request:1 (T.Save_refused "no")) in
  Alcotest.(check string) "the server said no, so nothing is outstanding" "not sent"
    (save_state refused);
  Alcotest.(check (option string)) "in its own words" (Some "no") refused.T.vws_status

let () =
  Alcotest.run
    "voice_wizard_session"
    [ ( "opening"
      , [ Alcotest.test_case "a session opens on the first question" `Quick
            test_a_session_opens_on_the_first_question
        ; Alcotest.test_case "the last step is review and next stays there" `Quick
            test_the_last_step_is_review_and_next_stays_there
        ] )
    ; ( "typing"
      , [ Alcotest.test_case "the first keystroke replaces a prefilled value" `Quick
            test_the_first_keystroke_replaces_a_prefilled_value
        ; Alcotest.test_case "backspace drops one scalar not one byte" `Quick
            test_backspace_drops_one_scalar_not_one_byte
        ; Alcotest.test_case "typing reaches the draft only on leaving the step" `Quick
            test_typing_reaches_the_draft_only_on_leaving_the_step
        ; Alcotest.test_case "going back finds what was typed" `Quick
            test_going_back_finds_what_was_typed
        ] )
    ; ( "saving"
      , [ Alcotest.test_case "a reply for another save is dropped" `Quick
            test_a_reply_for_another_save_is_dropped
        ; Alcotest.test_case "changing the draft lets go of the answers" `Quick
            test_changing_the_draft_lets_go_of_the_answers
        ; Alcotest.test_case "an unanswered save is read again before it can go twice"
            `Quick test_an_unanswered_save_is_read_again_before_it_can_go_twice
        ; Alcotest.test_case "a refusal leaves the draft ready to send" `Quick
            test_a_refusal_leaves_the_draft_ready_to_send
        ] )
    ; ( "switching"
      , [ Alcotest.test_case "switching to speech in drops a provider that cannot listen"
            `Quick test_switching_to_speech_in_drops_a_provider_that_cannot_listen
        ; Alcotest.test_case "cycling the provider keeps the name and drops the rest"
            `Quick test_cycling_the_provider_keeps_the_name_and_drops_the_rest
        ] )
    ]
