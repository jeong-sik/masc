(** Pure parameter/schema validation and JSON conversion, owned separately
    from message, response and stream types. *)

(** Tool parameter schema *)
type param_type =
  | String
  | Integer
  | Number
  | Boolean
  | Array
  | Object
[@@deriving yojson, show]

let param_type_to_string = function
  | String -> "string"
  | Integer -> "integer"
  | Number -> "number"
  | Boolean -> "boolean"
  | Array -> "array"
  | Object -> "object"
;;

type tool_param =
  { name : string
  ; description : string
  ; param_type : param_type
  ; required : bool
  }
[@@deriving yojson, show]

(* Keep the generated decoder private behind an exact object-field boundary.
   The generated record decoder is total, but it does not own this protocol's
   duplicate/unknown-field contract. *)
let tool_param_of_yojson_fields = tool_param_of_yojson

let param_type_of_string = function
  | "string" -> Ok String
  | "integer" -> Ok Integer
  | "number" -> Ok Number
  | "boolean" -> Ok Boolean
  | "array" -> Ok Array
  | "object" -> Ok Object
  | other -> Error other
;;

let tool_param_to_json (p : tool_param) : Yojson.Safe.t =
  `Assoc
    [ "name", `String p.name
    ; "description", `String p.description
    ; "param_type", `String (param_type_to_string p.param_type)
    ; "required", `Bool p.required
    ]
;;

(** Exact JSON shape of a value. Decoders report what arrived by naming this
    variant instead of re-inspecting the value, so a new [Yojson.Safe.t]
    constructor breaks the build rather than falling into a catch-all. *)
type json_shape =
  | Json_null
  | Json_bool
  | Json_int
  | Json_intlit
  | Json_float
  | Json_string
  | Json_list
  | Json_object
[@@deriving show, eq]

let json_shape_of_json : Yojson.Safe.t -> json_shape = function
  | `Null -> Json_null
  | `Bool _ -> Json_bool
  | `Int _ -> Json_int
  | `Intlit _ -> Json_intlit
  | `Float _ -> Json_float
  | `String _ -> Json_string
  | `List _ -> Json_list
  | `Assoc _ -> Json_object
;;

let json_shape_to_string = function
  | Json_null -> "null"
  | Json_bool -> "a boolean"
  | Json_int -> "an integer"
  | Json_intlit -> "an integer literal"
  | Json_float -> "a number"
  | Json_string -> "a string"
  | Json_list -> "an array"
  | Json_object -> "an object"
;;

let duplicate_object_keys fields =
  let rec collect acc = function
    | first :: (second :: _ as rest) when String.equal first second ->
      collect (first :: acc) rest
    | _ :: rest -> collect acc rest
    | [] -> acc
  in
  fields
  |> List.map fst
  |> List.sort String.compare
  |> collect []
  |> List.sort_uniq String.compare
;;

let exact_object_fields ~scope ~required ?(optional = []) fields =
  let expected = List.sort_uniq String.compare (required @ optional) in
  let actual = List.map fst fields |> List.sort_uniq String.compare in
  let missing = List.filter (fun name -> not (List.mem name actual)) required in
  let unknown = List.filter (fun name -> not (List.mem name expected)) actual in
  let duplicates = duplicate_object_keys fields in
  if List.is_empty missing && List.is_empty unknown && List.is_empty duplicates
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields mismatch (missing=[%s], unknown=[%s], duplicates=[%s])"
         scope
         (String.concat ", " missing)
         (String.concat ", " unknown)
         (String.concat ", " duplicates))
;;

(* Total field readers. [Yojson.Safe.Util.to_string] and friends raise
   [Type_error] on a shape mismatch, which would escape the [result] these
   decoders advertise; matching the constructor keeps the failure in the
   return type. *)
let json_string_field ~scope fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some other ->
    Error
      (Printf.sprintf
         "%s.%s must be a string, got %s"
         scope
         name
         (json_shape_to_string (json_shape_of_json other)))
  | None -> Error (Printf.sprintf "%s is missing field %s" scope name)
;;

let json_bool_field ~scope fields name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | Some other ->
    Error
      (Printf.sprintf
         "%s.%s must be a boolean, got %s"
         scope
         name
         (json_shape_to_string (json_shape_of_json other)))
  | None -> Error (Printf.sprintf "%s is missing field %s" scope name)
;;

(* The manual encoder omits an unset optional field. An explicit [null] is not
   that encoding and is rejected instead of being treated as an absent key. *)
let json_optional_bool_field ~scope fields name =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some other ->
    Error
      (Printf.sprintf
         "%s.%s must be a boolean, got %s"
         scope
         name
         (json_shape_to_string (json_shape_of_json other)))
;;

let tool_param_scope = "tool_param"

let tool_param_of_yojson json =
  match json with
  | `Assoc fields ->
    (match
       exact_object_fields
         ~scope:tool_param_scope
         ~required:[ "name"; "description"; "param_type"; "required" ]
         fields
     with
     | Error _ as error -> error
     | Ok () -> tool_param_of_yojson_fields json)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    tool_param_of_yojson_fields json
;;

let tool_param_of_json (json : Yojson.Safe.t) : (tool_param, string) result =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let scope = tool_param_scope in
    let* () =
      exact_object_fields
        ~scope
        ~required:[ "name"; "description"; "param_type"; "required" ]
        fields
    in
    let* name = json_string_field ~scope fields "name" in
    let* description = json_string_field ~scope fields "description" in
    let* param_type_name = json_string_field ~scope fields "param_type" in
    let* param_type =
      match param_type_of_string param_type_name with
      | Ok param_type -> Ok param_type
      | Error unknown -> Error (Printf.sprintf "unknown param_type: %s" unknown)
    in
    let* required = json_bool_field ~scope fields "required" in
    Ok { name; description; param_type; required }
  | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _) as other ->
    Error
      (Printf.sprintf
         "%s must be a JSON object, got %s"
         tool_param_scope
         (json_shape_to_string (json_shape_of_json other)))
;;

let params_to_input_schema (params : tool_param list) : Yojson.Safe.t =
  let properties =
    List.map
      (fun (p : tool_param) ->
         ( p.name
         , `Assoc
             [ "type", `String (param_type_to_string p.param_type)
             ; "description", `String p.description
             ] ))
      params
  in
  let required =
    List.filter_map
      (fun (p : tool_param) -> if p.required then Some (`String p.name) else None)
      params
  in
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List required
    ]
;;

(* ── JSON Schema -> parameter view ────────────────────────────────
   The derivation lives with schema construction rather than in the MCP bridge because
   {!tool_schema_of_input_schema} below is the only admissible way to store an
   authoritative schema, and it has to derive the parameter view itself for the
   two to stay in agreement. [Mcp_schema] re-exports these. *)

let json_schema_type_to_param_type_result value =
  match param_type_of_string value with
  | Ok param_type -> Ok param_type
  | Error unsupported ->
    Error (Printf.sprintf "unsupported JSON Schema type %S" unsupported)
;;

let json_schema_type_member_to_param_type_option type_name =
  match type_name with
  | "null" -> Ok None
  | value ->
    (match json_schema_type_to_param_type_result value with
     | Ok param_type -> Ok (Some param_type)
     | Error _ as error -> error)
;;

let required_list_of_schema schema =
  match schema with
  | `Assoc fields ->
    (match List.assoc_opt "required" fields with
     | None | Some `Null -> Ok []
     | Some (`List items) ->
       List.fold_right
         (fun item acc ->
            match item, acc with
            | `String value, Ok values -> Ok (value :: values)
            | _, Ok _ -> Error "required must contain only strings"
            | _, (Error _ as error) -> error)
         items
         (Ok [])
     | Some _ -> Error "required must be an array of strings")
  | _ -> Error "schema must be a JSON object"
;;

(* A property whose accepted values span several JSON types has no single
   [param_type]. JSON Schema counts every integer as a number, so that one pair
   narrows to [Number] instead of dropping the property — and with it the
   property's name, description, and required flag — from the parameter view.
   Every other combination stays unrepresentable. Both orderings of the pair are
   listed because which one [List.sort_uniq] produces follows the constructor
   order of {!param_type}, which this rule does not depend on.

   Declared once and shared: a [type] array and an [enum] reach this decision by
   different routes, and when only the array route carried the rule, mixed
   numeric enums such as ["enum": [1, 2.5]] lost their property. *)
let narrow_param_types types =
  match List.sort_uniq compare types with
  | [ param_type ] -> Some param_type
  | [ Integer; Number ] | [ Number; Integer ] -> Some Number
  | [] | _ :: _ :: _ -> None
;;

let property_type_from_union name values =
  let result =
    List.fold_left
      (fun acc item ->
         match acc, item with
         | Error _, _ -> acc
         | Ok selected, `String type_name ->
           (match json_schema_type_member_to_param_type_option type_name with
            | Ok (Some param_type) -> Ok (param_type :: selected)
            | Ok None -> Ok selected
            | Error _ as error -> error)
         | Ok _, _ ->
           Error (Printf.sprintf "property %S type array must contain only strings" name))
      (Ok [])
      values
  in
  match result with
  | Ok values -> Ok (narrow_param_types values)
  | Error _ as error -> error
;;

let param_type_of_json_value = function
  | `String _ -> Some String
  | `Int _ | `Intlit _ -> Some Integer
  | `Float _ -> Some Number
  | `Bool _ -> Some Boolean
  | `List _ -> Some Array
  | `Assoc _ -> Some Object
  | `Null -> None
;;

let infer_uniform_param_type values =
  values |> List.filter_map param_type_of_json_value |> narrow_param_types
;;

let property_type name prop =
  match prop with
  | `Bool _ -> Ok None
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String type_name) ->
       (match json_schema_type_member_to_param_type_option type_name with
        | Ok param_type -> Ok param_type
        | Error _ as error -> error)
     | Some (`List values) -> property_type_from_union name values
     | Some _ ->
       Error (Printf.sprintf "property %S type must be a string or string array" name)
     | None ->
       (match List.assoc_opt "const" fields, List.assoc_opt "enum" fields with
        | Some value, _ -> Ok (param_type_of_json_value value)
        | None, Some (`List values) -> Ok (infer_uniform_param_type values)
        | None, Some _ -> Error (Printf.sprintf "property %S enum must be an array" name)
        | None, None -> Ok None))
  | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error (Printf.sprintf "property %S must be a JSON object or boolean schema" name)
;;

let property_description prop =
  match prop with
  | `Assoc fields ->
    (match List.assoc_opt "description" fields with
     | Some (`String value) -> Ok value
     | None | Some `Null -> Ok ""
     | Some _ -> Error "description must be a string")
  | _ -> Error "property must be a JSON object"
;;

(* Params of a schema that has already cleared [input_schema_of_json]. Kept
   private so no caller can reach the conversion without the key check;
   the two used to disagree on a repeated key (#27841). *)
let json_schema_to_params_of_checked_schema schema =
  let ( let* ) = Result.bind in
  let* required_list = required_list_of_schema schema in
  match schema with
  | `Assoc fields ->
    (match List.assoc_opt "properties" fields with
     | None | Some `Null -> Ok []
     | Some (`Assoc pairs) ->
       List.fold_right
         (fun (name, prop) acc ->
            let* params = acc in
            let* param_type = property_type name prop in
            match param_type with
            | None -> Ok params
            | Some param_type ->
              let* description = property_description prop in
              let required = List.mem name required_list in
              Ok ({ name; description; param_type; required } :: params))
         pairs
         (Ok [])
     | Some _ -> Error "properties must be a JSON object")
  | _ -> Error "schema must be a JSON object"
;;

(* ── Tool argument schema boundary ────────────────────────────────
   A provider tool argument schema is a JSON object with unique keys. Anything
   else — an explicit null, a scalar, an array, or an object Yojson parsed with
   a repeated key — is a caller mistake, and is rejected here so it can never
   be stored. Because non-objects cannot be stored, [Some `Null] is
   unrepresentable and the [`Null]-means-absent encoding below is unambiguous. *)

(** Why a JSON value was refused as a tool argument schema. *)
type input_schema_error =
  | Input_schema_not_an_object of json_shape
  | Input_schema_duplicate_keys of
      { path : string
      ; keys : string list
      }
[@@deriving show, eq]

(* Path shown for the schema root; nested paths extend it with ".key" and
   "[index]" so a rejection names the offending object. *)
let input_schema_root_path = "input_schema"

let input_schema_error_to_string = function
  | Input_schema_not_an_object shape ->
    Printf.sprintf
      "%s must be a JSON object, got %s"
      input_schema_root_path
      (json_shape_to_string shape)
  | Input_schema_duplicate_keys { path; keys } ->
    Printf.sprintf "%s has duplicate keys: %s" path (String.concat ", " keys)
;;

(* Yojson parses a duplicate key into a repeated assoc entry, so uniqueness is
   not implied by the type and has to be checked. A duplicate nested inside
   "properties" is as ambiguous as one at the root, hence the full walk. *)
let rec check_unique_object_keys ~path (json : Yojson.Safe.t)
  : (unit, input_schema_error) result
  =
  match json with
  | `Assoc fields ->
    (match duplicate_object_keys fields with
     | _ :: _ as keys -> Error (Input_schema_duplicate_keys { path; keys })
     | [] ->
       List.fold_left
         (fun acc (key, value) ->
            match acc with
            | Error _ -> acc
            | Ok () -> check_unique_object_keys ~path:(path ^ "." ^ key) value)
         (Ok ())
         fields)
  | `List items ->
    List.fold_left
      (fun (index, acc) value ->
         ( index + 1
         , match acc with
           | Error _ -> acc
           | Ok () ->
             check_unique_object_keys ~path:(Printf.sprintf "%s[%d]" path index) value ))
      (0, Ok ())
      items
    |> snd
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ -> Ok ()
;;

(** Accept a value as a tool argument schema, or say exactly why not. *)
let input_schema_of_json (json : Yojson.Safe.t)
  : (Yojson.Safe.t, input_schema_error) result
  =
  match json with
  | `Assoc _ ->
    (match check_unique_object_keys ~path:input_schema_root_path json with
     | Ok () -> Ok json
     | Error _ as error -> error)
  | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _) as other ->
    Error (Input_schema_not_an_object (json_shape_of_json other))
;;

(** Tool params of [schema], refusing a schema that no reader can agree on.

    This is the same gate {!input_schema_of_json} applies before a schema is
    stored. Without it, Yojson keeps every pair of a repeated key and
    [List.assoc] silently answers with the first, so the same document
    produced one set of params here and a rejection on the storage path. *)
let json_schema_to_params_result schema =
  match input_schema_of_json schema with
  | Error error -> Error (input_schema_error_to_string error)
  | Ok checked -> json_schema_to_params_of_checked_schema checked
;;

let rec schema_definitely_excludes_objects = function
  | `Bool false -> true
  | `Bool true -> false
  | `Assoc fields ->
    let type_excludes =
      match List.assoc_opt "type" fields with
      | Some (`String type_name) -> not (String.equal type_name "object")
      | Some (`List values) ->
        List.for_all
          (function
            | `String type_name -> not (String.equal type_name "object")
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ ->
              false)
          values
      | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _) -> false
    in
    let const_excludes =
      match List.assoc_opt "const" fields with
      | Some (`Assoc _) | None -> false
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
        true
    in
    let enum_excludes =
      match List.assoc_opt "enum" fields with
      | Some (`List values) ->
        List.for_all
          (function
            | `Assoc _ -> false
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
              true)
          values
      | None
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
        false
    in
    let all_of_excludes =
      match List.assoc_opt "allOf" fields with
      | Some (`List schemas) -> List.exists schema_definitely_excludes_objects schemas
      | None
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
        false
    in
    let alternatives_exclude keyword =
      match List.assoc_opt keyword fields with
      | Some (`List schemas) -> List.for_all schema_definitely_excludes_objects schemas
      | None
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
        false
    in
    type_excludes
    || const_excludes
    || enum_excludes
    || all_of_excludes
    || alternatives_exclude "anyOf"
    || alternatives_exclude "oneOf"
  | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
;;

let validate_tool_argument_root_schema schema =
  match schema with
  | `Assoc fields ->
    let declared_type =
      match List.assoc_opt "type" fields with
      | None | Some (`String "object") -> Ok ()
      | Some (`List values) ->
        let type_names =
          List.fold_right
            (fun value acc ->
               match value, acc with
               | `String type_name, Ok names -> Ok (type_name :: names)
               | _, Ok _ -> Error "tool input schema root type must contain only strings"
               | _, (Error _ as error) -> error)
            values
            (Ok [])
        in
        (match type_names with
         | Ok names when List.sort_uniq String.compare names = [ "object" ] -> Ok ()
         | Ok _ -> Error "tool input schema root type must describe object arguments"
         | Error _ as error -> error)
      | Some (`String _) ->
        Error "tool input schema root type must describe object arguments"
      | Some _ -> Error "tool input schema root type must be a string or string array"
    in
    (match declared_type with
     | Error _ as error -> error
     | Ok () when schema_definitely_excludes_objects schema ->
       Error "tool input schema constraints cannot describe object arguments"
     | Ok () -> Ok ())
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "tool input schema must be a JSON object"
;;

(* [Yojson.Safe.t] carries no derived converters, so the deriving attributes on
   [tool_schema.input_schema] name these three explicitly. [@default None]
   represents absence by omitting the field; a present field is decoded here
   and must contain an admissible schema object. *)
let input_schema_to_yojson : Yojson.Safe.t option -> Yojson.Safe.t = function
  | None -> `Null
  | Some schema -> schema
;;

let input_schema_of_yojson json =
  match input_schema_of_json json with
  | Ok schema -> Ok (Some schema)
  | Error error -> Error (input_schema_error_to_string error)
;;

let pp_input_schema fmt = function
  | None -> Format.pp_print_string fmt "None"
  | Some schema -> Format.fprintf fmt "Some %s" (Yojson.Safe.to_string schema)
;;

(** Tool definition *)
type tool_schema =
  { name : string
  ; description : string
  ; parameters : tool_param list
  ; strict : bool option
    (** Per-function JSON Schema strict validation. [Some true] opts the tool
        into strict mode (OpenAI, DeepSeek Beta, Kimi, MiMo); [None] omits the
        field so providers apply their default. *)
  ; input_schema :
      (Yojson.Safe.t option
      [@default None]
      [@to_yojson input_schema_to_yojson]
      [@of_yojson input_schema_of_yojson]
      [@printer pp_input_schema])
    (** Authoritative wire form emitted to providers verbatim when [Some]; when
        [None] the wire form is derived from [parameters] by
        {!params_to_input_schema}. [parameters] is the derived view used for
        validation and introspection. The pair is only ever built by
        {!tool_schema_of_params} and {!tool_schema_of_input_schema}, so
        [Some schema] always satisfies
        [parameters = json_schema_to_params_result schema]. *)
  }
[@@deriving yojson, show]

(* ── Authoritative constructors ───────────────────────────────────
   [tool_schema] is [private] in the signature, so these two functions are the
   only way to obtain one. Each takes exactly one of the two views and derives
   the other, which is what makes the pair unable to disagree. *)

let tool_schema_of_params ?strict ~name ~description ~parameters () =
  { name; description; parameters; strict; input_schema = None }
;;

let tool_schema_of_input_schema ?strict ~name ~description ~input_schema ()
  : (tool_schema, string) result
  =
  match input_schema_of_json input_schema with
  | Error error -> Error (input_schema_error_to_string error)
  | Ok schema ->
    (match validate_tool_argument_root_schema schema with
     | Error _ as error -> error
     | Ok () ->
       (match json_schema_to_params_result schema with
        | Error detail -> Error detail
        | Ok parameters ->
          Ok { name; description; parameters; strict; input_schema = Some schema }))
;;

let enum_member_separator = '|'

let enum_vocabulary_text members =
  "one of: "
  ^ String.concat (Printf.sprintf " %c " enum_member_separator) members
;;

let tool_schema_of_input_schema_with_parameters
      ?strict
      ~name
      ~description
      ~parameters
      ~input_schema
      ()
  =
  match tool_schema_of_input_schema ?strict ~name ~description ~input_schema () with
  | Error _ as error -> error
  | Ok schema when schema.parameters = parameters -> Ok schema
  | Ok _ ->
    Error "tool_schema.parameters must equal the projection of tool_schema.input_schema"
;;

(* The derived decoder fills [parameters] and [input_schema] from independent
   JSON fields, which is exactly the divergence the constructors prevent. Route
   its output back through them and reject a pair the constructors could not
   have produced. *)
let tool_schema_of_yojson_fields = tool_schema_of_yojson

let tool_schema_of_yojson json =
  let decode () =
    match tool_schema_of_yojson_fields json with
    | Error _ as error -> error
    | Ok { name; description; parameters; strict; input_schema } ->
      (match input_schema with
       | None -> Ok (tool_schema_of_params ?strict ~name ~description ~parameters ())
       | Some input_schema ->
         tool_schema_of_input_schema_with_parameters
           ?strict
           ~name
           ~description
           ~parameters
           ~input_schema
           ())
  in
  match json with
  | `Assoc fields ->
    (match
       exact_object_fields
         ~scope:"tool_schema"
         ~required:[ "name"; "description"; "parameters"; "strict" ]
           (* Optional, not required: a payload written by a released version
              carries no "input_schema" key at all, and [@default None] makes
              this encoder omit it too. Requiring it would reject both. [strict]
              stays required because every released encoder emits it, as
              "strict": null when unset. *)
         ~optional:[ "input_schema" ]
         fields
     with
     | Error _ as error -> error
     | Ok () -> decode ())
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> decode ()
;;

let tool_schema_to_json (s : tool_schema) : Yojson.Safe.t =
  `Assoc
    ([ "name", `String s.name
     ; "description", `String s.description
     ; "parameters", `List (List.map tool_param_to_json s.parameters)
     ]
     (* Emit "strict" only when set so [None] round-trips to an absent field
        and providers keep their own default. *)
     @ (match s.strict with
        | Some b -> [ "strict", `Bool b ]
        | None -> [])
     (* Same absence encoding for the authoritative schema: an absent key means
        the wire form is derived from [parameters]. Encoding absence as a
        missing key rather than as [null] keeps the two distinct on the way
        back, so every schema this field can hold — a JSON object with unique
        keys, and nothing else — round-trips unchanged. *)
     @
     match s.input_schema with
     | Some schema -> [ "input_schema", schema ]
     | None -> [])
;;

let result_all items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | Ok item :: rest -> loop (item :: acc) rest
    | Error e :: _ -> Error e
  in
  loop [] items
;;

let tool_schema_scope = "tool_schema"

(* Total: every field is read by matching its JSON constructor, so a malformed
   persisted payload lands in [Error] rather than raising [Type_error] out of
   the advertised [result]. *)
let tool_schema_of_json (json : Yojson.Safe.t) : (tool_schema, string) result =
  let ( let* ) = Result.bind in
  match json with
  | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _) as other ->
    Error
      (Printf.sprintf
         "%s must be a JSON object, got %s"
         tool_schema_scope
         (json_shape_to_string (json_shape_of_json other)))
  | `Assoc fields ->
    let scope = tool_schema_scope in
    let* () =
      exact_object_fields
        ~scope
        ~required:[ "name"; "description"; "parameters" ]
        ~optional:[ "strict"; "input_schema" ]
        fields
    in
    let* name = json_string_field ~scope fields "name" in
    let* description = json_string_field ~scope fields "description" in
    let* strict = json_optional_bool_field ~scope fields "strict" in
    let* parameter_items =
      match List.assoc_opt "parameters" fields with
      | Some (`List items) -> Ok items
      | Some other ->
        Error
          (Printf.sprintf
             "%s.parameters must be an array, got %s"
             scope
             (json_shape_to_string (json_shape_of_json other)))
      | None -> Error (Printf.sprintf "%s is missing field parameters" scope)
    in
    let* parameters = parameter_items |> List.map tool_param_of_json |> result_all in
    (* [Yojson.Safe.Util.member] answers [`Null] for an absent key, so it
       cannot tell an omitted "input_schema" from a present one; the assoc
       lookup keeps the two distinct. *)
    (match List.assoc_opt "input_schema" fields with
     | Some input_schema ->
       tool_schema_of_input_schema_with_parameters
         ?strict
         ~name
         ~description
         ~parameters
         ~input_schema
         ()
     | None -> Ok (tool_schema_of_params ?strict ~name ~description ~parameters ()))
;;
