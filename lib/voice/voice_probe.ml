(* Voice_probe — diagnostics that ask every configured endpoint and report
   each one's answer, and the STT transcription chain the probes share with
   the media-reading path. Extracted from Voice_bridge (E09 Phase 2a,
   task-2526): probe_outcome/probe_attempt keep their closed result contract;
   callers keep the old names through Voice_bridge's re-exports.

   Design: reports/e09-voice-addon-boundary-design-20261023.md *)

include Voice_bridge_core

open Result.Syntax

let transcribe_via_http_stt = Voice_bridge_transport.transcribe_via_http_stt
let transcribe_via_command = Voice_bridge_transport.transcribe_via_command
let list_voices_via_http = Voice_bridge_transport.list_voices_via_http
let list_voices_via_command = Voice_bridge_transport.list_voices_via_command

(* Catalogue aliases: [transcriber_of_kind] and the transcript reader are pure
   catalogue logic and live in {!Voice_catalogue}; the command voice lister is
   transport-side and aliased here so this module does not depend on
   {!Voice_bridge} (which re-exports this module). *)
let transcriber_of_kind = Voice_catalogue.transcriber_of_kind
let transcript_of_stt_json = Voice_catalogue.transcript_of_stt_json

(* The catalogue row type lives in {!Voice_catalogue}; aliasing it here keeps
   the record literals below in scope and the public surface unchanged. *)
type catalogue_voice = Voice_catalogue.catalogue_voice = {
  voice_id : string;
  voice_name : string option;
  voice_language : string option;
  voice_aliases : string list;
}

let list_voices_via_command_endpoint endpoint =
  let* output = list_voices_via_command endpoint in
  match (Voice_runtime_overlay.adapter_for_endpoint endpoint).transport with
  | Voice_runtime_overlay.Macos_say ->
    Ok (Voice_catalogue.say_catalogue_of_output output)
  | Voice_runtime_overlay.Espeak_ng ->
    Ok (Voice_catalogue.espeak_catalogue_of_output output)
  | Voice_runtime_overlay.Elevenlabs_direct
  | Voice_runtime_overlay.Openai_compat
  | Voice_runtime_overlay.Voice_mcp
  | Voice_runtime_overlay.Whisper_cli ->
    Error
      (Printf.sprintf
         "endpoint %s does not list voices through a command, so no command \
          output holds a catalogue"
         endpoint.Voice_config.id)

let check_command_voice endpoint ~voice =
  Voice_catalogue.check_command_voice
    ~lister:list_voices_via_command_endpoint endpoint ~voice

(* The [status] field of every capture result this module returns. One closed
   set, spelled here and read back by {!capture_outcome_of_json}, so a reader
   cannot fall through a string it does not know into "nothing was heard". *)
type capture_status =
  | Transcribed
  | No_audio
  | Discarded
[@@deriving enumerate]

let capture_status_to_string = function
  | Transcribed -> "transcribed"
  | No_audio -> "no_audio"
  | Discarded -> "discarded"
;;

let capture_status_of_string s = List.find_opt (fun v -> String.equal (capture_status_to_string v) s) all_of_capture_status
;;

let available_stt_endpoints (stt : Voice_config.stt_config) =
  stt.Voice_config.endpoints |> List.filter (fun (ep : Voice_config.endpoint) -> ep.enabled)
;;

let transcribe_audio ~audio_file ?language_code ?deadline () =
  match Voice_config.load_detailed () with
  | Error (Voice_config.Invalid msg) ->
    (* An explicit voice config exists but is broken: surface the
       load failure instead of substituting a hardcoded model. *)
    Error (Printf.sprintf "voice config load failed: %s" msg)
  | Error Voice_config.Not_configured ->
    (* Voice is not set up in this environment: STT is explicitly
       disabled, which is not an error of the config itself. *)
    Error "no enabled STT endpoints configured"
  | Ok { Voice_config.stt = None; _ } ->
    (* The config loaded and has no [stt] section. Typed absence: there is no
       model to send, so nothing is sent. *)
    Error "voice config has no [stt] section, so STT is not set up"
  | Ok { Voice_config.stt = Some stt; _ } ->
    let endpoints = available_stt_endpoints stt in
    let deadline_passed () =
      match deadline with
      | Some deadline -> Monotonic_deadline.passed deadline
      | None -> false
    in
    let rec try_endpoints attempted = function
      | [] ->
        Error
          (Printf.sprintf
             "all enabled STT endpoints failed: %s"
             (String.concat " | " (List.rev attempted)))
      | _ :: _ when deadline_passed () ->
        (* A shared deadline is one budget for the whole chain: once it is
           spent no further endpoint is started. *)
        Error
          (Printf.sprintf
             "budget_spent: the STT deadline passed before every endpoint was tried: %s"
             (String.concat " | " (List.rev attempted)))
      | endpoint :: rest ->
        (* Asked the way this endpoint answers. The command kinds were wired
           into the probe and not into this loop, so a configured whisper_cli
           endpoint -- the only kind that transcribes without a server -- was
           sent an HTTP request it has no address for and reported as failed,
           while [voice-verify --audio] on the same configuration worked.
           [transcriber_of_kind] is the same closed answer the probe reads, so
           a kind added later stops this compiling until it has one. *)
        (* The model is this endpoint's: a whisper-cli file and a provider's
           model name are different vocabularies, so the section's fallback
           only applies to an endpoint that names none. The loader refuses a
           section that leaves a transcriber without one; [None] here is said,
           not sent as a blank. *)
        let with_model f =
          match Voice_config.model_at_endpoint ~default_model:stt.default_model endpoint with
          | Some model -> f model
          | None -> Error "this endpoint has no model and [voice.stt] names none"
        in
        let heard =
          match transcriber_of_kind endpoint.Voice_config.kind with
          | Does_not_transcribe ->
            (* Named rather than attempted. An endpoint that speaks, listed
               under [voice.stt], is a configuration to correct; an HTTP
               attempt reported it as a network failure instead. *)
            Error "this endpoint kind speaks and does not transcribe"
          | By_command ->
            (* The command answers with its own output and knows no language
               field; [language_code] is then the caller's or unknown. *)
            with_model (fun model ->
              Result.map
                (fun transcript -> transcript, None)
                (transcribe_via_command ?deadline endpoint ~audio_file ~model))
          | Over_http ->
            with_model (fun model ->
              match transcribe_via_http_stt ?deadline endpoint ~audio_file ~model with
              | Ok json ->
                Result.map
                  (fun text -> text, Json_util.get_string json "language_code")
                  (transcript_of_stt_json json)
              | Error error -> Error error)
        in
        (match heard with
         | Ok (text, reported_language) ->
           let lang =
             match language_code with
             | Some lc -> lc
             | None ->
               (* The endpoint says which language it heard, or does not. A
                  command answers with its transcript and no such field, so
                  "unknown" here is the endpoint having been silent about it
                  -- the same word this loop has always used. *)
               (match reported_language with
                | Some lc -> lc
                | None -> "unknown")
           in
           Ok
             (`Assoc
                 [ "status", `String (capture_status_to_string Transcribed)
                 ; "text", `String text
                 ; "language_code", `String lang
                 ; "endpoint_id", `String endpoint.id
                 ])
         | Error error ->
           let attempt = Printf.sprintf "%s: %s" endpoint.id error in
           (if rest <> []
            then
              log_error
                (Printf.sprintf
                   "STT endpoint %s failed; trying next endpoint: %s"
                   endpoint.id
                   error));
           try_endpoints (attempt :: attempted) rest)
    in
    if endpoints = []
    then Error "no enabled STT endpoints configured"
    else try_endpoints [] endpoints
;;

(* ── endpoint probes ───────────────────────────────────────────────────── *)

(* What one endpoint did when it was asked, in its own words.

   The fallback chains stop at the first endpoint that answers, which is right
   for serving a request and wrong for answering "is this configuration
   working". A chain that succeeds says nothing about the endpoints after the
   one that answered: a dead fallback looks exactly like a healthy one until
   the first endpoint goes away. A probe asks every endpoint and reports each.

   [try_http_tts_for_dashboard] above is the shape this replaces for
   diagnostics: it walks the same endpoints, drops every failure reason, and
   answers Some/None without naming which endpoint answered. Voice was down for
   six days behind exactly that kind of silence. *)
type probe_outcome =
  | Answered of string
  | Refused of string
  | Skipped of string

type probe_attempt =
  { endpoint_id : string
  ; kind : Voice_config.endpoint_kind
  ; outcome : probe_outcome
  }

let probe_outcome_to_string = function
  | Answered detail -> "answered: " ^ detail
  | Refused reason -> "refused: " ^ reason
  | Skipped reason -> "not asked: " ^ reason

let probe_attempt_json attempt =
  let state, detail =
    match attempt.outcome with
    | Answered detail -> "answered", detail
    | Refused reason -> "refused", reason
    | Skipped reason -> "skipped", reason
  in
  `Assoc
    [ "endpoint_id", `String attempt.endpoint_id
    ; "kind", `String (Voice_config.string_of_endpoint_kind attempt.kind)
    ; "state", `String state
    ; "detail", `String detail
    ]

let remove_quietly path = try Sys.remove path with Sys_error _ -> ()

let string_member key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
     | Some _ | None -> None)
  | _ -> None
;;

(* The shape ElevenLabs answers with, measured 2026-09-12 against
   /v2/voices: an object carrying [voices], each with [voice_id], [name] and a
   [labels] object whose [language] is the only field worth showing beside the
   name. A row without an id is dropped rather than shown: it cannot be chosen,
   and a list that offers unchoosable rows is worse than a shorter one. *)
let catalogue_voices_of_json json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "voices" fields with
     | Some (`List items) ->
       Ok
         (List.filter_map
            (fun item ->
              match string_member "voice_id" item with
              | None -> None
              | Some id ->
                let language =
                  match item with
                  | `Assoc entry ->
                    (match List.assoc_opt "labels" entry with
                     | Some labels -> string_member "language" labels
                     | None -> None)
                  | _ -> None
                in
                Some
                  { voice_id = id
                  ; voice_name = string_member "name" item
                  ; voice_language = language
                  ; voice_aliases = []
                  })
            items)
     | Some _ | None -> Error "the endpoint answered without a voices list")
  | _ -> Error "the endpoint answered with something other than an object"
;;

let list_voices_via_http_endpoint endpoint =
  match list_voices_via_http endpoint with
  | Error message -> Error message
  | Ok json -> catalogue_voices_of_json json
;;

(* Which voices an endpoint has. Two kinds publish a catalogue and they publish
   it differently -- ElevenLabs answers a URL, say answers a command -- so the
   resolved endpoint adapter picks which is asked rather than trying the other
   when one fails. A kind with no catalogue says so in words, because the
   reader is about to type the name instead.

   Saying it matters most for say, which does not fail on a voice it does not
   have: it speaks in the system voice instead, so a name typed from memory is
   wrong silently. *)
let list_voices (endpoint : Voice_config.endpoint) =
  let adapter = Voice_runtime_overlay.adapter_for_endpoint endpoint in
  match adapter.transport with
  | Voice_runtime_overlay.Elevenlabs_direct -> list_voices_via_http_endpoint endpoint
  | Voice_runtime_overlay.Macos_say | Voice_runtime_overlay.Espeak_ng ->
    list_voices_via_command_endpoint endpoint
  | Voice_runtime_overlay.Openai_compat ->
    Error
      (Printf.sprintf
         "voice config endpoint %s speaks the OpenAI shape, which has no voice list to \
          ask for: type the voice name the server expects"
         endpoint.Voice_config.id)
  | Voice_runtime_overlay.Voice_mcp ->
    Error
      (Printf.sprintf
         "voice config endpoint %s is reached through a tool, which is asked to speak \
          rather than asked what it can speak with"
         endpoint.Voice_config.id)
  | Voice_runtime_overlay.Whisper_cli ->
    Error
      (Printf.sprintf "voice config endpoint %s transcribes and has no voices"
         endpoint.Voice_config.id)
;;

let probe_stt ~audio_file () =
  match Voice_config.load_detailed () with
  | Error error -> Error (Voice_config.load_error_to_string error)
  | Ok config ->
    (match config.Voice_config.stt with
     | None -> Error "no [voice.stt] section is configured, so nothing transcribes"
     | Some stt ->
       Ok
         (List.map
            (fun (endpoint : Voice_config.endpoint) ->
              let outcome =
                if not endpoint.Voice_config.enabled
                then Skipped "disabled in the configuration"
                else (
                  (* A transcript is read by a person deciding whether the
                     endpoint heard them. %S escapes UTF-8 into byte numbers,
                     which for any language but English is unreadable --
                     measured on a Korean utterance. A transcript also arrives
                     with its own line breaks, which would break the
                     one-line-per-endpoint report.

                     An empty transcript is an answer, not a failure: the
                     endpoint was reached and heard nothing. Saying which it was
                     keeps a silent microphone apart from a dead endpoint. *)
                  let heard transcript =
                    let spoken =
                      String.trim
                        (String.map
                           (function
                             | '\n' | '\r' | '\t' -> ' '
                             | character -> character)
                           transcript)
                    in
                    Answered
                      (if String.equal spoken ""
                       then "reached, and heard nothing in the audio"
                       else Printf.sprintf "heard %s" spoken)
                  in
                  (* Asked with the model the transcription path would use. *)
                  let model =
                    Voice_config.model_at_endpoint ~default_model:stt.Voice_config.default_model
                      endpoint
                  in
                  match transcriber_of_kind endpoint.Voice_config.kind, model with
                  | Does_not_transcribe, (Some _ | None) ->
                    Skipped "this endpoint kind does not transcribe"
                  | (Over_http | By_command), None ->
                    Refused "this endpoint has no model and [voice.stt] names none"
                  | Over_http, Some model ->
                    (match transcribe_via_http_stt endpoint ~audio_file ~model with
                     | Ok json ->
                       (match transcript_of_stt_json json with
                        | Ok transcript -> heard transcript
                        | Error reason -> Refused reason)
                     | Error reason -> Refused reason)
                  | By_command, Some model ->
                    (match transcribe_via_command endpoint ~audio_file ~model with
                     | Ok transcript -> heard transcript
                     | Error reason -> Refused reason))
              in
              { endpoint_id = endpoint.Voice_config.id
              ; kind = endpoint.Voice_config.kind
              ; outcome
              })
            stt.Voice_config.endpoints))

let public_config_json () =
  match Voice_config.load_detailed () with
  | Ok config -> Ok (Voice_config.public_json config)
  | Error error ->
    Error
      (Tool_args.error_assoc
         [ "message", `String (Voice_config.load_error_to_string error)
         ; "config_path", `String (Voice_config.config_path ())
         ])
;;

