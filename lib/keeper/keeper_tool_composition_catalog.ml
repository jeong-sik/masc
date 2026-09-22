module Toml = Keeper_toml_loader
module Plan = Keeper_tool_plan

type expected_value =
  | String_value
  | String_array_value
  | Table_value
  | Table_array_value
  | Array_value

type enum_value_fault =
  | Empty_value
  | Padded_value
  | Line_break_in_value
  | Separator_in_value

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
  | Invalid_param_type of
      { path : string list
      ; type_name : string
      }
  | Param_enum_requires_string_type of
      { path : string list
      ; type_name : string
      }
  | Empty_param_enum of { path : string list }
  | Unsendable_param_enum_value of
      { path : string list
      ; value : string
      ; fault : enum_value_fault
      }
  | Duplicate_param_enum_value of
      { path : string list
      ; value : string
      }
  | Duplicate_param_name of
      { name : string
      ; param : string
      }
  | Unknown_param_reference of
      { name : string
      ; param : string
      }
  | Unused_param of
      { name : string
      ; param : string
      }
  | Plan_rejected of
      { name : string
      ; error : Plan.error
      }

type execution_mode =
  | Inline
  | Async

type param_type =
  | String_param
  | Integer_param
  | Number_param
  | Boolean_param
  | Enum_param of string list

type param =
  { param_name : string
  ; param_type : param_type
  ; param_description : string
  }

type entry =
  { name : string
  ; description : string option
  ; execution : execution_mode
  ; params : param list
  ; plan : Plan.t
  }

type t = entry list

let tool_name_prefix = "keeper_compose_"
let maximum_tool_name_bytes = 64
let maximum_composition_name_bytes = maximum_tool_name_bytes - String.length tool_name_prefix
let tool_name entry = tool_name_prefix ^ entry.name

(* Where the definition behind a composition tool lives, relative to the masc
   directory. Composed from the name rather than looked up, and that is sound
   here in a way it would not be for a shipped asset: this tool exists only
   because a SKILL.md at that path was read into the catalog. A name without
   the prefix is some other tool and answers [None]. *)
let skill_name_of_tool_name name =
  if String.starts_with ~prefix:tool_name_prefix name
  then (
    let skill =
      String.sub
        name
        (String.length tool_name_prefix)
        (String.length name - String.length tool_name_prefix)
    in
    if String.equal skill "" then None else Some skill)
  else None
;;

let skill_source_of_tool_name name =
  Option.map
    (fun skill -> "skills/" ^ skill ^ "/SKILL.md")
    (skill_name_of_tool_name name)
;;
let status_tool_name = "keeper_composition_status"
let cancel_tool_name = "keeper_composition_cancel"
let skill_tool_name = "keeper_skill"

let execution_mode_to_string = function
  | Inline -> "inline"
  | Async -> "async"
;;

let tool_kind (entry : entry) =
  match entry.execution with
  | Inline -> Keeper_tool_descriptor.Composition_tool
  | Async -> Keeper_tool_descriptor.Async_composition_tool
;;

let status_tool_kind = Keeper_tool_descriptor.Async_composition_tool
let cancel_tool_kind = Keeper_tool_descriptor.Async_composition_tool


let entries catalog = catalog

let find catalog name =
  List.find_opt (fun entry -> String.equal entry.name name) catalog
;;

let first_duplicate fields =
  let rec find_duplicate seen = function
    | [] -> None
    | (name, _) :: rest ->
      if List.mem name seen then Some name else find_duplicate (name :: seen) rest
  in
  find_duplicate [] fields
;;

let first_repeated_string values =
  let rec find_repeated seen = function
    | [] -> None
    | value :: rest ->
      if List.mem value seen then Some value else find_repeated (value :: seen) rest
  in
  find_repeated [] values
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
     | Ok "param" -> parse_param_template ~path fields
     | Ok "object" -> parse_object_template ~path fields
     | Ok "array" -> parse_array_template ~path fields
     | Ok kind -> Error (Invalid_template_kind { path; kind }))

and parse_param_template ~path fields =
  match validate_fields ~path ~allowed:[ "kind"; "name" ] fields with
  | Error _ as error -> error
  | Ok () ->
    (match required_nonempty_string ~path "name" fields with
     | Error _ as error -> error
     | Ok name -> Ok (Plan.Json_template.param ~name))

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

(* A member the model could not send back exactly. A provider that cannot
   carry [enum] gets the members written unquoted into the parameter's own
   description (Agent_core.Types.enum_vocabulary_text), while the call is
   still checked against the exact member. Any separator character in a
   member is refused, not only the spaced form the text uses: ["x |"] next to
   ["y"] would read as ["x"] and ["| y"]. *)
let enum_value_fault value =
  if String.equal value ""
  then Some Empty_value
  else if not (String.equal (String.trim value) value)
  then Some Padded_value
  else if String.contains value '\n' || String.contains value '\r'
  then Some Line_break_in_value
  else if String.contains value Agent_core.Types.enum_member_separator
  then Some Separator_in_value
  else None
;;

let first_unsendable_member ~path members =
  List.find_map
    (fun value ->
       Option.map
         (fun fault -> Unsendable_param_enum_value { path; value; fault })
         (enum_value_fault value))
    members
;;

(* [enum] narrows a string param to a closed member set. The key and the
   list shape are the ones config/tools uses; the accepted members are
   narrower here: strings only, no repeats, nothing empty or padded. The pair
   is read together: an [enum] on any other type has no JSON meaning the
   schema could carry, and an empty or repeated member list declares a
   choice the model cannot make sense of. *)
let parse_param_type ~path ~raw_type fields =
  match raw_type, List.assoc_opt "enum" fields with
  | "string", None -> Ok String_param
  | "string", Some raw_members ->
    (match string_array ~path ~field:"enum" raw_members with
     | Error _ as error -> error
     | Ok [] -> Error (Empty_param_enum { path })
     | Ok members ->
       (match first_unsendable_member ~path members with
        | Some error -> Error error
        | None ->
          (match first_repeated_string members with
           | Some value -> Error (Duplicate_param_enum_value { path; value })
           | None -> Ok (Enum_param members))))
  | "integer", None -> Ok Integer_param
  | "number", None -> Ok Number_param
  | "boolean", None -> Ok Boolean_param
  | ("integer" | "number" | "boolean"), Some _ ->
    Error (Param_enum_requires_string_type { path; type_name = raw_type })
  | type_name, (None | Some _) -> Error (Invalid_param_type { path; type_name })
;;

let parse_params ~path fields =
  match List.assoc_opt "params" fields with
  | None -> Ok []
  | Some raw ->
    (match table_array ~path ~field:"params" raw with
     | Error _ as error -> error
     | Ok raw_params ->
       let rec parse_all index parsed = function
         | [] -> Ok (List.rev parsed)
         | raw_param :: rest ->
           let param_path = path @ [ "params"; string_of_int index ] in
           (match table_fields ~path:param_path ~field:"param" raw_param with
            | Error _ as error -> error
            | Ok param_fields ->
              (match
                 validate_fields
                   ~path:param_path
                   ~allowed:[ "name"; "type"; "enum"; "description" ]
                   param_fields
               with
               | Error _ as error -> error
               | Ok () ->
                 (match
                    required_nonempty_string ~path:param_path "name" param_fields
                  with
                  | Error _ as error -> error
                  | Ok param_name ->
                    (match required_string ~path:param_path "type" param_fields with
                     | Error _ as error -> error
                     | Ok raw_type ->
                       (match
                          parse_param_type ~path:param_path ~raw_type param_fields
                        with
                        | Error _ as error -> error
                        | Ok param_type ->
                          (match
                             required_nonempty_string
                               ~path:param_path
                               "description"
                               param_fields
                           with
                           | Error _ as error -> error
                           | Ok param_description ->
                             parse_all
                               (index + 1)
                               ({ param_name; param_type; param_description }
                                :: parsed)
                               rest))))))
       in
       parse_all 0 [] raw_params)
;;

(* Declared and referenced parameter sets must agree exactly: a reference to
   an undeclared name would fail only at invocation, and a declared name no
   template reads is config without a consumer. *)
let validate_declared_params ~name ~params plan =
  let declared = List.map (fun param -> param.param_name) params in
  match first_repeated_string declared with
  | Some param -> Error (Duplicate_param_name { name; param })
  | None ->
    let used =
      Plan.nodes plan
      |> List.concat_map (fun (node : Plan.node) ->
        Plan.Json_template.param_names node.input)
      |> List.sort_uniq String.compare
    in
    (match List.find_opt (fun param -> not (List.mem param declared)) used with
     | Some param -> Error (Unknown_param_reference { name; param })
     | None ->
       (match List.find_opt (fun param -> not (List.mem param used)) declared with
        | Some param -> Error (Unused_param { name; param })
        | None -> Ok ()))
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
         ~allowed:[ "name"; "description"; "execution"; "params"; "nodes" ]
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
             (match parse_params ~path fields with
              | Error _ as error -> error
              | Ok params ->
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
                         (match validate_declared_params ~name ~params plan with
                          | Error _ as error -> error
                          | Ok () ->
                         (match execution with
                          | Inline ->
                            Ok { name; description; execution; params; plan }
                          | Async ->
                            (
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
                             | None ->
                               Ok { name; description; execution; params; plan }
                             | Some node ->
                               Error
                                 (Async_tool_not_statically_read_only
                                    { name
                                    ; node_id = node.id
                                    ; tool_name = node.tool_name
                                    }))))))))))))))))
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
  | Invalid_param_type { path; type_name } ->
    Printf.sprintf
      "invalid param type %S at %s (expected string, integer, number, or boolean)"
      type_name
      (String.concat "." path)
  | Param_enum_requires_string_type { path; type_name } ->
    Printf.sprintf
      "enum at %s needs type \"string\", not %S"
      (String.concat "." path)
      type_name
  | Empty_param_enum { path } ->
    "enum must list at least one member at " ^ String.concat "." path
  | Unsendable_param_enum_value { path; value; fault } ->
    let problem =
      match fault with
      | Empty_value -> "is empty"
      | Padded_value -> "has leading or trailing whitespace"
      | Line_break_in_value -> "contains a line break"
      | Separator_in_value ->
        Printf.sprintf
          "contains %C, which separates members when they are written into a description"
          Agent_core.Types.enum_member_separator
    in
    Printf.sprintf "enum member %S at %s %s" value (String.concat "." path) problem
  | Duplicate_param_enum_value { path; value } ->
    Printf.sprintf "enum lists member %S twice at %s" value (String.concat "." path)
  | Duplicate_param_name { name; param } ->
    Printf.sprintf "composition %S declares param %S twice" name param
  | Unknown_param_reference { name; param } ->
    Printf.sprintf
      "composition %S references param %S that its params list does not declare"
      name
      param
  | Unused_param { name; param } ->
    Printf.sprintf
      "composition %S declares param %S that no node input references"
      name
      param
  | Plan_rejected { name; error } ->
    Printf.sprintf "composition %S rejected: %s" name (Keeper_tool_plan.error_to_string error)
;;

let param_type_to_string = function
  | String_param | Enum_param _ -> "string"
  | Integer_param -> "integer"
  | Number_param -> "number"
  | Boolean_param -> "boolean"
;;

let param_property_schema param =
  let type_field = "type", `String (param_type_to_string param.param_type) in
  let description_field = "description", `String param.param_description in
  match param.param_type with
  | Enum_param members ->
    `Assoc
      [ type_field
      ; "enum", `List (List.map (fun member -> `String member) members)
      ; description_field
      ]
  | String_param | Integer_param | Number_param | Boolean_param ->
    `Assoc [ type_field; description_field ]
;;

let input_schema_of_params = function
  | [] ->
    (* Mirrors the surface's zero-param schema: no ["required"] key, because
       an empty one says nothing an absent one does not. *)
    `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc []
      ; "additionalProperties", `Bool false
      ]
  | params ->
    `Assoc
      [ "type", `String "object"
      ; ( "properties"
        , `Assoc
            (List.map
               (fun param -> param.param_name, param_property_schema param)
               params) )
      ; ( "required"
        , `List (List.map (fun param -> `String param.param_name) params) )
      ; "additionalProperties", `Bool false
      ]
;;

type instantiation_error =
  | Missing_argument of string
  | Instantiated_plan_rejected of Plan.error

let instantiation_error_to_string = function
  | Missing_argument param -> Printf.sprintf "missing required argument %S" param
  | Instantiated_plan_rejected error ->
    "instantiated plan rejected: " ^ Plan.error_to_string error
;;

let instantiation_error_to_json = function
  | Missing_argument param ->
    `Assoc [ "kind", `String "missing_argument"; "argument", `String param ]
  | Instantiated_plan_rejected error ->
    `Assoc
      [ "kind", `String "instantiated_plan_rejected"
      ; "error", Plan.error_to_json error
      ]
;;

(* Bind one invocation's arguments into the entry's plan. The declared plan
   keeps its [Param] leaves for the catalog's lifetime; execution takes the
   param-free copy built here, revalidated by the same [Plan.create] that
   admitted the declaration, so the executor never meets an unbound name. *)
let instantiate ~descriptors ~args entry =
  let lookup name =
    match args with
    | `Assoc fields -> List.assoc_opt name fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _
    | `Tuple _ | `Variant _ -> None
  in
  let rec rebuild rebuilt = function
    | [] ->
      (match Plan.create ~descriptors (List.rev rebuilt) with
       | Ok plan -> Ok plan
       | Error error -> Error (Instantiated_plan_rejected error))
    | (node : Plan.node) :: rest ->
      (match Plan.Json_template.substitute_params ~lookup node.input with
       | Error (Plan.Json_template.Missing_param param) ->
         Error (Missing_argument param)
       | Ok input ->
         rebuild
           (Plan.node ~id:node.id ~tool_name:node.tool_name ~after:node.after ~input ()
            :: rebuilt)
           rest)
  in
  rebuild [] (Plan.nodes entry.plan)
;;
