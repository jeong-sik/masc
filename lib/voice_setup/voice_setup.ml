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
  | Standalone_source_active of string
  | Voice_not_on_endpoint of string

type source =
  | Runtime_toml
  | Standalone_json of string

(* The [[voice]] table of runtime.toml, spelled once (#39539). *)
let voice_table = Runtime_toml_namespace.(key Voice)

let error_message = function
  | Configuration_unavailable detail -> "runtime.toml could not be read: " ^ detail
  | Configuration_changed ->
    "runtime.toml changed since it was read, so nothing was written"
  | Voice_section_invalid detail ->
    "the edit does not load as a voice configuration, so it was not written: " ^ detail
  | Configuration_rejected detail -> "the commit was refused: " ^ detail
  | Endpoint_path_unusable detail ->
    "the endpoint list cannot be written where it would have to go: " ^ detail
  | Standalone_source_active path ->
    Printf.sprintf
      "voice is read from %s because runtime.toml has no [voice] section; a \
       section written there would replace every setting that file carries, so \
       nothing was written. Configure voice in that file, or move it into \
       runtime.toml first"
      path
  | Voice_not_on_endpoint detail ->
    "a voice this edit names is not one its endpoint has, so nothing was written: "
    ^ detail
;;

exception Revision_changed
exception Voice_invalid of string
exception Standalone_active of string
exception Voice_missing of string

let endpoints_path = function
  | Tts -> voice_table ^ ".tts.endpoints"
  | Stt -> voice_table ^ ".stt.endpoints"
;;

let section_table = function
  | Tts -> voice_table ^ ".tts"
  | Stt -> voice_table ^ ".stt"
;;

let string_field key = function
  | None -> key, None
  | Some value -> key, Some (Toml_line_editor.String value)
;;

(* Destructured rather than read field by field so that a field added to
   Voice_config.endpoint fails to compile here instead of being quietly left out
   of what the writer emits. [command] is named and not written: this writer
   takes no executable path, which only the file's own author sets. *)
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
      (* File-owned like command: upsert edits only the fields listed below,
         so existing inline or nested mapping tables survive setup edits. *)
      ; agent_voices = _
      ; model
      ; command = _
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
  ; string_field "model" model
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
      ~path:(voice_table ^ ".tts")
      ~key:"default_voice"
      ~value:(Some voice)
  | Set_send_on_stop send ->
    Toml_line_editor.edit_table_bool
      contents
      ~path:(voice_table ^ ".stt")
      ~key:"send_on_stop"
      ~value:send
  | Set_agent_voice (agent, voice) ->
    Toml_line_editor.edit_table_scalar
      contents
      ~path:(voice_table ^ ".tts.agent_voices")
      ~key:agent
      ~value:voice
;;

(* The names each enabled command speaker can be asked for. say speaks a name
   it does not have in another voice and exits 0, so only its own list can
   tell a wrong name from a right one. *)
let command_voices = function
  | Some { Voice_config.tts = Some tts; _ } ->
    List.concat_map
      (fun (endpoint : Voice_config.endpoint) ->
        if not endpoint.Voice_config.enabled
        then []
        else (
          match Voice_runtime_overlay.speaker_of_endpoint endpoint with
          | Voice_runtime_overlay.By_command ->
            [ endpoint, Voice_config.voices_at_endpoint tts endpoint ]
          | Voice_runtime_overlay.Over_http
          | Voice_runtime_overlay.By_mcp_tool
          | Voice_runtime_overlay.Does_not_speak -> []))
      tts.Voice_config.endpoints
  | Some { Voice_config.tts = None; _ } | None -> []
;;

(* What the edit asks of a command speaker that it was not asked before. A name
   it already answered to is not checked again, so an edit elsewhere in the
   section is not refused over a name this edit did not write. The same id
   under another kind is another speaker with its own list. *)
let newly_asked ~before ~after =
  List.filter_map
    (fun ((endpoint : Voice_config.endpoint), voices) ->
      let asked_before =
        match
          List.find_opt
            (fun ((earlier : Voice_config.endpoint), _) ->
              String.equal earlier.Voice_config.id endpoint.Voice_config.id
              && earlier.Voice_config.kind = endpoint.Voice_config.kind)
            before
        with
        | Some (_, voices) -> voices
        | None -> []
      in
      match List.filter (fun voice -> not (List.mem voice asked_before)) voices with
      | [] -> None
      | _ :: _ as voices -> Some (endpoint, voices))
    after
;;

(* The edited text has to read back as a voice configuration before it is
   written. Nothing reads [voice] at boot: a section that does not load stays
   quiet until the first speak or transcribe, which is how it once went
   unnoticed for six days. A writer that committed text it had not read back
   would reproduce that. *)
let edited contents changes =
  let updated = List.fold_left apply_change contents changes in
  match Voice_config.parse_runtime_toml_text updated with
  | Error message -> raise (Voice_invalid message)
  | Ok after -> updated, after
;;

(* A text that did not load before the edit asked its speakers nothing, so
   every name the edited text asks of them is checked. *)
let require_command_voices ~check_command_voices contents after =
  let before =
    match Voice_config.parse_runtime_toml_text contents with
    | Ok config -> command_voices config
    | Error _ -> []
  in
  List.iter
    (fun (endpoint, voices) ->
      match check_command_voices endpoint ~voices with
      | Ok () -> ()
      | Error reason -> raise (Voice_missing reason))
    (newly_asked ~before ~after:(command_voices after))
;;

let revision_of (observation : Runtime.config_observation) =
  Runtime.config_source_revision_to_string observation.source_revision
;;

(* runtime.toml has no [voice] section and the standalone file exists: the
   loader reads that file, so it is the configuration in effect. *)
let standalone_in_effect ~standalone_path config =
  match config with
  | Some _ -> false
  | None -> Sys.file_exists standalone_path
;;

let observe ~runtime_config_path ~standalone_path =
  match Runtime.load_config_observation ~runtime_config_path () with
  | Error detail -> Error (Configuration_unavailable detail)
  | Ok observation ->
    (match Voice_config.parse_runtime_toml_text observation.source_text with
     | Error message -> Error (Voice_section_invalid message)
     | Ok (Some config) -> Ok (revision_of observation, Some (Runtime_toml, config))
     | Ok None when Sys.file_exists standalone_path ->
       (match Voice_config.load_standalone_file standalone_path with
        | Ok config ->
          Ok (revision_of observation, Some (Standalone_json standalone_path, config))
        | Error message ->
          Error (Voice_section_invalid (Printf.sprintf "%s: %s" standalone_path message)))
     | Ok None -> Ok (revision_of observation, None))
;;

(* Writing a first [voice] section while the standalone file is in effect would
   switch the loader over to that section and drop everything the file set.
   Checked against the text being edited, so apply decides it under the lock. *)
let refuse_over_standalone ~standalone_path contents =
  match Voice_config.parse_runtime_toml_text contents with
  | Ok config when standalone_in_effect ~standalone_path config ->
    raise (Standalone_active standalone_path)
  | Ok _ | Error _ -> ()
;;

let preview
    ~check_command_voices ~runtime_config_path ~standalone_path ~expected_revision changes
  =
  match Runtime.load_config_observation ~runtime_config_path () with
  | Error detail -> Error (Configuration_unavailable detail)
  | Ok observation ->
    if not (String.equal (revision_of observation) expected_revision)
    then Error Configuration_changed
    else (
      match
        refuse_over_standalone ~standalone_path observation.source_text;
        let updated, after = edited observation.source_text changes in
        require_command_voices ~check_command_voices observation.source_text after;
        updated
      with
      | updated -> Ok updated
      | exception Standalone_active path -> Error (Standalone_source_active path)
      | exception Voice_invalid message -> Error (Voice_section_invalid message)
      | exception Voice_missing reason -> Error (Voice_not_on_endpoint reason)
      | exception Entry_refused error ->
        Error (Endpoint_path_unusable (Toml_line_editor.entry_error_message error)))
;;

let commit ~runtime_config_path ~standalone_path ~expected_revision changes =
  (* The revision is checked again here, inside edit_config_text's lock, because
     preview read it outside one. *)
  let edit contents =
    let observation = Runtime.config_observation ~path:runtime_config_path contents in
    if not (String.equal (revision_of observation) expected_revision)
    then raise Revision_changed;
    refuse_over_standalone ~standalone_path contents;
    fst (edited contents changes)
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
  | exception Standalone_active path -> Error (Standalone_source_active path)
  | exception Voice_invalid message -> Error (Voice_section_invalid message)
  | exception Entry_refused error ->
    Error (Endpoint_path_unusable (Toml_line_editor.entry_error_message error))
;;

let apply
    ~check_command_voices ~runtime_config_path ~standalone_path ~expected_revision changes
  =
  (* The voice names are asked for here, outside the lock: listing say's voices
     takes about 0.6 seconds, and the same lock guards the server's keeper
     assignments and the TUI's own keys. The revision is a digest of the text,
     so the locked edit below, which commits only at [expected_revision],
     commits the text whose names were checked. *)
  match
    preview
      ~check_command_voices
      ~runtime_config_path
      ~standalone_path
      ~expected_revision
      changes
  with
  | Error error -> Error error
  | Ok _ -> commit ~runtime_config_path ~standalone_path ~expected_revision changes
;;

type voice_placement =
  | On_the_section
  | On_the_endpoint

(* The section default is readable by everyone that falls back to it only while
   they all speak the same vocabulary, and the kind is what that vocabulary
   belongs to: say takes a label, ElevenLabs a 20-character id, an OpenAI
   voice a name. So the question is identity, not a list of kinds to keep in
   step -- a kind added to {!Voice_config.endpoint_kind} needs no decision
   here, because a kind that is not the one being written already answers it.

   [alongside] is the section as it is now and [adding] the endpoint about to
   land in it. An endpoint of the same kind as every other one can take the
   section default; anything else has to carry its own, and accepts that
   per-keeper mappings do not reach it. A [None] alongside is an endpoint whose
   kind this binary cannot name, which is not the same kind as anything. *)
let voice_placement ~alongside ~adding =
  if List.for_all (fun kind -> kind = Some adding) alongside
  then On_the_section
  else On_the_endpoint
