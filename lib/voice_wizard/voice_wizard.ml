type provider =
  | Elevenlabs
  | Openai_compatible
  | Mcp_tool

let provider_label = function
  | Elevenlabs -> "elevenlabs"
  | Openai_compatible -> "openai_compatible"
  | Mcp_tool -> "mcp_tool"
;;

let provider_of_label = function
  | "elevenlabs" -> Some Elevenlabs
  | "openai_compatible" -> Some Openai_compatible
  | "mcp_tool" -> Some Mcp_tool
  | _ -> None
;;

(* Speech in is not offered an MCP tool: that kind synthesizes through a tool
   call and has no transcribe path, so offering it would produce an endpoint
   every probe reports as not asked. *)
let providers_for = function
  | Voice_setup.Tts -> [ Elevenlabs; Openai_compatible; Mcp_tool ]
  | Voice_setup.Stt -> [ Elevenlabs; Openai_compatible ]
;;

let kind_of_provider = function
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
               | Openai_compatible | Mcp_tool -> "")
  ; credential_variable =
      (match provider with
       | Elevenlabs -> elevenlabs_credential_variable
       | Openai_compatible | Mcp_tool -> "")
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
    "the section needs a model name: every endpoint in it is asked for this model \
     by name"
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
                | Mcp_tool -> None)
  ; mcp_url = (match draft.provider with
               | Mcp_tool -> optional draft.address
               | Elevenlabs | Openai_compatible -> None)
  ; health_url = None
  ; api_key_env = optional draft.credential_variable
  ; enabled = true
  ; timeout_seconds = draft.timeout_seconds
  ; default_voice = None
  }
;;

let changes draft =
  match gaps draft with
  | _ :: _ as gaps -> Error gaps
  | [] ->
    let model = String.trim draft.model in
    (* The section's default_model is set alongside the endpoint, not after it:
       a section that exists must name one, so an endpoint written on its own
       would leave a file the loader refuses. *)
    let voice =
      match draft.section with
      | Voice_setup.Tts -> [ Voice_setup.Set_tts_default_voice (String.trim draft.voice) ]
      | Voice_setup.Stt -> []
    in
    Ok
      ((Voice_setup.Set_default_model (draft.section, model) :: voice)
       @ [ Voice_setup.Put_endpoint (draft.section, endpoint_of_draft draft) ])
;;

type step =
  | Provider
  | Name
  | Address
  | Credential
  | Model
  | Voice
  | Review

let steps draft =
  let address =
    match draft.provider with
    | Elevenlabs -> []
    | Openai_compatible | Mcp_tool -> [ Address ]
  in
  let credential =
    match draft.provider with
    | Elevenlabs | Openai_compatible -> [ Credential ]
    | Mcp_tool -> []
  in
  let voice =
    match draft.section with
    | Voice_setup.Tts -> [ Voice ]
    | Voice_setup.Stt -> []
  in
  ((Provider :: Name :: address) @ credential @ [ Model ] @ voice) @ [ Review ]
;;

let step_prompt = function
  | Provider -> "Which provider serves this endpoint?"
  | Name -> "What should this endpoint be called? It is how the entry is addressed later."
  | Address -> "What address does it answer on?"
  | Credential ->
    "Which environment variable holds its key? Leave blank for a local server that \
     does not want one."
  | Model -> "Which model should every endpoint in this section be asked for?"
  | Voice -> "Which voice should speech out use by default?"
  | Review -> "Here is what will change."
;;

let step_gap = function
  | Provider -> None
  | Name -> Some Endpoint_id_is_blank
  | Address -> Some Address_is_blank
  | Credential -> Some Credential_variable_is_blank
  | Model -> Some Model_is_blank
  | Voice -> Some Voice_is_blank
  | Review -> None
;;
