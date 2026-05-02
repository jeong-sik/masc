open Base
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
let register_pre_hook () =
  let lookup name =
    Option.map
      (Agent_sdk.Tool_middleware.tool_schema_of_json ~name)
      (Tool_dispatch.lookup_schema name)
  in
  let hook = Agent_sdk.Tool_middleware.make_validation_hook ~lookup in
  Tool_dispatch.register_pre_hook (fun ~name ~args ->
    match hook ~name ~args with
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

