(** Tool_input_validation — Pre-dispatch validation via AGENT_CORE Tool_middleware.

    Delegates to [Agent_core.Tool_middleware.make_validation_hook] for strict
    schema checking and structured error feedback. AGENT_CORE 0.212 removed implicit
    type coercion: a mistyped scalar (e.g. string for integer) is a
    deterministic Reject carrying the field name, not a silent repair.

    @since 2.220.0 — AGENT_CORE delegation
    @since 2.221.0 — use Tool_middleware.make_validation_hook *)

(** Register input validation as a Tool_dispatch pre-hook.
    Must be called after all tool schemas are registered (server init).

    Tools without a registered schema are rejected fail-closed.  Empty
    schemas are accepted only for empty/no-arg calls. *)
let is_internal_marker_key key = String.length key > 0 && Char.equal key.[0] '_'

let strip_internal_marker_args (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
    `Assoc (List.filter (fun (key, _) -> not (is_internal_marker_key key)) fields)
  | _ -> args
;;

let required_names schema =
  match Json_util.assoc_member_opt "required" schema with
  | Some (`List items) ->
    List.filter_map
      (function
        | `String name -> Some name
        | _ -> None)
      items
  | _ -> []
;;

let schema_property_names schema =
  match Json_util.assoc_member_opt "properties" schema with
  | Some (`Assoc props) -> List.map fst props
  | _ -> []
;;

type schema_shape =
  { properties : string list
  ; required : string list
  ; one_of_required : string list list
  ; errors : string list
  }

let validated_property_names schema =
  match Json_util.assoc_member_opt "properties" schema with
  | None -> [], []
  | Some (`Assoc properties) -> List.map fst properties, []
  | Some other ->
    ( []
    , [ Printf.sprintf
          "properties: expected object, got %s"
          (Json_util.kind_name other)
      ] )
;;

let validated_required_names ?(path = "required") schema =
  match Json_util.assoc_member_opt "required" schema with
  | None -> [], []
  | Some (`List values) ->
    List.fold_right
      (fun value (names, errors) ->
         match value with
         | `String name ->
           let name = String.trim name in
           if String.equal name ""
           then
             ( names
             , Printf.sprintf "%s: expected non-empty string, got string" path
               :: errors )
           else name :: names, errors
         | other ->
           ( names
           , Printf.sprintf
               "%s: expected non-empty string, got %s"
               path
               (Json_util.kind_name other)
             :: errors ))
      values
      ([], [])
  | Some other ->
    ( []
    , [ Printf.sprintf
          "%s: expected string array, got %s"
          path
          (Json_util.kind_name other)
      ] )
;;

let validated_one_of_required_names schema =
  match Json_util.assoc_member_opt "oneOf" schema with
  | None -> [], []
  | Some (`List cases) ->
    let mapped_cases =
      List.mapi
        (fun index case ->
           match case with
           | `Assoc _ ->
             let required, errors =
               validated_required_names
                 ~path:(Printf.sprintf "oneOf[%d].required" index)
                 case
             in
             Some required, errors
           | other ->
             ( None
             , [ Printf.sprintf
                   "oneOf[%d]: expected object, got %s"
                   index
                   (Json_util.kind_name other)
               ] ))
        cases
    in
    List.fold_right
      (fun (required, errors) (required_acc, error_acc) ->
         ( match required with
           | Some required -> required :: required_acc
           | None -> required_acc )
         , errors @ error_acc)
      mapped_cases
      ([], [])
  | Some other ->
    ( []
    , [ Printf.sprintf
          "oneOf: expected object array, got %s"
          (Json_util.kind_name other)
      ] )
;;

let schema_shape schema =
  let properties, property_errors = validated_property_names schema in
  let required, required_errors = validated_required_names schema in
  let one_of_required, one_of_errors = validated_one_of_required_names schema in
  { properties
  ; required
  ; one_of_required
  ; errors = property_errors @ required_errors @ one_of_errors
  }
;;

let schema_shape_json schema =
  let shape = schema_shape schema in
  let base =
    [ "properties", Json_util.json_string_list shape.properties
    ; "required", Json_util.json_string_list shape.required
    ]
  in
  let fields =
    if shape.one_of_required = []
    then base
    else
      ( "one_of_required"
      , `List (List.map Json_util.json_string_list shape.one_of_required) )
      :: base
  in
  let fields =
    if shape.errors = []
    then fields
    else ("schema_errors", Json_util.json_string_list shape.errors) :: fields
  in
  `Assoc fields
;;

let prepare_args ?schema:_ ~name:_ args = strip_internal_marker_args args

let schema_has_properties = function
  | `Assoc fields ->
    (match List.assoc_opt "properties" fields with
     | Some (`Assoc (_ :: _)) -> true
     | _ ->
       (match List.assoc_opt "oneOf" fields with
        | Some (`List (_ :: _)) -> true
        | _ -> false))
  | _ -> false
;;

let property_names schema =
  schema_property_names schema
;;

let forbids_additional_properties schema =
  match Json_util.assoc_member_opt "additionalProperties" schema with
  | Some (`Bool false) -> true
  | _ -> false
;;

let unsupported_arg_names schema = function
  | `Assoc fields when forbids_additional_properties schema ->
    let properties = property_names schema in
    fields
    |> List.filter_map (fun (name, _) ->
      if List.mem name properties then None else Some name)
    |> List.sort_uniq String.compare
  | _ -> []
;;

type one_of_branch = {
  required : string list;
  consts : (string * Yojson.Safe.t) list;
  forbidden_required : string list;
}

let one_of_branch_constraints schema =
  match Json_util.assoc_member_opt "oneOf" schema with
  | Some (`List branches) ->
    let constraints =
      List.filter_map
        (fun branch ->
           let required = required_names branch in
           if required = []
           then None
           else
             let consts =
               match Json_util.assoc_member_opt "properties" branch with
               | Some (`Assoc props) ->
                 List.filter_map
                   (fun (name, prop_schema) ->
                      match prop_schema with
                      | `Assoc prop_fields ->
                        (match List.assoc_opt "const" prop_fields with
                         | Some const_value -> Some (name, const_value)
                         | None -> None)
                      | _ -> None)
                   props
               | _ -> []
             in
             let forbidden_required =
               match Json_util.assoc_member_opt "not" branch with
               | Some (`Assoc _ as not_schema) -> required_names not_schema
               | _ -> []
             in
             Some { required; consts; forbidden_required })
        branches
    in
    if List.length constraints = List.length branches then constraints else []
  | _ -> []
;;

let branch_label b =
  let const_parts =
    List.map
      (fun (name, value) ->
         Printf.sprintf "%s=%s" name (Yojson.Safe.to_string value))
      b.consts
  in
  let req_without_consts =
    List.filter (fun name -> not (List.mem_assoc name b.consts)) b.required
  in
  String.concat "+" (const_parts @ req_without_consts)
;;

let one_of_required_shape_error schema = function
  | `Assoc fields ->
    let branches = one_of_branch_constraints schema in
    if branches = []
    then None
    else (
      let has_present name =
        match List.assoc_opt name fields with
        | None -> false
        | Some `Null -> false
        | Some (`List []) -> false
        | Some _ -> true
      in
      let key_is_present name = Option.is_some (List.assoc_opt name fields) in
      let const_field_matches name expected =
        match List.assoc_opt name fields with
        | Some actual -> Yojson.Safe.equal actual expected
        | None -> true (* const is optional; absence does not disqualify *)
      in
      let branch_matches branch =
        List.for_all has_present branch.required
        && not (List.exists key_is_present branch.forbidden_required)
        && List.for_all
             (fun (name, expected) -> const_field_matches name expected)
             branch.consts
      in
      let matching = List.filter branch_matches branches in
      match matching with
      | [ _ ] -> None
      | [] ->
        let options =
          branches |> List.map branch_label |> String.concat " | "
        in
        Some (Printf.sprintf "arguments must include exactly one of: %s" options)
      | _ :: _ :: _ ->
        let options =
          matching |> List.map branch_label |> String.concat " | "
        in
        Some
          (Printf.sprintf
             "arguments match multiple mutually exclusive schemas: %s"
             options))
  | _ -> None
;;

(* The rejection names the fields the schema does accept, so the model can
   correct the call from the message alone instead of guessing a new name
   (analyst, 2026-08-22: agent → agent_name → author before it found the
   declared shape). *)
let schema_shape_error schema args =
  match unsupported_arg_names schema args with
  | name :: names ->
    let names_text = String.concat ", " (name :: names) in
    let accepted =
      match property_names schema with
      | [] -> "(none)"
      | accepted -> String.concat ", " accepted
    in
    Some
      (Printf.sprintf
         "received unsupported field(s): %s; accepted: %s"
         names_text
         accepted)
  | [] -> one_of_required_shape_error schema args
;;

(* ---------------------------------------------------------------- *)
(* Declared range/length constraints                                  *)
(*                                                                    *)
(* [Tool_bridge.params_of_json_schema] projects a JSON Schema onto the *)
(* AGENT_CORE [tool_param] record, which carries name/type/required only.     *)
(* Every minimum/maximum/minLength/maxLength/minItems/maxItems is      *)
(* dropped there, so agent core validation hook cannot see it. These      *)
(* checks therefore read the raw JSON Schema masc already holds.       *)
(* ---------------------------------------------------------------- *)

type numeric_keyword =
  | Minimum
  | Maximum
  | Exclusive_minimum
  | Exclusive_maximum

type count_keyword =
  | Min_length
  | Max_length
  | Min_items
  | Max_items

let numeric_keyword_json_name = function
  | Minimum -> "minimum"
  | Maximum -> "maximum"
  | Exclusive_minimum -> "exclusiveMinimum"
  | Exclusive_maximum -> "exclusiveMaximum"
;;

let count_keyword_json_name = function
  | Min_length -> "minLength"
  | Max_length -> "maxLength"
  | Min_items -> "minItems"
  | Max_items -> "maxItems"
;;

let numeric_keywords = [ Minimum; Maximum; Exclusive_minimum; Exclusive_maximum ]
let count_keywords = [ Min_length; Max_length; Min_items; Max_items ]

let constraint_keyword_json_names =
  List.map numeric_keyword_json_name numeric_keywords
  @ List.map count_keyword_json_name count_keywords
;;

(** A rejection caused by declared constraints. [Argument_out_of_range] is
    the caller's fault; [Schema_bound_malformed] is masc's — a declared
    bound that cannot be read. Both fail closed, and both keep the field
    path so the message names what to change. *)
type constraint_failure =
  | Argument_out_of_range of string
  | Schema_bound_malformed of string

type numeric_value =
  | Numeric_int of int
  | Numeric_float of float

let numeric_of_json : Yojson.Safe.t -> numeric_value option = function
  | `Int value -> Some (Numeric_int value)
  | `Float value when Float.is_finite value -> Some (Numeric_float value)
  | `Intlit literal ->
    (match int_of_string_opt literal with
     | Some value -> Some (Numeric_int value)
     | None -> None)
  | `Float _ | `Null | `Bool _ | `String _ | `Assoc _ | `List _ -> None
;;

(* Compare one native integer with one finite float without first rounding
   the integer to IEEE-754. [float_of_int] loses units above 2^53, which can
   otherwise make [maximum=9007199254740992.0] accept the integer one above
   it. OCaml ints occupy [Sys.int_size - 1] value bits; the positive limit is
   not itself representable as an int, while the negative limit is [min_int]. *)
let compare_int_float integer floating =
  let integer_magnitude_limit = Float.ldexp 1.0 (Sys.int_size - 1) in
  if floating >= integer_magnitude_limit
  then -1
  else if floating < -.integer_magnitude_limit
  then 1
  else
    let integral_part = int_of_float floating in
    let comparison = Int.compare integer integral_part in
    if comparison <> 0
    then comparison
    else Float.compare (Float.of_int integer) floating
;;

let numeric_compare left right =
  match left, right with
  | Numeric_int left, Numeric_int right -> Int.compare left right
  | Numeric_int left, Numeric_float right -> compare_int_float left right
  | Numeric_float left, Numeric_int right -> -(compare_int_float right left)
  | Numeric_float left, Numeric_float right -> Float.compare left right
;;

let numeric_to_string = function
  | Numeric_int value -> string_of_int value
  | Numeric_float value -> Printf.sprintf "%g" value
;;

(* JSON Schema counts string length in characters, not bytes. Counting
   bytes would reject a Korean title well under a declared maxLength. *)
let utf8_character_count source =
  let source_length = String.length source in
  let rec loop index count =
    if index >= source_length
    then count
    else (
      let decoded = String.get_utf_8_uchar source index in
      (* [utf_decode_length] is at least 1 even for an invalid byte, so the
         walk always terminates. *)
      loop (index + Uchar.utf_decode_length decoded) (count + 1))
  in
  loop 0 0
;;

let count_bound_of_json : Yojson.Safe.t -> int option = function
  | `Int value when value >= 0 -> Some value
  | `Float value
    when Float.is_integer value
         && value >= 0.0
         && value <= Float.of_int Int.max_int -> Some (int_of_float value)
  | `Intlit literal ->
    (match int_of_string_opt literal with
     | Some value when value >= 0 -> Some value
     | Some _ | None -> None)
  | `Int _
  | `Float _
  | `Null
  | `Bool _
  | `String _
  | `Assoc _
  | `List _
  -> None
;;

let schema_value_to_diagnostic_string = function
  | `Float value when not (Float.is_finite value) ->
    (match classify_float value with
     | FP_nan -> "NaN"
     | FP_infinite when value > 0.0 -> "Infinity"
     | FP_infinite -> "-Infinity"
     | FP_normal | FP_subnormal | FP_zero -> Printf.sprintf "%g" value)
  | value -> Yojson.Safe.to_string value
;;

let malformed_bound ~path ~keyword ~declared =
  Schema_bound_malformed
    (Printf.sprintf
       "schema declares an unreadable %s for %s: %s"
       keyword
       path
       (schema_value_to_diagnostic_string declared))
;;

(* A value whose JSON kind the keyword does not apply to is left alone:
   the declared [type] is enforced by the AGENT_CORE hook that already ran, so a
   surviving mismatch means the schema itself pairs a keyword with an
   incompatible type. [test_tool_input_validation] pins that no masc
   schema does. *)
let numeric_constraint_failure ~path ~keyword ~declared value =
  match numeric_of_json declared with
  | None ->
    Some
      (malformed_bound
         ~path
         ~keyword:(numeric_keyword_json_name keyword)
         ~declared)
  | Some bound ->
    (match numeric_of_json value with
     | None ->
       (match value with
        | `Float value when not (Float.is_finite value) ->
          Some
            (Argument_out_of_range
               (Printf.sprintf "%s must be a finite number" path))
        | `Intlit literal ->
          Some
            (Argument_out_of_range
               (Printf.sprintf
                  "%s integer literal %s is outside the native exact-comparison range"
                  path
                  literal))
        | `Int _ | `Float _ | `Null | `Bool _ | `String _ | `Assoc _ | `List _ ->
          None)
     | Some actual ->
       let comparison = numeric_compare actual bound in
       let violated =
         match keyword with
         | Minimum -> comparison < 0
         | Exclusive_minimum -> comparison <= 0
         | Maximum -> comparison > 0
         | Exclusive_maximum -> comparison >= 0
       in
       if not violated
       then None
       else (
         let actual_text = numeric_to_string actual in
         let bound_text = numeric_to_string bound in
         Some
           (Argument_out_of_range
              (match keyword with
               | Minimum ->
                 Printf.sprintf
                   "%s %s is below minimum %s"
                   path
                   actual_text
                   bound_text
               | Exclusive_minimum ->
                 Printf.sprintf
                   "%s %s is not greater than exclusiveMinimum %s"
                   path
                   actual_text
                   bound_text
               | Maximum ->
                 Printf.sprintf
                   "%s %s exceeds maximum %s"
                   path
                   actual_text
                   bound_text
               | Exclusive_maximum ->
                 Printf.sprintf
                   "%s %s is not less than exclusiveMaximum %s"
                   path
                   actual_text
                   bound_text))))
;;

let count_constraint_failure ~path ~keyword ~declared value =
  let measured =
    match keyword, value with
    | (Min_length | Max_length), `String text -> Some (utf8_character_count text)
    | (Min_items | Max_items), `List items -> Some (List.length items)
    | (Min_length | Max_length | Min_items | Max_items), _ -> None
  in
  match measured with
  | None -> None
  | Some actual ->
    (match count_bound_of_json declared with
     | None ->
       Some
         (malformed_bound ~path ~keyword:(count_keyword_json_name keyword) ~declared)
     | Some bound ->
       let violated =
         match keyword with
         | Min_length | Min_items -> actual < bound
         | Max_length | Max_items -> actual > bound
       in
       if not violated
       then None
       else
         Some
           (Argument_out_of_range
              (match keyword with
               | Min_length ->
                 Printf.sprintf
                   "%s has %d character(s), below minLength %d"
                   path
                   actual
                   bound
               | Max_length ->
                 Printf.sprintf
                   "%s has %d character(s), above maxLength %d"
                   path
                   actual
                   bound
               | Min_items ->
                 Printf.sprintf
                   "%s has %d item(s), below minItems %d"
                   path
                   actual
                   bound
               | Max_items ->
                 Printf.sprintf
                   "%s has %d item(s), above maxItems %d"
                   path
                   actual
                   bound)))
;;

let child_property_path parent name =
  if String.equal parent "" then name else parent ^ "." ^ name
;;

let rec constraint_failures ~path schema value =
  match schema with
  | `Assoc schema_fields ->
    let declared_here =
      List.filter_map
        (fun keyword ->
           match
             List.assoc_opt (numeric_keyword_json_name keyword) schema_fields
           with
           | None -> None
           | Some declared -> numeric_constraint_failure ~path ~keyword ~declared value)
        numeric_keywords
      @ List.filter_map
          (fun keyword ->
             match
               List.assoc_opt (count_keyword_json_name keyword) schema_fields
             with
             | None -> None
             | Some declared -> count_constraint_failure ~path ~keyword ~declared value)
          count_keywords
    in
    let nested =
      match value with
      | `Assoc value_fields ->
        (match List.assoc_opt "properties" schema_fields with
         | Some (`Assoc property_schemas) ->
           List.concat_map
             (fun (property_name, property_schema) ->
                match List.assoc_opt property_name value_fields with
                | None -> []
                | Some property_value ->
                  constraint_failures
                    ~path:(child_property_path path property_name)
                    property_schema
                    property_value)
             property_schemas
         | _ -> [])
      | `List items ->
        (match List.assoc_opt "items" schema_fields with
         | Some (`Assoc _ as item_schema) ->
           List.concat
             (List.mapi
                (fun index item ->
                   constraint_failures
                     ~path:(Printf.sprintf "%s[%d]" path index)
                     item_schema
                     item)
                items)
         | _ -> [])
      | _ -> []
    in
    declared_here @ nested
  | _ -> []
;;

(** Malformed declarations are schema defects independently of whether the
    corresponding optional argument was supplied. Checking them in a separate
    schema-only walk keeps an omitted field from turning fail-closed validation
    into a silent pass. *)
let rec malformed_schema_bound_failures ~path schema =
  match schema with
  | `Assoc schema_fields ->
    let declared_here =
      List.filter_map
        (fun keyword ->
           match
             List.assoc_opt (numeric_keyword_json_name keyword) schema_fields
           with
           | None -> None
           | Some declared ->
             (match numeric_of_json declared with
              | Some _ -> None
              | None ->
                Some
                  (malformed_bound
                     ~path
                     ~keyword:(numeric_keyword_json_name keyword)
                     ~declared)))
        numeric_keywords
      @ List.filter_map
          (fun keyword ->
             match
               List.assoc_opt (count_keyword_json_name keyword) schema_fields
             with
             | None -> None
             | Some declared ->
               (match count_bound_of_json declared with
                | Some _ -> None
                | None ->
                  Some
                    (malformed_bound
                       ~path
                       ~keyword:(count_keyword_json_name keyword)
                       ~declared)))
          count_keywords
    in
    let nested_properties =
      match List.assoc_opt "properties" schema_fields with
      | Some (`Assoc property_schemas) ->
        List.concat_map
          (fun (property_name, property_schema) ->
             malformed_schema_bound_failures
               ~path:(child_property_path path property_name)
               property_schema)
          property_schemas
      | _ -> []
    in
    let nested_items =
      match List.assoc_opt "items" schema_fields with
      | Some (`Assoc _ as item_schema) ->
        malformed_schema_bound_failures ~path:(path ^ "[]") item_schema
      | _ -> []
    in
    declared_here @ nested_properties @ nested_items
  | _ -> []
;;

(** First declared-constraint failure for [args], or [None]. A malformed
    bound is reported ahead of an out-of-range argument: masc's own schema
    defect must not be blamed on the caller. *)
let schema_constraint_failure schema args =
  match malformed_schema_bound_failures ~path:"" schema with
  | malformed :: _ -> Some malformed
  | [] ->
    let failures = constraint_failures ~path:"" schema args in
    (match failures with
     | [] -> None
     | first :: _ -> Some first)
;;

(** Every constraint declaration {!constraint_failures} can reach, as
    ["<field path>:<keyword>"]. Compared in tests against a raw scan of the
    whole schema so a declaration placed where the walker does not descend
    (a [oneOf] branch, a tuple-form [items]) is caught instead of silently
    unenforced. *)
let rec constraint_declaration_paths_at ~path schema =
  match schema with
  | `Assoc schema_fields ->
    let declared_here =
      List.filter_map
        (fun keyword_name ->
           if List.mem_assoc keyword_name schema_fields
           then Some (Printf.sprintf "%s:%s" path keyword_name)
           else None)
        constraint_keyword_json_names
    in
    let nested_properties =
      match List.assoc_opt "properties" schema_fields with
      | Some (`Assoc property_schemas) ->
        List.concat_map
          (fun (property_name, property_schema) ->
             constraint_declaration_paths_at
               ~path:(child_property_path path property_name)
               property_schema)
          property_schemas
      | _ -> []
    in
    let nested_items =
      match List.assoc_opt "items" schema_fields with
      | Some (`Assoc _ as item_schema) ->
        constraint_declaration_paths_at ~path:(path ^ "[]") item_schema
      | _ -> []
    in
    declared_here @ nested_properties @ nested_items
  | _ -> []
;;

let constraint_declaration_paths schema =
  constraint_declaration_paths_at ~path:"" schema
;;

let retired_transition_alias_names ~name = function
  | `Assoc fields when String.equal name "masc_transition" ->
    fields
    |> List.filter_map (fun (field, _) ->
      if String.equal field "to" || String.equal field "note" then Some field else None)
    |> List.sort_uniq String.compare
  | _ -> []
;;

let empty_tool_args = function
  | `Null | `Assoc [] -> true
  | _ -> false
;;

(* Empty input on a schema that cannot accept it is almost never a deliberate
   call: in the masc#29337 family the wire carried an empty object because the
   arguments never arrived (2026-08-26, keeper edgar.a.poe on GLM-5-turbo:
   Execute rejected on 5/5 attempts, masc_schedule_create 48 times), and the
   model looped on the generic shape error without learning that its arguments
   were lost, not merely wrong.  Say so explicitly, name the field(s) the call
   needed, and reject under a dedicated telemetry reason so the fleet-wide rate
   is measurable.  [one_of_branch_constraints] is [] unless every branch
   requires a field, which is exactly when empty input cannot match any
   branch; a schema with an all-optional branch keeps the generic path. *)
let empty_args_rejection schema args =
  if not (empty_tool_args args)
  then None
  else
    match required_names schema with
    | [] ->
      (match one_of_branch_constraints schema with
       | [] -> None
       | branches ->
         let options =
           branches |> List.map branch_label |> String.concat " | "
         in
         Some
           (Printf.sprintf
              "received an empty input object: the arguments did not arrive with \
               the call. The input must include exactly one of: %s. Re-emit the \
               tool call with the input object populated."
              options))
    | required ->
      Some
        (Printf.sprintf
           "received an empty input object: the arguments did not arrive with \
            the call. Required field(s): %s. Re-emit the tool call with the \
            input object populated."
           (String.concat ", " required))
;;

let emit_validation_telemetry ~tool ~result ~reason =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_tool_input_validation
    ~labels:[ "tool", tool; "result", result; "reason", reason ]
    ();
  Otel_spans.add_event
    ~name:"tool.param.validation"
    ~attrs:
      [ "tool.name", `String tool
      ; "tool.param.validation.result", `String result
      ; "tool.param.validation.reason", `String reason
      ]
    ()
;;

let pass_reason ~schema ~args ~prepared_args =
  match schema with
  | Some schema when not (schema_has_properties schema) -> "empty_schema"
  | Some _ when not (Yojson.Safe.equal prepared_args args) -> "normalized"
  | Some _ -> "valid"
  | None -> "missing_schema"
;;

(* Typed end to end: the params this hook already holds go straight into the
   authoritative constructor. The previous version rendered them to JSON and
   reparsed via [tool_schema_of_json], with a [failwith] on the reparse — a
   round-trip through a wire format that never left the process
   (RFC-0371 §3.1). *)
let validation_schema_of_json ~name json_schema : Agent_core.Types.tool_schema =
  let parameters = Tool_bridge.params_of_json_schema json_schema in
  Agent_core.Types.tool_schema_of_params ~name ~description:"" ~parameters ()
;;

(* [~schema] rather than [?schema]: every caller passes it, and the value is
   already an option, so an optional parameter here could not be erased and
   made the caller's [option] the wrong type. *)
let reject_validation ~(schema : Yojson.Safe.t option) ~name ~reason ~message =
  emit_validation_telemetry ~tool:name ~result:"fail" ~reason;
  Log.Tool_validation.info "tool_input_validation rejected %s: %s" name message;
  let base_data =
    [ "error", `String message
    ; "validation", `String "agent_core_tool_middleware"
    ; "reason", `String reason
    ; ( "failure_class"
      , `String
          (Tool_result.tool_failure_class_to_string
             Tool_result.Policy_rejection) )
    ]
  in
  let data =
    match schema with
    | None -> `Assoc base_data
    | Some schema -> `Assoc (("schema_shape", schema_shape_json schema) :: base_data)
  in
  Tool_dispatch.Reject
    (Tool_result.Failed
       { Tool_result.class_ = Tool_result.Policy_rejection
       ; message
       ; data
       ; metadata = None
       ; tool_name = name
       ; duration_ms = 0.0
       })
;;

let validation_exception_action ~name exn : Tool_dispatch.pre_hook_action =
  let error_text = Printexc.to_string exn in
  let message =
    Printf.sprintf
      "Tool '%s' parameter validation failed before dispatch: %s"
      name
      error_text
  in
  emit_validation_telemetry ~tool:name ~result:"fail" ~reason:"validation_exception";
  Log.Tool_validation.error "%s" message;
  Tool_dispatch.Reject
    (Tool_result.Failed
       { Tool_result.class_ = Tool_result.Runtime_failure
       ; message
       ; data =
           `Assoc
             [ "error", `String message
             ; "validation", `String "agent_core_tool_middleware"
             ; "exception", `String error_text
             ]
       ; metadata = None
       ; tool_name = name
       ; duration_ms = 0.0
       })
;;

let validation_action ?schema ~name ~args () : Tool_dispatch.pre_hook_action =
  try
    let schema =
      match schema with
      | Some _ as schema -> schema
      | None -> Tool_dispatch.lookup_schema name
    in
    let prepared_args = prepare_args ?schema ~name args in
    match schema with
    | None ->
      reject_validation
        ~schema
        ~name
        ~reason:"missing_schema"
        ~message:
          (Printf.sprintf
             "Tool '%s' has no registered input schema; refusing schema-less dispatch"
             name)
    | Some schema when not (schema_has_properties schema) ->
      let required = required_names schema in
      if required <> []
      then
        reject_validation
          ~schema:(Some schema)
          ~name
          ~reason:"malformed_schema"
          ~message:
            (Printf.sprintf
               "Tool '%s' schema declares required fields without input properties"
               name)
      else if empty_tool_args prepared_args
      then (
        emit_validation_telemetry ~tool:name ~result:"pass" ~reason:"empty_schema";
        if Yojson.Safe.equal prepared_args args
        then Tool_dispatch.Pass
        else Tool_dispatch.Proceed prepared_args)
      else
        reject_validation
          ~schema:(Some schema)
          ~name
          ~reason:"empty_schema_args"
          ~message:
            (Printf.sprintf
               "Tool '%s' declares no input fields but received arguments"
               name)
    | Some schema ->
      (match retired_transition_alias_names ~name prepared_args with
       | alias :: aliases ->
         let aliases = String.concat ", " (alias :: aliases) in
         reject_validation
           ~schema:(Some schema)
           ~name
           ~reason:"invalid_args"
           ~message:
             (Printf.sprintf
                "Tool '%s' received retired transition alias field(s): %s; use \
                 action and notes"
                name
                aliases)
       | [] ->
      (match empty_args_rejection schema prepared_args with
       | Some message ->
         reject_validation
           ~schema:(Some schema)
           ~name
           ~reason:"empty_args_required"
           ~message:(Printf.sprintf "Tool '%s' %s" name message)
       | None ->
      (match schema_shape_error schema prepared_args with
       | Some message ->
         reject_validation
           ~schema:(Some schema)
           ~name
           ~reason:"invalid_args"
           ~message:(Printf.sprintf "Tool '%s' %s" name message)
       | None ->
         let lookup lookup_name =
           let schema_opt =
             if String.equal lookup_name name
             then Some schema
             else Tool_dispatch.lookup_schema lookup_name
           in
           Option.map (validation_schema_of_json ~name:lookup_name) schema_opt
         in
         let hook = Agent_core.Tool_middleware.make_validation_hook ~lookup in
         (* Declared ranges are checked only once agent core has accepted the
            declared types, so a mistyped value reports its type error
            rather than a confusing range error. *)
         (match hook ~name ~args:prepared_args with
    | Agent_core.Tool_middleware.Pass ->
      (match schema_constraint_failure schema prepared_args with
       | Some (Argument_out_of_range message) ->
         reject_validation
           ~schema:(Some schema)
           ~name
           ~reason:"invalid_args"
           ~message:(Printf.sprintf "Tool '%s' %s" name message)
       | Some (Schema_bound_malformed message) ->
         reject_validation
           ~schema:(Some schema)
           ~name
           ~reason:"malformed_schema"
           ~message:(Printf.sprintf "Tool '%s' %s" name message)
       | None ->
         let reason = pass_reason ~schema:(Some schema) ~args ~prepared_args in
         emit_validation_telemetry ~tool:name ~result:"pass" ~reason;
         if Yojson.Safe.equal prepared_args args
         then Tool_dispatch.Pass
         else (
           Log.Tool_validation.debug
             "tool_input_validation normalized args for %s"
             name;
           Tool_dispatch.Proceed prepared_args))
    | Agent_core.Tool_middleware.Reject { message; _ } ->
      emit_validation_telemetry ~tool:name ~result:"fail" ~reason:"invalid_args";
      Log.Tool_validation.info "tool_input_validation rejected %s: %s" name message;
      (* Input-schema / policy rejection — classify so the
         dispatch-level metric label (failure_class) reflects the
         actual category instead of bucketing as "unclassified". *)
      Tool_dispatch.Reject
        (Tool_result.Failed
           { Tool_result.class_ = Tool_result.Policy_rejection
           ; message
           ; data =
               `Assoc
                 ( [ "schema_shape", schema_shape_json schema
                   ; "error", `String message
                   ; "validation", `String "agent_core_tool_middleware"
                   ; "reason", `String "invalid_args"
                   ; ( "failure_class"
                     , `String
                         (Tool_result.tool_failure_class_to_string
                            Tool_result.Policy_rejection) )
                   ] )
           ; metadata = None
           ; tool_name = name
           ; duration_ms = 0.0
           })
      ))))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> validation_exception_action ~name exn
;;

let validate_args ?schema ~name ~args () =
  match validation_action ?schema ~name ~args () with
  | Tool_dispatch.Pass -> Ok args
  | Tool_dispatch.Proceed coerced -> Ok coerced
  | Tool_dispatch.Reject result -> Error result
;;

let register_pre_hook () =
  Tool_dispatch.register_pre_hook (fun ~name ~args -> validation_action ~name ~args ())
;;
