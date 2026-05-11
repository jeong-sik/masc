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

    Tools without a registered schema are allowed through (permissive). *)
let is_internal_marker_key key = String.length key > 0 && Char.equal key.[0] '_'

let strip_internal_marker_args (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
    `Assoc (List.filter (fun (key, _) -> not (is_internal_marker_key key)) fields)
  | _ -> args
;;

let normalize_transition_args (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
    let has key = List.exists (fun (field, _) -> String.equal field key) fields in
    let fields =
      if has "note" && not (has "notes")
      then
        List.map
          (fun (key, value) ->
             if String.equal key "note" then "notes", value else key, value)
          fields
      else
        List.filter (fun (key, _) -> not (String.equal key "note" && has "notes")) fields
    in
    let has key = List.exists (fun (field, _) -> String.equal field key) fields in
    let fields =
      if has "to" && not (has "action")
      then
        List.map
          (fun (key, value) ->
             if String.equal key "to" then "action", value else key, value)
          fields
      else
        List.filter (fun (key, _) -> not (String.equal key "to" && has "action")) fields
    in
    `Assoc fields
  | _ -> args
;;

let required_names schema =
  match Yojson.Safe.Util.member "required" schema with
  | `List items ->
    List.filter_map
      (function
        | `String name -> Some name
        | _ -> None)
      items
  | _ -> []
;;

let has_enum schema =
  match Yojson.Safe.Util.member "enum" schema with
  | `List (_ :: _) -> true
  | _ -> false
;;

let optional_enum_fields schema =
  let required = required_names schema in
  match Yojson.Safe.Util.member "properties" schema with
  | `Assoc props ->
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

let prepare_args ?schema ~name args =
  let args = strip_internal_marker_args args in
  let args =
    if String.equal name "masc_transition" then normalize_transition_args args else args
  in
  normalize_blank_optional_enum_args ?schema args
;;

let validation_action ?schema ~name ~args () : Tool_dispatch.pre_hook_action =
  let lookup name =
    let schema =
      match schema with
      | Some schema -> Some schema
      | None -> Tool_dispatch.lookup_schema name
    in
    Option.map (Agent_sdk.Tool_middleware.tool_schema_of_json ~name) schema
  in
  let hook = Agent_sdk.Tool_middleware.make_validation_hook ~lookup in
  let schema =
    match schema with
    | Some _ as schema -> schema
    | None -> Tool_dispatch.lookup_schema name
  in
  let prepared_args = prepare_args ?schema ~name args in
  match hook ~name ~args:prepared_args with
  | Agent_sdk.Tool_middleware.Pass when not (Yojson.Safe.equal prepared_args args) ->
    Log.debug "tool_input_validation normalized args for %s" name;
    Proceed prepared_args
  | Agent_sdk.Tool_middleware.Pass -> Pass
  | Agent_sdk.Tool_middleware.Proceed coerced ->
    Log.debug "tool_input_validation coerced args for %s" name;
    Proceed coerced
  | Agent_sdk.Tool_middleware.Reject { message; _ } ->
    Log.info "tool_input_validation rejected %s: %s" name message;
    Reject
      { Tool_result.success = false
      ; data =
          `Assoc [ "error", `String message; "validation", `String "oas_tool_middleware" ]
      ; legacy_message = message
      ; tool_name = name
      ; duration_ms = 0.0
      ; (* Input-schema / policy rejection — classify so the
         dispatch-level metric label (failure_class) reflects the
         actual category instead of bucketing as "unclassified". *)
        failure_class = Some Tool_result.Policy_rejection
      }
;;

let validate_args ?schema ~name ~args () =
  match validation_action ?schema ~name ~args () with
  | Pass -> Ok args
  | Proceed coerced -> Ok coerced
  | Reject result -> Error result
;;

let register_pre_hook () =
  Tool_dispatch.register_pre_hook (fun ~name ~args -> validation_action ~name ~args ())
;;
