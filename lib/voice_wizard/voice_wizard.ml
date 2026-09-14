type provider =
  | Macos_say
  | Whisper_cli
  | Elevenlabs
  | Openai_compatible
  | Mcp_tool

let provider_label = function
  | Macos_say -> "macos_say"
  | Whisper_cli -> "whisper_cli"
  | Elevenlabs -> "elevenlabs"
  | Openai_compatible -> "openai_compatible"
  | Mcp_tool -> "mcp_tool"
;;

let provider_of_label = function
  | "macos_say" -> Some Macos_say
  | "whisper_cli" -> Some Whisper_cli
  | "elevenlabs" -> Some Elevenlabs
  | "openai_compatible" -> Some Openai_compatible
  | "mcp_tool" -> Some Mcp_tool
  | _ -> None
;;

(* Each side is offered what can do its half.

   Speech in is offered neither an MCP tool nor say: both synthesize and have
   no transcribe path, so offering either would write an endpoint every probe
   reports as not asked. Speech out is not offered whisper-cli for the mirror
   reason.

   say leads speech out and whisper-cli leads speech in because they are the
   two entries that need no address and no key: the command is on the machine
   or it is not, and nothing about them is a purchase. *)
let providers_for = function
  | Voice_setup.Tts -> [ Macos_say; Elevenlabs; Openai_compatible; Mcp_tool ]
  | Voice_setup.Stt -> [ Whisper_cli; Elevenlabs; Openai_compatible ]
;;

let kind_of_provider = function
  | Macos_say -> Voice_config.Macos_say
  | Whisper_cli -> Voice_config.Whisper_cli
  | Elevenlabs -> Voice_config.Elevenlabs_direct
  | Openai_compatible -> Voice_config.Openai_compat
  | Mcp_tool -> Voice_config.Voice_mcp
;;

type draft =
  { section : Voice_setup.section
  ; provider : provider
  ; endpoint_id : string
  ; address : string
  ; credential_variable : string
  ; model : string
  ; voice : string
  ; timeout_seconds : float option
  }

(* The one credential variable every ElevenLabs workstation uses, and the one
   address. Both are the same everywhere, so filling them in saves typing
   without guessing at anything local. *)
let elevenlabs_credential_variable = "ELEVENLABS_API_KEY"

let blank ~section ~provider =
  { section
  ; provider
  ; endpoint_id = ""
  ; address = (match provider with
               | Elevenlabs -> Voice_config.default_elevenlabs_base_url
               (* A command is reached by running it, so there is no address to
                  prefill and none to type. *)
               | Openai_compatible | Mcp_tool | Macos_say | Whisper_cli -> "")
  ; credential_variable =
      (match provider with
       | Elevenlabs -> elevenlabs_credential_variable
       (* Nothing leaves the machine for a command, so there is no key. *)
       | Openai_compatible | Mcp_tool | Macos_say | Whisper_cli -> "")
  ; model = ""
  ; voice = ""
  ; timeout_seconds = None
  }
;;

let suggested_addresses = function
  | Voice_setup.Stt -> [ "whisper.cpp", "http://127.0.0.1:2022/v1" ]
  | Voice_setup.Tts -> [ "mlx-audio", "http://127.0.0.1:8000/v1" ]
;;

type gap =
  | Endpoint_id_is_blank
  | Address_is_blank
  | Credential_variable_is_blank
  | Model_is_blank
  | Voice_is_blank

let gap_message = function
  | Endpoint_id_is_blank ->
    "the endpoint needs a name: it is how this entry is addressed later"
  | Address_is_blank -> "the endpoint needs an address to reach"
  | Credential_variable_is_blank ->
    "this provider needs the name of the environment variable holding its key"
  | Model_is_blank ->
    "this endpoint needs a model: it is written on the endpoint, so every other \
     endpoint in the section keeps the one it has"
  | Voice_is_blank -> "speech out needs a default voice"
;;

let blank_text value = String.equal (String.trim value) ""

(* Required fields, per provider and section, in the order the steps ask.

   An OpenAI-compatible endpoint needs an address and may go without a
   credential: leaving api_key_env out is what keeps the Authorization header
   off a local server that never asked for one, which is why that server answers
   200. ElevenLabs is the reverse -- it needs the key and carries a default
   address. *)
let gaps draft =
  let required =
    match draft.provider with
    (* say is asked for a voice, not a model, and runs a command on this
       machine: a name is all it needs beyond the voice speech out adds
       below. *)
    | Macos_say -> [ Endpoint_id_is_blank ]
    (* whisper-cli is asked for the file it loads rather than a name a provider
       looks up, so the model is required and nothing else is. *)
    | Whisper_cli -> [ Endpoint_id_is_blank; Model_is_blank ]
    | Elevenlabs -> [ Endpoint_id_is_blank; Credential_variable_is_blank; Model_is_blank ]
    | Openai_compatible -> [ Endpoint_id_is_blank; Address_is_blank; Model_is_blank ]
    | Mcp_tool -> [ Endpoint_id_is_blank; Address_is_blank; Model_is_blank ]
  in
  let required =
    match draft.section with
    | Voice_setup.Tts -> required @ [ Voice_is_blank ]
    | Voice_setup.Stt -> required
  in
  List.filter
    (fun gap ->
      match gap with
      | Endpoint_id_is_blank -> blank_text draft.endpoint_id
      | Address_is_blank -> blank_text draft.address
      | Credential_variable_is_blank -> blank_text draft.credential_variable
      | Model_is_blank -> blank_text draft.model
      | Voice_is_blank -> blank_text draft.voice)
    required
;;

let optional value = if blank_text value then None else Some (String.trim value)

let endpoint_of_draft draft : Voice_config.endpoint =
  let kind = kind_of_provider draft.provider in
  { Voice_config.id = String.trim draft.endpoint_id
  ; kind
  ; base_url = (match draft.provider with
                | Elevenlabs | Openai_compatible -> optional draft.address
                (* The loader refuses an address on a command kind, so the
                   draft cannot carry one into the file. *)
                | Mcp_tool | Macos_say | Whisper_cli -> None)
  ; mcp_url = (match draft.provider with
               | Mcp_tool -> optional draft.address
               | Elevenlabs | Openai_compatible | Macos_say | Whisper_cli -> None)
  ; health_url = None
  ; api_key_env = optional draft.credential_variable
  ; enabled = true
  ; timeout_seconds = draft.timeout_seconds
  ; default_voice = None
  (* Left unset so the two command kinds run the name they are normally
     installed under, which the overlay supplies. Pointing an endpoint at a
     binary PATH does not carry is an edit to the file, not a question worth
     asking everyone who sets one up. *)
  ; command = None
  (* On the endpoint, not the section: a second provider added to the same
     section would otherwise change the model the first one is asked for. *)
  ; model = optional draft.model
  }
;;

let changes draft =
  match gaps draft with
  | _ :: _ as gaps -> Error gaps
  | [] ->
    (* The model travels on the endpoint ({!endpoint_of_draft}), so nothing
       is written to the section's default_model and the endpoints already
       there keep the model they had. *)
    let voice =
      match draft.section with
      | Voice_setup.Tts -> [ Voice_setup.Set_tts_default_voice (String.trim draft.voice) ]
      | Voice_setup.Stt -> []
    in
    Ok (voice @ [ Voice_setup.Put_endpoint (draft.section, endpoint_of_draft draft) ])
;;

type step =
  | Section
  | Provider
  | Name
  | Address
  | Credential
  | Model
  | Voice
  | Review

(* Only the questions this provider is asked. A step with no answer to give is
   a step an operator walks through to press Enter on nothing, and for a
   command kind the address and the key are exactly that. *)
let steps draft =
  let address =
    match draft.provider with
    | Elevenlabs | Macos_say | Whisper_cli -> []
    | Openai_compatible | Mcp_tool -> [ Address ]
  in
  let credential =
    match draft.provider with
    | Elevenlabs | Openai_compatible -> [ Credential ]
    | Mcp_tool | Macos_say | Whisper_cli -> []
  in
  (* say takes a voice, not a model: it is the one entry here that is asked for
     no model at all. *)
  let model =
    match draft.provider with
    | Macos_say -> []
    | Whisper_cli | Elevenlabs | Openai_compatible | Mcp_tool -> [ Model ]
  in
  let voice =
    match draft.section with
    | Voice_setup.Tts -> [ Voice ]
    | Voice_setup.Stt -> []
  in
  ((Section :: Provider :: Name :: address) @ credential @ model @ voice) @ [ Review ]
;;

let step_prompt = function
  | Section -> "Is this endpoint for speech out or speech in?"
  | Provider -> "Which provider serves this endpoint?"
  | Name -> "What should this endpoint be called? It is how the entry is addressed later."
  | Address -> "What address does it answer on?"
  | Credential ->
    "Which environment variable holds its key? Leave blank for a local server that \
     does not want one."
  | Model ->
    "Which model should this endpoint be asked for? For whisper-cli it is the \
     path of the ggml file it loads."
  | Voice -> "Which voice should speech out use by default?"
  | Review -> "Here is what will change."
;;

let step_gap = function
  | Section -> None
  | Provider -> None
  | Name -> Some Endpoint_id_is_blank
  | Address -> Some Address_is_blank
  | Credential -> Some Credential_variable_is_blank
  | Model -> Some Model_is_blank
  | Voice -> Some Voice_is_blank
  | Review -> None
;;

(* ── the request a surface sends ───────────────────────────────────────── *)

(* The wire shape belongs to the server, which parses it back into the closed
   sum type before it means anything. Producing it here keeps one spelling of it
   on the sending side: a TUI and a dashboard that each wrote their own would
   drift, and the drift would only show as a request the server refuses. *)

let section_label = function
  | Voice_setup.Tts -> "tts"
  | Voice_setup.Stt -> "stt"

let endpoint_json (endpoint : Voice_config.endpoint) =
  let text key = function
    | Some value -> [ key, `String value ]
    | None -> []
  in
  `Assoc
    ([ "id", `String endpoint.Voice_config.id
     ; "kind", `String (Voice_config.string_of_endpoint_kind endpoint.Voice_config.kind)
     ; "enabled", `Bool endpoint.Voice_config.enabled
     ]
     @ text "base_url" endpoint.Voice_config.base_url
     @ text "mcp_url" endpoint.Voice_config.mcp_url
     @ text "health_url" endpoint.Voice_config.health_url
     @ text "api_key_env" endpoint.Voice_config.api_key_env
     @ text "default_voice" endpoint.Voice_config.default_voice
     @ text "model" endpoint.Voice_config.model
     @
     match endpoint.Voice_config.timeout_seconds with
     | Some seconds -> [ "timeout_seconds", `Float seconds ]
     | None -> [])

let change_json = function
  | Voice_setup.Put_endpoint (section, endpoint) ->
    `Assoc
      [ "change", `String "put_endpoint"
      ; "section", `String (section_label section)
      ; "endpoint", endpoint_json endpoint
      ]
  | Voice_setup.Remove_endpoint (section, id) ->
    `Assoc
      [ "change", `String "remove_endpoint"
      ; "section", `String (section_label section)
      ; "id", `String id
      ]
  | Voice_setup.Set_default_model (section, model) ->
    `Assoc
      [ "change", `String "set_default_model"
      ; "section", `String (section_label section)
      ; "model", `String model
      ]
  | Voice_setup.Set_tts_default_voice voice ->
    `Assoc [ "change", `String "set_tts_default_voice"; "voice", `String voice ]
  | Voice_setup.Set_send_on_stop send ->
    `Assoc [ "change", `String "set_send_on_stop"; "send", `Bool send ]
  | Voice_setup.Set_agent_voice (agent, voice) ->
    `Assoc
      [ "change", `String "set_agent_voice"
      ; "agent", `String agent
      ; ( "voice"
        , match voice with
          | Some voice -> `String voice
          | None -> `Null )
      ]

let save_request draft ~revision =
  match changes draft with
  | Error gaps -> Error gaps
  | Ok changes ->
    Ok
      (`Assoc
        [ "expected_revision", `String revision
        ; "changes", `List (List.map change_json changes)
        ])

(* Changing the side re-picks the provider when the current one does not serve
   it: an MCP tool speaks and does not listen, so carrying it across would leave
   a draft whose provider is not in its own offered list. Everything else is
   provider vocabulary and is reset with it. *)
let with_section draft section =
  if draft.section = section
  then draft
  else (
    let provider =
      if List.mem draft.provider (providers_for section)
      then draft.provider
      else (
        match providers_for section with
        | first :: _ -> first
        | [] -> draft.provider)
    in
    let fresh = blank ~section ~provider in
    { fresh with endpoint_id = draft.endpoint_id })
