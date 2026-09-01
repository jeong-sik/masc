type exact_input_kind =
  | System_prompt
  | Message of { role : string }
  | Tool_schema of { name : string }

type exact_input_item =
  { kind : exact_input_kind
  ; bytes : int
  ; sha256 : string
  ; text : string
  }

type provider_input =
  { trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_profile : string
  ; captured_at : float
  ; wire : Llm_provider.Request_wire_observer.observation
  ; items : exact_input_item list
  }

(* The interface constrains these; the implementation must still declare
   them — without this the record literals below have no fields in scope. *)
type attributed_turn =
  { record : Turn_record.t
  ; components : Turn_record.input_component list
  ; turns_behind_latest : int
  }

type selection =
  { latest : Turn_record.t
  ; attributed : attributed_turn option
  }

type reading =
  { turn : (selection, string) result
  ; provider_input : (provider_input, string) result
  }

type tab =
  | Composition
  | Exact_input
  | Input_map

type input_source =
  | Turn_prompt_assembly
  | Effective_tool_surface
  | Provider_message_list

type input_evidence =
  | Verified_exact_text
  | Serialized_turn_snapshot
  | Producer_digest_only
  | Byte_count_only

type input_map_row =
  { component : Turn_record.input_component_id
  ; bytes : int
  ; source : input_source
  ; evidence : input_evidence
  ; digest : string option
  ; exact_text : string option
  }

let ( let* ) = Result.bind

let decode_entry = function
  | `Assoc fields ->
      (match List.assoc_opt "record" fields with
       | Some json -> Turn_record.of_json json
       | None -> Error "turn-records entry is missing record")
  | _ -> Error "turn-records entry is not an object"

let decode_turn_records = function
  | `Assoc fields ->
      (match List.assoc_opt "entries" fields with
       | Some (`List rows) ->
           let rec decode reversed = function
             | [] -> Ok (List.rev reversed)
             | row :: rest ->
                 let* record = decode_entry row in
                 decode (record :: reversed) rest
           in
           let* records = decode [] rows in
           (match List.rev records with
            | [] -> Error "turn-records returned no rows"
            | (latest : Turn_record.t) :: _ as newest_first ->
                let rec newest_attributed = function
                  | [] -> None
                  | (record : Turn_record.t) :: rest ->
                      (match record.input_components with
                       | Some components ->
                           Some
                             { record
                             ; components
                             ; turns_behind_latest =
                                 latest.absolute_turn - record.absolute_turn
                             }
                       | None -> newest_attributed rest)
                in
                Ok { latest; attributed = newest_attributed newest_first })
       | Some _ -> Error "turn-records entries is not a list"
       | None -> Error "turn-records response is missing entries")
  | _ -> Error "turn-records response is not an object"

let exact_fields expected fields =
  List.length expected = List.length fields
  && List.for_all
       (fun name ->
          match List.filter (fun (key, _) -> String.equal key name) fields with
          | [ _ ] -> true
          | [] | _ :: _ :: _ -> false)
       expected

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("provider-input response is missing " ^ name)

let nonempty_string name = function
  | `String value when not (String.equal value "") -> Ok value
  | _ -> Error (name ^ " is not a non-empty string")

let nonnegative_int name = function
  | `Int value when value >= 0 -> Ok value
  | _ -> Error (name ^ " is not a non-negative integer")

let sha256 name = function
  | `String value when String_util.is_lowercase_sha256_hex value -> Ok value
  | _ -> Error (name ^ " is not a lowercase SHA-256")

let decode_system_prompt = function
  | `Null -> Ok []
  | `Assoc fields when exact_fields [ "bytes"; "sha256"; "text" ] fields ->
    let* bytes_json = field "bytes" fields in
    let* bytes = nonnegative_int "system_prompt.bytes" bytes_json in
    let* sha_json = field "sha256" fields in
    let* sha256 = sha256 "system_prompt.sha256" sha_json in
    let* text_json = field "text" fields in
    let* text = nonempty_string "system_prompt.text" text_json in
    if String.length text <> bytes
    then Error "system_prompt text length does not match bytes"
    else Ok [ { kind = System_prompt; bytes; sha256; text } ]
  | `Assoc _ -> Error "system_prompt fields are not exact"
  | _ -> Error "system_prompt is not an object or null"

let decode_indexed_items ~kind_of_label ~label_key = function
  | `List values ->
    let rec loop index reversed = function
      | [] -> Ok (List.rev reversed)
      | `Assoc fields :: rest
        when exact_fields
               [ "index"; label_key; "bytes"; "sha256"; "content" ]
               fields ->
        let* actual_index_json = field "index" fields in
        let* actual_index =
          nonnegative_int (label_key ^ ".index") actual_index_json
        in
        if actual_index <> index
        then
          Error
            (Printf.sprintf
               "%s index %d is not contiguous"
               label_key
               actual_index)
        else
          let* label_json = field label_key fields in
          let* label = nonempty_string label_key label_json in
          let* bytes_json = field "bytes" fields in
          let* bytes = nonnegative_int (label_key ^ ".bytes") bytes_json in
          let* sha_json = field "sha256" fields in
          let* sha256 = sha256 (label_key ^ ".sha256") sha_json in
          let* content = field "content" fields in
          let text = Yojson.Safe.pretty_to_string content in
          loop
            (index + 1)
            ({ kind = kind_of_label label; bytes; sha256; text } :: reversed)
            rest
      | `Assoc _ :: _ -> Error (label_key ^ " fields are not exact")
      | _ -> Error (label_key ^ " item is not an object")
    in
    loop 0 [] values
  | _ -> Error (label_key ^ " list is not an array")

let decode_provider_input ~expected_keeper ~expected_turn_ref = function
  | `Assoc fields
    when exact_fields
           [ "dashboard_surface"
           ; "schema"
           ; "keeper"
           ; "trace_id"
           ; "absolute_turn"
           ; "turn_ref"
           ; "runtime_profile"
           ; "captured_at"
           ; "wire"
           ; "system_prompt"
           ; "messages"
           ; "tool_schemas"
           ]
           fields ->
    let* schema_json = field "schema" fields in
    let* schema = nonempty_string "schema" schema_json in
    let* () =
      if String.equal schema "masc.resolved-provider-input.v1"
      then Ok ()
      else Error ("unknown provider-input schema " ^ schema)
    in
    let* keeper_json = field "keeper" fields in
    let* keeper = nonempty_string "keeper" keeper_json in
    let* () =
      if String.equal keeper expected_keeper
      then Ok ()
      else
        Error
          (Printf.sprintf
             "provider-input belongs to %S, expected %S"
             keeper
             expected_keeper)
    in
    let* trace_json = field "trace_id" fields in
    let* trace_id = nonempty_string "trace_id" trace_json in
    let* turn_json = field "absolute_turn" fields in
    let* absolute_turn = nonnegative_int "absolute_turn" turn_json in
    let turn_ref = Ids.Turn_ref.make ~trace_id ~absolute_turn in
    let* turn_ref_json = field "turn_ref" fields in
    let* observed_turn_ref =
      match Ids.Turn_ref.of_yojson turn_ref_json with
      | Ok value -> Ok value
      | Error detail -> Error detail
    in
    let* () =
      if Ids.Turn_ref.equal turn_ref observed_turn_ref
         && Ids.Turn_ref.equal turn_ref expected_turn_ref
      then Ok ()
      else Error "provider-input turn_ref does not match the selected turn"
    in
    let* runtime_json = field "runtime_profile" fields in
    let* runtime_profile = nonempty_string "runtime_profile" runtime_json in
    let* captured_json = field "captured_at" fields in
    let* captured_at =
      match captured_json with
      | `Float value when Float.is_finite value && value >= 0. -> Ok value
      | `Int value when value >= 0 -> Ok (Float.of_int value)
      | _ -> Error "captured_at is not a non-negative finite number"
    in
    let* wire_json = field "wire" fields in
    let* wire =
      match Llm_provider.Request_wire_observer.observation_of_yojson wire_json with
      | Ok value -> Ok value
      | Error detail -> Error detail
    in
    let* system_json = field "system_prompt" fields in
    let* system_items = decode_system_prompt system_json in
    let* messages_json = field "messages" fields in
    let* message_items =
      decode_indexed_items
        ~kind_of_label:(fun role -> Message { role })
        ~label_key:"role"
        messages_json
    in
    let* tools_json = field "tool_schemas" fields in
    let* tool_items =
      decode_indexed_items
        ~kind_of_label:(fun name -> Tool_schema { name })
        ~label_key:"name"
        tools_json
    in
    Ok
      { trace_id
      ; absolute_turn
      ; turn_ref
      ; runtime_profile
      ; captured_at
      ; wire
      ; items = system_items @ message_items @ tool_items
      }
  | `Assoc _ -> Error "provider-input response fields are not exact"
  | _ -> Error "provider-input response is not an object"

let prompt_block_label = function
  | Prompt_block_id.Keeper_instructions -> "Keeper instructions"
  | Prompt_block_id.Dynamic_context -> "Dynamic context"
  | Prompt_block_id.Temporal_summary -> "Temporal summary"
  | Prompt_block_id.Memory_os_recall -> "Memory recall"
  | Prompt_block_id.Operator_note -> "Operator note"

let input_component_label = function
  | Turn_record.Prompt_block block -> prompt_block_label block
  | Turn_record.Tool_schemas -> "Tool schemas"
  | Turn_record.Message_user -> "User messages"
  | Turn_record.Message_system -> "System messages"
  | Turn_record.Message_assistant_text -> "Assistant text"
  | Turn_record.Message_thinking -> "Thinking"
  | Turn_record.Message_redacted_thinking -> "Redacted thinking"
  | Turn_record.Message_tool_use -> "Tool calls"
  | Turn_record.Message_tool_result -> "Tool results"
  | Turn_record.Message_image -> "Images"
  | Turn_record.Message_document -> "Documents"
  | Turn_record.Message_audio -> "Audio"

(* The kind an item is grouped under. Not [exact_input_label]: that names a
   tool schema after its tool, which would put every schema in a group of one
   and hide that the schemas together are the second-largest thing in the
   request. *)
let exact_input_category = function
  | System_prompt -> "System prompt"
  | Message { role } -> "Message · " ^ role
  | Tool_schema _ -> "Tool schemas"

let exact_input_label = function
  | System_prompt -> "System prompt"
  | Message { role } -> "Message · " ^ role
  | Tool_schema { name } -> "Tool schema · " ^ name

let exact_input_items input = input.items

let format_bytes bytes =
  if bytes >= 1024 * 1024 then Printf.sprintf "%.1f MB" (float bytes /. 1048576.)
  else if bytes >= 1024 then Printf.sprintf "%.1f KB" (float bytes /. 1024.)
  else Printf.sprintf "%d B" bytes

let input_source = function
  | Turn_record.Prompt_block _ -> Turn_prompt_assembly
  | Turn_record.Tool_schemas -> Effective_tool_surface
  | Turn_record.Message_thinking ->
      Provider_message_list
  | Turn_record.Message_redacted_thinking ->
      Provider_message_list
  | Turn_record.Message_user
  | Turn_record.Message_system
  | Turn_record.Message_assistant_text
  | Turn_record.Message_tool_use
  | Turn_record.Message_tool_result ->
      Provider_message_list
  | Turn_record.Message_image
  | Turn_record.Message_document
  | Turn_record.Message_audio ->
      Provider_message_list

let input_source_label = function
  | Turn_prompt_assembly -> "turn prompt assembly"
  | Effective_tool_surface -> "effective tool surface"
  | Provider_message_list -> "provider message list"

let input_evidence_label = function
  | Verified_exact_text -> "VERIFIED"
  | Serialized_turn_snapshot -> "SERIALIZED"
  | Producer_digest_only -> "DIGEST ONLY"
  | Byte_count_only -> "BYTES ONLY"

let input_evidence_badge_cells evidence =
  String.length (input_evidence_label evidence) + 4

let verified_system_prompt (record : Turn_record.t) provider_input component_bytes =
  match provider_input with
  | Some input when Ids.Turn_ref.equal input.turn_ref record.turn_ref ->
    (match List.find_opt (fun item -> item.kind = System_prompt) input.items with
     | Some item ->
       let digest = Digestif.SHA256.(digest_string item.text |> to_hex) in
       (match
          List.find_opt
            (fun (block : Turn_record.prompt_block) ->
               block.block = Prompt_block_id.Keeper_instructions)
            record.blocks
        with
        | Some block
          when block.bytes = component_bytes
               && item.bytes = component_bytes
               && String.equal block.digest digest ->
          Some item.text
        | Some _ | None -> None)
     | None -> None)
  | Some _ | None -> None

let input_map_rows (record : Turn_record.t) provider_input =
  match record.input_components with
  | None -> []
  | Some components ->
      List.map
        (fun (item : Turn_record.input_component) ->
           let source = input_source item.component in
           let exact_text =
             match item.component with
             | Turn_record.Prompt_block Prompt_block_id.Keeper_instructions ->
               verified_system_prompt record provider_input item.bytes
             | Turn_record.Prompt_block _
             | Turn_record.Tool_schemas
             | Turn_record.Message_user
             | Turn_record.Message_system
             | Turn_record.Message_assistant_text
             | Turn_record.Message_thinking
             | Turn_record.Message_redacted_thinking
             | Turn_record.Message_tool_use
             | Turn_record.Message_tool_result
             | Turn_record.Message_image
             | Turn_record.Message_document
             | Turn_record.Message_audio -> None
           in
           let digest =
             match item.component with
             | Turn_record.Prompt_block block_id ->
                 record.blocks
                 |> List.find_opt
                      (fun (block : Turn_record.prompt_block) ->
                         block.block = block_id && block.bytes = item.bytes)
                 |> Option.map (fun (block : Turn_record.prompt_block) ->
                        block.digest)
             | Turn_record.Tool_schemas
             | Turn_record.Message_user
             | Turn_record.Message_system
             | Turn_record.Message_assistant_text
             | Turn_record.Message_thinking
             | Turn_record.Message_redacted_thinking
             | Turn_record.Message_tool_use
             | Turn_record.Message_tool_result
             | Turn_record.Message_image
             | Turn_record.Message_document
             | Turn_record.Message_audio -> None
           in
           let evidence =
             match exact_text, provider_input, digest with
             | Some _, _, _ -> Verified_exact_text
             | None, Some input, _
               when Ids.Turn_ref.equal input.turn_ref record.turn_ref ->
                 Serialized_turn_snapshot
             | None, (Some _ | None), Some _ -> Producer_digest_only
             | None, (Some _ | None), None -> Byte_count_only
           in
           { component = item.component
           ; bytes = item.bytes
           ; source
           ; evidence
           ; digest
           ; exact_text
           })
        components

let format_tokens tokens =
  if tokens >= 1_000_000 then Printf.sprintf "%.2fM" (float tokens /. 1_000_000.)
  else if tokens >= 1_000 then Printf.sprintf "%.1fk" (float tokens /. 1_000.)
  else string_of_int tokens
