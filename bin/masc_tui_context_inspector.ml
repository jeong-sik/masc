module Prompt_capture = Masc.Keeper_prompt_capture

type tool_surface_entry = Turn_record.tool_surface_entry =
  { name : string
  ; schema_bytes : int
  }

type tool_surface =
  | Surface_not_recorded
  | Surface_unresolved of { detail : string }
  | Surface_resolved of tool_surface_entry list

type reading =
  { turn : (Turn_record.t, string) result
  ; prompt : (Prompt_capture.capture, string) result
  ; tool_surface : tool_surface
  }

type tab =
  | Composition
  | Prompt_blocks
  | Input_map

type input_map_row =
  { component : Turn_record.input_component_id
  ; bytes : int
  ; included_by : string
  ; retention : string
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

let decode_prompt_capture ~expected_keeper = function
  | `Assoc fields as json ->
      (match List.assoc_opt "keeper" fields with
       | Some (`String keeper) when String.equal keeper expected_keeper ->
           Prompt_capture.capture_of_json json
       | Some (`String keeper) ->
           Error
             (Printf.sprintf "last-prompt belongs to %S, expected %S" keeper
                expected_keeper)
       | Some _ -> Error "last-prompt keeper is not a string"
       | None -> Error "last-prompt response is missing keeper")
  | _ -> Error "last-prompt response is not an object"

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

let unique_find predicate values =
  match List.filter predicate values with
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None

let prompt_exact_text
    (record : Turn_record.t)
    (capture : Prompt_capture.capture option)
    block_id
    component_bytes =
  match capture with
  | Some capture
    when String.equal capture.trace_id record.trace_id
         && capture.absolute_turn = record.absolute_turn ->
      (match
         ( unique_find
             (fun (block : Turn_record.prompt_block) ->
                block.block = block_id)
             record.blocks
         , unique_find
             (fun (block : Prompt_capture.block) -> block.id = block_id)
             capture.blocks )
       with
       | Some observed, Some captured ->
           let digest =
             Digestif.SHA256.(digest_string captured.text |> to_hex)
           in
           if observed.bytes = component_bytes
              && String.length captured.text = observed.bytes
              && String.equal digest observed.digest
           then Some captured.text
           else None
       | None, _ | _, None -> None)
  | Some _ | None -> None

let format_bytes bytes =
  if bytes >= 1024 * 1024 then Printf.sprintf "%.1f MB" (float bytes /. 1048576.)
  else if bytes >= 1024 then Printf.sprintf "%.1f KB" (float bytes /. 1024.)
  else Printf.sprintf "%d B" bytes

let tool_surface_sha256 (record : Turn_record.t) =
  match record.tool_surface_ref with
  | None -> None
  | Some marker ->
      (match Tool_output.decode_from_agent_core marker with
       | Tool_output.Decoded reference ->
           Some (Ok reference.Tool_output.sha256)
       | Tool_output.Not_marker ->
           Some (Error "tool surface reference is not a blob marker")
       | Tool_output.Invalid_marker { detail } ->
           Some (Error ("tool surface reference is malformed: " ^ detail)))

(* The payload shape is owned by Turn_record, beside the field that points at
   it, so the writing keeper and this reader cannot drift apart. *)
let decode_tool_surface_payload content =
  match Yojson.Safe.from_string content with
  | json -> Turn_record.tool_surface_of_json json
  | exception Yojson.Json_error detail ->
      Error ("tool surface payload was not JSON: " ^ detail)

let decode_tool_surface = function
  | `Assoc fields ->
      (match List.assoc_opt "content" fields with
       | Some (`String content) -> decode_tool_surface_payload content
       | Some _ -> Error "artifact content is not a string"
       | None ->
           (* The artifact endpoint answers its own failures in this envelope.
              Its words name the sha256 it refused, which a generic message
              here would throw away. *)
           (match List.assoc_opt "error" fields with
            | Some (`String detail) -> Error detail
            | Some _ | None -> Error "artifact response carries no content"))
  | _ -> Error "artifact response is not an object"

(* Largest first: the operator reading this row is deciding what to hold back,
   and config order answers a question nobody asked. *)
let tool_surface_listing entries =
  let by_size =
    List.stable_sort
      (fun left right -> compare right.schema_bytes left.schema_bytes)
      entries
  in
  String.concat "\n"
    (Printf.sprintf "%d tools went out on this request, largest schema first."
       (List.length entries)
     :: "Each size is that schema serialized alone, so they do not sum to the \
         total above."
     :: ""
     :: List.map
          (fun entry ->
             Printf.sprintf "%s  %s" (format_bytes entry.schema_bytes) entry.name)
          by_size)

let tool_surface_exact_text = function
  | Surface_not_recorded | Surface_unresolved _ -> None
  | Surface_resolved [] -> Some "This request carried no tool schemas."
  | Surface_resolved entries -> Some (tool_surface_listing entries)

let input_map_metadata = function
  | Turn_record.Prompt_block _ -> "turn prompt assembly", "bytes only"
  | Turn_record.Tool_schemas -> "effective tool surface", "schema bytes only"
  | Turn_record.Message_thinking ->
      "provider message list", "hidden reasoning; bytes only"
  | Turn_record.Message_redacted_thinking ->
      "provider message list", "redacted reasoning; bytes only"
  | Turn_record.Message_user
  | Turn_record.Message_system
  | Turn_record.Message_assistant_text
  | Turn_record.Message_tool_use
  | Turn_record.Message_tool_result ->
      "provider message list", "content not retained"
  | Turn_record.Message_image
  | Turn_record.Message_document
  | Turn_record.Message_audio ->
      "provider message list", "media bytes only"

let input_map_rows (record : Turn_record.t) capture ~tool_surface =
  match record.input_components with
  | None -> []
  | Some components ->
      List.map
        (fun (item : Turn_record.input_component) ->
           let included_by, default_retention =
             input_map_metadata item.component
           in
           (* A reference that would not read is reported on the row that
              wanted it. The column is the only place the operator learns the
              listing exists at all, so the reason travels with it rather than
              being swallowed into "bytes only". *)
           let default_retention =
             match item.component, tool_surface with
             | Turn_record.Tool_schemas, Surface_unresolved { detail } ->
                 "listing unreadable: " ^ detail
             | _ -> default_retention
           in
           let exact_text =
             match item.component with
             | Turn_record.Prompt_block block_id ->
                 prompt_exact_text record capture block_id item.bytes
             | Turn_record.Tool_schemas -> tool_surface_exact_text tool_surface
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
           { component = item.component
           ; bytes = item.bytes
           ; included_by
           ; retention =
               (match exact_text with
                | Some _ -> "verified exact text"
                | None -> default_retention)
           ; exact_text
           })
        components

let format_tokens tokens =
  if tokens >= 1_000_000 then Printf.sprintf "%.2fM" (float tokens /. 1_000_000.)
  else if tokens >= 1_000 then Printf.sprintf "%.1fk" (float tokens /. 1_000.)
  else string_of_int tokens
