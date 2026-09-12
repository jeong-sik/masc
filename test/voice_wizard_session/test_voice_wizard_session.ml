(* The terminal half of the wizard: which step it is on, what has been typed,
   and what survives moving between steps. The questions themselves are
   Voice_wizard's and tested there; what these fix is that an operator who goes
   back to change an answer finds the answer they gave, and that switching the
   side or the provider does not leave a draft in a shape its own rules refuse. *)

module T = Masc_tui_types

let session () =
  T.voice_wizard_open ~section:Voice_setup.Tts ~revision:"rev-1"

(* The session opens on whatever the section offers first, which for speech out
   is say -- the entry that needs nothing installed. Cases about a provider
   with an address or a key walk to it the way an operator does. *)
let rec walk_to session provider guard =
  if guard = 0
  then Alcotest.failf "never reached the provider under test"
  else if session.T.vws_draft.Voice_wizard.provider = provider
  then session
  else walk_to (T.voice_wizard_cycle_provider session) provider (guard - 1)

let session_on provider =
  walk_to (T.voice_wizard_go (session ()) Voice_wizard.Provider) provider 8

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
    T.voice_wizard_go (session_on Voice_wizard.Elevenlabs) Voice_wizard.Credential
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
  let s = T.voice_wizard_go (session_on Voice_wizard.Elevenlabs) Voice_wizard.Name in
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
    T.voice_wizard_open ~section:Voice_setup.Tts ~revision:"rev-1"
    |> fun opened ->
    (* Walked to the tool kind rather than opened on it: the session opens on
       whatever the section offers first, which is deliberately not this. *)
    let rec walk_to_tool session guard =
      if guard = 0 then session
      else if session.T.vws_draft.Voice_wizard.provider = Voice_wizard.Mcp_tool
      then session
      else walk_to_tool (T.voice_wizard_cycle_provider session) (guard - 1)
    in
    walk_to_tool (T.voice_wizard_go opened Voice_wizard.Provider) 6
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
  let s = T.voice_wizard_go (session_on Voice_wizard.Elevenlabs) Voice_wizard.Name in
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

let test_enter_commits_the_highlighted_first_voice () =
  let s = T.voice_wizard_go (session ()) Voice_wizard.Voice in
  let s = T.voice_wizard_with_voices s [ "Yuna", "Korean"; "Alex", "English" ] in
  Alcotest.(check string) "the highlighted row is the current input" "Yuna" s.T.vws_input;
  let next = T.voice_wizard_next s in
  Alcotest.(check string) "Enter commits the highlighted voice" "Yuna"
    next.T.vws_draft.Voice_wizard.voice

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
        ; Alcotest.test_case "Enter commits the highlighted first voice" `Quick
            test_enter_commits_the_highlighted_first_voice
        ] )
    ; ( "switching"
      , [ Alcotest.test_case "switching to speech in drops a provider that cannot listen"
            `Quick test_switching_to_speech_in_drops_a_provider_that_cannot_listen
        ; Alcotest.test_case "cycling the provider keeps the name and drops the rest"
            `Quick test_cycling_the_provider_keeps_the_name_and_drops_the_rest
        ] )
    ]
