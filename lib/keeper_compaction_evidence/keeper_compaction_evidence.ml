type t =
  { selected_runtime_id : string option
  ; before_checkpoint_bytes : int
  ; after_checkpoint_bytes : int
  ; before_message_count : int
  ; after_message_count : int
  ; summarized_message_count : int
  ; dropped_message_count : int
  ; before_tool_use_count : int
  ; after_tool_use_count : int
  ; before_tool_result_count : int
  ; after_tool_result_count : int
  }

type field =
  | Before_checkpoint_bytes
  | After_checkpoint_bytes
  | Before_message_count
  | After_message_count
  | Summarized_message_count
  | Dropped_message_count
  | Before_tool_use_count
  | After_tool_use_count
  | Before_tool_result_count
  | After_tool_result_count

type field_error =
  | Missing
  | Duplicate
  | Expected_integer
  | Negative_integer

type measure =
  | Checkpoint_bytes
  | Messages
  | Tool_uses
  | Tool_results

type decode_error =
  | Expected_object
  | Unknown_field of string
  | Invalid_field of field * field_error
  | Empty_selected_runtime_id
  | Invalid_transition of measure * int * int
  | No_messages_compacted

let schema =
  [ Before_checkpoint_bytes, "before_checkpoint_bytes"
  ; After_checkpoint_bytes, "after_checkpoint_bytes"
  ; Before_message_count, "before_message_count"
  ; After_message_count, "after_message_count"
  ; Summarized_message_count, "summarized_message_count"
  ; Dropped_message_count, "dropped_message_count"
  ; Before_tool_use_count, "before_tool_use_count"
  ; After_tool_use_count, "after_tool_use_count"
  ; Before_tool_result_count, "before_tool_result_count"
  ; After_tool_result_count, "after_tool_result_count"
  ]
;;

let field_name field = List.assoc field schema
let known_field name = List.exists (fun (_, key) -> String.equal name key) schema

let ( let* ) = Result.bind

let decode_nonnegative_integer fields field =
  match
    List.filter
      (fun (name, _) -> String.equal name (field_name field))
      fields
  with
  | [] -> Error (Invalid_field (field, Missing))
  | [ _, `Int value ] when value >= 0 -> Ok value
  | [ _, `Int _ ] -> Error (Invalid_field (field, Negative_integer))
  | [ _ ] -> Error (Invalid_field (field, Expected_integer))
  | _ -> Error (Invalid_field (field, Duplicate))
;;

let of_json ~selected_runtime_id = function
  | `Assoc fields ->
    let* () =
      match
        List.find_opt
          (fun (name, _) -> not (known_field name))
          fields
      with
      | None -> Ok ()
      | Some (name, _) -> Error (Unknown_field name)
    in
    let* () =
      match selected_runtime_id with
      | Some runtime_id when String.trim runtime_id = "" ->
        Error Empty_selected_runtime_id
      | Some _ | None -> Ok ()
    in
    let integer = decode_nonnegative_integer fields in
    let* before_checkpoint_bytes = integer Before_checkpoint_bytes in
    let* after_checkpoint_bytes = integer After_checkpoint_bytes in
    let* before_message_count = integer Before_message_count in
    let* after_message_count = integer After_message_count in
    let* summarized_message_count = integer Summarized_message_count in
    let* dropped_message_count = integer Dropped_message_count in
    let* before_tool_use_count = integer Before_tool_use_count in
    let* after_tool_use_count = integer After_tool_use_count in
    let* before_tool_result_count = integer Before_tool_result_count in
    let* after_tool_result_count = integer After_tool_result_count in
    if after_checkpoint_bytes >= before_checkpoint_bytes
    then Error (Invalid_transition (Checkpoint_bytes, before_checkpoint_bytes, after_checkpoint_bytes))
    else if after_message_count > before_message_count
    then Error (Invalid_transition (Messages, before_message_count, after_message_count))
    else if after_tool_use_count > before_tool_use_count
    then Error (Invalid_transition (Tool_uses, before_tool_use_count, after_tool_use_count))
    else if after_tool_result_count > before_tool_result_count
    then
      Error
        (Invalid_transition
           (Tool_results, before_tool_result_count, after_tool_result_count))
    else if summarized_message_count = 0 && dropped_message_count = 0
    then Error No_messages_compacted
    else
      Ok
        { selected_runtime_id
        ; before_checkpoint_bytes
        ; after_checkpoint_bytes
        ; before_message_count
        ; after_message_count
        ; summarized_message_count
        ; dropped_message_count
        ; before_tool_use_count
        ; after_tool_use_count
        ; before_tool_result_count
        ; after_tool_result_count
        }
  | _ -> Error Expected_object
;;

let to_json evidence =
  `Assoc
    [ "before_checkpoint_bytes", `Int evidence.before_checkpoint_bytes
    ; "after_checkpoint_bytes", `Int evidence.after_checkpoint_bytes
    ; "before_message_count", `Int evidence.before_message_count
    ; "after_message_count", `Int evidence.after_message_count
    ; "summarized_message_count", `Int evidence.summarized_message_count
    ; "dropped_message_count", `Int evidence.dropped_message_count
    ; "before_tool_use_count", `Int evidence.before_tool_use_count
    ; "after_tool_use_count", `Int evidence.after_tool_use_count
    ; "before_tool_result_count", `Int evidence.before_tool_result_count
    ; "after_tool_result_count", `Int evidence.after_tool_result_count
    ]
;;
