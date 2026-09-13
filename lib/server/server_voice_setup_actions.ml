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

(* A repeated name is a payload whose meaning depends on who reads it: the
   readers below take the first occurrence through [List.assoc_opt] while a
   client or proxy that re-serializes may keep the last, so {"enabled": false,
   "enabled": true} could commit the opposite of what was sent. Refused before
   any field is read. *)
let fields = function
  | `Assoc fields ->
    let duplicates =
      List.filter_map
        (fun (key, _) ->
          if List.length (List.filter (fun (other, _) -> String.equal key other) fields) > 1
          then Some key
          else None)
        fields
      |> List.sort_uniq String.compare
    in
    if duplicates = []
    then Ok fields
    else
      Error
        (Invalid_request
           (Printf.sprintf
              "a JSON object repeats %s"
              (String.concat ", " (List.map (fun key -> Printf.sprintf "%S" key) duplicates))))
  | _ -> Error (Invalid_request "expected a JSON object")

(* Trimmed, because every reader of these values compares them trimmed and
   none of them is free text: ids, section names, model and voice names, a
   revision. Returning the raw string made padding a per-caller problem, and
   one caller forgot -- [remove_endpoint] handed the padded id to the
   exact-match TOML editor, which matched nothing while the response said
   applied. *)
let string_field ~what fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok (String.trim value)
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

(* Zero or less is not a shorter timeout, it is one that has already expired:
   [Voice_bridge.call_voice_mcp_endpoint] hands the value to [Eio.Time.sleep], so
   the timeout branch wins immediately and an otherwise working endpoint fails
   every call while the API reported success. Infinities and NaN go the same way
   -- neither is a duration. *)
let optional_seconds ~what fields key =
  let positive value =
    if Float.is_finite value && value > 0.
    then Ok (Some value)
    else
      Error
        (Invalid_request
           (Printf.sprintf "%s needs %S to be a finite number greater than zero" what key))
  in
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`Float value) -> positive value
  | Some (`Int value) -> positive (float_of_int value)
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

(* [Voice_runtime_overlay.adapter_for_endpoint] resolves the id before it
   consults the kind, so an id that is an alias for another adapter wins over
   what the request declared: id = "elevenlabs" with kind = "openai_compat"
   reaches ElevenLabs with its authentication shape while this API reports an
   OpenAI-compatible endpoint. Refused here rather than written, because a
   config whose declared kind is not the transport the runtime uses is one no
   reader of it can trust. Making the kind authoritative in that resolver is the
   other way round and changes how files already written resolve. *)
let id_agrees_with_kind ~id ~kind =
  match Voice_runtime_overlay.resolve_adapter id with
  | None -> true
  | Some resolved ->
    String.equal
      resolved.Voice_runtime_overlay.canonical_name
      (Voice_runtime_overlay.adapter_for_endpoint_kind kind)
        .Voice_runtime_overlay.canonical_name

let endpoint_of_json json =
  let what = "an endpoint" in
  let* fields = fields json in
  let* () = no_unknown_fields ~what ~allowed:endpoint_allowed_fields fields in
  (* [Voice_config.select_endpoint] trims a requested id before comparing, so an
     id stored with padding could never be selected again -- not even with the id
     the observation handed back. [string_field] trims, which is the form every
     reader compares. *)
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
  let* () =
    if id_agrees_with_kind ~id ~kind
    then Ok ()
    else
      Error
        (Invalid_request
           (Printf.sprintf
              "endpoint id %S already names the %S transport, which is not the declared \
               kind %S; the runtime would resolve the id and reach the other one"
              id
              (match Voice_runtime_overlay.resolve_adapter id with
               | Some resolved -> resolved.Voice_runtime_overlay.canonical_name
               | None -> "")
              (Voice_config.string_of_endpoint_kind kind)))
  in
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
     (* Which program a command kind actually runs. Omitted, the observation
        described an endpoint by a default it may have overridden. The request
        still does not take it -- a path this route cannot check is not one to
        accept from a caller -- so this is a read-only field. *)
     @ text "command" endpoint.Voice_config.command
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
  | "set_send_on_stop" ->
    let what = "set_send_on_stop" in
    let* () = only ~what [ "send" ] in
    (match List.assoc_opt "send" fields with
     | Some (`Bool send) -> Ok (Voice_setup.Set_send_on_stop send)
     | Some _ | None ->
       Error
         (Invalid_request "set_send_on_stop needs \"send\" to be true or false"))
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
               [ (* Null rather than "" when the section names none: a
                    speaking section whose endpoints all take no model has
                    none, and a blank here reads as a model named "". *)
                 ( "default_model"
                 , match tts.Voice_config.default_model with
                   | Some model -> `String model
                   | None -> `Null )
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
    (* The documented full view left this out, so a client could not see a
       configured realtime endpoint and reported that part of setup as absent.
       It has no section-level settings of its own -- only endpoints. *)
    let session =
      match config with
      | None -> `Null
      | Some config ->
        section_json
          ~endpoints:
            (List.map endpoint_json config.Voice_config.session.Voice_config.endpoints)
          ~extra:[]
    in
    (* Capture thresholds, the local-playback allowlist and the Gate's bypasses
       are all in effect and none of them was described, so a client reading this
       as the full configuration showed defaults for values the file had already
       set. These three have no endpoints -- they are settings -- so they are
       serialized directly rather than through [section_json]. *)
    let capture =
      match config with
      | None -> `Null
      | Some config ->
        let capture = config.Voice_config.capture in
        `Assoc
          [ "calibration_seconds", `Float capture.Voice_config.calibration_seconds
          ; "trigger_margin_db", `Float capture.Voice_config.trigger_margin_db
          ; ( "trailing_silence_seconds"
            , `Float capture.Voice_config.trailing_silence_seconds )
          ; "speech_margin_db", `Float capture.Voice_config.speech_margin_db
          ; "noise_reduction", `Bool capture.Voice_config.noise_reduction
          ]
    in
    let local_playback =
      match config with
      | None -> `Null
      | Some config ->
        let playback = config.Voice_config.local_playback in
        `Assoc
          [ "enabled", `Bool playback.Voice_config.enabled
          ; ( "agents"
            , `List (List.map (fun agent -> `String agent) playback.Voice_config.agents) )
          ]
    in
    let gate =
      match config with
      | None -> `Null
      | Some config ->
        let gate = config.Voice_config.gate in
        `Assoc
          [ "always_allow", `Bool gate.Voice_config.always_allow
          ; ( "exempt_agents"
            , `List (List.map (fun agent -> `String agent) gate.Voice_config.exempt_agents) )
          ]
    in
    Ok
      (`Assoc
         [ "revision", `String revision
         ; "tts", tts
         ; "stt", stt
         ; "session", session
         ; "capture", capture
         ; "local_playback", local_playback
         ; "gate", gate
         ])

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
  (* The revision comes out of the write itself, not from reading the file
     again afterwards: a second read can see someone else's commit and hand
     the caller a revision its own change is not in. *)
  | Ok revision -> Ok (`Assoc [ "applied", `Bool true; "revision", `String revision ])

(* The endpoint a catalogue read is taken against. It is not an endpoint anyone
   configured: it is built for one request and thrown away, so it carries only
   what asking needs -- the kind, and the name of the variable holding that
   provider's key.

   The request chooses neither an address nor a command path. Catalogue reads
   use the endpoint kind's default transport destination. *)
let catalogue_endpoint_of_json json =
  let* fields = fields json in
  let* () =
    no_unknown_fields ~what:"a listing" ~allowed:[ "kind"; "api_key_env" ] fields
  in
  let* kind_text = string_field ~what:"a listing" fields "kind" in
  let* kind = kind_of_string kind_text in
  let* api_key_env = optional_string ~what:"a listing" fields "api_key_env" in
  let api_key_env = Option.map String.trim api_key_env in
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
