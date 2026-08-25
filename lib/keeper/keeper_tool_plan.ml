module Node_id = struct
  type t = string

  type error = Empty

  let make = function
    | "" -> Error Empty
    | value -> Ok value
  ;;

  let to_string value = value
  let equal = String.equal
  let compare = String.compare
end

module Json_pointer = struct
  type t = string list

  type syntax_error =
    | Missing_initial_slash
    | Dangling_escape of { segment : string }
    | Invalid_escape of
        { segment : string
        ; found : char
        }

  type resolution_error =
    | Missing_object_field of string
    | Ambiguous_object_field of string
    | Invalid_array_index of string
    | Array_index_out_of_bounds of int
    | Expected_container of string

  type schema_error =
    | Missing_properties of string
    | Missing_property_schema of string
    | Ambiguous_property_schema of string
    | Missing_items_schema of string
    | Expected_schema_container of string

  let root = []

  let decode_segment segment =
    let length = String.length segment in
    let buffer = Buffer.create length in
    let rec decode index =
      if index = length
      then Ok (Buffer.contents buffer)
      else
        match String.unsafe_get segment index with
        | '~' when index + 1 = length -> Error (Dangling_escape { segment })
        | '~' ->
          let escaped = String.unsafe_get segment (index + 1) in
          (match escaped with
           | '0' ->
             Buffer.add_char buffer '~';
             decode (index + 2)
           | '1' ->
             Buffer.add_char buffer '/';
             decode (index + 2)
           | found -> Error (Invalid_escape { segment; found }))
        | character ->
          Buffer.add_char buffer character;
          decode (index + 1)
    in
    decode 0
  ;;

  let of_string = function
    | "" -> Ok root
    | pointer when String.unsafe_get pointer 0 <> '/' -> Error Missing_initial_slash
    | pointer ->
      let encoded = String.sub pointer 1 (String.length pointer - 1) in
      let rec decode_all decoded = function
        | [] -> Ok (List.rev decoded)
        | segment :: rest ->
          (match decode_segment segment with
           | Ok segment -> decode_all (segment :: decoded) rest
           | Error _ as error -> error)
      in
      decode_all [] (String.split_on_char '/' encoded)
  ;;

  let segments pointer = pointer

  let unique_object_field name fields =
    match
      List.filter_map
        (fun (field, value) -> if String.equal field name then Some value else None)
        fields
    with
    | [ value ] -> Ok value
    | [] -> Error (Missing_object_field name)
    | _ -> Error (Ambiguous_object_field name)
  ;;

  let array_index segment =
    let length = String.length segment in
    let rec all_digits index =
      if index = length
      then true
      else
        match String.unsafe_get segment index with
        | '0' .. '9' -> all_digits (index + 1)
        | _ -> false
    in
    if length = 0
       || (length > 1 && Char.equal (String.unsafe_get segment 0) '0')
       || not (all_digits 0)
    then Error (Invalid_array_index segment)
    else
      match int_of_string_opt segment with
      | Some index -> Ok index
      | None -> Error (Invalid_array_index segment)
  ;;

  let resolve pointer json =
    let rec descend value = function
      | [] -> Ok value
      | segment :: rest ->
        (match value with
         | `Assoc fields ->
           (match unique_object_field segment fields with
            | Ok value -> descend value rest
            | Error _ as error -> error)
         | `List values ->
           (match array_index segment with
            | Error _ as error -> error
            | Ok index ->
              (match List.nth_opt values index with
               | Some value -> descend value rest
               | None -> Error (Array_index_out_of_bounds index)))
         | `Null
         | `Bool _
         | `Int _
         | `Intlit _
         | `Float _
         | `String _ -> Error (Expected_container segment))
    in
    descend json pointer
  ;;

  let unique_schema_property name fields =
    match List.assoc_opt "properties" fields with
    | None -> Error (Missing_properties name)
    | Some (`Assoc properties) ->
      (match
         List.filter_map
           (fun (field, schema) -> if String.equal field name then Some schema else None)
           properties
       with
       | [ schema ] -> Ok schema
       | [] -> Error (Missing_property_schema name)
       | _ -> Error (Ambiguous_property_schema name))
    | Some _ -> Error (Missing_properties name)
  ;;

  let resolve_schema pointer schema =
    let rec descend schema = function
      | [] -> Ok schema
      | segment :: rest ->
        (match schema with
         | `Assoc fields ->
           (match List.assoc_opt "type" fields with
            | Some (`String "object") ->
              (match unique_schema_property segment fields with
               | Ok schema -> descend schema rest
               | Error _ as error -> error)
            | Some (`String "array") ->
              (match array_index segment with
               | Error _ -> Error (Expected_schema_container segment)
               | Ok _ ->
                 (match List.assoc_opt "items" fields with
                  | Some item_schema -> descend item_schema rest
                  | None -> Error (Missing_items_schema segment)))
            | Some _ | None -> Error (Expected_schema_container segment))
         | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
           Error (Expected_schema_container segment))
    in
    descend schema pointer
  ;;
end

module Json_template = struct
  type t =
    | Literal of Yojson.Safe.t
    | Output of
        { node_id : Node_id.t
        ; pointer : Json_pointer.t
        }
    | Param of { name : string }
    | Object of (string * t) list
    | Array of t list

  type object_error = Duplicate_field of string

  type resolution_error =
    | Missing_output of Node_id.t
    | Pointer_resolution_failed of
        { node_id : Node_id.t
        ; error : Json_pointer.resolution_error
        }
    | Param_not_substituted of string

  type substitution_error = Missing_param of string

  let literal value = Literal value
  let output ~node_id ~pointer = Output { node_id; pointer }
  let param ~name = Param { name }
  let array values = Array values

  let object_ fields =
    let rec first_duplicate seen = function
      | [] -> None
      | (name, _) :: rest ->
        if List.mem name seen then Some name else first_duplicate (name :: seen) rest
    in
    match first_duplicate [] fields with
    | None -> Ok (Object fields)
    | Some name -> Error (Duplicate_field name)
  ;;

  let dependencies template =
    let rec collect acc = function
      | Literal _ | Param _ -> acc
      | Output { node_id; _ } ->
        if List.exists (Node_id.equal node_id) acc then acc else node_id :: acc
      | Object fields ->
        List.fold_left (fun acc (_, value) -> collect acc value) acc fields
      | Array values -> List.fold_left collect acc values
    in
    collect [] template |> List.rev
  ;;

  let references template =
    let rec collect acc = function
      | Literal _ | Param _ -> acc
      | Output { node_id; pointer } -> (node_id, pointer) :: acc
      | Object fields ->
        List.fold_left (fun acc (_, value) -> collect acc value) acc fields
      | Array values -> List.fold_left collect acc values
    in
    collect [] template |> List.rev
  ;;

  let param_names template =
    let rec collect acc = function
      | Literal _ | Output _ -> acc
      | Param { name } -> if List.mem name acc then acc else name :: acc
      | Object fields ->
        List.fold_left (fun acc (_, value) -> collect acc value) acc fields
      | Array values -> List.fold_left collect acc values
    in
    collect [] template |> List.rev
  ;;

  (* Substitution rebuilds the template with every [Param] replaced by the
     caller's value, so a plan created from the result is param-free and the
     executor never meets an unbound name. Structure is preserved exactly:
     no field is added or removed, so [Object] duplicate-field validity
     carries over from the input template. *)
  let substitute_params ~lookup template =
    let rec substitute = function
      | Literal _ as value -> Ok value
      | Output _ as value -> Ok value
      | Param { name } ->
        (match lookup name with
         | Some value -> Ok (Literal value)
         | None -> Error (Missing_param name))
      | Object fields ->
        let rec substitute_all rebuilt = function
          | [] -> Ok (Object (List.rev rebuilt))
          | (name, value) :: rest ->
            (match substitute value with
             | Ok value -> substitute_all ((name, value) :: rebuilt) rest
             | Error _ as error -> error)
        in
        substitute_all [] fields
      | Array values ->
        let rec substitute_all rebuilt = function
          | [] -> Ok (Array (List.rev rebuilt))
          | value :: rest ->
            (match substitute value with
             | Ok value -> substitute_all (value :: rebuilt) rest
             | Error _ as error -> error)
        in
        substitute_all [] values
    in
    substitute template
  ;;

  let resolve ~lookup template =
    let rec resolve_value = function
      | Literal value -> Ok value
      | Param { name } -> Error (Param_not_substituted name)
      | Output { node_id; pointer } ->
        (match lookup node_id with
         | None -> Error (Missing_output node_id)
         | Some output ->
           (match Json_pointer.resolve pointer output with
            | Ok value -> Ok value
            | Error error -> Error (Pointer_resolution_failed { node_id; error })))
      | Array values ->
        let rec resolve_all resolved = function
          | [] -> Ok (`List (List.rev resolved))
          | value :: rest ->
            (match resolve_value value with
             | Ok value -> resolve_all (value :: resolved) rest
             | Error _ as error -> error)
        in
        resolve_all [] values
      | Object fields ->
        let rec resolve_all resolved = function
          | [] -> Ok (`Assoc (List.rev resolved))
          | (name, value) :: rest ->
            (match resolve_value value with
             | Ok value -> resolve_all ((name, value) :: resolved) rest
             | Error _ as error -> error)
        in
        resolve_all [] fields
    in
    resolve_value template
  ;;
end

module Run_id = struct
  type t = int

  let next = Atomic.make 0
  let fresh () = Atomic.fetch_and_add next 1
  let equal = Int.equal
end

module Composition_run_id = struct
  type t = string

  let fresh = Random_id.uuid_v7
  let to_string value = value
  let equal = String.equal
end

type json_type =
  | Null_type
  | Boolean_type
  | Integer_type
  | Number_type
  | String_type
  | Array_type
  | Object_type

type schema_value_error =
  | Unsupported_schema_type of Yojson.Safe.t
  | Missing_required_field of
      { path : string list
      ; field : string
      }
  | Unexpected_field of
      { path : string list
      ; field : string
      }
  | Duplicate_value_field of
      { path : string list
      ; field : string
      }
  | Type_mismatch of
      { path : string list
      ; expected : json_type
      ; actual : json_type
      }

type schema_contract_error =
  | Expected_schema_object of
      { path : string list
      ; schema : Yojson.Safe.t
      }
  | Duplicate_schema_keyword of
      { path : string list
      ; keyword : string
      }
  | Missing_schema_type of { path : string list }
  | Unsupported_contract_type of
      { path : string list
      ; value : Yojson.Safe.t
      }
  | Unsupported_schema_keyword of
      { path : string list
      ; keyword : string
      }
  | Invalid_schema_keyword_value of
      { path : string list
      ; keyword : string
      ; value : Yojson.Safe.t
      }
  | Duplicate_required_field of
      { path : string list
      ; field : string
      }
  | Unknown_required_property of
      { path : string list
      ; field : string
      }

let json_type = function
  | `Null -> Null_type
  | `Bool _ -> Boolean_type
  | `Int _ | `Intlit _ -> Integer_type
  | `Float _ -> Number_type
  | `String _ -> String_type
  | `List _ -> Array_type
  | `Assoc _ -> Object_type
;;

let first_duplicate_field fields =
  let rec find seen = function
    | [] -> None
    | (name, _) :: rest ->
      if List.mem name seen then Some name else find (name :: seen) rest
  in
  find [] fields
;;

let first_duplicate_name names =
  let rec find seen = function
    | [] -> None
    | name :: rest ->
      if List.mem name seen then Some name else find (name :: seen) rest
  in
  find [] names
;;

let schema_type fields = List.assoc_opt "type" fields

let rec validate_schema_contract ~path schema =
  match schema with
  | `Assoc fields ->
    (match first_duplicate_field fields with
     | Some keyword -> Error (Duplicate_schema_keyword { path; keyword })
     | None ->
       (match schema_type fields with
        | None -> Error (Missing_schema_type { path })
        | Some (`String schema_type) ->
          let allowed_keywords =
            match schema_type with
            | "object" ->
              Ok [ "type"; "properties"; "required"; "additionalProperties" ]
            | "array" -> Ok [ "type"; "items" ]
            | "null" | "boolean" | "integer" | "number" | "string" -> Ok [ "type" ]
            | _ -> Error (Unsupported_contract_type { path; value = `String schema_type })
          in
          (match allowed_keywords with
           | Error _ as error -> error
           | Ok allowed_keywords ->
             (match
                List.find_opt
                  (fun (keyword, _) -> not (List.mem keyword allowed_keywords))
                  fields
              with
              | Some (keyword, _) -> Error (Unsupported_schema_keyword { path; keyword })
              | None -> validate_schema_keywords ~path ~schema_type fields))
        | Some value -> Error (Unsupported_contract_type { path; value })))
  | schema -> Error (Expected_schema_object { path; schema })

and validate_schema_keywords ~path ~schema_type fields =
  match schema_type with
  | "object" -> validate_object_schema_contract ~path fields
  | "array" ->
    (match List.assoc_opt "items" fields with
     | None -> Ok ()
     | Some item_schema -> validate_schema_contract ~path:(path @ [ "items" ]) item_schema)
  | "null" | "boolean" | "integer" | "number" | "string" -> Ok ()
  | _ -> assert false

and validate_object_schema_contract ~path fields =
  let properties_result =
    match List.assoc_opt "properties" fields with
    | None -> Ok []
    | Some (`Assoc properties) ->
      (match first_duplicate_field properties with
       | Some keyword ->
         Error (Duplicate_schema_keyword { path = path @ [ "properties" ]; keyword })
       | None ->
         let rec validate_properties = function
           | [] -> Ok properties
           | (name, schema) :: rest ->
             (match validate_schema_contract ~path:(path @ [ "properties"; name ]) schema with
              | Ok () -> validate_properties rest
              | Error _ as error -> error)
         in
         validate_properties properties)
    | Some value ->
      Error (Invalid_schema_keyword_value { path; keyword = "properties"; value })
  in
  match properties_result with
  | Error _ as error -> error
  | Ok properties ->
    let required_result =
      match List.assoc_opt "required" fields with
      | None -> Ok []
      | Some (`List values) ->
        let rec strings acc = function
          | [] -> Ok (List.rev acc)
          | `String field :: rest -> strings (field :: acc) rest
          | value :: _ ->
            Error (Invalid_schema_keyword_value { path; keyword = "required"; value })
        in
        strings [] values
      | Some value ->
        Error (Invalid_schema_keyword_value { path; keyword = "required"; value })
    in
    (match required_result with
     | Error _ as error -> error
     | Ok required ->
       (match first_duplicate_name required with
        | Some field -> Error (Duplicate_required_field { path; field })
        | None ->
          (match List.find_opt (fun field -> not (List.mem_assoc field properties)) required with
           | Some field -> Error (Unknown_required_property { path; field })
           | None ->
             (match List.assoc_opt "additionalProperties" fields with
              | None | Some (`Bool _) -> Ok ()
              | Some value ->
                Error
                  (Invalid_schema_keyword_value
                     { path; keyword = "additionalProperties"; value })))))

let rec validate_schema_value ~path schema value =
  match schema with
  | `Assoc schema_fields ->
    (match schema_type schema_fields with
     | Some (`String "object") -> validate_schema_object ~path schema_fields value
     | Some (`String "array") -> validate_schema_array ~path schema_fields value
     | Some (`String "null") -> validate_schema_scalar ~path Null_type value
     | Some (`String "string") -> validate_schema_scalar ~path String_type value
     | Some (`String "integer") -> validate_schema_scalar ~path Integer_type value
     | Some (`String "number") ->
       (match json_type value with
        | Integer_type | Number_type -> Ok ()
        | actual -> Error (Type_mismatch { path; expected = Number_type; actual }))
     | Some (`String "boolean") -> validate_schema_scalar ~path Boolean_type value
     | Some unsupported -> Error (Unsupported_schema_type unsupported)
     | None -> Error (Unsupported_schema_type `Null))
  | unsupported -> Error (Unsupported_schema_type unsupported)

and validate_schema_scalar ~path expected value =
  let actual = json_type value in
  if actual = expected then Ok () else Error (Type_mismatch { path; expected; actual })

and validate_schema_object ~path schema_fields value =
  match value with
  | `Assoc fields ->
    (match first_duplicate_field fields with
     | Some field -> Error (Duplicate_value_field { path; field })
     | None ->
       let properties =
         match List.assoc_opt "properties" schema_fields with
         | Some (`Assoc properties) -> properties
         | None | Some _ -> []
       in
       let required =
         match List.assoc_opt "required" schema_fields with
         | Some (`List values) ->
           List.filter_map (function `String name -> Some name | _ -> None) values
         | None | Some _ -> []
       in
       (match List.find_opt (fun name -> not (List.mem_assoc name fields)) required with
        | Some field -> Error (Missing_required_field { path; field })
        | None ->
          let additional_forbidden =
            match List.assoc_opt "additionalProperties" schema_fields with
            | Some (`Bool false) -> true
            | None | Some _ -> false
          in
          (match
             if additional_forbidden
             then List.find_opt (fun (name, _) -> not (List.mem_assoc name properties)) fields
             else None
           with
           | Some (field, _) -> Error (Unexpected_field { path; field })
           | None ->
             let rec validate_fields = function
               | [] -> Ok ()
               | (name, property_schema) :: rest ->
                 (match List.assoc_opt name fields with
                  | None -> validate_fields rest
                  | Some property_value ->
                    (match
                       validate_schema_value
                         ~path:(path @ [ name ])
                         property_schema
                         property_value
                     with
                     | Ok () -> validate_fields rest
                     | Error _ as error -> error))
             in
             validate_fields properties)))
  | other ->
    Error (Type_mismatch { path; expected = Object_type; actual = json_type other })

and validate_schema_array ~path schema_fields value =
  match value with
  | `List values ->
    (match List.assoc_opt "items" schema_fields with
     | None -> Ok ()
     | Some item_schema ->
       let rec validate_items index = function
         | [] -> Ok ()
         | item :: rest ->
           (match
              validate_schema_value
                ~path:(path @ [ string_of_int index ])
                item_schema
                item
            with
            | Ok () -> validate_items (index + 1) rest
            | Error _ as error -> error)
       in
       validate_items 0 values)
  | other ->
    Error (Type_mismatch { path; expected = Array_type; actual = json_type other })
;;

let validate_composable_schema schema = validate_schema_contract ~path:[] schema

type node =
  { id : Node_id.t
  ; tool_name : string
  ; input : Json_template.t
  ; after : Node_id.t list
  }

let node ~id ~tool_name ?(after = []) ~input () = { id; tool_name; input; after }

(* Why a real descriptor is absent from the Keeper model surface. Kept apart
   from [Unknown_tool] because the two need opposite answers: a misspelled name
   is fixed by correcting it, while an off-surface name is spelled correctly and
   is reached through the operator entrypoint or the descriptor that projects
   it. #29681 moved 13 descriptors to Operator_only/Transport_alias, and with
   only [Unknown_tool] to report, every one of them told the plan author to hunt
   for a typo that was not there. *)
type off_surface_reason =
  | Operator_only_tool
  | Aliased_by of { projected_by : string }
  | Unresolved_schema

type error =
  | Empty_plan
  | Unknown_descriptor_id of string
  | Duplicate_node_id of Node_id.t
  | Duplicate_tool_name of string
  | Unknown_tool of
      { node_id : Node_id.t
      ; tool_name : string
      }
  | Tool_off_keeper_surface of
      { node_id : Node_id.t
      ; tool_name : string
      ; reason : off_surface_reason
      }
  | Missing_dependency of
      { node_id : Node_id.t
      ; dependency : Node_id.t
      }
  | Opaque_output_reference of
      { node_id : Node_id.t
      ; source_node_id : Node_id.t
      ; source_tool_name : string
      }
  | Invalid_output_pointer of
      { node_id : Node_id.t
      ; source_node_id : Node_id.t
      ; pointer : Json_pointer.t
      ; error : Json_pointer.schema_error
      }
  | Invalid_output_schema of
      { node_id : Node_id.t
      ; tool_name : string
      ; error : schema_contract_error
      }
  | Multiple_terminal_nodes of Node_id.t list
  | Terminal_node_missing_dependency of
      { terminal_node_id : Node_id.t
      ; node_id : Node_id.t
      }
  | Dependency_cycle of Node_id.t list

let error_to_string = function
  | Empty_plan -> "plan has no nodes"
  | Unknown_descriptor_id id -> Printf.sprintf "descriptor id %S is not canonical" id
  | Duplicate_node_id node_id ->
    Printf.sprintf "duplicate node id %S" (Node_id.to_string node_id)
  | Duplicate_tool_name tool_name ->
    Printf.sprintf "descriptor tool name %S is ambiguous" tool_name
  | Unknown_tool { node_id; tool_name } ->
    Printf.sprintf "node %S names unknown tool %S" (Node_id.to_string node_id) tool_name
  | Tool_off_keeper_surface { node_id; tool_name; reason } ->
    Printf.sprintf
      "node %S names tool %S, which exists but is not on the Keeper model surface (%s)"
      (Node_id.to_string node_id)
      tool_name
      (match reason with
       | Operator_only_tool -> "operator-only"
       | Aliased_by { projected_by } -> Printf.sprintf "projected by %S" projected_by
       | Unresolved_schema -> "no resolved schema")
  | Missing_dependency { node_id; dependency } ->
    Printf.sprintf
      "node %S depends on missing node %S"
      (Node_id.to_string node_id)
      (Node_id.to_string dependency)
  | Opaque_output_reference { node_id; source_node_id; source_tool_name } ->
    Printf.sprintf
      "node %S references opaque output from node %S (%s)"
      (Node_id.to_string node_id)
      (Node_id.to_string source_node_id)
      source_tool_name
  | Invalid_output_pointer { node_id; source_node_id; pointer; _ } ->
    Printf.sprintf
      "node %S has invalid output pointer /%s for node %S"
      (Node_id.to_string node_id)
      (String.concat "/" (Json_pointer.segments pointer))
      (Node_id.to_string source_node_id)
  | Invalid_output_schema { node_id; tool_name; _ } ->
    Printf.sprintf
      "node %S tool %S declares an invalid composable output schema"
      (Node_id.to_string node_id)
      tool_name
  | Multiple_terminal_nodes node_ids ->
    Printf.sprintf
      "plan has multiple terminal nodes: %s"
      (node_ids |> List.map Node_id.to_string |> String.concat ", ")
  | Terminal_node_missing_dependency { terminal_node_id; node_id } ->
    Printf.sprintf
      "terminal node %S does not depend on node %S"
      (Node_id.to_string terminal_node_id)
      (Node_id.to_string node_id)
  | Dependency_cycle node_ids ->
    Printf.sprintf
      "plan dependency cycle: %s"
      (node_ids |> List.map Node_id.to_string |> String.concat " -> ")
;;

type t =
  { identity : int
  ; nodes : node list
  ; descriptors : (string * Keeper_tool_descriptor.t) list
  }

let next_plan_identity = Atomic.make 0

let nodes plan = plan.nodes

let stable_unique_node_ids ids =
  List.fold_left
    (fun unique id ->
       if List.exists (Node_id.equal id) unique then unique else unique @ [ id ])
    []
    ids
;;

let dependencies node =
  stable_unique_node_ids (node.after @ Json_template.dependencies node.input)
;;

let descriptor_entries descriptors =
  List.concat_map
    (fun descriptor ->
       Keeper_tool_descriptor.keeper_model_names descriptor
       |> List.map (fun name -> name, descriptor))
    descriptors
;;

(* Names owned by descriptors the Keeper model cannot call. [registered_names]
   is the name-integrity view, so it still carries transport-alias names after
   [keeper_model_names] has gone empty — which is exactly what tells an
   off-surface name apart from one nothing owns. This index never admits
   execution; it only names the rejection. *)
let off_surface_entries descriptors =
  List.concat_map
    (fun descriptor ->
       match Keeper_tool_descriptor.keeper_model_names descriptor with
       | _ :: _ -> []
       | [] ->
         let reason =
           match descriptor.Keeper_tool_descriptor.keeper_model_projection with
           | Keeper_tool_descriptor.Operator_only -> Operator_only_tool
           | Keeper_tool_descriptor.Transport_alias { projected_by } ->
             Aliased_by { projected_by }
           | Keeper_tool_descriptor.Preferred_public_name
           | Keeper_tool_descriptor.Internal_name -> Unresolved_schema
         in
         Keeper_tool_descriptor.registered_names descriptor
         |> List.map (fun name -> name, reason))
    descriptors
;;

let canonicalize_descriptors descriptors =
  let rec canonicalize resolved = function
    | [] -> Ok (List.rev resolved)
    | descriptor :: rest ->
      (match Keeper_tool_descriptor.find_id descriptor.Keeper_tool_descriptor.id with
       | None -> Error (Unknown_descriptor_id descriptor.id)
       | Some canonical -> canonicalize (canonical :: resolved) rest)
  in
  canonicalize [] descriptors
;;

let first_duplicate equal values =
  let rec find seen = function
    | [] -> None
    | value :: rest ->
      if List.exists (equal value) seen then Some value else find (value :: seen) rest
  in
  find [] values
;;

let descriptor_for_name descriptors name =
  List.find_map
    (fun (candidate, descriptor) ->
       if String.equal candidate name then Some descriptor else None)
    descriptors
;;

let node_for_id nodes id =
  List.find_opt (fun node -> Node_id.equal node.id id) nodes
;;

let validate_known_tools descriptors off_surface nodes =
  List.find_map
    (fun node ->
       match descriptor_for_name descriptors node.tool_name with
       | Some _ -> None
       | None ->
         (match List.assoc_opt node.tool_name off_surface with
          | Some reason ->
            Some
              (Tool_off_keeper_surface
                 { node_id = node.id; tool_name = node.tool_name; reason })
          | None -> Some (Unknown_tool { node_id = node.id; tool_name = node.tool_name })))
    nodes
;;

let validate_dependencies nodes =
  List.find_map
    (fun node ->
       dependencies node
       |> List.find_map (fun dependency ->
         match node_for_id nodes dependency with
         | Some _ -> None
         | None -> Some (Missing_dependency { node_id = node.id; dependency })))
    nodes
;;

let validate_output_references descriptors nodes =
  List.find_map
    (fun node ->
       Json_template.references node.input
       |> List.find_map (fun (source_node_id, pointer) ->
         match node_for_id nodes source_node_id with
         | None -> Some (Missing_dependency { node_id = node.id; dependency = source_node_id })
         | Some source_node ->
           (match descriptor_for_name descriptors source_node.tool_name with
            | None ->
              Some
                (Unknown_tool
                   { node_id = source_node.id; tool_name = source_node.tool_name })
            | Some source_descriptor ->
              (match source_descriptor.Keeper_tool_descriptor.composable_output with
               | Keeper_tool_descriptor.Json_output { schema } ->
                 (match Json_pointer.resolve_schema pointer schema with
                  | Ok _ -> None
                  | Error error ->
                    Some
                      (Invalid_output_pointer
                         { node_id = node.id; source_node_id; pointer; error }))
               | Keeper_tool_descriptor.Opaque_output ->
                 Some
                   (Opaque_output_reference
                      { node_id = node.id
                      ; source_node_id
                      ; source_tool_name = source_node.tool_name
                      })))))
    nodes
;;

let validate_output_schemas descriptors nodes =
  List.find_map
    (fun node ->
       match descriptor_for_name descriptors node.tool_name with
       | None -> Some (Unknown_tool { node_id = node.id; tool_name = node.tool_name })
       | Some descriptor ->
         (match descriptor.Keeper_tool_descriptor.composable_output with
          | Keeper_tool_descriptor.Opaque_output -> None
          | Keeper_tool_descriptor.Json_output { schema } ->
            (match validate_composable_schema schema with
             | Ok () -> None
             | Error error ->
               Some
                 (Invalid_output_schema
                    { node_id = node.id; tool_name = node.tool_name; error }))))
    nodes
;;

let dependency_cycle nodes =
  let rec cycle_members target = function
    | [] -> []
    | id :: rest ->
      if Node_id.equal id target then [ id ] else id :: cycle_members target rest
  in
  let rec visit path visited id =
    if List.exists (Node_id.equal id) path
    then Error (List.rev (cycle_members id path))
    else if List.exists (Node_id.equal id) visited
    then Ok visited
    else
      match node_for_id nodes id with
      | None -> Ok visited
      | Some node ->
        let rec visit_dependencies visited = function
          | [] -> Ok (id :: visited)
          | dependency :: rest ->
            (match visit (id :: path) visited dependency with
             | Error _ as error -> error
             | Ok visited -> visit_dependencies visited rest)
        in
        visit_dependencies visited (dependencies node)
  in
  let rec visit_all visited = function
    | [] -> None
    | node :: rest ->
      (match visit [] visited node.id with
       | Error cycle -> Some cycle
       | Ok visited -> visit_all visited rest)
  in
  visit_all [] nodes
;;

let validate_terminal_dependency_boundary descriptors nodes =
  let terminal_nodes =
    List.filter
      (fun node ->
         match descriptor_for_name descriptors node.tool_name with
         | Some { Keeper_tool_descriptor.execution = Keeper_tool_descriptor.Terminal; _ } ->
           true
         | Some
             { execution =
                 Keeper_tool_descriptor.Ordinary
                   (Keeper_tool_descriptor.Serial | Keeper_tool_descriptor.Concurrent)
             ; _
             }
         | None -> false)
      nodes
  in
  match terminal_nodes with
  | [] -> None
  | _ :: _ :: _ -> Some (Multiple_terminal_nodes (List.map (fun node -> node.id) terminal_nodes))
  | [ terminal ] ->
    let rec ancestors visited node_id =
      if List.exists (Node_id.equal node_id) visited
      then visited
      else
        match node_for_id nodes node_id with
        | None -> visited
        | Some node ->
          List.fold_left ancestors (node_id :: visited) (dependencies node)
    in
    let terminal_ancestors = ancestors [] terminal.id in
    List.find_map
      (fun node ->
         if Node_id.equal node.id terminal.id
            || List.exists (Node_id.equal node.id) terminal_ancestors
         then None
         else
           Some
             (Terminal_node_missing_dependency
                { terminal_node_id = terminal.id; node_id = node.id }))
      nodes
;;

let create ~descriptors nodes =
  match nodes with
  | [] -> Error Empty_plan
  | _ ->
    (match canonicalize_descriptors descriptors with
     | Error _ as error -> error
     | Ok canonical_descriptors ->
       (match first_duplicate Node_id.equal (List.map (fun node -> node.id) nodes) with
        | Some id -> Error (Duplicate_node_id id)
        | None ->
          let descriptors = descriptor_entries canonical_descriptors in
          let off_surface = off_surface_entries canonical_descriptors in
          (match first_duplicate String.equal (List.map fst descriptors) with
           | Some name -> Error (Duplicate_tool_name name)
           | None ->
             (match validate_known_tools descriptors off_surface nodes with
              | Some error -> Error error
              | None ->
                (match validate_output_schemas descriptors nodes with
                 | Some error -> Error error
                 | None ->
                   (match validate_dependencies nodes with
                    | Some error -> Error error
                    | None ->
                      (match validate_output_references descriptors nodes with
                       | Some error -> Error error
                       | None ->
                         (match dependency_cycle nodes with
                          | Some cycle -> Error (Dependency_cycle cycle)
                          | None ->
                            (match
                               validate_terminal_dependency_boundary descriptors nodes
                             with
                             | Some error -> Error error
                             | None ->
                               Ok
                                 { identity = Atomic.fetch_and_add next_plan_identity 1
                                 ; nodes
                                 ; descriptors
                                 })))))))))
;;

let dependency_layers plan =
  let rec build completed remaining acc =
    match remaining with
    | [] -> List.rev acc
    | _ ->
      let ready, blocked =
        List.partition
          (fun node ->
             List.for_all
               (fun dependency -> List.exists (Node_id.equal dependency) completed)
               (dependencies node))
          remaining
      in
      let completed = completed @ List.map (fun node -> node.id) ready in
      build completed blocked (ready :: acc)
  in
  build [] plan.nodes []
;;

let descriptor plan node_id =
  match node_for_id plan.nodes node_id with
  | Some node -> descriptor_for_name plan.descriptors node.tool_name
  | None -> None
;;

type output =
  { plan_identity : int
  ; run_id : Run_id.t
  ; node_id : Node_id.t
  ; tool_name : string
  ; value : Yojson.Safe.t
  }

type execution_error =
  | Unknown_node_id of Node_id.t
  | Input_template_resolution_failed of
      { node_id : Node_id.t
      ; error : Json_template.resolution_error
      }
  | Input_validation_failed of
      { node_id : Node_id.t
      ; tool_name : string
      ; rejection : Tool_result.result
      }
  | Output_validation_failed of
      { node_id : Node_id.t
      ; tool_name : string
      ; error : schema_value_error
      }
  | Output_not_composable of
      { node_id : Node_id.t
      ; tool_name : string
      }

let output_node_id output = output.node_id

let validate_output plan ~run_id ~node_id value =
  match node_for_id plan.nodes node_id with
  | None -> Error (Unknown_node_id node_id)
  | Some node ->
    (match descriptor_for_name plan.descriptors node.tool_name with
     | None -> Error (Unknown_node_id node_id)
     | Some descriptor ->
       (match descriptor.Keeper_tool_descriptor.composable_output with
        | Keeper_tool_descriptor.Opaque_output ->
          Error (Output_not_composable { node_id; tool_name = node.tool_name })
        | Keeper_tool_descriptor.Json_output { schema } ->
          (match validate_schema_value ~path:[] schema value with
           | Ok () ->
             Ok
               { plan_identity = plan.identity
               ; run_id
               ; node_id
               ; tool_name = node.tool_name
               ; value
               }
           | Error error ->
             Error
               (Output_validation_failed
                  { node_id; tool_name = node.tool_name; error }))))
;;

let resolve_input plan ~run_id ~node_id ~lookup =
  match node_for_id plan.nodes node_id with
  | None -> Error (Unknown_node_id node_id)
  | Some node ->
    let lookup_value dependency =
      match node_for_id plan.nodes dependency, lookup dependency with
      | Some source_node, Some output
        when Int.equal output.plan_identity plan.identity
             && Run_id.equal output.run_id run_id
             && Node_id.equal output.node_id dependency
             && String.equal output.tool_name source_node.tool_name -> Some output.value
      | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
    in
    (match Json_template.resolve ~lookup:lookup_value node.input with
     | Error error -> Error (Input_template_resolution_failed { node_id; error })
     | Ok input ->
       (match descriptor_for_name plan.descriptors node.tool_name with
        | None -> Error (Unknown_node_id node_id)
        | Some descriptor ->
          (match
             Tool_input_validation.validate_args
               ~schema:descriptor.Keeper_tool_descriptor.input_schema
               ~name:node.tool_name
               ~args:input
               ()
           with
           | Ok input -> Ok input
           | Error rejection ->
             Error
               (Input_validation_failed
                  { node_id; tool_name = node.tool_name; rejection }))))
;;
