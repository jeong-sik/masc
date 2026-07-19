(** Event_bus_slots — process-wide holders for the two
    [Agent_sdk.Event_bus.t] instances masc keeps at server bootstrap.

    {b masc slot} — MASC-owned bus, separate from the shared OAS
    Event_bus.  MASC domain events ([masc.broadcast], [masc.heartbeat],
    [masc.keeper.lifecycle], ...) are published here, not onto OAS's
    bus.  Enforces the OAS boundary documented in
    [event_bus.mli:103-107] — OAS's Event_bus is not a general-purpose
    telemetry channel.  Process-scoped [Atomic.t] singleton.

    {b keeper slot} — shared OAS Event_bus reference with domain-local
    override.  The current domain's [Domain.DLS] value is preferred; a
    process-wide fallback preserves legacy lookup semantics for domains
    that have not installed their own bus yet.  Kept in this module
    (rather than inline in keeper modules) to avoid dependency cycles
    between Keeper_keepalive and Keeper_agent_run.

    @since 2.353.0 (as [Masc_event_bus] / [Keeper_event_bus]; merged
           into one module with two named slots) *)

(** {1 masc slot — MASC-owned bus, process-wide [Atomic.t]} *)

val set_masc : Agent_sdk.Event_bus.t -> unit
(** Install the MASC Event_bus instance.  Called once at server
    bootstrap. *)

val get_masc : unit -> Agent_sdk.Event_bus.t option
(** [get_masc ()] returns the installed MASC Event_bus, or [None]
    before bootstrap (e.g. in unit tests that skip server bringup). *)

(** {1 keeper slot — shared OAS bus, [Domain.DLS] + process fallback} *)

val set_keeper : Agent_sdk.Event_bus.t -> unit
(** Install the event bus for the current domain and process fallback.
    Call once at bootstrap; re-install in a domain that owns a separate
    bus. *)

val get_keeper : unit -> Agent_sdk.Event_bus.t option
(** Read the installed event bus for the current domain, falling back
    to the process-level bus when the domain has no override. *)
