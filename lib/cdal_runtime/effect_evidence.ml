type effect_class =
  | Read_only
  | Local_mutation
  | External_effect
  | Shell_dynamic

type decision =
  | Allowed
  | Denied
  | Approval_required
  | Approved
  | Rejected
  | Edited
  | Skipped
  | Overridden

type result_status =
  | Pending
  | Succeeded
  | Failed
  | Not_run

type t =
  { schema_version : int
  ; tool_use_id : string
  ; tool_name : string
  ; effect_class : effect_class
  ; decision : decision
  ; decision_source : string
  ; input_hash : string
  ; input_summary : string
  ; sandbox : string option
  ; workdir : string option
  ; source_path : string option
  ; source_line : int option
  ; started_at : float
  ; ended_at : float option
  ; result_status : result_status
  ; violation_kind : string option
  ; turn : int option
  ; execution_mode : string option
  }

let schema_version_current = 1

let effect_class_to_string = function
  | Read_only -> "read_only"
  | Local_mutation -> "local_mutation"
  | External_effect -> "external_effect"
  | Shell_dynamic -> "shell_dynamic"
;;

let effect_class_of_string = function
  | "read_only" -> Ok Read_only
  | "workspace" | "workspace_mutating" | "local_mutation" -> Ok Local_mutation
  | "external" | "external_effect" -> Ok External_effect
  | "shell_dynamic" -> Ok Shell_dynamic
  | s -> Error (Printf.sprintf "unknown effect_class: %s" s)
;;

let decision_to_string = function
  | Allowed -> "allowed"
  | Denied -> "denied"
  | Approval_required -> "approval_required"
  | Approved -> "approved"
  | Rejected -> "rejected"
  | Edited -> "edited"
  | Skipped -> "skipped"
  | Overridden -> "overridden"
;;

let decision_of_string = function
  | "allowed" -> Ok Allowed
  | "denied" -> Ok Denied
  | "approval_required" -> Ok Approval_required
  | "approved" -> Ok Approved
  | "rejected" -> Ok Rejected
  | "edited" -> Ok Edited
  | "skipped" -> Ok Skipped
  | "overridden" -> Ok Overridden
  | s -> Error (Printf.sprintf "unknown decision: %s" s)
;;

let result_status_to_string = function
  | Pending -> "pending"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Not_run -> "not_run"
;;

let result_status_of_string = function
  | "pending" -> Ok Pending
  | "succeeded" -> Ok Succeeded
  | "failed" -> Ok Failed
  | "not_run" -> Ok Not_run
  | s -> Error (Printf.sprintf "unknown result_status: %s" s)
;;

let hash_input input = Yojson.Safe.to_string input |> Digest.string |> Digest.to_hex

let clip s =
  let limit = 200 in
  if String.length s <= limit then s else String.sub s 0 limit
;;

let make
      ?(schema_version = schema_version_current)
      ?input_hash
      ?input_summary
      ?sandbox
      ?workdir
      ?source_path
      ?source_line
      ?ended_at
      ?(result_status = Pending)
      ?violation_kind
      ?turn
      ?execution_mode
      ~tool_use_id
      ~tool_name
      ~effect_class
      ~decision
      ~decision_source
      ~input
      ~started_at
      ()
  =
  { schema_version
  ; tool_use_id
  ; tool_name
  ; effect_class
  ; decision
  ; decision_source
  ; input_hash = Option.value input_hash ~default:(hash_input input)
  ; input_summary =
      Option.value input_summary ~default:(clip (Yojson.Safe.to_string input))
  ; sandbox
  ; workdir
  ; source_path
  ; source_line
  ; started_at
  ; ended_at
  ; result_status
  ; violation_kind
  ; turn
  ; execution_mode
  }
;;

let option_to_json f = function
  | None -> `Null
  | Some v -> f v
;;

let to_json t =
  `Assoc
    [ "schema_version", `Int t.schema_version
    ; "tool_use_id", `String t.tool_use_id
    ; "tool_name", `String t.tool_name
    ; "effect_class", `String (effect_class_to_string t.effect_class)
    ; "decision", `String (decision_to_string t.decision)
    ; "decision_source", `String t.decision_source
    ; "input_hash", `String t.input_hash
    ; "input_summary", `String t.input_summary
    ; "sandbox", option_to_json (fun v -> `String v) t.sandbox
    ; "workdir", option_to_json (fun v -> `String v) t.workdir
    ; "source_path", option_to_json (fun v -> `String v) t.source_path
    ; "source_line", option_to_json (fun v -> `Int v) t.source_line
    ; "started_at", `Float t.started_at
    ; "ended_at", option_to_json (fun v -> `Float v) t.ended_at
    ; "result_status", `String (result_status_to_string t.result_status)
    ; "violation_kind", option_to_json (fun v -> `String v) t.violation_kind
    ; "turn", option_to_json (fun v -> `Int v) t.turn
    ; "execution_mode", option_to_json (fun v -> `String v) t.execution_mode
    ]
;;

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "missing field: %s" name)
;;

let int_field name fields =
  match assoc_field name fields with
  | Ok (`Int v) -> Ok v
  | Ok _ -> Error (Printf.sprintf "field %s must be an int" name)
  | Error _ as err -> err
;;

let string_field name fields =
  match assoc_field name fields with
  | Ok (`String v) -> Ok v
  | Ok _ -> Error (Printf.sprintf "field %s must be a string" name)
  | Error _ as err -> err
;;

let float_field name fields =
  match assoc_field name fields with
  | Ok (`Float v) -> Ok v
  | Ok (`Int v) -> Ok (float_of_int v)
  | Ok _ -> Error (Printf.sprintf "field %s must be a number" name)
  | Error _ as err -> err
;;

let option_string_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String v) -> Ok (Some v)
  | Some _ -> Error (Printf.sprintf "field %s must be a string or null" name)
;;

let option_float_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Float v) -> Ok (Some v)
  | Some (`Int v) -> Ok (Some (float_of_int v))
  | Some _ -> Error (Printf.sprintf "field %s must be a number or null" name)
;;

let option_int_field name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int v) -> Ok (Some v)
  | Some _ -> Error (Printf.sprintf "field %s must be an int or null" name)
;;

open Result_syntax

let of_json = function
  | `Assoc fields ->
    let* schema_version = int_field "schema_version" fields in
    let* tool_use_id = string_field "tool_use_id" fields in
    let* tool_name = string_field "tool_name" fields in
    let* effect_class =
      let* raw = string_field "effect_class" fields in
      effect_class_of_string raw
    in
    let* decision =
      let* raw = string_field "decision" fields in
      decision_of_string raw
    in
    let* decision_source = string_field "decision_source" fields in
    let* input_hash = string_field "input_hash" fields in
    let* input_summary = string_field "input_summary" fields in
    let* sandbox = option_string_field "sandbox" fields in
    let* workdir = option_string_field "workdir" fields in
    let* source_path = option_string_field "source_path" fields in
    let* source_line = option_int_field "source_line" fields in
    let* started_at = float_field "started_at" fields in
    let* ended_at = option_float_field "ended_at" fields in
    let* result_status =
      let* raw = string_field "result_status" fields in
      result_status_of_string raw
    in
    let* violation_kind = option_string_field "violation_kind" fields in
    let* turn = option_int_field "turn" fields in
    let* execution_mode = option_string_field "execution_mode" fields in
    Ok
      { schema_version
      ; tool_use_id
      ; tool_name
      ; effect_class
      ; decision
      ; decision_source
      ; input_hash
      ; input_summary
      ; sandbox
      ; workdir
      ; source_path
      ; source_line
      ; started_at
      ; ended_at
      ; result_status
      ; violation_kind
      ; turn
      ; execution_mode
      }
  | _ -> Error "effect evidence must be a JSON object"
;;
