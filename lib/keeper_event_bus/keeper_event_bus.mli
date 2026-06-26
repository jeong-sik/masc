(** Keeper_event_bus — OAS Event_bus reference with domain-local override.

    Holds the shared Event_bus instance set at server bootstrap. Separate
    module to avoid dependency cycles between Keeper_keepalive and
    Keeper_agent_run.

    The current domain's [Domain.DLS] value is preferred. A process-wide
    fallback preserves legacy lookup semantics for domains that have not
    installed their own bus yet.

    @since 2.255.0 *)

(** Install the event bus for the current domain and process fallback. Call
    once at bootstrap; re-install in a domain that owns a separate bus. *)
val set : Agent_sdk.Event_bus.t -> unit

(** Read the installed event bus for the current domain, falling back to the
    process-level bus when the domain has no override. *)
val get : unit -> Agent_sdk.Event_bus.t option
