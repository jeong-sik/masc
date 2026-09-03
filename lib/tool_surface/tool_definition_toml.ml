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

let as_provider_portable_pattern ~context value =
  let* pattern = as_non_empty_string ~context value in
  let length = String.length pattern in
  if length >= 2 && Char.equal pattern.[0] '^' && Char.equal pattern.[length - 1] '$'
  then Ok pattern
  else
    Error
      (sprintf
         "%s must start with '^' and end with '$' for native Ollama tool-schema compatibility"
         context)
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

(* TOML tells 0.0 from 0, and so does the schema: a float bound serializes as
   0.0 and an integer one as 0. Accepting an integer here would move the bytes
   of every declaration that carries one. *)
let as_float ~context = function
  | Otoml.TomlFloat value -> Ok value
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be a float, got %s" context (toml_shape other))
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

let as_int_list ~context value =
  let element index item = as_int ~context:(sprintf "%s[%d]" context index) item in
  match value with
  | Otoml.TomlArray items ->
    let rec collect index acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* v = element index item in
        collect (index + 1) (v :: acc) rest
    in
    collect 0 [] items
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) as
    other -> Error (sprintf "%s must be an array of integers, got %s" context (toml_shape other))
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
      (* Members carry the parameter's own type. tool_execute's [fd] enumerates
         1 and 2, and quoting those would declare a different schema than the
         executor reads. *)
      let* items =
        match declared with
        | Ptype_string ->
          let* values = as_string_list ~context:key_context value in
          Ok (List.map (fun v -> `String v) values)
        | Ptype_integer ->
          let* values = as_int_list ~context:key_context value in
          Ok (List.map (fun v -> `Int v) values)
        | Ptype_number | Ptype_boolean | Ptype_object | Ptype_array ->
          Error
            (sprintf
               "%s is only valid for type string or integer params, this param is type %s"
               key_context
               (param_type_to_string declared))
      in
      let* () =
        match items with
        | [] -> Error (sprintf "%s must not be empty" key_context)
        | _ :: _ -> Ok ()
      in
      Ok (Some ("enum", `List items))
    | "default" ->
      (match declared with
       | Ptype_integer ->
         let* v = as_int ~context:key_context value in
         Ok (Some ("default", `Int v))
       | Ptype_boolean ->
         let* v = as_bool ~context:key_context value in
         Ok (Some ("default", `Bool v))
       | Ptype_string ->
         (* A string default names which value a caller gets by omitting the
            key, the same way an integer one does. It was refused, so a tool
            that had one could not be declared here at all. *)
         let* v = as_non_empty_string ~context:key_context value in
         Ok (Some ("default", `String v))
       | Ptype_number | Ptype_object | Ptype_array ->
         Error
           (sprintf
              "%s is not supported for type %s"
              key_context
              (param_type_to_string declared)))
    | "minimum" | "maximum" ->
      (* The bound carries the parameter's own type: an integer bound
         serializes as 0 and a number bound as 0.0, and the two are different
         bytes on the wire. *)
      (match declared with
       | Ptype_integer ->
         let* v = as_int ~context:key_context value in
         Ok (Some (key, `Int v))
       | Ptype_number ->
         let* v = as_float ~context:key_context value in
         Ok (Some (key, `Float v))
       | Ptype_string | Ptype_boolean | Ptype_object | Ptype_array ->
         Error
           (sprintf
              "%s is only valid for type integer or number params, this param is type %s"
              key_context
              (param_type_to_string declared)))
    | "exclusive_minimum" ->
      (* A [number] bound, not an [integer] one: tool_execute's timeout_sec and
         the keeper sandbox durations are seconds, and "greater than zero" is
         what they mean -- zero is not a timeout. *)
      let* () = only_for ~context:key_context ~declared Ptype_number in
      let* v = as_float ~context:key_context value in
      Ok (Some ("exclusiveMinimum", `Float v))
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
      let* v = as_provider_portable_pattern ~context:key_context value in
      Ok (Some ("pattern", `String v))
    | "max_items" ->
      let* () = only_for ~context:key_context ~declared Ptype_array in
      let* v = as_int ~context:key_context value in
      Ok (Some ("maxItems", `Int v))
    | "min_items" ->
      let* () = only_for ~context:key_context ~declared Ptype_array in
      let* v = as_int ~context:key_context value in
      Ok (Some ("minItems", `Int v))
    | "unique_items" ->
      let* () = only_for ~context:key_context ~declared Ptype_array in
      let* v = as_bool ~context:key_context value in
      Ok (Some ("uniqueItems", `Bool v))
    | "additional_properties" ->
      (* JSON Schema lets this be a boolean or a schema. [false] closes the
         object; a schema says what an undeclared key must look like, which is
         how tool_execute's [env] admits any name and demands a string value.
         Only the value type is read here -- a nested [params] would be a
         different key. *)
      let* () = only_for ~context:key_context ~declared Ptype_object in
      (match value with
       | Otoml.TomlBoolean flag -> Ok (Some ("additionalProperties", `Bool flag))
       | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
         let* pairs = as_table_pairs ~context:key_context value in
         let* declared_type =
           match List.assoc_opt "type" pairs with
           | None ->
             Error (sprintf "%s as a schema must declare \"type\"" key_context)
           | Some v -> as_string ~context:(key_context ^ ".type") v
         in
         let* parsed = param_type_of_string declared_type in
         Ok (Some ("additionalProperties", `Assoc [ "type", `String (param_type_to_string parsed) ]))
       | _ ->
         Error
           (sprintf "%s must be a boolean or a table, got %s" key_context (toml_shape value)))
    | "min_properties" ->
      let* () = only_for ~context:key_context ~declared Ptype_object in
      let* v = as_int ~context:key_context value in
      Ok (Some ("minProperties", `Int v))
    | "max_properties" ->
      let* () = only_for ~context:key_context ~declared Ptype_object in
      let* v = as_int ~context:key_context value in
      Ok (Some ("maxProperties", `Int v))
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
    | "enum" ->
      let* () = only_for ~context:key_context ~declared Ptype_string in
      let* values = as_string_list ~context:key_context value in
      let* () =
        match values with
        | [] -> Error (sprintf "%s must not be empty" key_context)
        | _ :: _ -> Ok ()
      in
      Ok (Some ("enum", `List (List.map (fun v -> `String v) values)))
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
      let* v = as_provider_portable_pattern ~context:key_context value in
      Ok (Some ("pattern", `String v))
    | "additional_properties" ->
      (* JSON Schema lets this be a boolean or a schema. [false] closes the
         object; a schema says what an undeclared key must look like, which is
         how tool_execute's [env] admits any name and demands a string value.
         Only the value type is read here -- a nested [params] would be a
         different key. *)
      let* () = only_for ~context:key_context ~declared Ptype_object in
      (match value with
       | Otoml.TomlBoolean flag -> Ok (Some ("additionalProperties", `Bool flag))
       | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
         let* pairs = as_table_pairs ~context:key_context value in
         let* declared_type =
           match List.assoc_opt "type" pairs with
           | None ->
             Error (sprintf "%s as a schema must declare \"type\"" key_context)
           | Some v -> as_string ~context:(key_context ^ ".type") v
         in
         let* parsed = param_type_of_string declared_type in
         Ok (Some ("additionalProperties", `Assoc [ "type", `String (param_type_to_string parsed) ]))
       | _ ->
         Error
           (sprintf "%s must be a boolean or a table, got %s" key_context (toml_shape value)))
    | "min_properties" ->
      let* () = only_for ~context:key_context ~declared Ptype_object in
      let* v = as_int ~context:key_context value in
      Ok (Some ("minProperties", `Int v))
    | "max_properties" ->
      let* () = only_for ~context:key_context ~declared Ptype_object in
      let* v = as_int ~context:key_context value in
      Ok (Some ("maxProperties", `Int v))
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
  (* An object item may declare its fields or leave them open, the same as a
     top-level object parameter. The rule here used to demand [params], on the
     ground that an item with none is a shape no caller can satisfy; that is
     not what the surface does. keeper_surface_post carries Slack Block Kit
     blocks as bare {"type": "object"} items and checks their shape at run
     time, because the set of block types is Slack's to change, not ours. *)
  let* params =
    match declared, List.assoc_opt "params" pairs with
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

type help =
  { short_description : string option
  ; when_to_use : string option
  ; key_constraints : string list
  ; details_markdown : string option
  ; doc_refs : string list
  ; prompt_hints : string list
  ; examples : string list
  ; alternatives : string list
  }

type loading =
  | Always_loaded
  | Deferrable

let loading_to_string = function
  | Always_loaded -> "always_loaded"
  | Deferrable -> "deferrable"
;;

type loaded =
  { schema : Masc_domain.tool_schema
  ; keeper_projection : Masc_domain.tool_schema option
  ; agent_core_projection : Masc_domain.tool_schema option
  ; help : help option
  ; loading : loading
  ; operator_remote_description : string option
  ; shell_command : string list option
        (** RFC tools-as-shell-commands: the sub-command path this tool is
            reachable under inside a keeper's shell line ([board post get]
            makes [masc board post get p-1] callable without a provider
            round trip).  Stored word-split once here rather than split at
            every use.  Absent means the tool has no shell form. *)
  }

let help_of_pairs pairs =
  let optional_string key =
    match List.assoc_opt key pairs with
    | None -> Ok None
    | Some value ->
      let* text = as_non_empty_string ~context:("help." ^ key) value in
      Ok (Some text)
  in
  let string_list key =
    match List.assoc_opt key pairs with
    | None -> Ok []
    | Some value -> as_string_list ~context:("help." ^ key) value
  in
  let* short_description = optional_string "short_description" in
  let* when_to_use = optional_string "when_to_use" in
  let* details_markdown = optional_string "details_markdown" in
  let* key_constraints = string_list "key_constraints" in
  let* doc_refs = string_list "doc_refs" in
  let* prompt_hints = string_list "prompt_hints" in
  let* examples = string_list "examples" in
  let* alternatives = string_list "alternatives" in
  let* () =
    let known key =
      List.exists
        (String.equal key)
        [ "short_description"
        ; "when_to_use"
        ; "details_markdown"
        ; "key_constraints"
        ; "doc_refs"
        ; "prompt_hints"
        ; "examples"
        ; "alternatives"
        ]
    in
    let rec walk = function
      | [] -> Ok ()
      | (key, (_ : Otoml.t)) :: rest ->
        if known key then walk rest else Error (sprintf "unknown key \"help.%s\"" key)
    in
    walk pairs
  in
  let declares_nothing =
    short_description = None
    && when_to_use = None
    && details_markdown = None
    && key_constraints = []
    && doc_refs = []
    && prompt_hints = []
    && examples = []
    && alternatives = []
  in
  if declares_nothing
  then Error "help table declares nothing"
  else
    Ok
      { short_description
      ; when_to_use
      ; key_constraints
      ; details_markdown
      ; doc_refs
      ; prompt_hints
      ; examples
      ; alternatives
      }
;;

(* One admitted call shape: these fields present, those absent. [forbidden]
   says "none of these", which JSON Schema writes two ways -- [not: {required:
   [x]}] for a single name, and [not: {anyOf: [...]}] for several, because
   [not: {required: [a; b]}] would only forbid having *both*. The distinction
   is why the key is a list of names rather than a nested schema. *)
let alternative_json ~required ~forbidden ~description : Yojson.Safe.t =
  let one name = `Assoc [ "required", `List [ `String name ] ] in
  let negated =
    match forbidden with
    | [ single ] -> `Assoc [ "required", `List [ `String single ] ]
    | many -> `Assoc [ "anyOf", `List (List.map one many) ]
  in
  `Assoc
    [ "required", `List (List.map (fun name -> `String name) required)
    ; "not", negated
    ; "description", `String description
    ]
;;

(* [[one_of]] blocks, in file order. Each names the fields a call must carry
   and the ones it must not; the shape they build is documented on
   [alternative_json]. *)
let alternatives_of_pairs ~context pairs =
  let blocks =
    match List.assoc_opt "one_of" pairs with
    | None -> []
    | Some (Otoml.TomlTableArray items) -> items
    | Some other -> [ other ]
  in
  let one index block =
    let ctx = sprintf "%s.one_of[%d]" context index in
    let* fields = as_table_pairs ~context:ctx block in
    let* required =
      match List.assoc_opt "required" fields with
      | None -> Error (sprintf "%s is missing the required key \"required\"" ctx)
      | Some value -> as_string_list ~context:(ctx ^ ".required") value
    in
    let* forbidden =
      match List.assoc_opt "forbidden" fields with
      | None -> Error (sprintf "%s is missing the required key \"forbidden\"" ctx)
      | Some value -> as_string_list ~context:(ctx ^ ".forbidden") value
    in
    let* description =
      match List.assoc_opt "description" fields with
      | None -> Error (sprintf "%s is missing the required key \"description\"" ctx)
      | Some value -> as_non_empty_string ~context:(ctx ^ ".description") value
    in
    let* () =
      match required, forbidden with
      | [], _ -> Error (sprintf "%s.required must not be empty" ctx)
      | _, [] -> Error (sprintf "%s.forbidden must not be empty" ctx)
      | _ :: _, _ :: _ -> Ok ()
    in
    let known key =
      List.exists (String.equal key) [ "required"; "forbidden"; "description" ]
    in
    let rec walk = function
      | [] -> Ok ()
      | (key, (_ : Otoml.t)) :: rest ->
        if known key then walk rest else Error (sprintf "%s: unknown key %S" ctx key)
    in
    let* () = walk fields in
    Ok (alternative_json ~required ~forbidden ~description)
  in
  let rec collect index acc = function
    | [] -> Ok (List.rev acc)
    | block :: rest ->
      let* json = one index block in
      collect (index + 1) (json :: acc) rest
  in
  collect 0 [] blocks
;;

let assemble_input_schema ~params ~additional_properties ~alternatives : Yojson.Safe.t =
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
        | Some flag -> [ "additionalProperties", `Bool flag ])
     @ (match alternatives with
        | [] -> []
        | _ :: _ -> [ "oneOf", `List alternatives ]))
;;

(* The two projection tables — [keeper_projection] and
   [agent_core_projection] — share one grammar: a deliberately narrower
   description and input schema for one consumer surface, decoded with the
   same known-keys discipline as the file itself. *)
let projection_of_pairs ~context ~name pairs =
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
    ; input_schema = assemble_input_schema ~params ~additional_properties ~alternatives:[]
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
  let* loading =
    match List.assoc_opt "defer_loading" pairs with
    | None -> Ok Always_loaded
    | Some value ->
      let* flag = as_bool ~context:"defer_loading" value in
      Ok (if flag then Deferrable else Always_loaded)
  in
  let* operator_remote_description =
    match List.assoc_opt "operator_remote_description" pairs with
    | None -> Ok None
    | Some value ->
      let* text = as_non_empty_string ~context:"operator_remote_description" value in
      Ok (Some text)
  in
  let* shell_command =
    match List.assoc_opt "shell_command" pairs with
    | None -> Ok None
    | Some value ->
      let* text = as_non_empty_string ~context:"shell_command" value in
      (* The shell path is matched word-for-word against argv pieces, so it
         is stored word-split here once rather than split at every use. *)
      let path = String.split_on_char ' ' text in
      if List.exists (fun word -> word = "") path
      then Error (sprintf "shell_command %S has an empty word" text)
      else Ok (Some path)
  in
  let* alternatives = alternatives_of_pairs ~context:"tool" pairs in
  let* keeper_projection =
    match List.assoc_opt "keeper_projection" pairs with
    | None -> Ok None
    | Some value ->
      let* projection_pairs = as_table_pairs ~context:"keeper_projection" value in
      let* projection =
        projection_of_pairs
          ~context:"keeper_projection"
          ~name:declared_name
          projection_pairs
      in
      Ok (Some projection)
  in
  let* agent_core_projection =
    match List.assoc_opt "agent_core_projection" pairs with
    | None -> Ok None
    | Some value ->
      let* projection_pairs = as_table_pairs ~context:"agent_core_projection" value in
      let* projection =
        projection_of_pairs
          ~context:"agent_core_projection"
          ~name:declared_name
          projection_pairs
      in
      Ok (Some projection)
  in
  let* help =
    match List.assoc_opt "help" pairs with
    | None -> Ok None
    | Some value ->
      let* help_pairs = as_table_pairs ~context:"help" value in
      let* help = help_of_pairs help_pairs in
      Ok (Some help)
  in
  let* () =
    let known key =
      List.exists
        (String.equal key)
        [ "name"
        ; "description"
        ; "additional_properties"
        ; "params"
        ; "one_of"
        ; "keeper_projection"
        ; "agent_core_projection"
        ; "help"
        ; "defer_loading"
        ; "operator_remote_description"
        ; "shell_command"
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
        ; input_schema =
            assemble_input_schema ~params ~additional_properties ~alternatives
        }
    ; keeper_projection
    ; agent_core_projection
    ; help
    ; loading
    ; operator_remote_description
    ; shell_command
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
