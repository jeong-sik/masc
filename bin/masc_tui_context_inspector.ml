module Prompt_capture = Masc.Keeper_prompt_capture

type reading =
  { turn : (Turn_record.t, string) result
  ; prompt : (Prompt_capture.capture, string) result
  }

type tab =
  | Composition
  | Prompt_blocks

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
           let rec newest_observed = function
             | [] -> Error "no turn has an exact provider-input composition"
             | (record : Turn_record.t) :: rest ->
                 (match record.input_components with
                  | Some _ -> Ok record
                  | None -> newest_observed rest)
           in
           newest_observed (List.rev records)
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

let attributed_bytes (record : Turn_record.t) =
  Option.map
    (List.fold_left
       (fun total (component : Turn_record.input_component) ->
          total + component.bytes)
       0)
    record.input_components

let format_bytes bytes =
  if bytes >= 1024 * 1024 then Printf.sprintf "%.1f MB" (float bytes /. 1048576.)
  else if bytes >= 1024 then Printf.sprintf "%.1f KB" (float bytes /. 1024.)
  else Printf.sprintf "%d B" bytes

let format_tokens tokens =
  if tokens >= 1_000_000 then Printf.sprintf "%.2fM" (float tokens /. 1_000_000.)
  else if tokens >= 1_000 then Printf.sprintf "%.1fk" (float tokens /. 1_000.)
  else string_of_int tokens
