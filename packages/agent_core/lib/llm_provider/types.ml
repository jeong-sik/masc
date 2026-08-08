(** Unified LLM provider types.

    Single source of truth for message, response, tool, and streaming types.
    Downstream consumers link against this module directly.

    @since 0.42.0 *)

(** {1 Message Types} *)

(** Role in a conversation.
    4-variant superset: System and Tool are required by multi-agent
    coordinators that inject system prompts and relay tool results. *)
type role =
  | System
  | User
  | Assistant
  | Tool
[@@deriving yojson, show]

let role_to_string = function
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Tool -> "tool"
;;

let role_of_string = function
  | "system" -> Some System
  | "user" -> Some User
  | "assistant" -> Some Assistant
  | "tool" -> Some Tool
  | _ -> None
;;

(** {1 Tool Types} *)

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

(** Tool execution result types.
    Defined before content_block/message/api_response to avoid
    field-name shadowing on the [content] record field. *)
type tool_output =
  { content : string
  ; _meta : Yojson.Safe.t option
    (** Optional structured metadata forwarded to the MCP [tool_result._meta]
        field. [None] omits the field on the wire. *)
  }

type tool_error_class =
  | Transient
  | Deterministic
  | Unknown
[@@deriving yojson, show]

type tool_failure_kind =
  | Validation_error
  | Recoverable_tool_error
  | Non_retryable_tool_error
  | Reported_tool_error
  | Unattributed_tool_error
[@@deriving yojson, show]

type tool_failure_provenance =
  { failure_kind : tool_failure_kind
  ; error_class : tool_error_class option
  }
[@@deriving show]

type tool_result_outcome =
  | Tool_succeeded
  | Tool_failed of tool_failure_provenance
[@@deriving show]

let tool_failure_kind_is_recoverable = function
  | Validation_error | Recoverable_tool_error -> true
  | Non_retryable_tool_error | Reported_tool_error | Unattributed_tool_error -> false
;;

let tool_result_outcome_is_error = function
  | Tool_succeeded -> false
  | Tool_failed _ -> true
;;

type tool_error =
  { message : string
  ; recoverable : bool
  ; error_class : tool_error_class option
  }

type tool_result = (tool_output, tool_error) result

let tool_result_of_outcome ~content = function
  | Tool_succeeded -> Ok { content; _meta = None }
  | Tool_failed { failure_kind; error_class } ->
    Error
      { message = content
      ; recoverable = tool_failure_kind_is_recoverable failure_kind
      ; error_class
      }
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
   The derivation lives here rather than in the MCP bridge because
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

let json_schema_to_params_result schema =
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

(** Tool choice mode *)
type tool_choice =
  | Auto
  | Any
  | Tool of string
  | None_ (** Disables tool use. Anthropic: {type:none}, Openai: "none" *)
[@@deriving show]

let tool_choice_to_json = function
  | Auto -> `Assoc [ "type", `String "auto" ]
  | Any -> `Assoc [ "type", `String "any" ]
  | Tool name -> `Assoc [ "type", `String "tool"; "name", `String name ]
  | None_ -> `Assoc [ "type", `String "none" ]
;;

type response_format =
  | Off
  | JsonMode
  | JsonSchema of Yojson.Safe.t
[@@deriving show]

let response_format_to_json = function
  | Off -> `Assoc [ "type", `String "off" ]
  | JsonMode -> `Assoc [ "type", `String "json_mode" ]
  | JsonSchema schema -> `Assoc [ "type", `String "json_schema"; "schema", schema ]
;;

(** {1 Content Types} *)

(** Closed set of supported media source carriers. *)
type media_source_kind =
  | Base64
  | Url
  | File_id
[@@deriving show]

let media_source_kind_to_string = function
  | Base64 -> "base64"
  | Url -> "url"
  | File_id -> "file_id"
;;

let media_source_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "base64" -> Some Base64
  | "url" -> Some Url
  | "file_id" -> Some File_id
  | _ -> None
;;

type reasoning_detail =
  { raw : Yojson.Safe.t
  ; text : string option
  }
[@@deriving show]

(** Content block types -- inline records for clarity *)
type content_block =
  | Text of string
  | Thinking of
      { content : string
      ; signature : string option
        (** [Some s]: Anthropic cryptographic signature, replayed byte-exact on
            tool turns (never sanitized or re-encoded). [None]: provider
            reasoning that carries no verification signature
            (OpenAI-compatible / Gemini / GLM / Ollama). Replaces the former
            [thinking_type : string], which conflated this signature with a
            free-form provider label ("reasoning" / "thinking" /
            "reasoning_summary") that no consumer read. *)
      }
  | ReasoningDetails of
      { reasoning_content : string option
      ; details : reasoning_detail list
      }
  | RedactedThinking of string
  | ToolUse of
      { id : string
      ; name : string
      ; input : Yojson.Safe.t
      }
  | ToolResult of
      { tool_use_id : string
      ; content : string
      ; outcome : tool_result_outcome
      ; json : Yojson.Safe.t option
        (** Parsed JSON payload when available. Consumers
                        should prefer [json] over [content] for structured access.
                        [content] remains the canonical string for API serialization. *)
      ; content_blocks : content_block list option
        (** Structured multi-block result (e.g. text + image). When [Some],
                        providers that accept an array tool_result content serialize
                        the blocks; [content] stays the canonical string fallback. *)
      }
  | Image of
      { media_type : string
      ; data : string
      ; source_type : media_source_kind
      }
  | Document of
      { media_type : string
      ; data : string
      ; source_type : media_source_kind
      }
  | Audio of
      { media_type : string
      ; data : string
      ; source_type : media_source_kind
      }
[@@deriving show]

let reasoning_details_text
      ~(reasoning_content : string option)
      ~(details : reasoning_detail list)
  : string
  =
  let details_text =
    details
    |> List.filter_map (fun (detail : reasoning_detail) -> detail.text)
    |> String.concat ""
  in
  match reasoning_content with
  | Some content -> if content = "" then details_text else content
  | None -> details_text
;;

(** Message metadata: extensible typed key-value pairs attached to a message.
    Keys are caller-defined strings; values are JSON payloads. *)
type metadata = (string * Yojson.Safe.t) list [@@deriving show]

module Conversation_metadata = struct
  type run_boundary =
    | Absent
    | Present
    | Invalid
    | Duplicate

  let run_boundary_key = "oas.agent_run_boundary.v1"
  let run_boundary_entry = run_boundary_key, `Bool true
  let run_boundary = [ run_boundary_entry ]

  let classify_run_boundary metadata =
    let values =
      List.filter_map
        (fun (key, value) ->
           if String.equal key run_boundary_key then Some value else None)
        metadata
    in
    match values with
    | [] -> Absent
    | [ `Bool true ] -> Present
    | [ _ ] -> Invalid
    | _ -> Duplicate
  ;;

  let is_mergeable_followup = function
    | [] -> true
    | metadata -> classify_run_boundary metadata = Present && List.length metadata = 1
  ;;
end

module Extra_system_context_provenance = struct
  type classification =
    | Absent
    | Present
    | Invalid
    | Duplicate

  let key = "oas.extra_system_context.v1"
  let entry = key, `Bool true
  let metadata = [ entry ]

  let classify metadata =
    let values =
      List.filter_map
        (fun (field_key, value) ->
           if String.equal field_key key then Some value else None)
        metadata
    in
    match values with
    | [] -> Absent
    | [ `Bool true ] -> Present
    | [ _ ] -> Invalid
    | _ -> Duplicate
  ;;
end

(** Exact producer binding for stored reasoning artifacts. *)
module Reasoning_source = struct
  type provider_instance = Provider_instance_id of string [@@deriving show]

  type t =
    { provider_kind : Provider_kind.t
    ; provider_instance : provider_instance
    ; canonical_model_id : string
    ; replay_contract : Reasoning_replay_contract.t
    }
  [@@deriving show]

  type classification =
    | Absent
    | Present of t
    | Invalid
    | Duplicate
  [@@deriving show]

  let key = "oas.reasoning_source.v2"
  let sha256_hex_length = 64

  let provider_instance_id_is_canonical value =
    String.length value = sha256_hex_length
    && String.for_all
         (function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false)
         value
  ;;

  let provider_instance ~base_url ~request_path =
    let canonical value = Uri.of_string value |> Uri.canonicalize |> Uri.to_string in
    let material = canonical base_url ^ "\000" ^ canonical request_path in
    Provider_instance_id Digestif.SHA256.(to_hex (digest_string material))
  ;;

  let create ~provider_kind ~provider_instance ~canonical_model_id ~replay_contract =
    if String.trim canonical_model_id = ""
    then Error "canonical_model_id must not be blank"
    else Ok { provider_kind; provider_instance; canonical_model_id; replay_contract }
  ;;

  let equal left right =
    left.provider_kind = right.provider_kind
    && left.provider_instance = right.provider_instance
    && String.equal left.canonical_model_id right.canonical_model_id
    && Reasoning_replay_contract.equal left.replay_contract right.replay_contract
  ;;

  (* Everything except the concrete endpoint: same provider kind, same
     canonical request model, same typed replay contract. This is the widest
     difference a self-contained reasoning text can survive, because none of
     those three dimensions changed — only the base URL / request path the
     bytes travelled over. *)
  let same_contract_and_model stored target =
    stored.provider_kind = target.provider_kind
    && String.equal stored.canonical_model_id target.canonical_model_id
    && Reasoning_replay_contract.equal stored.replay_contract target.replay_contract
  ;;

  let rotation_admits
        ~(rotation_policy : Reasoning_replay_contract.rotation_policy)
        ~stored
        ~target
    =
    match rotation_policy with
    | Require_identical_source -> equal stored target
    | Allow_endpoint_rotation -> same_contract_and_model stored target
  ;;

  let to_json source =
    let (Provider_instance_id provider_instance_id) = source.provider_instance in
    `Assoc
      [ "provider_kind", `String (Provider_kind.to_string source.provider_kind)
      ; "provider_instance_id", `String provider_instance_id
      ; "canonical_model_id", `String source.canonical_model_id
      ; "replay_contract", Reasoning_replay_contract.to_yojson source.replay_contract
      ]
  ;;

  let values_for key fields =
    List.filter_map
      (fun (field_key, value) -> if String.equal field_key key then Some value else None)
      fields
  ;;

  let of_json = function
    | `Assoc fields ->
      (match
         ( values_for "provider_kind" fields
         , values_for "provider_instance_id" fields
         , values_for "canonical_model_id" fields
         , values_for "replay_contract" fields )
       with
       | ( [ `String provider_raw ]
         , [ `String provider_instance_id ]
         , [ `String canonical_model_id ]
         , [ replay_contract_json ] )
         when List.length fields = 4
              && provider_instance_id_is_canonical provider_instance_id ->
         (match Provider_kind.of_string provider_raw with
          | Some provider_kind
            when String.equal provider_raw (Provider_kind.to_string provider_kind) ->
            (match Reasoning_replay_contract.of_yojson replay_contract_json with
             | Error _ -> None
             | Ok replay_contract ->
               (match
                  create
                    ~provider_kind
                    ~provider_instance:(Provider_instance_id provider_instance_id)
                    ~canonical_model_id
                    ~replay_contract
                with
                | Ok source -> Some source
                | Error _ -> None))
          | Some _ | None -> None)
       | _ -> None)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
  ;;

  let entry source = key, to_json source
  let metadata source = [ entry source ]
  let to_yojson = to_json

  let of_yojson json =
    match of_json json with
    | Some source -> Ok source
    | None -> Error "Reasoning_source: invalid JSON"
  ;;

  let classify metadata =
    let values = values_for key metadata in
    match values with
    | [] -> Absent
    | [ value ] ->
      (match of_json value with
       | Some source -> Present source
       | None -> Invalid)
    | _ -> Duplicate
  ;;

  let add source metadata =
    match classify metadata with
    | Absent -> Ok (entry source :: metadata)
    | Present existing when equal existing source -> Ok metadata
    | Present _ -> Error "conflicting reasoning source"
    | Invalid -> Error "malformed reasoning source"
    | Duplicate -> Error "duplicate reasoning source"
  ;;
end

(** A single message in the conversation.
    [name] identifies the speaker (e.g. tool result source).
    [tool_call_id] links a tool result back to its tool_use request. *)
type message =
  { role : role
  ; content : content_block list
  ; name : string option [@default None]
  ; tool_call_id : string option [@default None]
  ; metadata : metadata [@default []]
  }
[@@deriving show]

(** {1 Response Types} *)

(** Stop reason from API.
    2025-2026 extended: Refusal, ContentFilter, RepetitionTruncation,
    PauseTurn, Compaction, ContextWindowExceeded. *)
type stop_reason =
  | EndTurn
  | StopToolUse
  | MaxTokens
  | StopSequence
  | Refusal (** Policy refusal (Anthropic, OpenAI, Gemini SAFETY). *)
  | ContentFilter (** Provider content-policy filter terminated generation. *)
  | RepetitionTruncation (** Provider repetition guard terminated generation. *)
  | PauseTurn (** Anthropic long-running turn pause. *)
  | Compaction (** Anthropic context compaction. *)
  | ContextWindowExceeded (** Anthropic context window exceeded. *)
  | UnmatchedToolCalls
  (** Internal fail-closed response shape: a provider claimed a tool turn
          but no executable tool block was assembled. This is not a provider
          terminal reason and is constructed only after wire reconciliation. *)
  | Unknown of string
[@@deriving show]

let stop_reason_of_string = function
  | "end_turn" -> EndTurn
  | "tool_use" -> StopToolUse
  | "max_tokens" | "length" | "length_limit" -> MaxTokens
  | "stop_sequence" -> StopSequence
  | "refusal" -> Refusal
  | "content_filter" -> ContentFilter
  | "repetition_truncation" -> RepetitionTruncation
  | "pause_turn" -> PauseTurn
  | "compaction" -> Compaction
  | "model_context_window_exceeded"
  | "context_window_exceeded"
  | "context_length_exceeded"
  | "max_context_length"
  | "context_limit_exceeded" -> ContextWindowExceeded
  | "unmatched_tool_calls" -> UnmatchedToolCalls
  | other -> Unknown other
;;

(* Canonical wire serialization of [stop_reason]: the exact inverse of
   [stop_reason_of_string]. [stop_reason_of_string (stop_reason_to_string r) = r]
   holds for every constructor (with the inherent caveat that [Unknown s]
   collapses to its decoded constructor when [s] is itself a known wire token).
   SSOT for stop-reason wire strings — callers must delegate here instead of
   re-spelling the literals, which previously drifted across modules
   (e.g. "tool_use" vs "stop_tool_use"). *)
let stop_reason_to_string = function
  | EndTurn -> "end_turn"
  | StopToolUse -> "tool_use"
  | MaxTokens -> "max_tokens"
  | StopSequence -> "stop_sequence"
  | Refusal -> "refusal"
  | ContentFilter -> "content_filter"
  | RepetitionTruncation -> "repetition_truncation"
  | PauseTurn -> "pause_turn"
  | Compaction -> "compaction"
  | ContextWindowExceeded -> "model_context_window_exceeded"
  | UnmatchedToolCalls -> "unmatched_tool_calls"
  | Unknown s -> s
;;

(* Stable, low-cardinality telemetry label for [stop_reason]. Identical to
   [stop_reason_to_string] except [Unknown _] collapses to the constant
   ["unknown"] so provider-supplied raw strings cannot explode metric-label
   cardinality. Use for Otel/metric labels; use [stop_reason_to_string] for
   wire/round-trip serialization. The explicit constructor list (rather than a
   wildcard) forces a compile error if a new [stop_reason] variant is added. *)
let stop_reason_to_metric_label = function
  | Unknown _ -> "unknown"
  | ( EndTurn
    | StopToolUse
    | MaxTokens
    | StopSequence
    | Refusal
    | ContentFilter
    | RepetitionTruncation
    | PauseTurn
    | Compaction
    | ContextWindowExceeded
    | UnmatchedToolCalls ) as r -> stop_reason_to_string r
;;

(** API usage from a single response *)
type api_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cache_creation_input_tokens : int
  ; cache_read_input_tokens : int
  ; cost_usd : float option
  }
[@@deriving show, yojson]

(** Provider-reported inference timing from a single API call.
    llama-server populates all fields; cloud providers return [None]. *)
type inference_timings =
  { prompt_n : int option
  ; prompt_ms : float option
  ; prompt_per_second : float option
  ; predicted_n : int option
  ; predicted_ms : float option
  ; predicted_per_second : float option
  ; cache_n : int option
  }
[@@deriving show, yojson]

(** The provider wire field that carries one output-token decision.  This is an
    envelope identity, not a provider brand: providers using an
    OpenAI-compatible endpoint share the matching OpenAI envelope. *)
type output_token_envelope = Output_token_wire_internal.envelope =
  | Openai_chat_max_tokens
  | Openai_responses_max_output_tokens
  | Anthropic_messages_max_tokens
  | Gemini_generation_config_max_output_tokens
  | Ollama_options_num_predict

type output_token_policy = Output_token_wire_internal.policy =
  | Omitted
  | Explicit
  | Explicit_clamped
  | Required_catalog_fallback
  | Required_capability_override_fallback

type output_token_ceiling_source = Output_token_wire_internal.ceiling_source =
  | Catalog_model
  | Declared_capability_override
  | Provider_default

let pp_output_token_envelope = Output_token_wire_internal.pp_envelope
let show_output_token_envelope = Output_token_wire_internal.show_envelope
let equal_output_token_envelope = Output_token_wire_internal.equal_envelope
let pp_output_token_policy = Output_token_wire_internal.pp_policy
let show_output_token_policy = Output_token_wire_internal.show_policy
let equal_output_token_policy = Output_token_wire_internal.equal_policy
let pp_output_token_ceiling_source = Output_token_wire_internal.pp_ceiling_source
let show_output_token_ceiling_source = Output_token_wire_internal.show_ceiling_source
let equal_output_token_ceiling_source = Output_token_wire_internal.equal_ceiling_source
let output_token_envelope_to_yojson = Output_token_wire_internal.envelope_to_yojson
let output_token_envelope_of_yojson = Output_token_wire_internal.envelope_of_yojson
let output_token_policy_to_yojson = Output_token_wire_internal.policy_to_yojson
let output_token_policy_of_yojson = Output_token_wire_internal.policy_of_yojson

let output_token_ceiling_source_to_yojson =
  Output_token_wire_internal.ceiling_source_to_yojson
;;

let output_token_ceiling_source_of_yojson =
  Output_token_wire_internal.ceiling_source_of_yojson
;;

type output_token_ceiling = Output_token_wire_internal.ceiling =
  { value : int
  ; source : output_token_ceiling_source
  }
[@@deriving show, eq]

let output_token_ceiling = Output_token_wire_internal.ceiling

type output_token_receipt = Output_token_wire_internal.receipt

type required_output_token_error = Output_token_wire_internal.required_error =
  | Required_output_token_ceiling_missing
[@@deriving show, eq]

let optional_output_token_receipt = Output_token_wire_internal.optional_receipt
let required_output_token_receipt = Output_token_wire_internal.required_receipt
let output_token_receipt_envelope = Output_token_wire_internal.receipt_envelope
let output_token_receipt_requested = Output_token_wire_internal.receipt_requested
let output_token_receipt_effective = Output_token_wire_internal.receipt_effective
let output_token_receipt_policy = Output_token_wire_internal.receipt_policy
let output_token_receipt_ceiling = Output_token_wire_internal.receipt_ceiling

let output_token_receipt_ceiling_source =
  Output_token_wire_internal.receipt_ceiling_source
;;

let output_token_receipt_to_yojson = Output_token_wire_internal.receipt_to_yojson
let output_token_receipt_of_yojson = Output_token_wire_internal.receipt_of_yojson
let equal_output_token_receipt = Output_token_wire_internal.equal_receipt
let pp_output_token_receipt = Output_token_wire_internal.pp_receipt
let show_output_token_receipt = Output_token_wire_internal.show_receipt

(** Per-call inference telemetry.
    Parsed from the raw API response; never computed by downstream. *)
type inference_telemetry =
  { system_fingerprint : string option
  ; timings : inference_timings option
  ; reasoning_tokens : int option
  ; request_latency_ms : int option
  ; peak_memory_gb : float option
  ; provider_kind : Provider_kind.t option
  ; reasoning_effort : string option
  ; canonical_model_id : string option
  ; reasoning_source : Reasoning_source.t option
  ; effective_context_window : int option
  ; provider_internal_action_count : int option
  ; ttfrc_ms : float option
  ; prefill_ms : float option
  }
[@@deriving show, yojson]

let default_inference_telemetry : inference_telemetry =
  { system_fingerprint = None
  ; timings = None
  ; reasoning_tokens = None
  ; request_latency_ms = None
  ; peak_memory_gb = None
  ; provider_kind = None
  ; reasoning_effort = None
  ; canonical_model_id = None
  ; reasoning_source = None
  ; effective_context_window = None
  ; provider_internal_action_count = None
  ; ttfrc_ms = None
  ; prefill_ms = None
  }
;;

(** API response *)
type api_response =
  { id : string
  ; model : string
  ; stop_reason : stop_reason
  ; content : content_block list
  ; usage : api_usage option
  ; telemetry : inference_telemetry option
  }
[@@deriving show]

type assistant_message_error =
  | Reasoning_source_telemetry_missing
  | Reasoning_source_missing
[@@deriving show]

let content_has_reasoning_artifact content =
  List.exists
    (function
      | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
      | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
    content
;;

let assistant_message_of_response (response : api_response) =
  let message metadata =
    { role = Assistant
    ; content = response.content
    ; name = None
    ; tool_call_id = None
    ; metadata
    }
  in
  if not (content_has_reasoning_artifact response.content)
  then Ok (message [])
  else (
    match response.telemetry with
    | None -> Error Reasoning_source_telemetry_missing
    | Some { reasoning_source = None; _ } -> Error Reasoning_source_missing
    | Some { reasoning_source = Some source; _ } ->
      Ok (message (Reasoning_source.metadata source)))
;;

(** {1 SSE Streaming Types} *)

type content_delta =
  | TextDelta of string
  | ThinkingDelta of string
  | ThinkingSignatureDelta of string
  | ReasoningDetailsDelta of
      { reasoning_content : string option
      ; details : reasoning_detail list
      }
  | InputJsonDelta of string
  (** Incremental fragment of a tool-call arguments JSON string. The
          accumulator appends successive fragments to the block buffer. *)
  | InputJsonSnapshot of string
  (** A whole tool-call arguments value serialized in a single delta, used
          by providers that stream [arguments] as a JSON object/array instead of
          string fragments. The accumulator replaces the block buffer rather
          than appending, so a provider that re-emits the same complete value
          does not concatenate it into invalid JSON (e.g.
          [{"limit":10}{"limit":10}]). *)
  | MediaDelta of
      { media_type : string
      ; source_type : media_source_kind
      ; data : string
      }
  (** A chunk of a streamed media (image/document/audio) content block.
            Carries the block-level [media_type] and [source_type] alongside the
            [data] payload so the SSE layer needs no new {!ContentBlockStart}
            fields; the accumulator records the metadata (idempotent across
            chunks) and concatenates [data]. *)

type sse_event =
  | MessageStart of
      { id : string
      ; model : string
      ; usage : api_usage option
      }
  | ContentBlockStart of
      { index : int
      ; content_type : string
      ; tool_id : string option
      ; tool_name : string option
      }
  | ContentBlockDelta of
      { index : int
      ; delta : content_delta
      }
  | ContentBlockStop of { index : int }
  | MessageDelta of
      { stop_reason : stop_reason option
      ; usage : api_usage option
      }
  | MessageStop
  | Ping
  | SSEError of
      { message : string
      ; error_type : string option
        (** Provider error-object [type] (e.g. ["rate_limit_exceeded"]),
                the streaming-time discriminator. Lets a mid-stream error
                converge onto the same classification path as an initial HTTP
                error instead of collapsing to [NetworkError {Unknown}].
                [None] when the provider omits it. *)
      ; raw : string
        (** Original error payload JSON, carried verbatim so the consumer
                can feed it to [Retry.classify_error] (retry_after, hard-quota
                detection) exactly as the non-streaming path does. *)
      }
  | NDJSONError of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | SSEParseFailed of
      { raw : string
      ; reason : string
      }
  | NDJSONParseFailed of
      { raw : string
      ; reason : string
      }
  | SSEUnknownEventType of
      { event_type : string
      ; raw : string
      }
  | SSEUnsupportedPart of
      { provider_kind : Provider_kind.t
      ; part : string
      ; raw : string
      }
  | SSEUnsupportedResponse of
      { provider_kind : Provider_kind.t
      ; response : string
      ; raw : string
      }
  | Connected
  | Timeout of string
  | StreamIncomplete of { reason : string }

(** Terminal error captured while accumulating a streaming response.

    The accumulator stores this typed value (not a flattened string). Provider
    envelopes, malformed payloads, unknown events, and incomplete streams are
    preserved as distinct facts at the transport boundary; retry policy is
    decided above OAS. This replaces the prior [string] carrier that collapsed
    provider-owned failures into one [NetworkError {Unknown}] bucket. *)
type stream_error =
  | Stream_provider_error of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | Stream_parse_failed of
      { reason : string
      ; raw : string
      }
  | Stream_ndjson_parse_failed of
      { reason : string
      ; raw : string
      }
  | Stream_incomplete of { reason : string }
  | Stream_unknown_event of
      { event_type : string
      ; raw : string
      }
  | Stream_unsupported_part of
      { provider_kind : Provider_kind.t
      ; part : string
      ; raw : string
      }
  | Stream_unsupported_response of
      { provider_kind : Provider_kind.t
      ; response : string
      ; raw : string
      }

(** {1 Convenience Constructors}

    Convenience constructors for consumers that work with flat [string]
    messages and need to convert to [content_block list]. *)

(** Create a message with default [None] for optional fields. *)
let make_message ?name ?tool_call_id ?(metadata = []) ~role content =
  { role; content; name; tool_call_id; metadata }
;;

(** Create a text content block. *)
let text_block text = Text text

(** Create a base64-backed image content block by default. *)
let image_block ?(source_type = Base64) ~media_type ~data () =
  Image { media_type; data; source_type }
;;

(** Create a base64-backed document content block by default. *)
let document_block ?(source_type = Base64) ~media_type ~data () =
  Document { media_type; data; source_type }
;;

(** Create a base64-backed audio content block by default. *)
let audio_block ?(source_type = Base64) ~media_type ~data () =
  Audio { media_type; data; source_type }
;;

(** Create a text-only message. *)
let text_message role text = make_message ~role [ Text text ]

(** Create a user message from arbitrary content blocks. *)
let user_msg_blocks blocks = make_message ~role:User blocks

(** Create a system message. *)
let system_msg text = text_message System text

(** Create a user message. *)
let user_msg text = text_message User text

(** Create an assistant message. *)
let assistant_msg text = text_message Assistant text

(** Try to parse content as JSON, returning None on failure. *)
let try_parse_json (s : string) : Yojson.Safe.t option =
  if String.length s = 0
  then None
  else (
    match Yojson.Safe.from_string s with
    | json -> Some json
    | exception Yojson.Json_error _ -> None)
;;

(** Create a tool result message.
    When [json] is not provided, attempts to parse [content] as JSON
    so downstream consumers can access structured data without re-parsing. *)
let tool_result_msg ~tool_use_id ~content ?(outcome = Tool_succeeded) ?json () =
  let json =
    match json with
    | Some _ -> json
    | None -> try_parse_json content
  in
  make_message
    ~tool_call_id:tool_use_id
    ~role:Tool
    [ ToolResult { tool_use_id; content; outcome; json; content_blocks = None } ]
;;

(** {1 Tool Result Validation}

    Minimal structural validation for tool result payloads.
    P0 Verification Loop will extend this with full JSON Schema checking. *)

type tool_result_validation_error =
  | Expected_object of string (** Expected JSON object, got other type *)
  | Expected_array of string (** Expected JSON array, got other type *)
  | Empty_content of string (** Tool returned empty content *)
  | Json_parse_failed of string (** Content is not valid JSON *)
[@@deriving show]

(** Validate that a ToolResult's payload matches a minimal expected shape.
    Returns [Ok ()] when the result passes, or a descriptive error.
    This is the foundation for P0's full JSON Schema validation loop. *)
let validate_tool_result_shape
      ~expect_object:(expect_obj : bool)
      ~expect_array:(expect_arr : bool)
      (block : content_block)
  : (unit, tool_result_validation_error) result
  =
  match block with
  | ToolResult { content; json; _ } ->
    if String.length (String.trim content) = 0
    then Error (Empty_content "ToolResult content is empty")
    else if expect_obj || expect_arr
    then (
      match json with
      | None ->
        (* content was not parseable as JSON *)
        Error (Json_parse_failed "ToolResult content is not valid JSON")
      | Some json_value ->
        if expect_obj && not expect_arr
        then (
          match json_value with
          | `Assoc _ -> Ok ()
          | _ -> Error (Expected_object "ToolResult JSON is not an object"))
        else if expect_arr && not expect_obj
        then (
          match json_value with
          | `List _ -> Ok ()
          | _ -> Error (Expected_array "ToolResult JSON is not an array"))
        else
          (* Both allowed — any JSON is fine *)
          Ok ())
    else Ok ()
  | _ -> Ok ()
;;

(** Extract text from content blocks, concatenating with newlines.
    Drops Thinking, Image, ToolUse, etc. *)
let text_of_content content =
  content
  |> List.filter_map (function
    | Text s -> Some s
    | ToolResult { content; _ } -> Some content
    | _ -> None)
  |> String.concat "\n"
;;

(** Extract text from a message. *)
let text_of_message (msg : message) = text_of_content msg.content

(** Extract text from an api_response. *)
let text_of_response (resp : api_response) = text_of_content resp.content

(** Extract end-user-visible assistant text from content blocks.
    This is intentionally narrower than [text_of_content]: tool results are
    model-visible execution payloads, and Thinking blocks are provider reasoning
    payloads. Neither belongs in an answer-text projection. *)
let visible_text_of_content content =
  content
  |> List.filter_map (function
    | Text s -> Some s
    | Thinking _
    | ReasoningDetails _
    | RedactedThinking _
    | ToolUse _
    | ToolResult _
    | Image _
    | Document _
    | Audio _ -> None)
  |> String.concat "\n"
;;

(** Extract end-user-visible assistant text from a message. *)
let visible_text_of_message (msg : message) = visible_text_of_content msg.content

(** Extract end-user-visible assistant text from an api_response. *)
let visible_text_of_response (resp : api_response) = visible_text_of_content resp.content

(** {1 Usage Helpers} *)

let zero_api_usage =
  { input_tokens = 0
  ; output_tokens = 0
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = None
  }
;;

let usage_of_response (resp : api_response) = resp.usage
let total_tokens (usage : api_usage) = usage.input_tokens + usage.output_tokens
