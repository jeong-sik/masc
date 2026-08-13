module Toml = Keeper_toml_loader
module Plan = Keeper_tool_plan

type expected_value =
  | String_value
  | String_array_value
  | Table_value
  | Table_array_value
  | Array_value

type error =
  | Toml_syntax of string
  | Empty_catalog
  | Unknown_field of
      { path : string list
      ; field : string
      }
  | Duplicate_field of
      { path : string list
      ; field : string
      }
  | Missing_field of
      { path : string list
      ; field : string
      }
  | Wrong_value_kind of
      { path : string list
      ; field : string
      ; expected : expected_value
      }
  | Empty_name of { path : string list }
  | Composition_name_too_long of
      { name : string
      ; maximum_bytes : int
      }
  | Invalid_composition_name_character of
      { name : string
      ; character : char
      }
  | Duplicate_composition_name of string
  | Invalid_execution_mode of
      { path : string list
      ; mode : string
      }
  | Async_tool_not_statically_read_only of
      { name : string
      ; node_id : Plan.Node_id.t
      ; tool_name : string
      }
  | Invalid_template_kind of
      { path : string list
      ; kind : string
      }
  | Invalid_node_id of
      { path : string list
      ; error : Plan.Node_id.error
      }
  | Invalid_json_pointer of
      { path : string list
      ; error : Plan.Json_pointer.syntax_error
      }
  | Duplicate_template_object_field of
      { path : string list
      ; field : string
      }
  | Plan_rejected of
      { name : string
      ; error : Plan.error
      }

type execution_mode =
  | Inline
  | Async

type entry =
  { name : string
  ; description : string option
  ; execution : execution_mode
  ; plan : Plan.t
  }

type t = entry list

let tool_name_prefix = "keeper_compose_"
let maximum_tool_name_bytes = 64
let maximum_composition_name_bytes = maximum_tool_name_bytes - String.length tool_name_prefix
let tool_name entry = tool_name_prefix ^ entry.name
let status_tool_name = "keeper_composition_status"
let cancel_tool_name = "keeper_composition_cancel"

let execution_mode_to_string = function
  | Inline -> "inline"
  | Async -> "async"
;;

let path ~config_root = Filename.concat config_root "tool-compositions.toml"

let entries catalog = catalog

let find catalog name =
  List.find_opt (fun entry -> String.equal entry.name name) catalog
;;

let model_tool_names catalog =
  let entry_names = List.map tool_name catalog in
  if List.exists (fun entry -> entry.execution = Async) catalog
  then entry_names @ [ status_tool_name; cancel_tool_name ]
  else entry_names
;;

let first_duplicate fields =
  let rec find_duplicate seen = function
    | [] -> None
    | (name, _) :: rest ->
      if List.mem name seen then Some name else find_duplicate (name :: seen) rest
  in
  find_duplicate [] fields
;;

let validate_fields ~path ~allowed fields =
  match first_duplicate fields with
  | Some field -> Error (Duplicate_field { path; field })
  | None ->
    (match List.find_opt (fun (field, _) -> not (List.mem field allowed)) fields with
     | Some (field, _) -> Error (Unknown_field { path; field })
     | None -> Ok ())
;;

let required_field ~path field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field { path; field })
;;

let string_value ~path ~field = function
  | Toml.Toml_string value -> Ok value
  | _ -> Error (Wrong_value_kind { path; field; expected = String_value })
;;

let required_string ~path field fields =
  match required_field ~path field fields with
  | Error _ as error -> error
  | Ok value -> string_value ~path ~field value
;;

let required_nonempty_string ~path field fields =
  match required_string ~path field fields with
  | Error _ as error -> error
  | Ok "" -> Error (Empty_name { path = path @ [ field ] })
  | Ok value -> Ok value
;;

let optional_string ~path field fields =
  match List.assoc_opt field fields with
  | None -> Ok None
  | Some value ->
    (match string_value ~path ~field value with
     | Ok value -> Ok (Some value)
     | Error _ as error -> error)
;;

let table_fields ~path ~field = function
  | Toml.Toml_table fields | Toml.Toml_inline_table fields -> Ok fields
  | _ -> Error (Wrong_value_kind { path; field; expected = Table_value })
;;

let table_array ~path ~field = function
  | Toml.Toml_table_array values -> Ok values
  | _ -> Error (Wrong_value_kind { path; field; expected = Table_array_value })
;;

let array_values ~path ~field = function
  | Toml.Toml_array values | Toml.Toml_table_array values -> Ok values
  | Toml.Toml_string_array values ->
    Ok (List.map (fun value -> Toml.Toml_string value) values)
  | _ -> Error (Wrong_value_kind { path; field; expected = Array_value })
;;

let string_array ~path ~field = function
  | Toml.Toml_string_array values -> Ok values
  | Toml.Toml_array values ->
    let rec strings parsed = function
      | [] -> Ok (List.rev parsed)
      | Toml.Toml_string value :: rest -> strings (value :: parsed) rest
      | _ :: _ ->
        Error (Wrong_value_kind { path; field; expected = String_array_value })
    in
    strings [] values
  | _ -> Error (Wrong_value_kind { path; field; expected = String_array_value })
;;

let rec json_of_toml = function
  | Toml.Toml_string value -> `String value
  | Toml.Toml_int value -> `Int value
  | Toml.Toml_float value -> `Float value
  | Toml.Toml_bool value -> `Bool value
  | Toml.Toml_string_array values ->
    `List (List.map (fun value -> `String value) values)
  | Toml.Toml_array values | Toml.Toml_table_array values ->
    `List (List.map json_of_toml values)
  | Toml.Toml_table fields | Toml.Toml_inline_table fields ->
    `Assoc (List.map (fun (name, value) -> name, json_of_toml value) fields)
  | Toml.Toml_offset_datetime value
  | Toml.Toml_local_datetime value
  | Toml.Toml_local_date value
  | Toml.Toml_local_time value -> `String value
;;

let node_id ~path raw =
  match Plan.Node_id.make raw with
  | Ok id -> Ok id
  | Error error -> Error (Invalid_node_id { path; error })
;;

let pointer ~path raw =
  match Plan.Json_pointer.of_string raw with
  | Ok pointer -> Ok pointer
  | Error error -> Error (Invalid_json_pointer { path; error })
;;

let rec parse_template ~path value =
  match table_fields ~path ~field:"template" value with
  | Error _ as error -> error
  | Ok fields ->
    (match required_string ~path "kind" fields with
     | Error _ as error -> error
     | Ok "literal" -> parse_literal_template ~path fields
     | Ok "output" -> parse_output_template ~path fields
     | Ok "object" -> parse_object_template ~path fields
     | Ok "array" -> parse_array_template ~path fields
     | Ok kind -> Error (Invalid_template_kind { path; kind }))

and parse_literal_template ~path fields =
  match validate_fields ~path ~allowed:[ "kind"; "value" ] fields with
  | Error _ as error -> error
  | Ok () ->
    (match required_field ~path "value" fields with
     | Error _ as error -> error
     | Ok value -> Ok (Plan.Json_template.literal (json_of_toml value)))

and parse_output_template ~path fields =
  match validate_fields ~path ~allowed:[ "kind"; "node"; "pointer" ] fields with
  | Error _ as error -> error
  | Ok () ->
    (match required_nonempty_string ~path "node" fields with
     | Error _ as error -> error
     | Ok raw_node ->
       (match required_string ~path "pointer" fields with
        | Error _ as error -> error
        | Ok raw_pointer ->
          (match node_id ~path:(path @ [ "node" ]) raw_node with
           | Error _ as error -> error
           | Ok node_id ->
             (match pointer ~path:(path @ [ "pointer" ]) raw_pointer with
              | Error _ as error -> error
              | Ok pointer -> Ok (Plan.Json_template.output ~node_id ~pointer)))))

and parse_object_template ~path fields =
  match validate_fields ~path ~allowed:[ "kind"; "fields" ] fields with
  | Error _ as error -> error
  | Ok () ->
    (match required_field ~path "fields" fields with
     | Error _ as error -> error
     | Ok raw_fields ->
       (match array_values ~path ~field:"fields" raw_fields with
        | Error _ as error -> error
        | Ok raw_fields ->
          let rec parse_fields index parsed = function
            | [] ->
              (match Plan.Json_template.object_ (List.rev parsed) with
               | Ok template -> Ok template
               | Error (Plan.Json_template.Duplicate_field field) ->
                 Error (Duplicate_template_object_field { path; field }))
            | raw_field :: rest ->
              let field_path = path @ [ "fields"; string_of_int index ] in
              (match table_fields ~path:field_path ~field:"field" raw_field with
               | Error _ as error -> error
               | Ok field_fields ->
                 (match
                    validate_fields
                      ~path:field_path
                      ~allowed:[ "name"; "value" ]
                      field_fields
                  with
                  | Error _ as error -> error
                  | Ok () ->
                    (match required_nonempty_string ~path:field_path "name" field_fields with
                     | Error _ as error -> error
                     | Ok name ->
                       (match required_field ~path:field_path "value" field_fields with
                        | Error _ as error -> error
                        | Ok value ->
                          (match parse_template ~path:(field_path @ [ "value" ]) value with
                           | Error _ as error -> error
                           | Ok value ->
                             parse_fields (index + 1) ((name, value) :: parsed) rest)))))
          in
          parse_fields 0 [] raw_fields))

and parse_array_template ~path fields =
  match validate_fields ~path ~allowed:[ "kind"; "items" ] fields with
  | Error _ as error -> error
  | Ok () ->
    (match required_field ~path "items" fields with
     | Error _ as error -> error
     | Ok raw_items ->
       (match array_values ~path ~field:"items" raw_items with
        | Error _ as error -> error
        | Ok raw_items ->
          let rec parse_items index parsed = function
            | [] -> Ok (Plan.Json_template.array (List.rev parsed))
            | item :: rest ->
              (match parse_template ~path:(path @ [ "items"; string_of_int index ]) item with
               | Error _ as error -> error
               | Ok item -> parse_items (index + 1) (item :: parsed) rest)
          in
          parse_items 0 [] raw_items))
;;

let parse_node ~path value =
  match table_fields ~path ~field:"node" value with
  | Error _ as error -> error
  | Ok fields ->
    (match validate_fields ~path ~allowed:[ "id"; "tool"; "after"; "input" ] fields with
     | Error _ as error -> error
     | Ok () ->
       (match required_nonempty_string ~path "id" fields with
        | Error _ as error -> error
        | Ok raw_id ->
          (match required_nonempty_string ~path "tool" fields with
           | Error _ as error -> error
           | Ok tool_name ->
             (match
                match List.assoc_opt "after" fields with
                | None -> Ok []
                | Some value -> string_array ~path ~field:"after" value
              with
              | Error _ as error -> error
              | Ok raw_after ->
                (match required_field ~path "input" fields with
                 | Error _ as error -> error
                 | Ok raw_input ->
                   (match node_id ~path:(path @ [ "id" ]) raw_id with
                    | Error _ as error -> error
                    | Ok id ->
                      let rec parse_after index parsed = function
                        | [] -> Ok (List.rev parsed)
                        | raw :: rest ->
                          (match node_id ~path:(path @ [ "after"; string_of_int index ]) raw with
                           | Error _ as error -> error
                           | Ok id -> parse_after (index + 1) (id :: parsed) rest)
                      in
                      (match parse_after 0 [] raw_after with
                       | Error _ as error -> error
                       | Ok after ->
                         (match parse_template ~path:(path @ [ "input" ]) raw_input with
                          | Error _ as error -> error
                          | Ok input -> Ok (Plan.node ~id ~tool_name ~after ~input ())))))))))
;;

let parse_composition ~index value =
  let path = [ "compositions"; string_of_int index ] in
  match table_fields ~path ~field:"composition" value with
  | Error _ as error -> error
  | Ok fields ->
    (match
       validate_fields
         ~path
         ~allowed:[ "name"; "description"; "execution"; "nodes" ]
         fields
     with
     | Error _ as error -> error
     | Ok () ->
       (match required_nonempty_string ~path "name" fields with
       | Error _ as error -> error
       | Ok name ->
         if String.length name > maximum_composition_name_bytes
         then
           Error
             (Composition_name_too_long
                { name; maximum_bytes = maximum_composition_name_bytes })
         else
           (match
              String.to_seq name
              |> Seq.find (function
                | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> false
                | _ -> true)
            with
            | Some character ->
              Error (Invalid_composition_name_character { name; character })
            | None ->
           (match optional_string ~path "description" fields with
           | Error _ as error -> error
           | Ok description ->
             (match required_string ~path "execution" fields with
              | Error _ as error -> error
              | Ok raw_execution ->
                (match raw_execution with
                 | "inline" -> Ok Inline
                 | "async" -> Ok Async
                 | mode -> Error (Invalid_execution_mode { path; mode }))
                |> (function
                 | Error _ as error -> error
                 | Ok execution ->
             (match required_field ~path "nodes" fields with
              | Error _ as error -> error
              | Ok raw_nodes ->
                (match table_array ~path ~field:"nodes" raw_nodes with
                 | Error _ as error -> error
                 | Ok raw_nodes ->
                   let rec parse_nodes index parsed = function
                     | [] -> Ok (List.rev parsed)
                     | node :: rest ->
                       (match parse_node ~path:(path @ [ "nodes"; string_of_int index ]) node with
                        | Error _ as error -> error
                        | Ok node -> parse_nodes (index + 1) (node :: parsed) rest)
                   in
                   (match parse_nodes 0 [] raw_nodes with
                    | Error _ as error -> error
                    | Ok nodes ->
                      (match
                         Plan.create
                           ~descriptors:(Keeper_tool_descriptor.all_descriptors ())
                           nodes
                       with
                       | Error error -> Error (Plan_rejected { name; error })
                       | Ok plan ->
                         (match execution with
                          | Inline -> Ok { name; description; execution; plan }
                          | Async ->
                            (match
                               Plan.nodes plan
                               |> List.find_map (fun (node : Plan.node) ->
                                 match Plan.descriptor plan node.id with
                                 | Some descriptor
                                   when Keeper_tool_descriptor.readonly_static_hint
                                          descriptor
                                        = Some true ->
                                   None
                                 | Some _ | None -> Some node)
                             with
                             | None -> Ok { name; description; execution; plan }
                             | Some node ->
                               Error
                                 (Async_tool_not_statically_read_only
                                    { name
                                    ; node_id = node.id
                                    ; tool_name = node.tool_name
                                    })))))))))))))
;;

let parse content =
  match Toml.parse_toml content with
  | Error message -> Error (Toml_syntax message)
  | Ok fields ->
    (match validate_fields ~path:[] ~allowed:[ "compositions" ] fields with
     | Error _ as error -> error
     | Ok () ->
       (match required_field ~path:[] "compositions" fields with
        | Error _ -> Error Empty_catalog
        | Ok raw_compositions ->
          (match table_array ~path:[] ~field:"compositions" raw_compositions with
           | Error _ as error -> error
           | Ok [] -> Error Empty_catalog
           | Ok raw_compositions ->
             let rec parse_entries index parsed = function
               | [] -> Ok (List.rev parsed)
               | composition :: rest ->
                 (match parse_composition ~index composition with
                  | Error _ as error -> error
                  | Ok entry ->
                    (match List.find_opt (fun current -> String.equal current.name entry.name) parsed with
                     | Some _ -> Error (Duplicate_composition_name entry.name)
                     | None -> parse_entries (index + 1) (entry :: parsed) rest))
             in
             parse_entries 0 [] raw_compositions)))
;;

let node_id_to_string = Keeper_tool_plan.Node_id.to_string

let plan_error_to_string = function
  | Keeper_tool_plan.Empty_plan -> "plan has no nodes"
  | Keeper_tool_plan.Unknown_descriptor_id id ->
    Printf.sprintf "descriptor id %S is not canonical" id
  | Keeper_tool_plan.Duplicate_node_id node_id ->
    Printf.sprintf "duplicate node id %S" (node_id_to_string node_id)
  | Keeper_tool_plan.Duplicate_tool_name tool_name ->
    Printf.sprintf "descriptor tool name %S is ambiguous" tool_name
  | Keeper_tool_plan.Unknown_tool { node_id; tool_name } ->
    Printf.sprintf
      "node %S names unknown tool %S"
      (node_id_to_string node_id)
      tool_name
  | Keeper_tool_plan.Missing_dependency { node_id; dependency } ->
    Printf.sprintf
      "node %S depends on missing node %S"
      (node_id_to_string node_id)
      (node_id_to_string dependency)
  | Keeper_tool_plan.Opaque_output_reference
      { node_id; source_node_id; source_tool_name } ->
    Printf.sprintf
      "node %S references opaque output from node %S (%s)"
      (node_id_to_string node_id)
      (node_id_to_string source_node_id)
      source_tool_name
  | Keeper_tool_plan.Invalid_output_pointer
      { node_id; source_node_id; pointer; _ } ->
    Printf.sprintf
      "node %S has invalid output pointer /%s for node %S"
      (node_id_to_string node_id)
      (String.concat "/" (Keeper_tool_plan.Json_pointer.segments pointer))
      (node_id_to_string source_node_id)
  | Keeper_tool_plan.Invalid_output_schema { node_id; tool_name; _ } ->
    Printf.sprintf
      "node %S tool %S declares an invalid composable output schema"
      (node_id_to_string node_id)
      tool_name
  | Keeper_tool_plan.Multiple_terminal_nodes node_ids ->
    Printf.sprintf
      "plan has multiple terminal nodes: %s"
      (node_ids |> List.map node_id_to_string |> String.concat ", ")
  | Keeper_tool_plan.Terminal_node_missing_dependency
      { terminal_node_id; node_id } ->
    Printf.sprintf
      "terminal node %S does not depend on node %S"
      (node_id_to_string terminal_node_id)
      (node_id_to_string node_id)
  | Keeper_tool_plan.Dependency_cycle node_ids ->
    Printf.sprintf
      "plan dependency cycle: %s"
      (node_ids |> List.map node_id_to_string |> String.concat " -> ")
;;

let error_to_string = function
  | Toml_syntax detail -> "invalid TOML: " ^ detail
  | Empty_catalog -> "catalog must declare at least one composition"
  | Unknown_field { path; field } ->
    Printf.sprintf "unknown field %S at %s" field (String.concat "." path)
  | Duplicate_field { path; field } ->
    Printf.sprintf "duplicate field %S at %s" field (String.concat "." path)
  | Missing_field { path; field } ->
    Printf.sprintf "missing field %S at %s" field (String.concat "." path)
  | Wrong_value_kind { path; field; _ } ->
    Printf.sprintf "wrong value kind for %S at %s" field (String.concat "." path)
  | Empty_name { path } -> "empty name at " ^ String.concat "." path
  | Composition_name_too_long { name; maximum_bytes } ->
    Printf.sprintf
      "composition name %S exceeds %d bytes"
      name
      maximum_bytes
  | Invalid_composition_name_character { name; character } ->
    Printf.sprintf "composition name %S contains unsupported character %C" name character
  | Duplicate_composition_name name -> "duplicate composition name: " ^ name
  | Invalid_execution_mode { path; mode } ->
    Printf.sprintf
      "invalid execution mode %S at %s (expected inline or async)"
      mode
      (String.concat "." path)
  | Async_tool_not_statically_read_only { name; node_id; tool_name } ->
    Printf.sprintf
      "async composition %S node %S tool %S is not statically read-only"
      name
      (node_id_to_string node_id)
      tool_name
  | Invalid_template_kind { path; kind } ->
    Printf.sprintf "invalid template kind %S at %s" kind (String.concat "." path)
  | Invalid_node_id { path; _ } -> "invalid node id at " ^ String.concat "." path
  | Invalid_json_pointer { path; _ } ->
    "invalid JSON pointer at " ^ String.concat "." path
  | Duplicate_template_object_field { path; field } ->
    Printf.sprintf
      "duplicate template object field %S at %s"
      field
      (String.concat "." path)
  | Plan_rejected { name; error } ->
    Printf.sprintf "composition %S rejected: %s" name (plan_error_to_string error)
;;
