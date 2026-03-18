open Keeper_types

(** Inject the OAS Event_bus for keeper snapshot event publishing. *)
val set_bus : Agent_sdk.Event_bus.t -> unit

val running_keepers : unit -> int
val keeper_keepalive_running : string -> bool
val keeper_keepalive_started_at : string -> float option
val start_keepalive :
  ?proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
val stop_keepalive : string -> unit
