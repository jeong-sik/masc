(** Typed provider/client refusals that agent-core's generic [AuthError] and
    [ProviderUnavailable] arms previously collapsed together (RFC S2 §3.5 / §16.1):
    - [Key_refused]: provider rejected the account's registered API key (HTTP 401/403).
    - [Spawn_refused]: local client subprocess refused to spawn before any turn ran. *)

type t =
  | Key_refused of
      { provider : string
      ; detail : string
      }
  | Spawn_refused of
      { provider : string
      ; detail : string
      }

val equal : t -> t -> bool
val to_string : t -> string
val core_error : t -> Agent_core.Error.t
val of_core_error : Agent_core.Error.t -> t option
