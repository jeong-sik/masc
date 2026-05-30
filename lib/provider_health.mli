type health_state =
  | Healthy
  | Unhealthy of
      { since : float
      ; consecutive_failures : int
      }

type t

val create : Coord.config -> t

val start_probe_fiber :
  sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> t -> unit
(** Spawn one fiber per [providers.X.healthcheck enabled=true] block. *)

val is_healthy : t -> provider_id:string -> bool

val record_attempt_result :
  t -> provider_id:string -> success:bool -> http_status:int option -> unit
(** Feed in-band per-turn results; counts toward thresholds alongside probe results. *)

val snapshot : t -> (string * health_state) list
(** For dashboard / Prometheus gauge. *)

val filter_healthy : t -> provider_id:('a -> string) -> 'a list -> 'a list
(** Filter unhealthy candidates, failing open when all candidates would be removed. *)

val set_active : t -> unit
val active : unit -> t option

module For_testing : sig
  type provider =
    { provider_id : string
    ; endpoint : string option
    ; probe_interval_seconds : int
    ; unhealthy_threshold : int
    ; recovery_threshold : int
    }

  val create : provider list -> t
  val probe_failure_should_warn : before:health_state -> after:health_state -> bool
  val clear_active : unit -> unit
end
