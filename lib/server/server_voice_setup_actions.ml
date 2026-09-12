type error =
  | Invalid_request of string
  | Setup_failed of Voice_setup.error

let error_message = function
  | Invalid_request detail -> detail
  | Setup_failed error -> Voice_setup.error_message error

let runtime_config_path ~base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config")
    Config_dir_resolver.runtime_toml_filename

(* ── wire shapes ───────────────────────────────────────────────────────── *)

let fields = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Invalid_request "expected a JSON object")

let string_field ~what fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ | None ->
    Error (Invalid_request (Printf.sprintf "%s needs a non-empty %S" what key))

let optional_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Some value
  | Some _ | None -> None

let section_of_string ~what = function
  | "tts" -> Ok Voice_setup.Tts
  | "stt" -> Ok Voice_setup.Stt
  | other ->
    Error
      (Invalid_request
         (Printf.sprintf "%s names an unknown section %S; expected \"tts\" or \"stt\"" what
            other))

(* Refused by name rather than defaulted: a kind this build does not have is a
   request for something that will not work, and guessing writes the guess to
   runtime.toml. *)
let kind_of_string = function
  | "openai_compat" -> Ok Voice_config.Openai_compat
  | "elevenlabs_direct" -> Ok Voice_config.Elevenlabs_direct
  | "voice_mcp" -> Ok Voice_config.Voice_mcp
  | "macos_say" -> Ok Voice_config.Macos_say
  | "whisper_cli" -> Ok Voice_config.Whisper_cli
  | other ->
    Error
      (Invalid_request
         (Printf.sprintf
            "unknown endpoint kind %S; expected \"openai_compat\", \
             \"elevenlabs_direct\", \"voice_mcp\", \"macos_say\" or \"whisper_cli\""
            other))

let ( let* ) = Result.bind

let endpoint_of_json json =
  let* fields = fields json in
  let* id = string_field ~what:"an endpoint" fields "id" in
  let* kind_text = string_field ~what:"an endpoint" fields "kind" in
  let* kind = kind_of_string kind_text in
  let enabled =
    match List.assoc_opt "enabled" fields with
    | Some (`Bool value) -> value
    | Some _ | None -> true
  in
  let timeout_seconds =
    match List.assoc_opt "timeout_seconds" fields with
    | Some (`Float value) -> Some value
    | Some (`Int value) -> Some (float_of_int value)
    | Some _ | None -> None
  in
  Ok
    { Voice_config.id
    ; kind
    ; base_url = optional_string fields "base_url"
    ; mcp_url = optional_string fields "mcp_url"
    ; health_url = optional_string fields "health_url"
    ; api_key_env = optional_string fields "api_key_env"
    ; enabled
    ; timeout_seconds
    ; default_voice = optional_string fields "default_voice"
    (* Not taken from the request. A command kind knows the name it is
       installed under, and an override is a path this route cannot check;
       someone who needs one edits the file. *)
    ; command = None
    }

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
     @
     match endpoint.Voice_config.timeout_seconds with
     | Some seconds -> [ "timeout_seconds", `Float seconds ]
     | None -> [])

let change_of_json json =
  let* fields = fields json in
  let* change = string_field ~what:"a change" fields "change" in
  let section () =
    let* text = string_field ~what:"a change" fields "section" in
    section_of_string ~what:"a change" text
  in
  match change with
  | "put_endpoint" ->
    let* section = section () in
    let* endpoint =
      match List.assoc_opt "endpoint" fields with
      | Some endpoint -> endpoint_of_json endpoint
      | None -> Error (Invalid_request "put_endpoint needs an \"endpoint\" object")
    in
    Ok (Voice_setup.Put_endpoint (section, endpoint))
  | "remove_endpoint" ->
    let* section = section () in
    let* id = string_field ~what:"remove_endpoint" fields "id" in
    Ok (Voice_setup.Remove_endpoint (section, id))
  | "set_default_model" ->
    let* section = section () in
    let* model = string_field ~what:"set_default_model" fields "model" in
    Ok (Voice_setup.Set_default_model (section, model))
  | "set_tts_default_voice" ->
    let* voice = string_field ~what:"set_tts_default_voice" fields "voice" in
    Ok (Voice_setup.Set_tts_default_voice voice)
  | "set_agent_voice" ->
    let* agent = string_field ~what:"set_agent_voice" fields "agent" in
    (* A null voice clears the mapping, which is a different request from not
       mentioning the field at all. *)
    (match List.assoc_opt "voice" fields with
     | Some `Null | None -> Ok (Voice_setup.Set_agent_voice (agent, None))
     | Some (`String voice) when String.trim voice <> "" ->
       Ok (Voice_setup.Set_agent_voice (agent, Some voice))
     | Some _ ->
       Error
         (Invalid_request "set_agent_voice needs \"voice\" to be a non-empty string or null"))
  | other ->
    Error (Invalid_request (Printf.sprintf "unknown change %S" other))

let changes_of_json fields =
  match List.assoc_opt "changes" fields with
  | Some (`List values) ->
    List.fold_left
      (fun acc json ->
        let* changes = acc in
        let* change = change_of_json json in
        Ok (change :: changes))
      (Ok [])
      values
    |> Result.map List.rev
  | Some _ | None -> Error (Invalid_request "expected a \"changes\" array")

let request_of_json json =
  let* fields = fields json in
  let* revision = string_field ~what:"the request" fields "expected_revision" in
  let* changes = changes_of_json fields in
  Ok (revision, changes)

(* ── routes ────────────────────────────────────────────────────────────── *)

let section_json ~endpoints ~extra = `Assoc (extra @ [ "endpoints", `List endpoints ])

let observe ~base_path =
  match Voice_setup.observe ~runtime_config_path:(runtime_config_path ~base_path) with
  | Error error -> Error (Setup_failed error)
  | Ok (revision, config) ->
    let tts =
      match config with
      | None -> `Null
      | Some config ->
        (match config.Voice_config.tts with
         | None -> `Null
         | Some tts ->
           section_json
             ~endpoints:(List.map endpoint_json tts.Voice_config.endpoints)
             ~extra:
               [ ( "default_model"
                 , match tts.Voice_config.default_model with
                   | Some model -> `String model
                   | None -> `Null )
               ; "default_voice", `String tts.Voice_config.default_voice
               ; ( "agent_voices"
                 , `Assoc
                     (List.map
                        (fun (agent, voice) -> agent, `String voice)
                        tts.Voice_config.agent_voices) )
               ])
    in
    let stt =
      match config with
      | None -> `Null
      | Some config ->
        (match config.Voice_config.stt with
         | None -> `Null
         | Some stt ->
           section_json
             ~endpoints:(List.map endpoint_json stt.Voice_config.endpoints)
             ~extra:[ "default_model", `String stt.Voice_config.default_model ])
    in
    Ok (`Assoc [ "revision", `String revision; "tts", tts; "stt", stt ])

let preview ~base_path json =
  let* revision, changes = request_of_json json in
  match
    Voice_setup.preview
      ~runtime_config_path:(runtime_config_path ~base_path)
      ~expected_revision:revision
      changes
  with
  | Error error -> Error (Setup_failed error)
  | Ok text -> Ok (`Assoc [ "runtime_toml", `String text ])

let apply ~base_path json =
  let* revision, changes = request_of_json json in
  let path = runtime_config_path ~base_path in
  match Voice_setup.apply ~runtime_config_path:path ~expected_revision:revision changes with
  | Error error -> Error (Setup_failed error)
  | Ok () ->
    (* The revision after the write, so a caller can keep editing without
       reading again. *)
    (match Voice_setup.observe ~runtime_config_path:path with
     | Error error -> Error (Setup_failed error)
     | Ok (revision, _) ->
       Ok (`Assoc [ "applied", `Bool true; "revision", `String revision ]))

(* The endpoint a catalogue read is taken against. It is not an endpoint anyone
   configured: it is built for one request and thrown away, so it carries only
   what asking needs -- the kind, and the name of the variable holding that
   provider's key.

   The request chooses neither an address nor a command path. Catalogue reads
   use the endpoint kind's default transport destination. *)
let catalogue_endpoint_of_json json =
  let* fields = fields json in
  let* kind_text = string_field ~what:"a listing" fields "kind" in
  let* kind = kind_of_string kind_text in
  let api_key_env =
    match List.assoc_opt "api_key_env" fields with
    | Some (`String value) when String.trim value <> "" -> Some (String.trim value)
    | Some _ | None -> None
  in
  Ok
    { Voice_config.id = "voice-catalogue-read"
    ; kind
    ; base_url = None
    ; mcp_url = None
    ; health_url = None
    ; api_key_env
    ; enabled = true
    ; timeout_seconds = None
    ; default_voice = None
    ; command = None
    }
;;
