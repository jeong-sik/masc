(** Execution resource lifecycle events for Lane Add-on instances.

    Instances observe either a container or a native process identity.
    Acquisition and verified release are provenance facts of the runtime, so
    they are published on the MASC-owned event bus as Custom events. The
    durable JSONL row and the SSE relay come from [Keeper_event_bridge];
    this module only mints the typed occurrence.

    Contract: publishing never blocks the lifecycle, a missing bus degrades
    to one warning, and no execution identity is fabricated. Before acquisition,
    [resource] is [None]. The wire's [container_id] projection is populated only
    for an actual container resource.

    @since 0.35.11 *)

type lifecycle =
  | Acquired
      (** [on_created] fired: the actual execution resource identity is in hand. *)
  | Acquire_failed
      (** [backend.start] returned an error; the identity may or may not have
          been acquired before the failure. *)
  | Release_confirmed
      (** stop or recover_stop confirmed release through the recorded execution authority. *)
  | Release_incomplete
      (** Release is unverified: stop/recover_stop failed or settlement
          through the recorded execution authority remains unconfirmed. *)

type resource = {
  instance_id : string;
  run_id : string;
  package_id : string;
  package_revision : string;
  resource : Lane_addon_lifecycle.resource option;
      (** Only the identity actually observed. [None] before acquisition. *)
  detail : string option;
      (** Failure reason for the failed/incomplete variants. *)
}

val all : lifecycle list
(** Every lifecycle, once each. A reader of the wire recognises an event by
    walking this list through {!wire_name} rather than by holding its own copy
    of the four names. *)

val wire_name : lifecycle -> string
(** Closed mapping to the four [masc.lane.resource.*] wire names. Subscribers
    rely on the exact strings; tests pin them. *)

val event : lifecycle -> resource -> Agent_core.Event_bus.event
(** The occurrence {!publish} puts on the bus. Exposed so a reader of the wire
    can be tested against the frame the bridge makes of it. *)

val publish : lifecycle -> resource -> unit
(** Publish on the MASC-owned bus with [correlation_id = instance_id] and
    [run_id = run_id]. No causal claim is minted: the envelope never sets
    [caused_by]. Does nothing but warn when the bus is not installed. *)
