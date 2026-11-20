module T = Masc_tui_types
module P = Masc_tui_async_protocol
module W = Masc_tui_words
module WA = Masc_tui_transport.Workspace_admission

let fork_voice_daemon ~enqueue_async ~mailbox ~fallback f =
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
        f ();
        `Stop_daemon)
  | None -> enqueue_async mailbox (fallback "Eio switch is unavailable")

(* Writing a configuration is not the same as it working. After the save, every
   configured endpoint is asked to say one sentence, and each answer is shown --
   including the ones that refused, which is the part a chain hides by stopping
   at the first endpoint that answers. *)

(* The probe after a save the workspace guard stopped: the notice, then that
   the configuration it would test is already saved. *)
let voice_probe_kept_back ~ko refusal =
  T.workspace_refusal_text ~ko ~request:W.Kept_request.Voice_probe refusal
  ^ " · "
  ^ if ko then "설정은 저장됨" else "configuration saved"

let launch_voice_wizard_probe (state : T.state) ~mailbox ~request message =
  if not (T.server_authority_ready state) then
    state.voice_wizard <-
      Option.map
        (fun session ->
          Option.value ~default:session
            (Masc_tui_voice_wizard_session.voice_wizard_after_probe session
               ~request
               (Error
                  (voice_probe_kept_back
                     ~ko:(state.ui_language = T.Lang_ko)
                     T.Workspace_identity_not_confirmed))))
        state.voice_wizard
  else begin
    let enqueue_async = WA.workspace_enqueue state in
    let check = WA.capture_admission state ~mailbox in
    let host = WA.server_peer_host in
    let port = state.port in
    let payload = Yojson.Safe.to_string (`Assoc [ ("message", `String message) ]) in
    let run () =
      let result =
        match check () with
        | Error refusal -> Error (T.Request_withdrawn refusal)
        | Ok () ->
            Masc_tui_http.post_json_with_timeout
              ~timeout_sec:Masc_tui_http.voice_probe_timeout_sec ~host ~port
              ~path:"/api/v1/voice/probe/tts" ~body:payload
            |> Result.map_error (fun detail -> T.Request_failed detail)
      in
      enqueue_async mailbox (P.Voice_msg (P.Voice_wizard_probed (request, result)))
    in
    fork_voice_daemon ~enqueue_async ~mailbox
      ~fallback:(fun reason ->
        P.Voice_msg (P.Voice_wizard_probed (request, Error (T.Request_failed reason))))
      run
  end

(* The admin setup read, which names each endpoint and the runtime.toml
   revision. Shared by the pane's load and the wizard's read after a save that
   got no answer. *)
let read_voice_setup ~host ~port =
  match Masc_tui_http.http_get ~host ~port ~path:"/api/v1/voice/setup" with
  | Ok (200, body) -> (
      match Yojson.Safe.from_string body with
      | json -> Ok json
      | exception Yojson.Json_error _ ->
          Error "voice setup did not parse as JSON")
  | Ok (code, body) ->
      Error (Printf.sprintf "voice setup HTTP %d: %s" code (String.trim body))
  | Error message -> Error message

let voice_setup_revision = function
  | `Assoc fields -> (
      match List.assoc_opt "revision" fields with
      | Some (`String revision) when String.trim revision <> "" -> Some revision
      | Some _ | None -> None)
  | _ -> None

(* Read runtime.toml's revision again for the save numbered [request]. Its own
   message rather than the pane's load: a load already in flight when the save
   went out answers the revision from before it, and taken as this read it
   would say nothing was written when something was. *)
let launch_voice_wizard_reread (state : T.state) ~mailbox ~request =
  if T.server_authority_ready state then begin
    let enqueue_async = WA.workspace_enqueue state in
    let host = WA.server_peer_host in
    let port = state.port in
    let run () =
      let result =
        match read_voice_setup ~host ~port with
        | Error message -> Error message
        | Ok json -> (
            match voice_setup_revision json with
            | Some revision -> Ok revision
            | None -> Error "the setup read named no revision")
      in
      enqueue_async mailbox (P.Voice_msg (P.Voice_wizard_reread (request, result)))
    in
    fork_voice_daemon ~enqueue_async ~mailbox
      ~fallback:(fun reason -> P.Voice_msg (P.Voice_wizard_reread (request, Error reason)))
      run
  end
  else T.suspend_voice_wizard_read state

(* The sentence the endpoints are asked to say. In Korean because that is what
   this workstation speaks, and an endpoint can answer for one language and not
   another -- which is the thing a probe is for. *)
let voice_wizard_probe_sentence = "음성 연결을 확인합니다"

(* The probe row's first two columns, in display cells. *)
let voice_probe_endpoint_cells = 20
let voice_probe_state_cells = 10

let voice_wizard_probe_lines json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "endpoints" fields with
      | Some (`List items) ->
          List.filter_map
            (fun item ->
              match item with
              | `Assoc entry ->
                  let text key =
                    match List.assoc_opt key entry with
                    (* A refusal is whatever the probed endpoint wrote, and
                       [box_line] keeps escape sequences rather than stripping
                       them. An endpoint that answers with control bytes would
                       otherwise redraw the screen from inside this row. *)
                    | Some (`String value) ->
                        Masc.Tui_terminal_text.sanitize_terminal_text value
                    | Some _ | None -> Masc_tui_theme.Glyph.no_value
                  in
                  (* The state is the answer the wizard was opened to get. Left
                     out, an endpoint that refused drew in the same shape as one
                     that answered. The same three words the CLI prints, so the
                     two readings of one probe agree. *)
                  let state =
                    match List.assoc_opt "state" entry with
                    | Some (`String "answered") -> "answered"
                    | Some (`String "refused") -> "refused"
                    | Some (`String "skipped") -> "not asked"
                    (* A state this build does not know is shown as the probe
                       wrote it, not folded into a mark that hides it. *)
                    | Some (`String other) ->
                        Masc.Tui_terminal_text.sanitize_terminal_text other
                    | Some _ | None -> Masc_tui_theme.Glyph.no_value
                  in
                  (* Padded by display cells: the no-value mark is one column
                     and three bytes, so a byte-counted field ended short. *)
                  Some
                    (String.concat " "
                       [ Masc_tui_message_layout.fit_width (text "endpoint_id")
                           voice_probe_endpoint_cells
                       ; Masc_tui_message_layout.fit_width state
                           voice_probe_state_cells
                       ; text "detail" ])
              | _ -> None)
            items
      | Some _ | None -> [])
  | _ -> []

(* The kinds already in the section the draft is going into. A voice name is
   provider vocabulary, so whether the draft's voice can be the section default
   depends on what else falls back to it -- {!Voice_setup.voice_placement} is
   the rule and this is its input.

   Three answers, and the difference between the last two is what this is
   careful about. An empty list is "read it, nothing is there": the draft owns
   the default. A [None] entry is "something is there whose kind this binary
   cannot name", which is not a kind anything can be said to share. And a
   section that could not be read at all is reported as one unnameable entry
   rather than as an empty one -- the pane drops its answer whenever a refresh
   fails, and reading that as an empty section is what would put a voice over a
   default it never saw. The save then refuses, because a section written with
   no default it can read is one the loader rejects. A refusal is the answer
   that can be acted on; a quiet overwrite is not. *)
let unread_section = [ None ]

let voice_setup_section_kinds (state : T.state) (section : Voice_setup.section)
    =
  let side =
    match section with Voice_setup.Tts -> "tts" | Voice_setup.Stt -> "stt"
  in
  match state.voice_setup with
  | None -> unread_section
  | Some (`Assoc fields) -> (
      match List.assoc_opt side fields with
      (* The route answers null for a side nothing is configured for. *)
      | Some `Null | None -> []
      | Some (`Assoc section_fields) -> (
          match List.assoc_opt "endpoints" section_fields with
          | Some (`List entries) ->
              List.map
                (fun entry ->
                  match entry with
                  | `Assoc entry -> (
                      match List.assoc_opt "kind" entry with
                      | Some (`String kind) ->
                          Voice_config.endpoint_kind_of_name kind
                      | Some _ | None -> None)
                  | _ -> None)
                entries
          | Some _ | None -> unread_section)
      | Some _ -> unread_section)
  | Some _ -> unread_section

let launch_voice_wizard_save (state : T.state) ~mailbox
    (session : Masc_tui_voice_wizard_session.voice_wizard_session) =
  (* A save the guard stopped did not leave, and the wizard keeps its draft:
     said as kept back, never as the server's refusal (RFC §2). *)
  let kept_back refusal =
    let ko = state.ui_language = T.Lang_ko in
    W.kept_back ~ko ~request:W.Kept_request.Voice_setup_save
      (T.workspace_refusal_reason ~ko refusal)
      W.Draft_kept
  in
  if not (T.server_authority_ready state) then
    state.voice_wizard <-
      Some
        { session with
          Masc_tui_voice_wizard_session.vws_status =
            Some (kept_back T.Workspace_identity_not_confirmed)
        }
  else
    let enqueue_async = WA.workspace_enqueue state in
    let check = WA.capture_admission state ~mailbox in
    let alongside =
      voice_setup_section_kinds state
        session.Masc_tui_voice_wizard_session.vws_draft.Voice_wizard.section
    in
    match
      ( Masc_tui_voice_wizard_session.voice_wizard_save_held session
      , Voice_wizard.save_request
          session.Masc_tui_voice_wizard_session.vws_draft
          ~revision:session.Masc_tui_voice_wizard_session.vws_revision
          ~alongside )
    with
    | Some reason, _ ->
        state.voice_wizard <-
          Some
            { session with Masc_tui_voice_wizard_session.vws_status = Some reason }
    | None, Error gaps ->
        (* The wizard would not have offered Review with gaps left, but the draft
           can be edited backwards, so the refusal is said rather than assumed
           impossible. *)
        state.voice_wizard <-
          Some
            { session with
              Masc_tui_voice_wizard_session.vws_status =
                Some (String.concat "; " (List.map Voice_wizard.gap_message gaps))
            }
    | None, Ok body ->
        state.voice_wizard_requests <- state.voice_wizard_requests + 1;
        let request = state.voice_wizard_requests in
        state.voice_wizard <-
          Some
            (Masc_tui_voice_wizard_session.voice_wizard_sending session ~request);
        let host = WA.server_peer_host in
        let port = state.port in
        let payload = Yojson.Safe.to_string body in
        let run () =
          let reply =
            match
              match check () with
              | Error refusal -> Error refusal
              | Ok () ->
                  Ok
                    (Masc_tui_http.post_json_outcome ~host ~port
                       ~path:"/api/v1/voice/setup" ~body:payload)
            with
            | Error refusal ->
                Masc_tui_voice_wizard_session.Save_kept_back (kept_back refusal)
            | Ok (Masc_tui_http.Post_answered json) -> (
                match voice_setup_revision json with
                | Some revision ->
                    Masc_tui_voice_wizard_session.Save_written revision
                (* Written, by the status, but with no revision to keep editing
                   against: what the session holds is now stale, and whether it is
                   this write's is exactly what the reread decides. *)
                | None ->
                    Masc_tui_voice_wizard_session.Save_unanswered_reply
                      "the answer named no revision")
            | Ok (Masc_tui_http.Post_refused message) ->
                Masc_tui_voice_wizard_session.Save_refused message
            | Ok (Masc_tui_http.Post_unanswered detail) ->
                Masc_tui_voice_wizard_session.Save_unanswered_reply detail
          in
          enqueue_async mailbox (P.Voice_msg (P.Voice_wizard_saved (request, reply)))
        in
        (* Nothing was sent, so this is a refusal and not an unknown outcome. *)
        fork_voice_daemon ~enqueue_async ~mailbox
          ~fallback:(fun reason ->
            P.Voice_msg
              (P.Voice_wizard_saved
                 (request, Masc_tui_voice_wizard_session.Save_refused reason)))
          run

(* The voices to choose from. Asked of the first endpoint [voice.tts] names:
   a section's endpoints are a fallback chain for one voice, and an id is
   provider vocabulary, so the endpoint in front is the one whose vocabulary
   an assignment has to speak. *)
let voice_setup_first_tts_endpoint (state : T.state) =
  let member path json =
    List.fold_left
      (fun acc key ->
        match acc with
        | Some (`Assoc fields) -> List.assoc_opt key fields
        | Some _ | None -> None)
      (Some json) path
  in
  match state.voice_setup with
  | None -> None
  | Some json -> (
      match member [ "tts"; "endpoints" ] json with
      | Some (`List (`Assoc entry :: _)) -> (
          let text key =
            match List.assoc_opt key entry with
            | Some (`String value) when String.trim value <> "" ->
                Some (String.trim value)
            | Some _ | None -> None
          in
          match text "kind" with
          | Some kind -> Some (kind, text "api_key_env")
          | None -> None)
      | Some _ | None -> None)

let voice_agent_voice_rows json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "voices" fields with
      | Some (`List items) ->
          List.filter_map
            (function
              | `Assoc voice -> (
                  let text key =
                    match List.assoc_opt key voice with
                    | Some (`String value) when String.trim value <> "" ->
                        Some (String.trim value)
                    | Some _ | None -> None
                  in
                  match text "id" with
                  | None -> None
                  | Some id ->
                      let label =
                        match (text "name", text "language") with
                        | Some name, Some language ->
                            Printf.sprintf "%s (%s)" name language
                        | Some name, None -> name
                        | None, Some language ->
                            Printf.sprintf "%s (%s)" id language
                        | None, None -> id
                      in
                      Some (id, label))
              | _ -> None)
            items
      | Some _ | None -> [])
  | _ -> []

let launch_voice_agent_voices (state : T.state) ~mailbox ~kind ~api_key_env =
  let ready = T.server_authority_ready state in
  state.voice_agent_voices <-
    Option.map
      (fun (session : T.voice_agent_session) ->
        { session with
          T.vas_lookup = Some (kind, api_key_env)
        ; vas_loading_voices = ready
        })
      state.voice_agent_voices;
  if ready then begin
    let enqueue_async = WA.workspace_enqueue state in
    let host = WA.server_peer_host in
    let port = state.port in
    let payload =
      Yojson.Safe.to_string
        (`Assoc
          ([ ("kind", `String kind) ]
          @
          match api_key_env with
          | Some variable -> [ ("api_key_env", `String variable) ]
          | None -> []))
    in
    let run () =
      let result =
        match
          Masc_tui_http.post_json_outcome ~host ~port
            ~path:"/api/v1/voice/voices" ~body:payload
        with
        | Masc_tui_http.Post_answered json -> Ok json
        | Masc_tui_http.Post_refused message -> Error message
        | Masc_tui_http.Post_unanswered detail -> Error detail
      in
      enqueue_async mailbox
        (P.Voice_msg (P.Voice_agent_voices_loaded result))
    in
    fork_voice_daemon ~enqueue_async ~mailbox
      ~fallback:(fun reason ->
        P.Voice_msg (P.Voice_agent_voices_loaded (Error reason)))
      run
  end

let launch_voice_agent_voice_save (state : T.state) ~mailbox
    (session : T.voice_agent_session) =
  if not (T.server_authority_ready state) then
    state.voice_agent_voices <-
      Some
        { session with
          T.vas_status =
            Some
              (T.workspace_refusal_text
                 ~ko:(state.ui_language = T.Lang_ko)
                 ~request:W.Kept_request.Agent_voice_save
                 T.Workspace_identity_not_confirmed)
        }
  else
    let enqueue_async = WA.workspace_enqueue state in
    let check = WA.capture_admission state ~mailbox in
    match T.voice_agent_selected session with
    | None ->
        state.voice_agent_voices <-
          Some
            { session with
              T.vas_status =
                Some
                  (T.ui_text state ~ko:"먼저 키퍼와 목소리를 선택하세요"
                     ~en:"pick a keeper and a voice first")
            }
    | Some (agent, voice) ->
        state.voice_agent_voices <-
          Some
            { session with
              T.vas_saving = true
            ; vas_status =
                Some
                  (T.ui_text state ~ko:"키퍼 목소리 배정을 저장하고 있습니다"
                     ~en:"saving the assignment")
            };
        let host = WA.server_peer_host in
        let port = state.port in
        let payload =
          Yojson.Safe.to_string
            (`Assoc
              [ ("expected_revision", `String session.T.vas_revision)
              ; ( "changes"
                , `List
                    [ `Assoc
                        [ ("change", `String "set_agent_voice")
                        ; ("agent", `String agent)
                        ; ("voice", `String voice)
                        ]
                    ] )
              ])
        in
        let run () =
          let result =
            match
              match check () with
              | Error refusal -> Error refusal
              | Ok () ->
                  Ok
                    (Masc_tui_http.post_json_outcome ~host ~port
                       ~path:"/api/v1/voice/setup" ~body:payload)
            with
            | Error refusal -> Error (T.Request_withdrawn refusal)
            | Ok (Masc_tui_http.Post_answered json) -> Ok json
            | Ok (Masc_tui_http.Post_refused message) ->
                Error (T.Request_failed message)
            | Ok (Masc_tui_http.Post_unanswered detail) ->
                Error (T.Request_failed detail)
          in
          enqueue_async mailbox
            (P.Voice_msg (P.Voice_agent_voice_saved result))
        in
        fork_voice_daemon ~enqueue_async ~mailbox
          ~fallback:(fun reason ->
            P.Voice_msg
              (P.Voice_agent_voice_saved (Error (T.Request_failed reason))))
          run

(* One resolution for the panel and every capture: the environment wins when
   it names a device (the way sox reads AUDIODEV), the stored pick is next,
   and only a panel asked to name a device falls back to the probe. Both go
   through {!Masc.Voice_bridge.resolved_audio_device}, so what the panel
   names is what the recorder opens. *)
let resolved_audio_input_device ~pick ~for_display =
  match Masc.Voice_bridge.resolved_audio_device ~pick () with
  | Some device -> Some device
  | None when not for_display -> None
  | None -> (
      match Masc_tui_audio_device.default_input () with
      | Masc_tui_audio_device.Default_input name -> Some name
      (* The panel shows "unknown" for each of these; the log keeps them
         apart, because a machine with no input selected and a probe
         that could not read the report call for different fixes. *)
      | Masc_tui_audio_device.No_default_input ->
          Log.Transport.info
            "voice: the audio report marks no device as the default input";
          None
      | Masc_tui_audio_device.Probe_failed reason ->
          Log.Transport.warn
            "voice: the default input device could not be read: %s" reason;
          None
      | Masc_tui_audio_device.No_probe_on_this_platform -> None)

(* What voice actually resolved to, plus the microphone the recorder would
   open.

   The server's answer is the only surface that separates "voice is not
   configured" from "a config exists and does not parse". runtime.toml shows
   the second as though it were fine, which is how a six-day outage stayed
   invisible.

   The input device is read here rather than asked of the server: no server
   knows it. sox opens whatever CoreAudio calls default, and captures that come
   back empty are usually a different microphone than the operator assumes. *)
let launch_voice_config_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
    let enqueue_async = WA.workspace_enqueue state in
    let host = WA.server_peer_host in
    let port = state.port in
    let pick = state.boot_audio_input_device in
    let run () =
      let config =
        match Masc_tui_http.http_get ~host ~port ~path:"/api/v1/voice/config" with
        | Ok (200, body) -> (
            match Yojson.Safe.from_string body with
            | json -> Ok json
            | exception Yojson.Json_error _ ->
                Error "voice config did not parse as JSON")
        | Ok (code, body) ->
            Error (Masc_tui_http.named_refusal "voice config" ~status:code ~body)
        | Error message -> Error message
      in
      let device = resolved_audio_input_device ~pick ~for_display:true in
      (* The admin read, which names each endpoint. The public config route above
         answers three booleans and no identity, so a panel built only on it can
         say that a fallback exists and not which one. *)
      let setup = read_voice_setup ~host ~port in
      enqueue_async mailbox
        (P.Voice_msg (P.Voice_config_loaded (config, setup, device)))
    in
    fork_voice_daemon ~enqueue_async ~mailbox
      ~fallback:(fun reason ->
        P.Voice_msg
          (P.Voice_config_loaded (Error reason, Error reason, None)))
      run
  end
