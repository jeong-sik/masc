module Plan = Keeper_tool_plan

type template_error =
  | Template_not_an_object of { found : string }
  | Template_missing_kind
  | Template_unknown_kind of string
  | Template_missing_field of
      { kind : string
      ; field : string
      }
  | Template_invalid_field of
      { kind : string
      ; field : string
      ; found : string
      }
  | Template_invalid_pointer of { pointer : string }
  | Template_duplicate_object_field of string

type error =
  | Request_not_an_object of { found : string }
  | Missing_nodes
  | Nodes_not_an_array of { found : string }
  | Node_not_an_object of
      { index : int
      ; found : string
      }
  | Node_missing_field of
      { index : int
      ; field : string
      }
  | Node_invalid_field of
      { index : int
      ; field : string
      ; found : string
      }
  | Node_empty_id of { index : int }
  | Node_template_error of
      { index : int
      ; error : template_error
      }
  | Unknown_request_field of { field : string }
  | Plan_rejected of Keeper_tool_plan.error

let kind_name = Json_util.kind_name

let template_error_message = function
  | Template_not_an_object { found } ->
    Printf.sprintf "input template must be an object, found %s" found
  | Template_missing_kind -> "input template is missing \"kind\""
  | Template_unknown_kind kind ->
    Printf.sprintf
      "unknown template kind %S (expected literal, output, object, or array)"
      kind
  | Template_missing_field { kind; field } ->
    Printf.sprintf "template kind %S is missing field %S" kind field
  | Template_invalid_field { kind; field; found } ->
    Printf.sprintf "template kind %S field %S has invalid value: %s" kind field found
  | Template_invalid_pointer { pointer } ->
    Printf.sprintf "invalid JSON pointer %S (must start with '/')" pointer
  | Template_duplicate_object_field field ->
    Printf.sprintf "template object declares field %S twice" field
;;

let error_message = function
  | Request_not_an_object { found } ->
    Printf.sprintf "plan request must be an object, found %s" found
  | Missing_nodes -> "plan request is missing \"nodes\""
  | Nodes_not_an_array { found } ->
    Printf.sprintf "\"nodes\" must be an array, found %s" found
  | Node_not_an_object { index; found } ->
    Printf.sprintf "node %d must be an object, found %s" index found
  | Node_missing_field { index; field } ->
    Printf.sprintf "node %d is missing field %S" index field
  | Node_invalid_field { index; field; found } ->
    Printf.sprintf "node %d field %S has invalid value: %s" index field found
  | Node_empty_id { index } -> Printf.sprintf "node %d has an empty id" index
  | Node_template_error { index; error } ->
    Printf.sprintf "node %d input: %s" index (template_error_message error)
  | Unknown_request_field { field } ->
    Printf.sprintf "unknown plan request field %S (only \"nodes\" is accepted)" field
  | Plan_rejected error -> Plan.error_to_string error
;;

let template_error_to_json error =
  let tag name fields = `Assoc (("kind", `String name) :: fields) in
  match error with
  | Template_not_an_object { found } ->
    tag "template_not_an_object" [ "found", `String found ]
  | Template_missing_kind -> tag "template_missing_kind" []
  | Template_unknown_kind kind -> tag "template_unknown_kind" [ "value", `String kind ]
  | Template_missing_field { kind; field } ->
    tag "template_missing_field" [ "template", `String kind; "field", `String field ]
  | Template_invalid_field { kind; field; found } ->
    tag
      "template_invalid_field"
      [ "template", `String kind; "field", `String field; "found", `String found ]
  | Template_invalid_pointer { pointer } ->
    tag "template_invalid_pointer" [ "pointer", `String pointer ]
  | Template_duplicate_object_field field ->
    tag "template_duplicate_object_field" [ "field", `String field ]
;;

let error_to_json error =
  let tag name fields = `Assoc (("kind", `String name) :: fields) in
  match error with
  | Request_not_an_object { found } ->
    tag "request_not_an_object" [ "found", `String found ]
  | Missing_nodes -> tag "missing_nodes" []
  | Nodes_not_an_array { found } -> tag "nodes_not_an_array" [ "found", `String found ]
  | Node_not_an_object { index; found } ->
    tag "node_not_an_object" [ "index", `Int index; "found", `String found ]
  | Node_missing_field { index; field } ->
    tag "node_missing_field" [ "index", `Int index; "field", `String field ]
  | Node_invalid_field { index; field; found } ->
    tag
      "node_invalid_field"
      [ "index", `Int index; "field", `String field; "found", `String found ]
  | Node_empty_id { index } -> tag "node_empty_id" [ "index", `Int index ]
  | Node_template_error { index; error } ->
    tag
      "node_template_error"
      [ "index", `Int index; "error", template_error_to_json error ]
  | Unknown_request_field { field } ->
    tag "unknown_request_field" [ "field", `String field ]
  | Plan_rejected plan_error ->
    tag
      "plan_rejected"
      [ "error", Plan.error_to_json plan_error
      ; "message", `String (Plan.error_to_string plan_error)
      ]
;;

let composable_tool_names ~descriptors =
  descriptors
  |> List.filter_map (fun descriptor ->
    match descriptor.Keeper_tool_descriptor.composable_output with
    | Keeper_tool_descriptor.Opaque_output -> None
    | Keeper_tool_descriptor.Json_output _ ->
      (match Keeper_tool_descriptor.keeper_model_names descriptor with
       | name :: _ -> Some name
       | [] -> None))
  |> List.sort_uniq String.compare
;;

let ( let* ) = Result.bind

let node_id_of_string ~index ~field value =
  match Plan.Node_id.make value with
  | Ok id -> Ok id
  | Error Plan.Node_id.Empty ->
    if String.equal field "id"
    then Error (Node_empty_id { index })
    else Error (Node_invalid_field { index; field; found = "empty string" })
;;

let rec template_of_json json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | None -> Error Template_missing_kind
     | Some (`String "literal") ->
       (match List.assoc_opt "value" fields with
        | None -> Error (Template_missing_field { kind = "literal"; field = "value" })
        | Some value -> Ok (Plan.Json_template.literal value))
     | Some (`String "output") ->
       let* node =
         match List.assoc_opt "node" fields with
         | Some (`String node) -> Ok node
         | Some other ->
           Error
             (Template_invalid_field
                { kind = "output"; field = "node"; found = kind_name other })
         | None -> Error (Template_missing_field { kind = "output"; field = "node" })
       in
       let* node_id =
         match Plan.Node_id.make node with
         | Ok id -> Ok id
         | Error Plan.Node_id.Empty ->
           Error
             (Template_invalid_field
                { kind = "output"; field = "node"; found = "empty string" })
       in
       let* pointer_text =
         match List.assoc_opt "pointer" fields with
         | Some (`String pointer) -> Ok pointer
         | Some other ->
           Error
             (Template_invalid_field
                { kind = "output"; field = "pointer"; found = kind_name other })
         | None ->
           Error (Template_missing_field { kind = "output"; field = "pointer" })
       in
       (match Plan.Json_pointer.of_string pointer_text with
        | Ok pointer -> Ok (Plan.Json_template.output ~node_id ~pointer)
        | Error _ -> Error (Template_invalid_pointer { pointer = pointer_text }))
     | Some (`String "object") ->
       (match List.assoc_opt "fields" fields with
        | None -> Error (Template_missing_field { kind = "object"; field = "fields" })
        | Some (`List entries) ->
          let* parsed =
            List.fold_left
              (fun acc entry ->
                 let* acc = acc in
                 match entry with
                 | `Assoc entry_fields ->
                   let* name =
                     match List.assoc_opt "name" entry_fields with
                     | Some (`String name) -> Ok name
                     | Some other ->
                       Error
                         (Template_invalid_field
                            { kind = "object"
                            ; field = "fields.name"
                            ; found = kind_name other
                            })
                     | None ->
                       Error
                         (Template_missing_field
                            { kind = "object"; field = "fields.name" })
                   in
                   let* value =
                     match List.assoc_opt "value" entry_fields with
                     | Some value -> template_of_json value
                     | None ->
                       Error
                         (Template_missing_field
                            { kind = "object"; field = "fields.value" })
                   in
                   Ok ((name, value) :: acc)
                 | other ->
                   Error
                     (Template_invalid_field
                        { kind = "object"
                        ; field = "fields"
                        ; found = kind_name other
                        }))
              (Ok [])
              entries
          in
          (match Plan.Json_template.object_ (List.rev parsed) with
           | Ok template -> Ok template
           | Error (Plan.Json_template.Duplicate_field field) ->
             Error (Template_duplicate_object_field field))
        | Some other ->
          Error
            (Template_invalid_field
               { kind = "object"; field = "fields"; found = kind_name other }))
     | Some (`String "array") ->
       (match List.assoc_opt "items" fields with
        | None -> Error (Template_missing_field { kind = "array"; field = "items" })
        | Some (`List items) ->
          let* parsed =
            List.fold_left
              (fun acc item ->
                 let* acc = acc in
                 let* template = template_of_json item in
                 Ok (template :: acc))
              (Ok [])
              items
          in
          Ok (Plan.Json_template.array (List.rev parsed))
        | Some other ->
          Error
            (Template_invalid_field
               { kind = "array"; field = "items"; found = kind_name other }))
     | Some (`String kind) -> Error (Template_unknown_kind kind)
     | Some other ->
       Error
         (Template_invalid_field
            { kind = "?"; field = "kind"; found = kind_name other }))
  | other -> Error (Template_not_an_object { found = kind_name other })
;;

let node_of_json ~index json =
  match json with
  | `Assoc fields ->
    let* () =
      List.fold_left
        (fun acc (field, _) ->
           let* () = acc in
           match field with
           | "id" | "tool" | "after" | "input" -> Ok ()
           | other ->
             Error (Node_invalid_field { index; field = other; found = "unexpected" }))
        (Ok ())
        fields
    in
    let* id_text =
      match List.assoc_opt "id" fields with
      | Some (`String id) -> Ok id
      | Some other ->
        Error (Node_invalid_field { index; field = "id"; found = kind_name other })
      | None -> Error (Node_missing_field { index; field = "id" })
    in
    let* id = node_id_of_string ~index ~field:"id" id_text in
    let* tool_name =
      match List.assoc_opt "tool" fields with
      | Some (`String tool) -> Ok tool
      | Some other ->
        Error (Node_invalid_field { index; field = "tool"; found = kind_name other })
      | None -> Error (Node_missing_field { index; field = "tool" })
    in
    let* after =
      match List.assoc_opt "after" fields with
      | None -> Ok []
      | Some (`List entries) ->
        let* ids =
          List.fold_left
            (fun acc entry ->
               let* acc = acc in
               match entry with
               | `String value ->
                 let* id = node_id_of_string ~index ~field:"after" value in
                 Ok (id :: acc)
               | other ->
                 Error
                   (Node_invalid_field
                      { index; field = "after"; found = kind_name other }))
            (Ok [])
            entries
        in
        Ok (List.rev ids)
      | Some other ->
        Error (Node_invalid_field { index; field = "after"; found = kind_name other })
    in
    let* input =
      match List.assoc_opt "input" fields with
      | None -> Ok (Plan.Json_template.literal (`Assoc []))
      | Some template_json ->
        (match template_of_json template_json with
         | Ok template -> Ok template
         | Error error -> Error (Node_template_error { index; error }))
    in
    Ok (Plan.node ~id ~tool_name ~after ~input ())
  | other -> Error (Node_not_an_object { index; found = kind_name other })
;;

let plan_of_json ~descriptors json =
  match json with
  | `Assoc fields ->
    let* () =
      List.fold_left
        (fun acc (field, _) ->
           let* () = acc in
           match field with
           | "nodes" -> Ok ()
           | other -> Error (Unknown_request_field { field = other }))
        (Ok ())
        fields
    in
    (match List.assoc_opt "nodes" fields with
     | None -> Error Missing_nodes
     | Some (`List node_jsons) ->
       let* nodes =
         List.fold_left
           (fun acc (index, node_json) ->
              let* acc = acc in
              let* node = node_of_json ~index node_json in
              Ok (node :: acc))
           (Ok [])
           (List.mapi (fun index node_json -> index, node_json) node_jsons)
       in
       (match Plan.create ~descriptors (List.rev nodes) with
        | Ok plan -> Ok plan
        | Error error -> Error (Plan_rejected error))
     | Some other -> Error (Nodes_not_an_array { found = kind_name other }))
  | other -> Error (Request_not_an_object { found = kind_name other })
;;
