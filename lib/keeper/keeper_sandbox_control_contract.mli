(** Typed input contract shared by keeper sandbox schemas and handlers. *)

type bounded_float =
  { minimum : float
  ; maximum : float
  ; default : float
  }

val managed_ttl_sec : bounded_float
(** Bounds for the lifetime of a managed sandbox container. *)

val operation_timeout_sec : bounded_float
(** Bounds for sandbox start and stop operation timeouts. *)

val clamp : bounded_float -> float -> float
(** [clamp bounds value] applies the same inclusive bounds advertised by the
    JSON schema. *)

type stop_scope =
  | Stop_managed
  | Stop_turn
  | Stop_all

val all_stop_scopes : stop_scope list
(** Exhaustive ordered set exposed by the sandbox-stop schema. *)

val default_stop_scope : stop_scope

val stop_scope_to_string : stop_scope -> string
val stop_scope_strings : string list
val parse_stop_scope : string -> (stop_scope, string) result
