open Keeper_meta_contract
open Keeper_tool_shared_runtime

(** Runtime adapter for client-intercepted voice agent tools.

    The string [name] arriving from the descriptor dispatch layer is
    parsed into a typed [voice_command] at the module boundary; every
    branch downstream operates on the variant. The OCaml type checker
    then forces every new variant to update [command_to_string] and
    the dispatch match in [handle], eliminating the silent-drift
    failure mode of an open string-classifier. *)

type voice_command =
  | Speak
  | Listen
  | Agent

(** Canonical enumeration. Must list every constructor of
    [voice_command]; adding a variant without appending here is the
    one remaining drift vector — guarded by
    [test_voice_command_descriptor_parity], which compares this list
    against the registered [keeper_voice_*] descriptors. *)
let all_commands : voice_command list =
  [ Speak; Listen; Agent ]

let command_to_string = function
  | Speak -> "keeper_voice_speak"
  | Listen -> "keeper_voice_listen"
  | Agent -> "keeper_voice_agent"

(** Derived from [all_commands] + [command_to_string] so that adding a
    variant requires only the [command_to_string] branch + the
    [all_commands] entry — never a separate string-literal match. *)
let command_of_string (s : string) : voice_command option =
  List.find_opt (fun c -> String.equal (command_to_string c) s) all_commands

type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  call_summary:string option ->
  continue:(unit -> Keeper_tool_execution.t) ->
  Keeper_tool_execution.t

(* The one argument a speak is for. Read once here for both the handler and
   the approval row: a [message] that is absent, not a string, or blank is
   not a speak, so there is nothing to play and nothing to state. *)
let speak_message_of_args (args : Yojson.Safe.t) =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "message" fields with
     | Some (`String message) ->
       (match String_util.trim_nonempty message with
        | Some message -> Ok message
        | None -> Error "message is blank")
     | Some _ -> Error "message must be a string"
     | None -> Error "message is missing")
  | _ -> Error "arguments must be an object"

(* What a speak approval is about, in one line: the first line of what would
   be said, whole. *)
let speak_call_summary ~message = String_util.first_nonblank_line message

(* Which way a speak leaves the tool. The Gate reviews it unless the keeper
   or the voice config exempts it; a config that does not load is a third
   answer, not "not exempt": no provider can be reached under it, so a review
   would approve nothing and hide why. The refusal carries the loader's own
   sentence from the one read that decided the route. A second read in the
   bridge would decide again, and a config repaired between the two reads
   would play without the review the first read denied.

   No voice config at all is the fourth answer, for the same reason as the
   third: there is no endpoint to speak through, so a review approves nothing
   and, once approved, the bridge fails the call as a runtime fault the model
   is told to report as one. The model is told instead that voice is not set
   up here, before anyone is asked to approve it.

   The config is read first, once, for every route. An exemption answers
   whether the Gate reviews a speak, not whether voice exists: an exempt
   keeper with no config used to reach the bridge and get the same runtime
   fault, one site of the two. *)
type speak_route =
  | Exempt_from_gate
  | Reviewed_by_gate
  | Refused_by_voice_config of string
  | Refused_voice_not_configured

let voice_not_configured_message =
  "voice is not configured in this workspace: no [voice] section in \
   runtime.toml and no voice_config.json, so there is no TTS endpoint to speak \
   through. Say it in text instead. An operator can enable voice by adding a \
   [voice] section whose tts.endpoints lists one."

let handle_speak_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(authorize_external_effect : external_effect_authorizer)
      ~(args : Yojson.Safe.t)
  =
  let provider =
    Safe_ops.json_string_opt "provider" args
    |> Option.map String.trim
    |> function
    | Some p when p <> "" -> Some p
    | _ -> None
  in
  let priority = max 1 (Safe_ops.json_int ~default:1 "priority" args) in
  let audio_device =
    Safe_ops.json_string_opt "audio_device" args
    |> Option.map String.trim
    |> function
    | Some d when d <> "" -> Some d
    | _ -> None
  in
  match speak_message_of_args args with
  | Error reason ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Workflow_rejection
      (error_json (reason ^ ". Good: message='Hello team.'. Bad: message=''."))
  | Ok message -> (
    match
      ( Eio_context.get_root_switch_opt ()
      , Eio_context.get_clock_opt ()
      , Eio_context.get_net_opt () )
    with
    | Some sw, Some clock, Some net ->
      let run_speak () =
        match
          Voice_bridge.agent_speak
            ~sw
            ~clock
            ~net
            ~agent_id:meta.name
            ~message
            ?provider
            ~priority
            ?audio_device
            ()
        with
        | Ok
            { Voice_bridge.completion = Voice_bridge.Spoken | Voice_bridge.Synthesized
            ; payload = json
            } ->
          (* RFC-0235 P1 3b: record the utterance to the keeper's chat so a
             connected device can read AND hear it, not just the server's
             speakers. The audio clip carries the token of the synthesized
             file so the dashboard can fetch /api/v1/voice/audio/<token>. *)
          let base_dir = config.Workspace.base_path in
          let surface = Surface_ref.Dashboard { session_id = None } in
          let clip : Keeper_chat_store.audio_clip option =
            Option.bind (Json_util.get_string json "audio_file") (fun audio_file ->
              Keeper_chat_store.audio_clip_of_synthesized_file
                ~audio_file
                ~message_text:message
                ~device_id:audio_device)
          in
          Keeper_chat_store.append_assistant_message
            ~base_dir ~keeper_name:meta.name ~content:message ~surface ?audio:clip ();
          Keeper_tool_execution.success (Yojson.Safe.to_string json)
        | Ok
            { Voice_bridge.completion = Voice_bridge.Dedup_skipped
            ; payload = json
            } ->
          Keeper_tool_execution.success (Yojson.Safe.to_string json)
        | Error err ->
          Keeper_tool_execution.failure
            ~class_:Tool_result.Runtime_failure
            (Tool_args.error_response_with
               [ "agent_id", `String meta.name
               ; "message", `String err
               ])
      in
      let route =
        match Voice_config.load_detailed () with
        | Error Voice_config.Not_configured -> Refused_voice_not_configured
        | Error (Voice_config.Invalid reason) -> Refused_by_voice_config reason
        | Ok vcfg ->
          (match meta.always_allow with
           | Some true -> Exempt_from_gate
           | Some false | None ->
             (match meta.voice_always_allow with
              | Some true -> Exempt_from_gate
              | Some false | None ->
                if Voice_config.voice_gate_always_allow_for_agent vcfg meta.name
                then Exempt_from_gate
                else Reviewed_by_gate))
      in
      (match route with
       | Exempt_from_gate -> run_speak ()
       | Refused_by_voice_config reason ->
         Keeper_tool_execution.failure
           ~class_:Tool_result.Runtime_failure
           (Tool_args.error_response_with
              [ "agent_id", `String meta.name
              ; "message", `String reason
              ])
       | Refused_voice_not_configured ->
         Keeper_tool_execution.failure
           ~class_:Tool_result.Dependency_unavailable
           (Tool_args.error_response_with
              [ "agent_id", `String meta.name
              ; "message", `String voice_not_configured_message
              ])
       | Reviewed_by_gate ->
         (* Synchronous on purpose: the tool schema promises "blocks until
            playback finishes". The former fire-and-forget queue returned
            status="queued" immediately, so the model never saw playback
            complete and re-spoke the same content every sub-turn
            (2026-06-10 live voice-repeat incident). *)
         authorize_external_effect
           ~operation:(command_to_string Speak)
           ~input:args
           ~call_summary:(speak_call_summary ~message)
           ~continue:run_speak)
    | _ ->
      Keeper_tool_execution.success
        (Yojson.Safe.to_string
           (keeper_text_fallback_json ~agent_id:meta.name ~message)))

(* Listen opens the user's microphone window, so it never becomes a Gate
   request. An approval cycle outlives the recording window (auto_judge
   resolution is measured in tens of seconds, and a capture the model gave
   no timeout waits [Voice_capture.default_capture_timeout_seconds] for
   speech), and a post-approval replay would open the microphone after the
   user has stopped talking. Inbound speech is input collection, not an
   outbound effect; speak is the voice leaf that still goes to the Gate,
   where Auto_judge allows it as a local output and Manual parks it. *)
let handle_listen_with_outcome ~(meta : keeper_meta) ~(args : Yojson.Safe.t) ()
  =
  (* No timeout named is the bridge's default, which is the number the tool
     schema advertises; a second default here would be a second number for
     the same knob. *)
  let timeout_sec = Safe_ops.json_float_opt "timeout_seconds" args in
  let language_code = Safe_ops.json_string_opt "language_code" args in
  match
    Voice_bridge.record_and_transcribe
      ~agent_id:meta.name
      ?timeout_sec
      ?language_code
      ()
  with
  | Ok json -> Keeper_tool_execution.success (Yojson.Safe.to_string json)
  | Error err ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      (Tool_args.error_response_with
         [ "error", `String err
         ; "agent_id", `String meta.name
         ])

let append_assoc_fields json fields =
  match json with
  | `Assoc existing -> `Assoc (existing @ fields)
  | other -> `Assoc (("voice_config", other) :: fields)

(* How a voice turn travels. Operator speech is transcribed into a normal
   keeper text turn; keeper speech leaves through keeper_voice_speak as a TTS
   clip the dashboard fetches by token. *)
let voice_loop_json =
  `Assoc
    [ ( "operator_input"
      , `Assoc
          [ "capture", `String "dashboard_microphone_or_audio_upload"
          ; "server_route", `String "POST /api/v1/voice/transcribe"
          ; "handoff", `String "transcribed_text_enters_normal_keeper_turn"
          ] )
    ; ( "keeper_output"
      , `Assoc
          [ "tool", `String "keeper_voice_speak"
          ; "delivery", `String "tts_audio_clip"
          ; ( "browser_route"
            , `String ("GET " ^ Masc_network_defaults.voice_audio_path "<token>") )
          ] )
    ]

let voice_agent_capability_fields =
  [ "voice_loop", voice_loop_json
  ; ( "input_modes"
    , `List [ `String "browser_record_transcribe"; `String "server_microphone_listen" ] )
  ; ( "output_modes"
    , `List [ `String "tts_audio_clip"; `String "local_playback_if_configured" ] )
  ]

let handle_agent_with_outcome ~(meta : keeper_meta) =
  match Voice_bridge.get_agent_voice ~agent_id:meta.name with
  | Ok json ->
    Keeper_tool_execution.success
      (Yojson.Safe.to_string
         (append_assoc_fields json voice_agent_capability_fields))
  | Error err ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      (Tool_args.error_response_with
         [ "agent_id", `String meta.name
         ; "message", `String err
         ])

let handle_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(authorize_external_effect : external_effect_authorizer)
      ~(command : voice_command)
      ~(args : Yojson.Safe.t)
      ()
  =
  match command with
  | Speak ->
    handle_speak_with_outcome ~config ~meta ~authorize_external_effect ~args
  | Listen -> handle_listen_with_outcome ~meta ~args ()
  | Agent -> handle_agent_with_outcome ~meta

let handle_voice_tool_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(authorize_external_effect : external_effect_authorizer)
      ~(name : string)
      ~(args : Yojson.Safe.t)
      ()
  =
  match command_of_string name with
  | Some command ->
    handle_with_outcome ~config ~meta ~authorize_external_effect ~command ~args ()
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Runtime_failure
      (error_json ~fields:[ "tool", `String name ] "unknown_voice_tool")

let handle_voice_tool ~config ~meta ~authorize_external_effect ~name ~args () =
  (handle_voice_tool_with_outcome
     ~config
     ~meta
     ~authorize_external_effect
     ~name
     ~args
     ())
    .raw_output
