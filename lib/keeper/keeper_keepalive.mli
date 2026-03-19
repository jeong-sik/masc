open Keeper_types

type keepalive_entry = {
  stop : bool ref;
  started_at : float;
}

(** Inject the shared Event_bus for keeper snapshot publishing. *)
val set_bus : Agent_sdk.Event_bus.t -> unit

val running_keepers : unit -> int
val keeper_keepalive_running : string -> bool
val keeper_keepalive_started_at : string -> float option
val keeper_spawn_slots_available : unit -> bool

(** Register a keepalive entry in the internal registry.
    Used by Keeper_resident_supervisor for backward-compatible registration. *)
val register_keepalive : string -> keepalive_entry -> unit

(** Remove a keepalive entry from the internal registry. *)
val unregister_keepalive : string -> unit

(** The heartbeat loop body, extracted for reuse by the supervisor.
    Runs synchronously in the calling fiber until [stop] becomes true. *)
val run_heartbeat_loop :
  proactive_warmup_sec:int -> 'a context -> keeper_meta -> bool ref -> unit

val start_keepalive :
  ?proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
val stop_keepalive : string -> unit
