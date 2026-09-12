type t = Optional | Required
type reason = Model_tools_disabled | Binding_tools_unsupported | No_tools_supplied
  | Native_tools_cannot_be_disabled
[@@deriving yojson]
type failure = { runtime_id : string; reason : reason } [@@deriving yojson]
type Agent_core.Error.carrier += Required_tools_unavailable of failure

let check_surface requirement ~runtime_id ~surface_enabled ~has_tools =
  match requirement with
  | Optional -> Ok ()
  | Required when not surface_enabled -> Error {runtime_id;reason=Model_tools_disabled}
  | Required when not has_tools -> Error {runtime_id;reason=No_tools_supplied}
  | Required -> Ok ()

let check_provider requirement ~runtime_id provider_config =
  match requirement with
  | Optional -> Ok ()
  | Required ->
    if Runtime_transport.provider_supports_inline_tools provider_config then Ok ()
    else Error {runtime_id;reason=Binding_tools_unsupported}

let to_core_error failure =
  let reason = match failure.reason with
    | Model_tools_disabled -> "resolved model does not support tools"
    | Binding_tools_unsupported -> "materialized provider binding does not support inline tools"
    | No_tools_supplied -> "this execution owner was given no tools"
    | Native_tools_cannot_be_disabled -> "this execution owner cannot disable built-in tools" in
  Agent_core.Error.Internal_carried
    {message=Printf.sprintf "runtime %s cannot satisfy required tools: %s" failure.runtime_id reason;
     carrier=Required_tools_unavailable failure}

let of_core_error = function
  | Agent_core.Error.Internal_carried {carrier=Required_tools_unavailable failure;_} -> Some failure
  | _ -> None

let should_try_next error = Option.is_some (of_core_error error)
