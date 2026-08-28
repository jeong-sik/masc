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

type t =
  { objective : string
  ; execution : execution
  ; ordinary_tool_references : Surface.ordinary_tool_reference list
  ; descriptors : Descriptor.t list
  ; capability_surface_sha256 : string
  }

let input_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ "objective", `Assoc [ "type", `String "string"; "minLength", `Int 1 ]
          ; ( "execution"
            , `Assoc
                [ "type", `String "string"
                ; "enum", `List [ `String "inline"; `String "async" ]
                ] )
          ; ( "ordinary_tool_references"
            , `Assoc
                [ "type", `String "array"
                ; "minItems", `Int 1
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

let canonical_json json =
  match Keeper_chat_operation.canonical_json_string json with
  | Ok bytes -> bytes
  | Error detail -> invalid_arg ("constructed Assembler JSON is invalid: " ^ detail)
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

let prompt_variables request =
  [ "capability_surface_sha256", request.capability_surface_sha256
  ; "execution", execution_to_string request.execution
  ; "objective", request.objective
  ; ( "ordinary_tool_references_json"
    , canonical_json
        (`List
          (List.map
             Surface.ordinary_tool_reference_to_yojson
             request.ordinary_tool_references)) )
  ; "plan_input_schema_json", canonical_json Keeper_tool_plan_request.input_schema
  ; ( "tool_descriptors_json"
    , canonical_json (`List (List.map descriptor_json request.descriptors)) )
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
;;
