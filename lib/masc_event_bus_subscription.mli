(** MASC-owned resource contracts for every OAS event-bus subscriber.

    OAS owns the transport and validates the queue resource contract. MASC owns
    why each process-local projection subscribes, which overflow behaviour it
    accepts, and the exact capacity allocated to it. Keeping the subscriber
    vocabulary closed prevents call sites from silently inventing queue
    policies or capacities. *)

type subscriber =
  | Sse_bridge
  | Telemetry_consumer
  | Keeper_turn
  | Keeper_lifecycle_listener

type t

val for_subscriber : subscriber -> t
(** Return the immutable contract for [subscriber]. *)

val purpose : t -> string
(** Stable, bounded telemetry label passed to OAS. It does not participate in
    event routing. *)

val capacity : t -> int
val overflow : t -> Agent_sdk.Event_bus.overflow

val subscription_config : t -> Agent_sdk.Event_bus.subscription_config
(** OAS-validated queue configuration. Contract construction fails at module
    initialization if a source declaration is invalid; no fallback is used. *)

val overflow_label : Agent_sdk.Event_bus.overflow -> string
