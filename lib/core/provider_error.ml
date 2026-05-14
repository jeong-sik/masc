type capacity_scope = [ `Model | `Provider ]

type provider_error =
  | RateLimit of {
      retry_after : float option;
    }
  | CapacityExhausted of {
      scope : capacity_scope;
    }
  | AuthError
  | ServerError of {
      code : int;
      transient : bool;
    }
  | InvalidRequest of {
      reason : string;
    }
  | CliWrappedHardQuota of {
      detail : string;
    }
  | CliWrappedMaxTurns of {
      detail : string;
    }
  | CliWrappedResumableSession of {
      detail : string;
      exit_code : int option;
    }
  | PermissionDenied of {
      resource : string option;
    }
  | ModelNotFound

type t = provider_error

let scope_to_string = function
  | `Model -> "model"
  | `Provider -> "provider"

let to_error_kind = function
  | RateLimit _ -> "rate_limit"
  | CapacityExhausted _ -> "capacity_exhausted"
  | AuthError -> "auth_error"
  | ServerError _ -> "server_error"
  | InvalidRequest _ -> "invalid_request"
  | CliWrappedHardQuota _ -> "cli_wrapped_hard_quota"
  | CliWrappedMaxTurns _ -> "cli_wrapped_max_turns"
  | CliWrappedResumableSession _ -> "cli_wrapped_resumable_session"
  | PermissionDenied _ -> "permission_denied"
  | ModelNotFound -> "model_not_found"

let string_list_to_yojson values =
  `List (List.map (fun value -> `String value) values)

let float_option_to_yojson = function
  | Some value -> `Float value
  | None -> `Null

let public_runtime_provider_label = "runtime"
let public_runtime_model_label = "runtime"

let to_yojson = function
  | RateLimit { retry_after } ->
      `Assoc
        [
          ("kind", `String "rate_limit");
          ("retry_after", float_option_to_yojson retry_after);
          ("provider", `String public_runtime_provider_label);
        ]
  | CapacityExhausted { scope } ->
      `Assoc
        [
          ("kind", `String "capacity_exhausted");
          ("scope", `String (scope_to_string scope));
          ("affected", string_list_to_yojson [ public_runtime_provider_label ]);
        ]
  | AuthError ->
      `Assoc
        [
          ("kind", `String "auth_error");
          ("provider", `String public_runtime_provider_label);
        ]
  | ServerError { code; transient } ->
      `Assoc
        [
          ("kind", `String "server_error");
          ("code", `Int code);
          ("transient", `Bool transient);
        ]
  | InvalidRequest { reason } ->
      `Assoc
        [
          ("kind", `String "invalid_request");
          ("provider", `String public_runtime_provider_label);
          ("reason", `String reason);
        ]
  | CliWrappedHardQuota { detail } ->
      `Assoc
        [
          ("kind", `String "cli_wrapped_hard_quota");
          ("provider", `String public_runtime_provider_label);
          ("detail", `String detail);
        ]
  | CliWrappedMaxTurns { detail } ->
      `Assoc
        [
          ("kind", `String "cli_wrapped_max_turns");
          ("provider", `String public_runtime_provider_label);
          ("detail", `String detail);
        ]
  | CliWrappedResumableSession { detail; exit_code } ->
      `Assoc
        [
          ("kind", `String "cli_wrapped_resumable_session");
          ("provider", `String public_runtime_provider_label);
          ("detail", `String detail);
          ("exit_code",
           match exit_code with
           | Some code -> `Int code
           | None -> `Null);
        ]
  | PermissionDenied { resource } ->
      `Assoc
        [
          ("kind", `String "permission_denied");
          ("provider", `String public_runtime_provider_label);
          ("resource",
           match resource with
           | Some r -> `String r
           | None -> `Null);
        ]
  | ModelNotFound ->
      `Assoc
        [
          ("kind", `String "model_not_found");
          ("provider", `String public_runtime_provider_label);
          ("model_name", `String public_runtime_model_label);
        ]

let affected_providers = function
  | RateLimit _
  | AuthError
  | InvalidRequest _
  | CliWrappedHardQuota _
  | CliWrappedMaxTurns _
  | CliWrappedResumableSession _
  | PermissionDenied _
  | ModelNotFound
  | CapacityExhausted _ ->
      [ public_runtime_provider_label ]
  | ServerError _ -> []

let is_capacity_exhausted = function
  | CapacityExhausted _ -> true
  | RateLimit _
  | AuthError
  | ServerError _
  | InvalidRequest _
  | CliWrappedHardQuota _
  | CliWrappedMaxTurns _
  | CliWrappedResumableSession _
  | PermissionDenied _
  | ModelNotFound ->
      false
