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

let affected_providers = function
  | RateLimit { provider; _ }
  | AuthError { provider }
  | InvalidRequest { provider; _ } ->
      [ provider ]
  | CapacityExhausted { affected; _ } -> affected
  | ServerError _ -> []

let is_capacity_exhausted = function
  | CapacityExhausted _ -> true
  | RateLimit _
  | AuthError _
  | ServerError _
  | InvalidRequest _ ->
      false
