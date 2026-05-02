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
let is_internal_marker_key key =
  String.length key > 0 && Char.equal key.[0] '_'

let strip_internal_marker_args (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
      `Assoc (List.filter (fun (key, _) -> not (is_internal_marker_key key)) fields)
  | _ -> args

let normalize_transition_args (args : Yojson.Safe.t) : Yojson.Safe.t =
  match args with
  | `Assoc fields ->
      let has key =
        List.exists (fun (field, _) -> String.equal field key) fields
      in
      let fields =
        if has "note" && not (has "notes") then
          List.map
            (fun (key, value) ->
              if String.equal key "note" then ("notes", value) else (key, value))
            fields
        else
          List.filter
            (fun (key, _) -> not (String.equal key "note" && has "notes"))
            fields
      in
      let has key =
        List.exists (fun (field, _) -> String.equal field key) fields
      in
      let fields =
        if has "to" && not (has "action") then
          List.map
            (fun (key, value) ->
              if String.equal key "to" then ("action", value) else (key, value))
            fields
        else
          List.filter
            (fun (key, _) -> not (String.equal key "to" && has "action"))
            fields
      in
      `Assoc fields
  | _ -> args

let prepare_args ~name args =
  let args = strip_internal_marker_args args in
  if String.equal name "masc_transition" then normalize_transition_args args
  else args

let register_pre_hook () =
  let lookup name =
    Option.map
      (Agent_sdk.Tool_middleware.tool_schema_of_json ~name)
      (Tool_dispatch.lookup_schema name)
  in
  let hook = Agent_sdk.Tool_middleware.make_validation_hook ~lookup in
  Tool_dispatch.register_pre_hook (fun ~name ~args ->
    let prepared_args = prepare_args ~name args in
    match hook ~name ~args:prepared_args with
    | Agent_sdk.Tool_middleware.Pass
      when not (Yojson.Safe.equal prepared_args args) ->
      Log.debug "tool_input_validation normalized args for %s" name;
      Proceed prepared_args
    | Agent_sdk.Tool_middleware.Pass -> Pass
    | Agent_sdk.Tool_middleware.Proceed coerced ->
      Log.debug "tool_input_validation coerced args for %s" name;
      Proceed coerced
    | Agent_sdk.Tool_middleware.Reject { message; _ } ->
      Log.info "tool_input_validation rejected %s: %s" name message;
      Reject {
        Tool_result.success = false;
        data = `Assoc [
          ("error", `String message);
          ("validation", `String "oas_tool_middleware");
        ];
        tool_name = name;
        duration_ms = 0.0;
      })
