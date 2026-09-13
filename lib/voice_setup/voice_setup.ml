type section =
  | Tts
  | Stt

type change =
  | Put_endpoint of section * Voice_config.endpoint
  | Remove_endpoint of section * string
  | Set_default_model of section * string
  | Set_tts_default_voice of string
  | Set_send_on_stop of bool
  | Set_agent_voice of string * string option

type error =
  | Configuration_unavailable of string
  | Configuration_changed
  | Voice_section_invalid of string
  | Configuration_rejected of string
  | Endpoint_path_unusable of string

let error_message = function
  | Configuration_unavailable detail -> "runtime.toml could not be read: " ^ detail
  | Configuration_changed ->
    "runtime.toml changed since it was read, so nothing was written"
  | Voice_section_invalid detail ->
    "the edit does not load as a voice configuration, so it was not written: " ^ detail
  | Configuration_rejected detail -> "the commit was refused: " ^ detail
  | Endpoint_path_unusable detail ->
    "the endpoint list cannot be written where it would have to go: " ^ detail
;;

exception Revision_changed
exception Voice_invalid of string

let endpoints_path = function
  | Tts -> "voice.tts.endpoints"
  | Stt -> "voice.stt.endpoints"
;;

let section_table = function
  | Tts -> "voice.tts"
  | Stt -> "voice.stt"
;;

let string_field key = function
  | None -> key, None
  | Some value -> key, Some (Toml_line_editor.String value)
;;

(* Destructured rather than read field by field so that a field added to
   Voice_config.endpoint fails to compile here instead of being quietly left out
   of what the writer emits. The loader's whitelist and this list are the same
   nine names, and a tenth that only one side knows is how a section stops
   loading. *)
let endpoint_fields (endpoint : Voice_config.endpoint) =
  let { Voice_config.id = _
      ; kind
      ; base_url
      ; mcp_url
      ; health_url
      ; api_key_env
      ; enabled
      ; timeout_seconds
      ; default_voice
      }
    =
    endpoint
  in
  [ "kind", Some (Toml_line_editor.String (Voice_config.string_of_endpoint_kind kind))
  ; string_field "base_url" base_url
  ; string_field "mcp_url" mcp_url
  ; string_field "health_url" health_url
  ; string_field "api_key_env" api_key_env
  ; "enabled", Some (Toml_line_editor.Bool enabled)
  ; ( "timeout_seconds"
    , Option.map (fun seconds -> Toml_line_editor.Float seconds) timeout_seconds )
  ; string_field "default_voice" default_voice
  ]
;;

exception Entry_refused of Toml_line_editor.entry_error

let put_endpoint contents ~path (endpoint : Voice_config.endpoint) =
  match
    Toml_line_editor.upsert_table_array_entry
      contents
      ~path
      ~id_key:"id"
      ~id:endpoint.Voice_config.id
      ~fields:(endpoint_fields endpoint)
  with
  | Ok updated -> updated
  | Error error -> raise (Entry_refused error)
;;

let apply_change contents = function
  | Put_endpoint (section, endpoint) ->
    put_endpoint contents ~path:(endpoints_path section) endpoint
  | Remove_endpoint (section, id) ->
    Toml_line_editor.remove_table_array_entry
      contents
      ~path:(endpoints_path section)
      ~id_key:"id"
      ~id
  | Set_default_model (section, model) ->
    Toml_line_editor.edit_table_scalar
      contents
      ~path:(section_table section)
      ~key:"default_model"
      ~value:(Some model)
  | Set_tts_default_voice voice ->
    Toml_line_editor.edit_table_scalar
      contents
      ~path:"voice.tts"
      ~key:"default_voice"
      ~value:(Some voice)
  | Set_send_on_stop send ->
    Toml_line_editor.edit_table_bool
      contents
      ~path:"voice.stt"
      ~key:"send_on_stop"
      ~value:send
  | Set_agent_voice (agent, voice) ->
    Toml_line_editor.edit_table_scalar
      contents
      ~path:"voice.tts.agent_voices"
      ~key:agent
      ~value:voice
;;

(* The edited text has to read back as a voice configuration before it is
   written. Nothing reads [voice] at boot: a section that does not load stays
   quiet until the first speak or transcribe, which is how it once went
   unnoticed for six days. A writer that committed text it had not read back
   would reproduce that. *)
let checked contents changes =
  let updated = List.fold_left apply_change contents changes in
  match Voice_config.parse_runtime_toml_text updated with
  | Ok _ -> updated
  | Error message -> raise (Voice_invalid message)
;;

let revision_of (observation : Runtime.config_observation) =
  Runtime.config_source_revision_to_string observation.source_revision
;;

let observe ~runtime_config_path =
  match Runtime.load_config_observation ~runtime_config_path () with
  | Error detail -> Error (Configuration_unavailable detail)
  | Ok observation ->
    (match Voice_config.parse_runtime_toml_text observation.source_text with
     | Error message -> Error (Voice_section_invalid message)
     | Ok config -> Ok (revision_of observation, config))
;;

let preview ~runtime_config_path ~expected_revision changes =
  match Runtime.load_config_observation ~runtime_config_path () with
  | Error detail -> Error (Configuration_unavailable detail)
  | Ok observation ->
    if not (String.equal (revision_of observation) expected_revision)
    then Error Configuration_changed
    else (
      match checked observation.source_text changes with
      | updated -> Ok updated
      | exception Voice_invalid message -> Error (Voice_section_invalid message)
      | exception Entry_refused error ->
        Error (Endpoint_path_unusable (Toml_line_editor.entry_error_message error)))
;;

let apply ~runtime_config_path ~expected_revision changes =
  (* The revision is checked again here, inside edit_config_text's lock, because
     preview read it outside one. *)
  let edit contents =
    let observation = Runtime.config_observation ~path:runtime_config_path contents in
    if not (String.equal (revision_of observation) expected_revision)
    then raise Revision_changed;
    checked contents changes
  in
  match Runtime.edit_config_text ~runtime_config_path edit with
  (* The revision this write produced, out of the commit itself. Reading it
     back afterwards is a second, unlocked observation: it answers a failure
     for a write that landed, and when another writer commits in between it
     answers that writer's revision -- which this caller would then hand back
     as [expected_revision] without ever having seen what it described. *)
  | Ok receipt -> Ok (revision_of receipt.Runtime.observation)
  | Error detail -> Error (Configuration_rejected detail)
  | exception Revision_changed -> Error Configuration_changed
  | exception Voice_invalid message -> Error (Voice_section_invalid message)
  | exception Entry_refused error ->
    Error (Endpoint_path_unusable (Toml_line_editor.entry_error_message error))
;;

type voice_placement =
  | On_the_section
  | On_the_endpoint

let voice_placement ~section_exists =
  if section_exists then On_the_endpoint else On_the_section
