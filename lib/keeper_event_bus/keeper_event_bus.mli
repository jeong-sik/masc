(** Keeper_event_bus — Process-scoped OAS Event_bus reference.

    Holds the shared Event_bus instance set once at server bootstrap.
    Separate module to avoid dependency cycles between Keeper_keepalive
    and Keeper_agent_run.

    @since 2.255.0 *)

(** Install the process-wide event bus. Call once at bootstrap. *)
val set : Agent_sdk.Event_bus.t -> unit

(** Read the installed event bus, if any. *)
val get : unit -> Agent_sdk.Event_bus.t option
