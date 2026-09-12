type error =
  | Invalid_request of string
  | Setup_failed of Voice_setup.error

let error_message = function
  | Invalid_request detail -> detail
  | Setup_failed error -> Voice_setup.error_message error

(* The resolver, not a rebuilt path: MASC_CONFIG_DIR moves the config root, and
   a hand-joined <base_path>/.masc/config/runtime.toml reads and writes a
   different file from the one the runtime loads under that override -- an apply
   would report success over a file nothing consumes. *)
let runtime_config_path ~base_path =
  Config_dir_resolver.runtime_toml_path_for_base_path ~base_path

(* ── wire shapes ───────────────────────────────────────────────────────── *)

let fields = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Invalid_request "expected a JSON object")

let string_field ~what fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some _ | None ->
    Error (Invalid_request (Printf.sprintf "%s needs a non-empty %S" what key))

(* Absence and a wrong type are different answers. Substituting a default for a
   mistyped value commits configuration the caller did not send: "enabled":
   "false" read as true, a string timeout dropped. Each reader below refuses
   what it cannot read rather than filling it in. *)
let optional_string ~what fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) ->
    Error (Invalid_request (Printf.sprintf "%s needs %S to be a non-empty string" what key))
  | Some _ ->
    Error (Invalid_request (Printf.sprintf "%s needs %S to be a string" what key))

let optional_bool ~what fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some _ -> Error (Invalid_request (Printf.sprintf "%s needs %S to be a boolean" what key))

let optional_seconds ~what fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (float_of_int value))
  | Some _ -> Error (Invalid_request (Printf.sprintf "%s needs %S to be a number" what key))

(* A name this decoder does not read is a request it is not carrying out. The
   misspelling that matters is a credential one: api_key_en writes an endpoint
   with no key and reports success. *)
let no_unknown_fields ~what ~allowed fields =
  match List.filter (fun (key, _) -> not (List.mem key allowed)) fields with
  | [] -> Ok ()
  | unknown ->
    Error
      (Invalid_request
         (Printf.sprintf
            "%s does not take %s"
            what
            (String.concat ", " (List.map (fun (key, _) -> Printf.sprintf "%S" key) unknown))))

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
  (* The observation emits these two, so refusing them here made the API unable
     to put back what it had just handed out. They carry no address and run a
     command instead; [command] stays out of the request because each kind
     already knows the argv it runs (Voice_runtime_overlay.endpoint_command
     falls back to it), and a path this route cannot check is not one to take
     from a caller. *)
  | "macos_say" -> Ok Voice_config.Macos_say
  | "whisper_cli" -> Ok Voice_config.Whisper_cli
  | other ->
    Error
      (Invalid_request
         (Printf.sprintf
            "unknown endpoint kind %S; expected \"openai_compat\", \
             \"elevenlabs_direct\", \"voice_mcp\", \"macos_say\" or \"whisper_cli\""
            other))

(* Which section a kind can serve. A kind installed in the section it cannot
   answer is a success report over an endpoint that never runs: voice_mcp is
   asked to speak and skipped by the STT probe, and say has no transcription at
   all. Every kind is named rather than folded into a default so a kind added
   later stops the compiler here. *)
let kind_serves_section kind (section : Voice_setup.section) =
  match kind, section with
  | Voice_config.Openai_compat, (Voice_setup.Tts | Voice_setup.Stt)
  | Voice_config.Elevenlabs_direct, (Voice_setup.Tts | Voice_setup.Stt)
  | Voice_config.Voice_mcp, Voice_setup.Tts
  | Voice_config.Macos_say, Voice_setup.Tts
  | Voice_config.Whisper_cli, Voice_setup.Stt -> true
  | Voice_config.Voice_mcp, Voice_setup.Stt
  | Voice_config.Macos_say, Voice_setup.Stt
  | Voice_config.Whisper_cli, Voice_setup.Tts -> false

let ( let* ) = Result.bind

let endpoint_allowed_fields =
  [ "id"; "kind"; "enabled"; "timeout_seconds"; "base_url"; "mcp_url"; "health_url";
    "api_key_env"; "default_voice" ]

let endpoint_of_json json =
  let what = "an endpoint" in
  let* fields = fields json in
  let* () = no_unknown_fields ~what ~allowed:endpoint_allowed_fields fields in
  let* id = string_field ~what fields "id" in
  let* kind_text = string_field ~what fields "kind" in
  let* kind = kind_of_string kind_text in
  let* enabled = optional_bool ~what fields "enabled" in
  let* timeout_seconds = optional_seconds ~what fields "timeout_seconds" in
  let* base_url = optional_string ~what fields "base_url" in
  let* mcp_url = optional_string ~what fields "mcp_url" in
  let* health_url = optional_string ~what fields "health_url" in
  let* api_key_env = optional_string ~what fields "api_key_env" in
  let* default_voice = optional_string ~what fields "default_voice" in
  Ok
    { Voice_config.id
    ; kind
    ; base_url
    ; mcp_url
    ; health_url
    ; api_key_env
    (* Absent means enabled: an endpoint written without the field is one the
       operator means to use. Spelled as a match because absence is a case
       here, not a value to fill in. *)
    ; enabled = (match enabled with Some value -> value | None -> true)
    ; timeout_seconds
    ; default_voice
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
  (* Each variant takes exactly its own fields. A name the variant does not read
     is a contradiction worth refusing rather than obeying halfway:
     set_agent_voice with "section":"stt" used to succeed and write
     voice.tts.agent_voices, the opposite of what the caller named. *)
  let only ~what allowed = no_unknown_fields ~what ~allowed:("change" :: allowed) fields in
  let section ~what =
    let* text = string_field ~what fields "section" in
    section_of_string ~what text
  in
  match change with
  | "put_endpoint" ->
    let what = "put_endpoint" in
    let* () = only ~what [ "section"; "endpoint" ] in
    let* section = section ~what in
    let* endpoint =
      match List.assoc_opt "endpoint" fields with
      | Some endpoint -> endpoint_of_json endpoint
      | None -> Error (Invalid_request "put_endpoint needs an \"endpoint\" object")
    in
    if not (kind_serves_section endpoint.Voice_config.kind section)
    then
      Error
        (Invalid_request
           (Printf.sprintf
              "endpoint kind %S does not serve the %S section"
              (Voice_config.string_of_endpoint_kind endpoint.Voice_config.kind)
              (match section with Voice_setup.Tts -> "tts" | Voice_setup.Stt -> "stt")))
    else Ok (Voice_setup.Put_endpoint (section, endpoint))
  | "remove_endpoint" ->
    let what = "remove_endpoint" in
    let* () = only ~what [ "section"; "id" ] in
    let* section = section ~what in
    let* id = string_field ~what fields "id" in
    Ok (Voice_setup.Remove_endpoint (section, id))
  | "set_default_model" ->
    let what = "set_default_model" in
    let* () = only ~what [ "section"; "model" ] in
    let* section = section ~what in
    let* model = string_field ~what fields "model" in
    Ok (Voice_setup.Set_default_model (section, model))
  | "set_tts_default_voice" ->
    let what = "set_tts_default_voice" in
    let* () = only ~what [ "voice" ] in
    let* voice = string_field ~what fields "voice" in
    Ok (Voice_setup.Set_tts_default_voice voice)
  | "set_agent_voice" ->
    let what = "set_agent_voice" in
    let* () = only ~what [ "agent"; "voice" ] in
    let* agent = string_field ~what fields "agent" in
    (* A null voice clears the mapping, which is a different request from not
       mentioning the field at all. Folding the two together turned a payload
       that forgot the field into a deletion. *)
    (match List.assoc_opt "voice" fields with
     | Some `Null -> Ok (Voice_setup.Set_agent_voice (agent, None))
     | Some (`String voice) when String.trim voice <> "" ->
       Ok (Voice_setup.Set_agent_voice (agent, Some voice))
     | None ->
       Error
         (Invalid_request
            "set_agent_voice needs \"voice\": a non-empty string to set one, or null to \
             clear it")
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
  let* () =
    no_unknown_fields ~what:"the request" ~allowed:[ "expected_revision"; "changes" ] fields
  in
  let* revision = string_field ~what:"the request" fields "expected_revision" in
  let* changes = changes_of_json fields in
  Ok (revision, changes)

(* ── routes ────────────────────────────────────────────────────────────── *)

let section_json ~endpoints ~extra = `Assoc (extra @ [ "endpoints", `List endpoints ])

(* The tuning actually used when synthesizing. Left out, an admin client showed
   provider defaults for a voice the file had already tuned. *)
let tuning_json (tuning : Voice_config.voice_tuning) =
  `Assoc
    [ "stability", `Float tuning.Voice_config.stability
    ; "similarity_boost", `Float tuning.Voice_config.similarity_boost
    ; "style", `Float tuning.Voice_config.style
    ]

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
               [ "default_model", `String tts.Voice_config.default_model
               ; "default_voice", `String tts.Voice_config.default_voice
               ; "default_voice_settings", tuning_json tts.Voice_config.default_voice_settings
               ; ( "agent_voices"
                 , `Assoc
                     (List.map
                        (fun (agent, voice) -> agent, `String voice)
                        tts.Voice_config.agent_voices) )
               ; ( "agent_voice_settings"
                 , `Assoc
                     (List.map
                        (fun (agent, tuning) -> agent, tuning_json tuning)
                        tts.Voice_config.agent_voice_settings) )
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
             ~extra:
               [ "default_model", `String stt.Voice_config.default_model
               (* Behaviourally significant and it was missing: with this on,
                  ending a capture sends the transcript straight away, and a
                  client that could not see it showed the default-off flow. *)
               ; "send_on_stop", `Bool stt.Voice_config.send_on_stop
               ])
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
