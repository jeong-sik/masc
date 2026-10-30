(* One run of the voice setup wizard.

   The questions, their order, and the rule for when a draft is complete come
   from [Voice_wizard], which has no I/O and is shared with whatever surface
   asks the same questions next. What lives here is only what a terminal needs:
   the text being typed, the revision the session was opened against, and the
   last thing the server said. *)
(* Where the session's last save stands. Every save is numbered, and a reply is
   applied only while the session is waiting on that number. The replies used
   to carry nothing but their result and landed on whatever session was open
   when they arrived: after esc and a reopen, the new draft was marked saved,
   and a second save showed the first save's probe under it. *)
type voice_wizard_save =
  | Save_not_sent
  | Save_sending of int
  | Save_probing of int
      (** Written. The endpoints are being asked, and their answer carries this
          number. *)
  | Save_settled
  | Save_unanswered of { request : int; revision : string }
      (** Sent against [revision], and nothing came back that says whether it
          was written: the connection dropped or the deadline passed. The
          session reads runtime.toml again before it lets the draft be sent
          twice. *)
  | Save_needs_reopen of string
      (** The read after an unanswered save could not rule the write out. A
          retry would carry a revision this session no longer knows is
          current, so it waits for esc and a fresh read. The string says why. *)

type voice_wizard_session =
  { vws_draft : Voice_wizard.draft
  ; vws_step : Voice_wizard.step
  ; vws_input : string
  ; vws_replace_on_type : bool
        (** The first keystroke replaces a prefilled value rather than appending
            to it, the way the configuration editor does: the prefill is a
            suggestion, and typing over it is what an operator means. *)
  ; vws_revision : string
        (** What the configuration read as when this session opened. The save
            carries it, so a session left open while something else wrote is
            told rather than overwriting it. *)
  ; vws_status : string option
  ; vws_save : voice_wizard_save
  ; vws_probe : string list
        (** What each endpoint answered after the save, one line each. The
            wizard writes a configuration; whether anything on the other end
            responds is measured, not inferred from the write succeeding. *)
  }

let voice_wizard_value (draft : Voice_wizard.draft) (step : Voice_wizard.step) =
  match step with
  | Voice_wizard.Name -> draft.Voice_wizard.endpoint_id
  | Voice_wizard.Address -> draft.Voice_wizard.address
  | Voice_wizard.Credential -> draft.Voice_wizard.credential_variable
  | Voice_wizard.Model -> draft.Voice_wizard.model
  | Voice_wizard.Voice -> draft.Voice_wizard.voice
  | Voice_wizard.Section | Voice_wizard.Provider | Voice_wizard.Review -> ""

let voice_wizard_with_value (draft : Voice_wizard.draft) (step : Voice_wizard.step) value
  : Voice_wizard.draft
  =
  match step with
  | Voice_wizard.Name -> { draft with Voice_wizard.endpoint_id = value }
  | Voice_wizard.Address -> { draft with Voice_wizard.address = value }
  | Voice_wizard.Credential -> { draft with Voice_wizard.credential_variable = value }
  | Voice_wizard.Model -> { draft with Voice_wizard.model = value }
  | Voice_wizard.Voice -> { draft with Voice_wizard.voice = value }
  | Voice_wizard.Section | Voice_wizard.Provider | Voice_wizard.Review -> draft

let voice_wizard_open ~section ~provider ~revision =
  let draft = Voice_wizard.blank ~section ~provider in
  let step =
    match Voice_wizard.steps draft with
    | first :: _ -> first
    | [] -> Voice_wizard.Review
  in
  { vws_draft = draft
  ; vws_step = step
  ; vws_input = voice_wizard_value draft step
  ; vws_replace_on_type = true
  ; vws_revision = revision
  ; vws_status = None
  ; vws_save = Save_not_sent
  ; vws_probe = []
  }

let voice_wizard_is_sending session =
  match session.vws_save with
  | Save_sending _ -> true
  | Save_not_sent | Save_probing _ | Save_settled | Save_unanswered _ | Save_needs_reopen _ ->
    false

(* Changing the draft. The rows under it answered the save that was sent, and
   left there they read as answers about the draft now on screen -- a TTS probe
   stayed under a draft switched to STT. A probe still on its way is about that
   earlier draft too, so it is let go. A save whose outcome is unknown is not:
   editing does not tell the session whether runtime.toml was written. *)
let voice_wizard_edited session =
  { session with
    vws_probe = []
  ; vws_save =
      (match session.vws_save with
       | Save_probing _ | Save_settled -> Save_not_sent
       | (Save_not_sent | Save_sending _ | Save_unanswered _ | Save_needs_reopen _) as held ->
         held)
  }

let voice_wizard_append session text =
  voice_wizard_edited
    { session with
      vws_input = (if session.vws_replace_on_type then text else session.vws_input ^ text)
    ; vws_replace_on_type = false
    ; vws_status = None
    }

let voice_wizard_backspace session =
  voice_wizard_edited
    { session with
      vws_input =
        (if session.vws_replace_on_type then ""
         else Masc_tui_message_layout.drop_last_utf8_scalar session.vws_input)
    ; vws_replace_on_type = false
    ; vws_status = None
    }

let voice_wizard_clear session =
  voice_wizard_edited
    { session with vws_input = ""; vws_replace_on_type = false; vws_status = None }

(* Whether Enter on Review may send the draft, and what to say when not. *)
let voice_wizard_save_held session =
  match session.vws_save with
  | Save_not_sent | Save_probing _ | Save_settled -> None
  | Save_sending _ -> Some "saving…"
  | Save_unanswered _ ->
    Some "reading runtime.toml again to see whether the last save was written…"
  | Save_needs_reopen reason -> Some reason

let voice_wizard_sending session ~request =
  { session with vws_save = Save_sending request; vws_status = Some "saving…"; vws_probe = [] }

(* What came back for a save, already told apart: an answer that carries the
   revision the write produced, a refusal the server gave in words, and no
   answer at all. *)
type voice_wizard_save_reply =
  | Save_written of string
  | Save_refused of string
  | Save_unanswered_reply of string

(* [None] when the reply is not for the save this session is waiting on. *)
let voice_wizard_after_save session ~request reply =
  match session.vws_save with
  | Save_sending sent when sent = request ->
    Some
      (match reply with
       | Save_written revision ->
         (* The revision this save produced. The wizard stays open, and a second
            save from it has to carry this one, not the one read before. *)
         let session = { session with vws_revision = revision; vws_probe = [] } in
         (match session.vws_draft.Voice_wizard.section with
          | Voice_setup.Tts ->
            { session with
              vws_save = Save_probing request
            ; vws_status = Some "saved. asking the endpoints to answer…"
            }
          | Voice_setup.Stt ->
            (* Transcription needs audio this pane does not have. The CLI takes
               a file, and the runbook says how to make one. *)
            { session with
              vws_save = Save_settled
            ; vws_status = Some "saved. run  masc voice-verify --audio FILE  to hear it back"
            })
       | Save_refused message ->
         { session with vws_save = Save_not_sent; vws_status = Some message }
       | Save_unanswered_reply detail ->
         { session with
           vws_save = Save_unanswered { request; revision = session.vws_revision }
         ; vws_status =
             Some
               (Printf.sprintf
                  "the save got no answer (%s), so it may have been written. reading \
                   runtime.toml again…"
                  detail)
         })
  | Save_sending _ | Save_not_sent | Save_probing _ | Save_settled | Save_unanswered _
  | Save_needs_reopen _ ->
    None

let voice_wizard_after_probe session ~request result =
  match session.vws_save with
  | Save_probing sent when sent = request ->
    Some
      (match result with
       | Ok lines -> { session with vws_save = Save_settled; vws_status = Some "saved."; vws_probe = lines }
       | Error message -> { session with vws_save = Save_settled; vws_status = Some message })
  | Save_probing _ | Save_not_sent | Save_sending _ | Save_settled | Save_unanswered _
  | Save_needs_reopen _ ->
    None

(* The read taken after a save that got no answer. The same revision means
   nothing was written, so the draft can go again against it. A different one
   means runtime.toml moved -- by that save or by someone else -- and adopting
   it would let a retry overwrite a write this session never saw. *)
let voice_wizard_after_reread session ~request result =
  match session.vws_save with
  | Save_unanswered { request = sent; revision } when sent = request ->
    Some
      (match result with
       | Ok current when String.equal current revision ->
         { session with
           vws_save = Save_not_sent
         ; vws_status = Some "nothing was written. enter saves again"
         }
       | Ok _ ->
         let reason =
           "runtime.toml changed after the save that got no answer. esc, check the \
            endpoints, and open the wizard again"
         in
         { session with vws_save = Save_needs_reopen reason; vws_status = Some reason }
       | Error message ->
         let reason =
           Printf.sprintf
             "runtime.toml could not be read again (%s). esc and open the wizard again"
             message
         in
         { session with vws_save = Save_needs_reopen reason; vws_status = Some reason })
  | Save_unanswered _ | Save_not_sent | Save_sending _ | Save_probing _ | Save_settled
  | Save_needs_reopen _ ->
    None

(* Typing is kept out of the draft until the step is left, so backing out of a
   step does not carry a half-typed value with it. *)
let voice_wizard_commit session =
  let draft =
    voice_wizard_with_value session.vws_draft session.vws_step
      (String.trim session.vws_input)
  in
  { session with vws_draft = draft }

let voice_wizard_go session step =
  let session = voice_wizard_commit session in
  { session with
    vws_step = step
  ; vws_input = voice_wizard_value session.vws_draft step
  ; vws_replace_on_type = true
  ; vws_status = None
  }

(* The step list is recomputed from the draft each time rather than kept: the
   provider decides which steps exist, so changing it changes the list under
   the session. *)
let voice_wizard_neighbour session ~ahead =
  let steps = Voice_wizard.steps (voice_wizard_commit session).vws_draft in
  let rec walk previous = function
    | [] -> None
    | step :: rest ->
      if step = session.vws_step
      then if ahead then (match rest with next :: _ -> Some next | [] -> None) else previous
      else walk (Some step) rest
  in
  walk None steps

let voice_wizard_next session =
  match voice_wizard_neighbour session ~ahead:true with
  | Some step -> voice_wizard_go session step
  | None -> voice_wizard_commit session

let voice_wizard_previous session =
  match voice_wizard_neighbour session ~ahead:false with
  | Some step -> voice_wizard_go session step
  | None -> session

(* Providers are cycled rather than typed: the set is closed, and which ones a
   section can use is a rule Voice_wizard owns. *)
let voice_wizard_cycle_provider session =
  let offered = Voice_wizard.providers_for session.vws_draft.Voice_wizard.section in
  let rec next_after = function
    | [] -> None
    | provider :: rest ->
      if provider = session.vws_draft.Voice_wizard.provider
      then (match rest with candidate :: _ -> Some candidate | [] -> List.nth_opt offered 0)
      else next_after rest
  in
  match next_after offered with
  | None -> session
  | Some provider ->
    let draft =
      Voice_wizard.blank ~section:session.vws_draft.Voice_wizard.section ~provider
    in
    (* The name survives a provider change; everything else is provider
       vocabulary and would be wrong under the new one. *)
    let draft =
      { draft with
        Voice_wizard.endpoint_id = session.vws_draft.Voice_wizard.endpoint_id
      }
    in
    voice_wizard_edited
      { session with
        vws_draft = draft
      ; vws_input = voice_wizard_value draft session.vws_step
      ; vws_replace_on_type = true
      ; vws_status = None
      }

(* The side walks under the same keys the provider does: both are closed sets,
   and the reader is picking either way. *)
let voice_wizard_cycle_section session =
  let other =
    match session.vws_draft.Voice_wizard.section with
    | Voice_setup.Tts -> Voice_setup.Stt
    | Voice_setup.Stt -> Voice_setup.Tts
  in
  let draft = Voice_wizard.with_section session.vws_draft other in
  voice_wizard_edited
    { session with
      vws_draft = draft
    ; vws_input = voice_wizard_value draft session.vws_step
    ; vws_replace_on_type = true
    ; vws_status = None
    }
