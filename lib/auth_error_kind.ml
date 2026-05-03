(** Closed-enum classification of [Types.t] for auth-related logging
    and prometheus metric labels.

    Replaces inline string-label matching at:
    - [lib/server/server_auth.ml] dashboard_actor_fallback warn/counter
    - [lib/mcp_server_eio_execute.ml] silent_auth_token_error_kind (follow-up)

    The string labels are stable contract for prometheus dashboards and
    must round-trip through [to_string] / [of_string]. The variant is
    closed so that any new auth-relevant [Types.t] constructor that
    needs its own label requires an explicit code change here, not a
    silent fall-through to ["other"]. *)

type t =
  | Token_mismatch
  | Token_expired
  | Unauthorized
  | Forbidden
  | Agent_not_found
  | Io_error
  | Invalid_json
  | Other

let to_string = function
  | Token_mismatch -> "token_mismatch"
  | Token_expired -> "token_expired"
  | Unauthorized -> "unauthorized"
  | Forbidden -> "forbidden"
  | Agent_not_found -> "agent_not_found"
  | Io_error -> "io_error"
  | Invalid_json -> "invalid_json"
  | Other -> "other"

let of_string = function
  | "token_mismatch" -> Some Token_mismatch
  | "token_expired" -> Some Token_expired
  | "unauthorized" -> Some Unauthorized
  | "forbidden" -> Some Forbidden
  | "agent_not_found" -> Some Agent_not_found
  | "io_error" -> Some Io_error
  | "invalid_json" -> Some Invalid_json
  | "other" -> Some Other
  | _ -> None

let classify : Types.t -> t = function
  | Types.Auth (Types.Auth_error.InvalidToken _) -> Token_mismatch
  | Types.Auth (Types.Auth_error.TokenExpired _) -> Token_expired
  | Types.Auth (Types.Auth_error.Unauthorized _) -> Unauthorized
  | Types.Auth (Types.Auth_error.Forbidden _) -> Forbidden
  | Types.Agent (Types.Agent_error.NotFound _) -> Agent_not_found
  | Types.System (Types.System_error.IoError _) -> Io_error
  | Types.System (Types.System_error.InvalidJson _) -> Invalid_json
  | _ -> Other

let all =
  [ Token_mismatch
  ; Token_expired
  ; Unauthorized
  ; Forbidden
  ; Agent_not_found
  ; Io_error
  ; Invalid_json
  ; Other
  ]
