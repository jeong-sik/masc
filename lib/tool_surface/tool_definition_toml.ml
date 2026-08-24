(* See tool_definition_toml.mli. *)

let sprintf = Printf.sprintf
let ( let* ) = Result.bind

(* ── Closed vocabularies ──────────────────────────────────────────────── *)

(* JSON Schema [type] values a param may declare. The vocabulary grows only
   when a consumer grows; an unknown value is a boot error, never a default. *)
type param_type =
  | Ptype_string
  | Ptype_integer
  | Ptype_number
  | Ptype_boolean
  | Ptype_object
  | Ptype_array

let param_type_of_string = function
  | "string" -> Ok Ptype_string
  | "integer" -> Ok Ptype_integer
  | "number" -> Ok Ptype_number
  | "boolean" -> Ok Ptype_boolean
  | "object" -> Ok Ptype_object
  | "array" -> Ok Ptype_array
  | other -> Error (sprintf "unknown type %S" other)
;;

let param_type_to_string = function
  | Ptype_string -> "string"
  | Ptype_integer -> "integer"
  | Ptype_number -> "number"
  | Ptype_boolean -> "boolean"
  | Ptype_object -> "object"
  | Ptype_array -> "array"
;;

(* ── TOML value accessors ─────────────────────────────────────────────── *)

let toml_shape = function
  | Otoml.TomlString _ -> "a string"
  | Otoml.TomlInteger _ -> "an integer"
  | Otoml.TomlFloat _ -> "a float"
  | Otoml.TomlBoolean _ -> "a boolean"
  | Otoml.TomlOffsetDateTime _ -> "an offset datetime"
  | Otoml.TomlLocalDateTime _ -> "a local datetime"
  | Otoml.TomlLocalDate _ -> "a local date"
  | Otoml.TomlLocalTime _ -> "a local time"
  | Otoml.TomlArray _ -> "an array"
  | Otoml.TomlTable _ -> "a table"
  | Otoml.TomlInlineTable _ -> "an inline table"
  | Otoml.TomlTableArray _ -> "an array of tables"
;;

let as_string ~context = function
  | Otoml.TomlString value -> Ok value
  | ( Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a string, got %s" context (toml_shape other))
;;

let as_non_empty_string ~context value =
  let* text = as_string ~context value in
  if String.equal (String.trim text) ""
  then Error (sprintf "%s must not be empty" context)
  else Ok text
;;

let as_bool ~context = function
  | Otoml.TomlBoolean value -> Ok value
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a boolean, got %s" context (toml_shape other))
;;

let as_int ~context = function
  | Otoml.TomlInteger value -> Ok value
  | ( Otoml.TomlString _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be an integer, got %s" context (toml_shape other))
;;

let as_table_pairs ~context = function
  | Otoml.TomlTable pairs | Otoml.TomlInlineTable pairs -> Ok pairs
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) as other ->
    Error (sprintf "%s must be a table, got %s" context (toml_shape other))
;;

let as_string_list ~context value =
  let element index item =
    as_string ~context:(sprintf "%s[%d]" context index) item
  in
  match value with
  | Otoml.TomlArray items ->
    let rec collect index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* text = element index item in
        collect (index + 1) (text :: acc) rest
    in
    collect 0 [] items
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be an array of strings, got %s" context (toml_shape other))
;;

(* ── Shared helpers ───────────────────────────────────────────────────── *)

let find_param_type ~context pairs =
  match List.assoc_opt "type" pairs with
  | None -> Error (sprintf "%s is missing the required key \"type\"" context)
  | Some value ->
    let* raw = as_string ~context:(sprintf "%s.type" context) value in
    (match param_type_of_string raw with
     | Ok declared -> Ok declared
     | Error message -> Error (sprintf "%s.type: %s" context message))
;;

let only_for ~context ~declared allowed =
  if declared = allowed
  then Ok ()
  else
    Error
      (sprintf
         "%s is only valid for type %s params, this param is type %s"
         context
         (param_type_to_string allowed)
         (param_type_to_string declared))
;;

let ensure_unique_names ~context names =
  let rec walk seen = function
    | [] -> Ok ()
    | name :: rest ->
      if List.exists (String.equal name) seen
      then Error (sprintf "%s declares %S twice" context name)
      else walk (name :: seen) rest
  in
  walk [] names
;;

(* Fold [pairs] in document order through [field], keeping the emitted JSON
   pairs in that same order. This is what makes a migrated definition
   byte-comparable with the OCaml literal it replaced. *)
let ordered_fields ~field pairs =
  let rec walk acc = function
    | [] -> Ok (List.rev acc)
    | (key, value) :: rest ->
      let* emitted = field key value in
      (match emitted with
       | None -> walk acc rest
       | Some pair -> walk (pair :: acc) rest)
  in
  walk [] pairs
;;

(* ── One parameter grammar, used at every depth ──────────────────────────
   A parameter can be an object with its own [params], and one of those can be
   an array whose [items] are objects with [params] again. The two shapes were
   separate functions with separate key sets, so a schema nested one level
   deeper than the writer anticipated was rejected as an unknown key rather
   than parsed. masc_add_task.contract, masc_transition.handoff_context and
   masc_batch_add_tasks.tasks are all that shape and could not move to TOML at
   all. The grammar is written once here and recurses; a level that JSON Schema
   allows is a level this reads. *)

type parsed_param =
  { param_name : string
  ; param_required : bool
  ; param_json : Yojson.Safe.t
  }

let rec param_of_pairs ~context pairs =
  let* name =
    match List.assoc_opt "name" pairs with
    | None -> Error (sprintf "%s is missing the required key \"name\"" context)
    | Some value -> as_non_empty_string ~context:(sprintf "%s.name" context) value
  in
  let context = sprintf "%s (%s)" context name in
  let* declared = find_param_type ~context pairs in
  let* required =
    match List.assoc_opt "required" pairs with
    | None -> Ok false
    | Some value -> as_bool ~context:(sprintf "%s.required" context) value
  in
  let field key value =
    let key_context = sprintf "%s.%s" context key in
    match key with
    | "name" | "required" -> Ok None
    | "type" -> Ok (Some ("type", `String (param_type_to_string declared)))
    | "description" ->
      let* text = as_non_empty_string ~context:key_context value in
      Ok (Some ("description", `String text))
    | "enum" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* values = as_string_list ~context:key_context value in
      let* () =
        match values with
        | [] -> Error (sprintf "%s must not be empty" key_context)
        | _ :: _ -> Ok ()
      in
      Ok (Some ("enum", `List (List.map (fun v -> `String v) values)))
    | "default" ->
      (match declared with
       | Ptype_integer ->
         let* v = as_int ~context:key_context value in
         Ok (Some ("default", `Int v))
       | Ptype_boolean ->
         let* v = as_bool ~context:key_context value in
         Ok (Some ("default", `Bool v))
       | Ptype_string | Ptype_number | Ptype_object | Ptype_array ->
         Error
           (sprintf
              "%s is not supported for type %s"
              key_context
              (param_type_to_string declared)))
    | "minimum" | "maximum" ->
      let* () = only_for ~context:key_context ~declared Ptype_integer in
      let* v = as_int ~context:key_context value in
      Ok (Some (key, `Int v))
    | "max_length" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* v = as_int ~context:key_context value in
      Ok (Some ("maxLength", `Int v))
    | "min_length" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* v = as_int ~context:key_context value in
      Ok (Some ("minLength", `Int v))
    | "pattern" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* v = as_non_empty_string ~context:key_context value in
      Ok (Some ("pattern", `String v))
    | "max_items" ->
      let* () = only_for ~context:key_context ~declared Ptype_array in
      let* v = as_int ~context:key_context value in
      Ok (Some ("maxItems", `Int v))
    | "additional_properties" ->
      let* () = only_for ~context:key_context ~declared Ptype_object in
      let* v = as_bool ~context:key_context value in
      Ok (Some ("additionalProperties", `Bool v))
    | "params" ->
      let* () = only_for ~context:key_context ~declared Ptype_object in
      let* parsed = params_of_value ~context:key_context value in
      Ok (Some ("properties", `Assoc (List.map (fun p -> p.param_name, p.param_json) parsed)))
    | "items" ->
      let* () = only_for ~context:key_context ~declared Ptype_array in
      let* item_pairs = as_table_pairs ~context:key_context value in
      let* json = items_json ~context:key_context item_pairs in
      Ok (Some ("items", json))
    | other -> Error (sprintf "%s: unknown key %S" context other)
  in
  let* fields = ordered_fields ~field pairs in
  (* A nested object carries its children's [required] as a sibling list, the
     same way the top level does. The child's own [required = true] is read
     here rather than emitted into the child, so the list sits where JSON
     Schema puts it. *)
  let* fields =
    match declared, List.assoc_opt "params" pairs with
    | Ptype_object, Some value ->
      let* parsed = params_of_value ~context value in
      (match List.filter (fun p -> p.param_required) parsed with
       | [] -> Ok fields
       | needed ->
         Ok
           (fields
            @ [ ( "required"
                , `List (List.map (fun p -> `String p.param_name) needed) )
              ]))
    | _ -> Ok fields
  in
  Ok { param_name = name; param_required = required; param_json = `Assoc fields }

and params_of_value ~context value =
  match value with
  | Otoml.TomlTableArray tables ->
    let element index table =
      let element_context = sprintf "%s[%d]" context index in
      let* pairs = as_table_pairs ~context:element_context table in
      param_of_pairs ~context:element_context pairs
    in
    let rec collect index acc = function
      | [] -> Ok (List.rev acc)
      | table :: rest ->
        let* parsed = element index table in
        collect (index + 1) (parsed :: acc) rest
    in
    let* parsed = collect 0 [] tables in
    let* () = ensure_unique_names ~context (List.map (fun p -> p.param_name) parsed) in
    Ok parsed
  | Otoml.TomlArray [] ->
    Error (sprintf "%s must not be an empty array; omit the key instead" context)
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray (_ :: _)
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ) as other ->
    Error (sprintf "%s must be an array of tables, got %s" context (toml_shape other))

and items_json ~context pairs =
  let* declared = find_param_type ~context pairs in
  let* () =
    match declared with
    | Ptype_string | Ptype_object -> Ok ()
    | Ptype_integer | Ptype_number | Ptype_boolean | Ptype_array ->
      Error
        (sprintf
           "%s.type %s is not supported for items"
           context
           (param_type_to_string declared))
  in
  let field key value =
    let key_context = sprintf "%s.%s" context key in
    match key with
    | "type" -> Ok (Some ("type", `String (param_type_to_string declared)))
    (* An element carries the same constraints a parameter of that type does.
       The two key sets used to differ, so a string element could not say how
       short it may be even though a string parameter could. *)
    | "description" ->
      let* text = as_non_empty_string ~context:key_context value in
      Ok (Some ("description", `String text))
    | "min_length" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* v = as_int ~context:key_context value in
      Ok (Some ("minLength", `Int v))
    | "max_length" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* v = as_int ~context:key_context value in
      Ok (Some ("maxLength", `Int v))
    | "pattern" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* v = as_non_empty_string ~context:key_context value in
      Ok (Some ("pattern", `String v))
    | "additional_properties" ->
      let* () = only_for ~context:key_context ~declared Ptype_object in
      let* v = as_bool ~context:key_context value in
      Ok (Some ("additionalProperties", `Bool v))
    | "params" ->
      (match declared with
       | Ptype_object ->
         let* parsed = params_of_value ~context:key_context value in
         Ok
           (Some
              ("properties", `Assoc (List.map (fun p -> p.param_name, p.param_json) parsed)))
       | Ptype_string | Ptype_integer | Ptype_number | Ptype_boolean
       | Ptype_array ->
         Error (sprintf "%s is only valid when the items type is object" key_context))
    | other -> Error (sprintf "%s: unknown key %S" context other)
  in
  let* fields = ordered_fields ~field pairs in
  (* Array items of type object declare their fields or declare nothing: an
     items table with no [params] is a shape no caller can satisfy. A
     top-level object parameter is not held to this — the fixture's [meta]
     is an open bag by design. *)
  let* params =
    match declared, List.assoc_opt "params" pairs with
    | Ptype_object, None ->
      Error (sprintf "%s of type object must declare params" context)
    | Ptype_object, Some value -> params_of_value ~context value
    | _ -> Ok []
  in
  (* Same rule as a nested object: the item's required children are listed on
     the item, not marked on each child. *)
  let fields =
    match List.filter (fun p -> p.param_required) params with
    | [] -> fields
    | needed ->
      fields @ [ "required", `List (List.map (fun p -> `String p.param_name) needed) ]
  in
  Ok (`Assoc fields)
;;

(* ── Tool definition ──────────────────────────────────────────────────── *)

type loaded =
  { schema : Masc_domain.tool_schema
  ; keeper_projection : Masc_domain.tool_schema option
  }

let assemble_input_schema ~params ~additional_properties : Yojson.Safe.t =
  let properties = List.map (fun p -> p.param_name, p.param_json) params in
  let required =
    params
    |> List.filter (fun p -> p.param_required)
    |> List.map (fun p -> `String p.param_name)
  in
  `Assoc
    ([ "type", `String "object"; "properties", `Assoc properties ]
     @ (match required with
        | [] -> []
        | _ :: _ -> [ "required", `List required ])
     @ (match additional_properties with
        | None -> []
        | Some flag -> [ "additionalProperties", `Bool flag ]))
;;

let keeper_projection_of_pairs ~name pairs =
  let context = "keeper_projection" in
  let* description =
    match List.assoc_opt "description" pairs with
    | None -> Error (sprintf "%s is missing the required key \"description\"" context)
    | Some value ->
      as_non_empty_string ~context:(sprintf "%s.description" context) value
  in
  let* additional_properties =
    match List.assoc_opt "additional_properties" pairs with
    | None -> Ok None
    | Some value ->
      let* flag =
        as_bool ~context:(sprintf "%s.additional_properties" context) value
      in
      Ok (Some flag)
  in
  let* params =
    match List.assoc_opt "params" pairs with
    | None -> Ok []
    | Some value -> params_of_value ~context:(sprintf "%s.params" context) value
  in
  let* () =
    let known key =
      List.exists
        (String.equal key)
        [ "description"; "additional_properties"; "params" ]
    in
    let rec walk = function
      | [] -> Ok ()
      | (key, (_ : Otoml.t)) :: rest ->
        if known key
        then walk rest
        else Error (sprintf "%s: unknown key %S" context key)
    in
    walk pairs
  in
  Ok
    { Masc_domain.name
    ; description
    ; input_schema = assemble_input_schema ~params ~additional_properties
    }
;;

let tool_of_pairs ~name pairs =
  let* declared_name =
    match List.assoc_opt "name" pairs with
    | None -> Error "missing the required key \"name\""
    | Some value -> as_non_empty_string ~context:"name" value
  in
  let* () =
    if String.equal declared_name name
    then Ok ()
    else
      Error
        (sprintf "declares name %S but the file name requires %S" declared_name name)
  in
  let* description =
    match List.assoc_opt "description" pairs with
    | None -> Error "missing the required key \"description\""
    | Some value -> as_non_empty_string ~context:"description" value
  in
  let* additional_properties =
    match List.assoc_opt "additional_properties" pairs with
    | None -> Ok None
    | Some value ->
      let* flag = as_bool ~context:"additional_properties" value in
      Ok (Some flag)
  in
  let* params =
    match List.assoc_opt "params" pairs with
    | None -> Ok []
    | Some value -> params_of_value ~context:"params" value
  in
  let* keeper_projection =
    match List.assoc_opt "keeper_projection" pairs with
    | None -> Ok None
    | Some value ->
      let* projection_pairs = as_table_pairs ~context:"keeper_projection" value in
      let* projection =
        keeper_projection_of_pairs ~name:declared_name projection_pairs
      in
      Ok (Some projection)
  in
  let* () =
    let known key =
      List.exists
        (String.equal key)
        [ "name"
        ; "description"
        ; "additional_properties"
        ; "params"
        ; "keeper_projection"
        ]
    in
    let rec walk = function
      | [] -> Ok ()
      | (key, (_ : Otoml.t)) :: rest ->
        if known key then walk rest else Error (sprintf "unknown key %S" key)
    in
    walk pairs
  in
  Ok
    { schema =
        { Masc_domain.name = declared_name
        ; description
        ; input_schema = assemble_input_schema ~params ~additional_properties
        }
    ; keeper_projection
    }
;;

let load ~name ~contents =
  match Otoml.Parser.from_string_result contents with
  | Error message -> Error (sprintf "tool definition %s: TOML parse error: %s" name message)
  | Ok (Otoml.TomlTable pairs) ->
    (match tool_of_pairs ~name pairs with
     | Ok schema -> Ok schema
     | Error message -> Error (sprintf "tool definition %s: %s" name message))
  | Ok
      ( ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
        | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
        | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
        | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlInlineTable _
        | Otoml.TomlTableArray _ ) as other ) ->
    Error
      (sprintf "tool definition %s: top level must be a table, got %s" name (toml_shape other))
;;

(* ── Embedded tree validation ─────────────────────────────────────────── *)

let tools_asset_prefix = "tools/"
let manifest_relative_path = tools_asset_prefix ^ "managed-assets.json"

let validate_embedded ~read ~files =
  let validate_one acc rel =
    let* () = acc in
    if not (String.starts_with ~prefix:tools_asset_prefix rel)
    then Ok ()
    else if String.equal rel manifest_relative_path
    then Ok ()
    else if not (String.equal (Filename.dirname rel) "tools")
    then Error (sprintf "tool definitions must sit directly under tools/: %s" rel)
    else if not (Filename.check_suffix rel ".toml")
    then Error (sprintf "unexpected file in the embedded tool definition tree: %s" rel)
    else (
      let name = Filename.remove_extension (Filename.basename rel) in
      match read rel with
      | None -> Error (sprintf "embedded tool definition unreadable: %s" rel)
      | Some contents ->
        (match load ~name ~contents with
         | Ok (_ : loaded) -> Ok ()
         | Error message -> Error message))
  in
  List.fold_left validate_one (Ok ()) files
;;
