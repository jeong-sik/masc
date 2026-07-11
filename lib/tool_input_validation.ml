module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_input_validation — Pre-dispatch validation via OAS Tool_middleware.

    Delegates to [Agent_sdk.Tool_middleware.make_validation_hook] for type
    coercion and structured error feedback.

    @since 2.220.0 — OAS delegation
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

let has_enum schema =
  match Json_util.assoc_member_opt "enum" schema with
  | Some (`List (_ :: _)) -> true
  | _ -> false
;;

let optional_enum_fields schema =
  let required = required_names schema in
  match Json_util.assoc_member_opt "properties" schema with
  | Some (`Assoc props) ->
    List.filter_map
      (fun (name, prop_schema) ->
         if (not (List.mem name required)) && has_enum prop_schema
         then Some name
         else None)
      props
  | _ -> []
;;

let normalize_blank_optional_enum_args ?schema args =
  match schema, args with
  | Some schema, `Assoc fields ->
    let optional_enums = optional_enum_fields schema in
    if optional_enums = []
    then args
    else
      `Assoc
        (List.filter
           (fun (key, value) ->
              match value with
              | `String raw when List.mem key optional_enums && String.trim raw = "" ->
                false
              | _ -> true)
           fields)
  | _ -> args
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

let schema_has_property_name schema name = List.mem name (schema_property_names schema)

let is_execute_typed_argv_schema schema =
  schema_has_property_name schema "executable"
  && schema_has_property_name schema "argv"
  && schema_has_property_name schema "pipeline"
;;

let is_execute_tool_name name =
  let name = Tool_name_alias_axis.strip_mcp_masc_prefix name in
  match Tool_name_alias_axis.public_tool_of_name name with
  | Some Tool_name_alias_axis.Execute -> true
  | Some (Tool_name_alias_axis.Edit
         | Tool_name_alias_axis.Web_fetch
         | Tool_name_alias_axis.Read
         | Tool_name_alias_axis.Grep
         | Tool_name_alias_axis.Web_search
         | Tool_name_alias_axis.Write) -> false
  | None ->
    String.equal
      name
      (Tool_name_alias_axis.internal_name Tool_name_alias_axis.Execute)
;;

let normalize_execute_args_envelope ?schema ~name args =
  match schema, args with
  | Some schema, `Assoc [ "args", (`Assoc _ as nested) ]
    when is_execute_tool_name name && is_execute_typed_argv_schema schema -> nested
  | _ -> args
;;

let schema_type_includes schema expected =
  match Json_util.assoc_member_opt "type" schema with
  | Some (`String actual) -> String.equal actual expected
  | Some (`List values) ->
    List.exists
      (function
        | `String actual -> String.equal actual expected
        | _ -> false)
      values
  | _ -> false
;;

let schema_expects_array schema =
  schema_type_includes schema "array"
  || Option.is_some (Json_util.assoc_member_opt "items" schema)
;;

let schema_expects_object schema =
  schema_type_includes schema "object"
  || Option.is_some (Json_util.assoc_member_opt "properties" schema)
  || Option.is_some (Json_util.assoc_member_opt "additionalProperties" schema)
;;

let schema_accepts_composite_value schema = function
  | `List _ -> schema_expects_array schema
  | `Assoc _ -> schema_expects_object schema
  | _ -> false
;;

let schema_property_schema schema key =
  match Json_util.assoc_member_opt "properties" schema with
  | Some (`Assoc properties) -> List.assoc_opt key properties
  | _ -> None
;;

let schema_items_schema schema =
  Json_util.assoc_member_opt "items" schema
;;

let rec normalize_schema_json_string_composites ~schema value =
  match value with
  | `String raw when schema_expects_array schema || schema_expects_object schema ->
    (match
       try Some (Yojson.Safe.from_string raw) with
       | Yojson.Json_error _ -> None
     with
     | Some parsed when schema_accepts_composite_value schema parsed ->
       normalize_schema_json_string_composites ~schema parsed
     | _ -> value)
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, field_value) ->
            match schema_property_schema schema key with
            | None -> key, field_value
            | Some field_schema ->
              key, normalize_schema_json_string_composites ~schema:field_schema field_value)
         fields)
  | `List values ->
    (match schema_items_schema schema with
     | None -> value
     | Some item_schema ->
       `List
         (List.map
            (fun item -> normalize_schema_json_string_composites ~schema:item_schema item)
            values))
  | _ -> value
;;

let prepare_args ?schema ~name args =
  let args = strip_internal_marker_args args in
  let args = normalize_execute_args_envelope ?schema ~name args in
  let args =
    match schema with
    | None -> args
    | Some schema -> normalize_schema_json_string_composites ~schema args
  in
  normalize_blank_optional_enum_args ?schema args
;;

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

let schema_has_property schema name = schema_has_property_name schema name

let typed_shell_unsupported_field_hint schema names =
  let has_shell_fields =
    schema_has_property schema "executable" && schema_has_property schema "argv"
  in
  let has_legacy_shell_string =
    List.exists (fun name -> String.equal name "cmd" || String.equal name "command") names
  in
  if has_shell_fields && has_legacy_shell_string
  then
    Some
      "typed shell execution has no cmd/command field; use executable/argv, \
       e.g. executable=\"git\" argv=[\"status\",\"--short\"]. Do not include the \
       executable again in argv"
  else None
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

let schema_shape_error schema args =
  match unsupported_arg_names schema args with
  | name :: names ->
    let names = name :: names in
    let names_text = String.concat ", " names in
    let hint =
      match typed_shell_unsupported_field_hint schema names with
      | None -> ""
      | Some hint -> "; " ^ hint
    in
    Some (Printf.sprintf "received unsupported field(s): %s%s" names_text hint)
  | [] -> one_of_required_shape_error schema args
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

let validation_schema_of_json ~name json_schema : Agent_sdk.Types.tool_schema =
  { name
  ; description = ""
  ; parameters = Tool_bridge.params_of_json_schema json_schema
  ; strict = None
  }
;;

let reject_validation ~name ~reason ~message =
  emit_validation_telemetry ~tool:name ~result:"fail" ~reason;
  Log.Tool_validation.info "tool_input_validation rejected %s: %s" name message;
  Tool_dispatch.Reject
    (Error
       { Tool_result.class_ = Tool_result.Policy_rejection
       ; message
       ; data =
           `Assoc
             [ "error", `String message
             ; "validation", `String "oas_tool_middleware"
             ; "reason", `String reason
             ; ( "failure_class"
               , `String
                   (Tool_result.tool_failure_class_to_string
                      Tool_result.Policy_rejection) )
             ]
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
    (Error
       { Tool_result.class_ = Tool_result.Runtime_failure
       ; message
       ; data =
           `Assoc
             [ "error", `String message
             ; "validation", `String "oas_tool_middleware"
             ; "exception", `String error_text
             ]
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
           ~name
           ~reason:"invalid_args"
           ~message:
             (Printf.sprintf
                "Tool '%s' received retired transition alias field(s): %s; use \
                 action and notes"
                name
                aliases)
       | [] ->
      (match schema_shape_error schema prepared_args with
       | Some message ->
         reject_validation
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
         let hook = Agent_sdk.Tool_middleware.make_validation_hook ~lookup in
         (match hook ~name ~args:prepared_args with
    | Agent_sdk.Tool_middleware.Pass when not (Yojson.Safe.equal prepared_args args) ->
      let reason = pass_reason ~schema:(Some schema) ~args ~prepared_args in
      emit_validation_telemetry ~tool:name ~result:"pass" ~reason;
      Log.Tool_validation.debug "tool_input_validation normalized args for %s" name;
      Tool_dispatch.Proceed prepared_args
    | Agent_sdk.Tool_middleware.Pass ->
      let reason = pass_reason ~schema:(Some schema) ~args ~prepared_args in
      emit_validation_telemetry ~tool:name ~result:"pass" ~reason;
      Tool_dispatch.Pass
    | Agent_sdk.Tool_middleware.Proceed coerced ->
      emit_validation_telemetry ~tool:name ~result:"pass" ~reason:"coerced";
      Log.Tool_validation.debug "tool_input_validation coerced args for %s" name;
      Tool_dispatch.Proceed coerced
    | Agent_sdk.Tool_middleware.Reject { message; _ } ->
      emit_validation_telemetry ~tool:name ~result:"fail" ~reason:"invalid_args";
      Log.Tool_validation.info "tool_input_validation rejected %s: %s" name message;
      (* Input-schema / policy rejection — classify so the
         dispatch-level metric label (failure_class) reflects the
         actual category instead of bucketing as "unclassified". *)
      Tool_dispatch.Reject
        (Error
           { Tool_result.class_ = Tool_result.Policy_rejection
           ; message
           ; data =
               `Assoc
                 [ "error", `String message
                 ; "validation", `String "oas_tool_middleware"
                 ; "reason", `String "invalid_args"
                 ; ( "failure_class"
                   , `String
                       (Tool_result.tool_failure_class_to_string
                          Tool_result.Policy_rejection) )
                 ]
           ; tool_name = name
           ; duration_ms = 0.0
           })
      )))
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
