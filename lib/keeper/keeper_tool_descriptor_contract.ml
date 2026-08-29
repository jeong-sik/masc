module Descriptor = Keeper_tool_descriptor

type schema_location =
  | Input_schema
  | Composable_output_schema

type canonical_json_error = Keeper_chat_operation.canonical_json_error =
  | Duplicate_object_key of string
  | Non_finite_float

type t =
  { descriptor_id : string
  ; capability_id : string
  ; accepted_tool_name : string
  ; model_projection : Descriptor.keeper_model_projection
  ; input_schema : Yojson.Safe.t
  ; composable_output : Descriptor.composable_output
  ; execution : Descriptor.execution
  }

type create_error =
  | Accepted_tool_name_not_projected of
      { accepted : string
      ; projected : string list
      }
  | Non_canonical_schema of
      { location : schema_location
      ; error : canonical_json_error
      }

type decode_error =
  | Non_canonical_json of canonical_json_error
  | Expected_object
  | Unknown_field of string
  | Missing_field of string
  | Expected_string of string
  | Expected_nullable_string of string
  | Empty_string of string
  | Invalid_model_projection of string
  | Model_projection_payload_mismatch
  | Invalid_composable_output of string
  | Composable_output_payload_mismatch
  | Invalid_execution of string

let ( let* ) = Result.bind
let normalize = Keeper_chat_operation.canonical_json

let normalize_schema location schema =
  normalize schema
  |> Result.map_error (fun error -> Non_canonical_schema { location; error })
;;

let create ~accepted_tool_name descriptor =
  let projected = Descriptor.keeper_model_names descriptor in
  if not (List.exists (String.equal accepted_tool_name) projected)
  then Error (Accepted_tool_name_not_projected { accepted = accepted_tool_name; projected })
  else
    let* input_schema = normalize_schema Input_schema descriptor.Descriptor.input_schema in
    let* composable_output =
      match descriptor.composable_output with
      | Descriptor.Opaque_output -> Ok Descriptor.Opaque_output
      | Descriptor.Json_output { schema } ->
        let* schema = normalize_schema Composable_output_schema schema in
        Ok (Descriptor.Json_output { schema })
    in
    Ok
      { descriptor_id = descriptor.id
      ; capability_id = descriptor.capability_id
      ; accepted_tool_name
      ; model_projection = descriptor.keeper_model_projection
      ; input_schema
      ; composable_output
      ; execution = descriptor.execution
      }
;;

let model_projection_fields = function
  | Descriptor.Preferred_public_name -> "preferred_public_name", `Null
  | Descriptor.Internal_name -> "internal_name", `Null
  | Descriptor.Operator_only -> "operator_only", `Null
  | Descriptor.Transport_alias { projected_by } ->
    "transport_alias", `String projected_by
;;

let composable_output_fields = function
  | Descriptor.Opaque_output -> "opaque", `Null
  | Descriptor.Json_output { schema } -> "json", schema
;;

let execution_name = function
  | Descriptor.Ordinary Descriptor.Serial -> "serial"
  | Descriptor.Ordinary Descriptor.Concurrent -> "concurrent"
  | Descriptor.Direct_terminal -> "direct_terminal"
  | Descriptor.Terminal -> "terminal"
;;

let to_yojson contract =
  let model_projection, projected_by =
    model_projection_fields contract.model_projection
  in
  let composable_output, output_schema =
    composable_output_fields contract.composable_output
  in
  `Assoc
    [ "descriptor_id", `String contract.descriptor_id
    ; "capability_id", `String contract.capability_id
    ; "accepted_tool_name", `String contract.accepted_tool_name
    ; "model_projection", `String model_projection
    ; "projected_by", projected_by
    ; "input_schema", contract.input_schema
    ; "composable_output", `String composable_output
    ; "output_schema", output_schema
    ; "execution", `String (execution_name contract.execution)
    ]
;;

let allowed_fields =
  [ "descriptor_id"
  ; "capability_id"
  ; "accepted_tool_name"
  ; "model_projection"
  ; "projected_by"
  ; "input_schema"
  ; "composable_output"
  ; "output_schema"
  ; "execution"
  ]
;;

let required field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field field)
;;

let string field fields =
  let* value = required field fields in
  match value with
  | `String "" -> Error (Empty_string field)
  | `String value -> Ok value
  | _ -> Error (Expected_string field)
;;

let nullable_string field fields =
  let* value = required field fields in
  match value with
  | `Null -> Ok None
  | `String "" -> Error (Empty_string field)
  | `String value -> Ok (Some value)
  | _ -> Error (Expected_nullable_string field)
;;

let model_projection_of_fields name projected_by =
  match name, projected_by with
  | "preferred_public_name", None -> Ok Descriptor.Preferred_public_name
  | "internal_name", None -> Ok Descriptor.Internal_name
  | "operator_only", None -> Ok Descriptor.Operator_only
  | "transport_alias", Some projected_by ->
    Ok (Descriptor.Transport_alias { projected_by })
  | ( "preferred_public_name" | "internal_name" | "operator_only" | "transport_alias" )
    , _ -> Error Model_projection_payload_mismatch
  | value, _ -> Error (Invalid_model_projection value)
;;

let composable_output_of_fields name output_schema =
  match name, output_schema with
  | "opaque", `Null -> Ok Descriptor.Opaque_output
  | "json", schema -> Ok (Descriptor.Json_output { schema })
  | "opaque", _ -> Error Composable_output_payload_mismatch
  | value, _ -> Error (Invalid_composable_output value)
;;

let execution_of_string = function
  | "serial" -> Ok (Descriptor.Ordinary Descriptor.Serial)
  | "concurrent" -> Ok (Descriptor.Ordinary Descriptor.Concurrent)
  | "direct_terminal" -> Ok Descriptor.Direct_terminal
  | "terminal" -> Ok Descriptor.Terminal
  | value -> Error (Invalid_execution value)
;;

let of_yojson json =
  let* json = normalize json |> Result.map_error (fun error -> Non_canonical_json error) in
  match json with
  | `Assoc fields ->
    let* () =
      match List.find_opt (fun (field, _) -> not (List.mem field allowed_fields)) fields with
      | Some (field, _) -> Error (Unknown_field field)
      | None -> Ok ()
    in
    let* descriptor_id = string "descriptor_id" fields in
    let* capability_id = string "capability_id" fields in
    let* accepted_tool_name = string "accepted_tool_name" fields in
    let* model_projection_name = string "model_projection" fields in
    let* projected_by = nullable_string "projected_by" fields in
    let* model_projection =
      model_projection_of_fields model_projection_name projected_by
    in
    let* input_schema = required "input_schema" fields in
    let* composable_output_name = string "composable_output" fields in
    let* output_schema = required "output_schema" fields in
    let* composable_output =
      composable_output_of_fields composable_output_name output_schema
    in
    let* execution_name = string "execution" fields in
    let* execution = execution_of_string execution_name in
    Ok
      { descriptor_id
      ; capability_id
      ; accepted_tool_name
      ; model_projection
      ; input_schema
      ; composable_output
      ; execution
      }
  | _ -> Error Expected_object
;;

let descriptor_id contract = contract.descriptor_id
let accepted_tool_name contract = contract.accepted_tool_name
