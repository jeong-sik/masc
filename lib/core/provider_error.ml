type capacity_scope = [ `Model | `Provider ]

type provider_error =
  | RateLimit of {
      retry_after : float option;
      provider : string;
    }
  | CapacityExhausted of {
      scope : capacity_scope;
      affected : string list;
    }
  | AuthError of {
      provider : string;
    }
  | ServerError of {
      code : int;
      transient : bool;
    }
  | InvalidRequest of {
      provider : string;
      reason : string;
    }
  | CliWrappedHardQuota of {
      provider : string;
      detail : string;
    }
  | CliWrappedMaxTurns of {
      provider : string;
      detail : string;
    }
  | CliWrappedResumableSession of {
      provider : string;
      detail : string;
      exit_code : int option;
    }
  | PermissionDenied of {
      provider : string;
      resource : string option;
    }
  | ModelNotFound of {
      provider : string;
      model_name : string;
    }

type t = provider_error

let scope_to_string = function
  | `Model -> "model"
  | `Provider -> "provider"

let to_error_kind = function
  | RateLimit _ -> "rate_limit"
  | CapacityExhausted _ -> "capacity_exhausted"
  | AuthError _ -> "auth_error"
  | ServerError _ -> "server_error"
  | InvalidRequest _ -> "invalid_request"
  | CliWrappedHardQuota _ -> "cli_wrapped_hard_quota"
  | CliWrappedMaxTurns _ -> "cli_wrapped_max_turns"
  | CliWrappedResumableSession _ -> "cli_wrapped_resumable_session"
  | PermissionDenied _ -> "permission_denied"
  | ModelNotFound _ -> "model_not_found"

let string_list_to_yojson values =
  `List (List.map (fun value -> `String value) values)

let float_option_to_yojson = function
  | Some value -> `Float value
  | None -> `Null

let to_yojson = function
  | RateLimit { retry_after; provider } ->
      `Assoc
        [
          ("kind", `String "rate_limit");
          ("retry_after", float_option_to_yojson retry_after);
          ("provider", `String provider);
        ]
  | CapacityExhausted { scope; affected } ->
      `Assoc
        [
          ("kind", `String "capacity_exhausted");
          ("scope", `String (scope_to_string scope));
          ("affected", string_list_to_yojson affected);
        ]
  | AuthError { provider } ->
      `Assoc
        [
          ("kind", `String "auth_error");
          ("provider", `String provider);
        ]
  | ServerError { code; transient } ->
      `Assoc
        [
          ("kind", `String "server_error");
          ("code", `Int code);
          ("transient", `Bool transient);
        ]
  | InvalidRequest { provider; reason } ->
      `Assoc
        [
          ("kind", `String "invalid_request");
          ("provider", `String provider);
          ("reason", `String reason);
        ]
  | CliWrappedHardQuota { provider; detail } ->
      `Assoc
        [
          ("kind", `String "cli_wrapped_hard_quota");
          ("provider", `String provider);
          ("detail", `String detail);
        ]
  | CliWrappedMaxTurns { provider; detail } ->
      `Assoc
        [
          ("kind", `String "cli_wrapped_max_turns");
          ("provider", `String provider);
          ("detail", `String detail);
        ]
  | CliWrappedResumableSession { provider; detail; exit_code } ->
      `Assoc
        [
          ("kind", `String "cli_wrapped_resumable_session");
          ("provider", `String provider);
          ("detail", `String detail);
          ("exit_code",
           match exit_code with
           | Some code -> `Int code
           | None -> `Null);
        ]
  | PermissionDenied { provider; resource } ->
      `Assoc
        [
          ("kind", `String "permission_denied");
          ("provider", `String provider);
          ("resource",
           match resource with
           | Some r -> `String r
           | None -> `Null);
        ]
  | ModelNotFound { provider; model_name } ->
      `Assoc
        [
          ("kind", `String "model_not_found");
          ("provider", `String provider);
          ("model_name", `String model_name);
        ]

let affected_providers = function
  | RateLimit { provider; _ }
  | AuthError { provider }
  | InvalidRequest { provider; _ }
  | CliWrappedHardQuota { provider; _ }
  | CliWrappedMaxTurns { provider; _ }
  | CliWrappedResumableSession { provider; _ }
  | PermissionDenied { provider; _ }
  | ModelNotFound { provider; _ } ->
      [ provider ]
  | CapacityExhausted { affected; _ } -> affected
  | ServerError _ -> []

let is_capacity_exhausted = function
  | CapacityExhausted _ -> true
  | RateLimit _
  | AuthError _
  | ServerError _
  | InvalidRequest _
  | CliWrappedHardQuota _
  | CliWrappedMaxTurns _
  | CliWrappedResumableSession _
  | PermissionDenied _
  | ModelNotFound _ ->
      false
