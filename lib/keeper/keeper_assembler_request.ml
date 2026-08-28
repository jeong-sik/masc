module Surface = Keeper_capability_surface
module Descriptor = Keeper_tool_descriptor

type execution = Keeper_plan_proposal.execution =
  | Inline
  | Async

type error =
  | Request_not_object
  | Duplicate_field of string
  | Unknown_field of string
  | Missing_field of string
  | Invalid_field_type of
      { field : string
      ; expected : string
      ; found : string
      }
  | Blank_objective
  | Invalid_execution of string
  | Empty_tool_references
  | Reference_parse_failed of
      { index : int
      ; error : Surface.ordinary_tool_reference_parse_error
      }
  | Duplicate_tool_reference of Surface.ordinary_tool_reference
  | Reference_resolution_failed of
      { index : int
      ; error : Surface.ordinary_tool_resolution_error
      }
  | Referenced_tool_unavailable of
      { index : int
      ; reference : Surface.ordinary_tool_reference
      ; availability : Surface.capability_availability
      }
  | Async_tool_not_statically_read_only of
      { descriptor_id : string
      ; capability_id : string
      }
  | Prompt_variable_json_not_canonicalizable of
      { variable : string
      ; detail : string
      }

type t =
  { objective : string
  ; execution : execution
  ; ordinary_tool_references : Surface.ordinary_tool_reference list
  ; descriptors : Descriptor.t list
  ; capability_surface_sha256 : string
  }

let input_schema =
  (* These are syntax constraints shared with the decoder. They do not select
     capabilities: exact identity and availability are resolved only against
     the supplied frozen surface below. *)
  let nonblank_string =
    `Assoc
      [ "type", `String "string"
      ; "minLength", `Int 1
      ; "pattern", `String "^([^ \t\n\012\r]|[ \t\n\012\r])*[^ \t\n\012\r]([^ \t\n\012\r]|[ \t\n\012\r])*$"
      ]
  in
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ "objective", nonblank_string
          ; ( "execution"
            , `Assoc
                [ "type", `String "string"
                ; "enum", `List [ `String "inline"; `String "async" ]
                ] )
          ; ( "ordinary_tool_references"
            , `Assoc
                [ "type", `String "array"
                ; "minItems", `Int 1
                ; "uniqueItems", `Bool true
                ; "items", Surface.ordinary_tool_reference_schema
                ] )
          ] )
    ; ( "required"
      , `List
          [ `String "objective"
          ; `String "execution"
          ; `String "ordinary_tool_references"
          ] )
    ; "additionalProperties", `Bool false
    ]
;;

let ( let* ) = Result.bind

let first_duplicate fields =
  let rec loop seen = function
    | [] -> None
    | (field, _) :: rest ->
      if List.mem field seen then Some field else loop (field :: seen) rest
  in
  loop [] fields
;;

let required fields field =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field field)
;;

let parse_execution = function
  | `String "inline" -> Ok Inline
  | `String "async" -> Ok Async
  | `String value -> Error (Invalid_execution value)
  | value ->
    Error
      (Invalid_field_type
         { field = "execution"
         ; expected = "string"
         ; found = Json_util.kind_name value
         })
;;

let reference_equal left right =
  Yojson.Safe.equal
    (Surface.ordinary_tool_reference_to_yojson left)
    (Surface.ordinary_tool_reference_to_yojson right)
;;

let parse_references = function
  | `List [] -> Error Empty_tool_references
  | `List values ->
    let rec loop index seen references = function
      | [] -> Ok (List.rev references)
      | value :: rest ->
        let* reference =
          Surface.ordinary_tool_reference_of_yojson value
          |> Result.map_error (fun error -> Reference_parse_failed { index; error })
        in
        if List.exists (reference_equal reference) seen
        then Error (Duplicate_tool_reference reference)
        else loop (index + 1) (reference :: seen) (reference :: references) rest
    in
    loop 0 [] [] values
  | value ->
    Error
      (Invalid_field_type
         { field = "ordinary_tool_references"
         ; expected = "array"
         ; found = Json_util.kind_name value
         })
;;

let resolve_references capability_surface references =
  let rec loop index descriptors = function
    | [] -> Ok (List.rev descriptors)
    | reference :: rest ->
      (match Surface.resolve_ordinary_tool_reference capability_surface reference with
       | Error error -> Error (Reference_resolution_failed { index; error })
       | Ok (Surface.Tool_unavailable availability) ->
         Error (Referenced_tool_unavailable { index; reference; availability })
       | Ok (Surface.Active_tool descriptor) ->
         loop (index + 1) (descriptor :: descriptors) rest)
  in
  loop 0 [] references
;;

let validate_execution execution descriptors =
  match execution with
  | Inline -> Ok ()
  | Async ->
    (match
       List.find_opt
         (fun descriptor -> Descriptor.readonly_static_hint descriptor <> Some true)
         descriptors
     with
     | None -> Ok ()
     | Some descriptor ->
       Error
         (Async_tool_not_statically_read_only
            { descriptor_id = descriptor.id; capability_id = descriptor.capability_id }))
;;

let of_yojson ~capability_surface = function
  | `Assoc fields ->
    (match first_duplicate fields with
     | Some field -> Error (Duplicate_field field)
     | None ->
       (match
          List.find_opt
            (fun (field, _) ->
               not
                 (List.mem
                    field
                    [ "objective"; "execution"; "ordinary_tool_references" ]))
            fields
        with
        | Some (field, _) -> Error (Unknown_field field)
        | None ->
          let* objective_json = required fields "objective" in
          let* objective =
            match objective_json with
            | `String value when String.equal (String.trim value) "" ->
              Error Blank_objective
            | `String value -> Ok value
            | value ->
              Error
                (Invalid_field_type
                   { field = "objective"
                   ; expected = "string"
                   ; found = Json_util.kind_name value
                   })
          in
          let* execution_json = required fields "execution" in
          let* execution = parse_execution execution_json in
          let* references_json = required fields "ordinary_tool_references" in
          let* ordinary_tool_references = parse_references references_json in
          let* descriptors =
            resolve_references capability_surface ordinary_tool_references
          in
          let* () = validate_execution execution descriptors in
          Ok
            { objective
            ; execution
            ; ordinary_tool_references
            ; descriptors
            ; capability_surface_sha256 = Surface.digest capability_surface
            }))
  | _ -> Error Request_not_object
;;

let objective request = request.objective
let execution request = request.execution
let ordinary_tool_references request = request.ordinary_tool_references
let descriptors request = request.descriptors
let capability_surface_sha256 request = request.capability_surface_sha256

let canonical_json ~variable json =
  match Keeper_chat_operation.canonical_json_string json with
  | Ok bytes -> Ok bytes
  | Error detail ->
    Error (Prompt_variable_json_not_canonicalizable { variable; detail })
;;

let execution_to_string = function
  | Inline -> "inline"
  | Async -> "async"
;;

let descriptor_json descriptor =
  `Assoc
    (Descriptor.discovery_fields descriptor
     @ [ "input_schema", descriptor.Descriptor.input_schema ])
;;

let output_schema =
  let closed properties required =
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc properties
      ; "required", `List (List.map (fun name -> `String name) required)
      ; "additionalProperties", `Bool false
      ]
  in
  `Assoc
    [ ( "oneOf"
      , `List
          [ closed
              [ "kind", `Assoc [ "const", `String "plan" ]
              ; "plan", Keeper_tool_plan_request.input_schema
              ]
              [ "kind"; "plan" ]
          ; closed
              [ "kind", `Assoc [ "const", `String "cannot_assemble" ] ]
              [ "kind" ]
          ] )
    ]
;;

type output =
  | Plan of
      { plan_json : Yojson.Safe.t
      ; plan : Keeper_tool_plan.t
      }
  | Cannot_assemble

type output_error =
  | Output_not_object
  | Output_duplicate_field of string
  | Output_unknown_field of string
  | Output_missing_field of string
  | Output_invalid_kind of Yojson.Safe.t
  | Output_plan_rejected of Keeper_tool_plan_request.error

let output_of_yojson ~request = function
  | `Assoc fields ->
    (match first_duplicate fields with
     | Some field -> Error (Output_duplicate_field field)
     | None ->
       let* kind =
         match List.assoc_opt "kind" fields with
         | Some value -> Ok value
         | None -> Error (Output_missing_field "kind")
       in
       (match kind with
        | `String "cannot_assemble" ->
          (match fields with
           | [ "kind", _ ] -> Ok Cannot_assemble
           | _ ->
             let field = List.find (fun (name, _) -> not (String.equal name "kind")) fields |> fst in
             Error (Output_unknown_field field))
        | `String "plan" ->
          (match List.find_opt (fun (name, _) -> not (List.mem name [ "kind"; "plan" ])) fields with
           | Some (field, _) -> Error (Output_unknown_field field)
           | None ->
             let* plan_json =
               match List.assoc_opt "plan" fields with
               | Some value -> Ok value
               | None -> Error (Output_missing_field "plan")
             in
             Keeper_tool_plan_request.plan_of_json
               ~descriptors:request.descriptors
               plan_json
             |> Result.map (fun plan -> Plan { plan_json; plan })
             |> Result.map_error (fun error -> Output_plan_rejected error))
        | value -> Error (Output_invalid_kind value)))
  | _ -> Error Output_not_object
;;

let output_error_to_yojson = function
  | Output_not_object -> `Assoc [ "kind", `String "output_not_object" ]
  | Output_duplicate_field field ->
    `Assoc [ "kind", `String "output_duplicate_field"; "field", `String field ]
  | Output_unknown_field field ->
    `Assoc [ "kind", `String "output_unknown_field"; "field", `String field ]
  | Output_missing_field field ->
    `Assoc [ "kind", `String "output_missing_field"; "field", `String field ]
  | Output_invalid_kind actual ->
    `Assoc [ "kind", `String "output_invalid_kind"; "actual", actual ]
  | Output_plan_rejected error ->
    `Assoc
      [ "kind", `String "output_plan_rejected"
      ; "error", Keeper_tool_plan_request.error_to_json error
      ]
;;

let prompt_variables request =
  let* references =
    canonical_json
      ~variable:"ordinary_tool_references_json"
      (`List
        (List.map
           Surface.ordinary_tool_reference_to_yojson
           request.ordinary_tool_references))
  in
  let* output_schema =
    canonical_json ~variable:"assembler_output_schema_json" output_schema
  in
  let* descriptors =
    canonical_json
      ~variable:"tool_descriptors_json"
      (`List (List.map descriptor_json request.descriptors))
  in
  Ok
    [ "capability_surface_sha256", request.capability_surface_sha256
    ; "execution", execution_to_string request.execution
    ; "objective", request.objective
    ; "ordinary_tool_references_json", references
    ; "assembler_output_schema_json", output_schema
    ; "tool_descriptors_json", descriptors
    ]
;;

let error_to_yojson = function
  | Request_not_object -> `Assoc [ "kind", `String "request_not_object" ]
  | Duplicate_field field ->
    `Assoc [ "kind", `String "duplicate_field"; "field", `String field ]
  | Unknown_field field ->
    `Assoc [ "kind", `String "unknown_field"; "field", `String field ]
  | Missing_field field ->
    `Assoc [ "kind", `String "missing_field"; "field", `String field ]
  | Invalid_field_type { field; expected; found } ->
    `Assoc
      [ "kind", `String "invalid_field_type"
      ; "field", `String field
      ; "expected", `String expected
      ; "found", `String found
      ]
  | Blank_objective -> `Assoc [ "kind", `String "blank_objective" ]
  | Invalid_execution value ->
    `Assoc [ "kind", `String "invalid_execution"; "value", `String value ]
  | Empty_tool_references -> `Assoc [ "kind", `String "empty_tool_references" ]
  | Reference_parse_failed { index; error } ->
    `Assoc
      [ "kind", `String "reference_parse_failed"
      ; "index", `Int index
      ; "error", Surface.ordinary_tool_reference_parse_error_to_yojson error
      ]
  | Duplicate_tool_reference reference ->
    `Assoc
      [ "kind", `String "duplicate_tool_reference"
      ; "reference", Surface.ordinary_tool_reference_to_yojson reference
      ]
  | Reference_resolution_failed { index; error } ->
    `Assoc
      [ "kind", `String "reference_resolution_failed"
      ; "index", `Int index
      ; "error", Surface.ordinary_tool_resolution_error_to_yojson error
      ]
  | Referenced_tool_unavailable { index; reference; availability } ->
    `Assoc
      [ "kind", `String "referenced_tool_unavailable"
      ; "index", `Int index
      ; "reference", Surface.ordinary_tool_reference_to_yojson reference
      ; "availability", `String (Surface.capability_availability_to_string availability)
      ]
  | Async_tool_not_statically_read_only { descriptor_id; capability_id } ->
    `Assoc
      [ "kind", `String "async_tool_not_statically_read_only"
      ; "descriptor_id", `String descriptor_id
      ; "capability_id", `String capability_id
      ]
  | Prompt_variable_json_not_canonicalizable { variable; detail } ->
    `Assoc
      [ "kind", `String "prompt_variable_json_not_canonicalizable"
      ; "variable", `String variable
      ; "detail", `String detail
      ]
;;
