(** Masc_event_bus_policy — named, audited configurations for each
    [Agent_sdk.Event_bus.t] MASC creates.

    Until this module existed, both buses (the OAS runtime bus and the
    MASC domain bus) were created with bare [Agent_sdk.Event_bus.create ()],
    silently inheriting OAS's defaults [buffer_size = 256] and
    [policy = Block].  Operators reading [server_bootstrap_loops.ml]
    could not tell whether those defaults were a deliberate choice or
    a missing override; reviewers had no way to audit "what happens
    if the subscriber drain stalls" without cross-reading OAS source.

    This module makes each policy choice explicit and named so the
    bootstrap call sites read as audited contracts and so the
    [masc_oas_bus_capacity] gauge can publish the chosen capacity per
    bus to [/metrics].

    Adding a new bus MUST extend this module — the surrounding code
    accepts [t] values only, not bare ints. *)

type backpressure_policy = Agent_sdk.Event_bus.backpressure_policy =
  | Block
  | Drop_oldest
  | Drop_newest

type t = private {
  bus_name : string;
      (** Human-readable name, used as the [bus] label on the
          [masc_oas_bus_capacity] gauge.  Must be unique. *)
  buffer_size : int;
      (** Per-subscriber [Eio.Stream] capacity allocated when
          [subscribe] is called.  Bounds memory and defines the
          fullness gate for [Drop_*] policies. *)
  policy : backpressure_policy;
      (** Decides what happens when a subscriber's stream is full
          when [publish] tries to deliver.  [Block] holds the
          publisher (back-pressure propagation); [Drop_oldest] /
          [Drop_newest] sacrifice an event. *)
  rationale : string;
      (** Short prose naming *why* this configuration was chosen.
          Lives in source rather than a wiki so the decision survives
          rebase / refactor. *)
}

val oas_runtime : t
(** Bus shared with the OAS turn pipeline.  [Block] is required so a
    slow subscriber back-pressures publishers (no event loss during
    turn replay).  256 buffer matches OAS's own default and is the
    measured headroom for a single turn's emissions. *)

val masc_domain : t
(** Bus for MASC-domain events (broadcast, heartbeat, keeper, autonomy,
    harness, trust).  Same configuration as [oas_runtime] — these are
    semantic events whose loss would silently break the coordination
    invariants. *)

val create_bus : t -> Agent_sdk.Event_bus.t
(** Materialise the chosen configuration and publish the
    [masc_oas_bus_capacity] gauge sample with [bus] and [policy]
    labels so the capacity ceiling is visible in [/metrics]. *)

val to_policy_label : backpressure_policy -> string
(** [Block | Drop_oldest | Drop_newest] → kebab-case label. *)
