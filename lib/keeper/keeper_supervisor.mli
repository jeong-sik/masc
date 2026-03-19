(** Keeper_supervisor — OAS-inspired fiber lifecycle supervisor.

    Wraps keeper heartbeat fibers with Eio.Promise-based liveness tracking.
    Detects zombie fibers (Hashtbl entry with terminated fiber) and performs
    automatic restart with exponential backoff.

    Integrates with:
    - Keeper_keepalive.run_heartbeat_loop for fiber body
    - OAS Event_bus for lifecycle event publishing
    - Sentinel Pulse for periodic sweep scheduling

    @since 2.102.0 *)

open Keeper_types

(** {1 Supervised State} *)

type supervised_state = {
  name : string;
  fiber_health : fiber_health;
  restart_count : int;
  last_restart_ts : float;
  crash_log : (float * string) list;   (** Most recent 5 entries *)
}

(** {1 Initialization} *)

val init : bus:Agent_sdk.Event_bus.t -> unit
(** Connect the OAS Event_bus. Call once during bootstrap. *)

(** {1 Supervised Execution} *)

val supervise_keepalive :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
(** Start a keeper heartbeat loop inside a supervised fiber.
    Registers in both the legacy keepalive registry (backward compat)
    and the supervisor registry (Promise-based liveness tracking).
    On fiber termination, resolves the Promise and publishes
    lifecycle events via Event_bus. *)

(** {1 Sweep and Recovery} *)

val sweep_and_recover : 'a context -> unit
(** Scan all supervised keepers. Detect zombies (resolved Promise),
    restart with exponential backoff if within budget, mark dead otherwise.
    Called periodically by a Sentinel Pulse consumer. *)

(** {1 Queries} *)

val fiber_health_of : string -> fiber_health
(** Fiber-level health of a keeper by name.
    Returns Fiber_unknown if the keeper is not in the supervised registry. *)

val supervised_state_of : string -> supervised_state option
(** Full supervised state snapshot for a keeper, or None if not supervised. *)

val crash_log_of : string -> (float * string) list
(** Recent crash entries (up to 5) for a supervised keeper. *)

val supervised_count : unit -> int
(** Number of keepers currently in the supervised registry. *)

(** {1 Pure Helpers (exposed for testing)} *)

val backoff_delay : int -> float
(** Compute exponential backoff delay for the given attempt number.
    Uses MASC_KEEPER_SUPERVISOR_BACKOFF_BASE_S and _MAX_S. *)

val keep_last_n : int -> 'a -> 'a list -> 'a list
(** [keep_last_n n item lst] prepends [item] and keeps at most [n] entries. *)
