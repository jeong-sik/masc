(** Container lifecycle events for Lane Add-on instances.

    Each instance owns one Docker container (docs/design/lane-addon-v0.md).
    Acquisition and verified release are provenance facts of the runtime, so
    they are published on the MASC-owned event bus as Custom events. The
    durable JSONL row and the SSE relay come from [Keeper_event_bridge];
    this module only mints the typed occurrence.

    Contract: publishing never blocks the lifecycle, a missing bus degrades
    to one warning, and no container identity is fabricated — an unacquired
    container stays [None] on the wire.

    @since 0.35.11 *)

type lifecycle =
  | Acquired
      (** [on_created] fired: the real container identity is in hand. *)
  | Acquire_failed
      (** [backend.start] returned an error; the identity may or may not have
          been acquired before the failure. *)
  | Release_confirmed
      (** stop or recover_stop confirmed removal of the exact container. *)
  | Release_incomplete
      (** Removal is unverified: stop/recover_stop failed, or the worker
          ended without a retained container identity. *)

type resource = {
  instance_id : string;
  run_id : string;
  package_id : string;
  package_revision : string;
  container_id : string option;
      (** Only the identity actually observed. [None] before acquisition. *)
  detail : string option;
      (** Failure reason for the failed/incomplete variants. *)
}

val wire_name : lifecycle -> string
(** Closed mapping to the four [masc.lane.resource.*] wire names. Subscribers
    rely on the exact strings; tests pin them. *)

val publish : lifecycle -> resource -> unit
(** Publish on the MASC-owned bus with [correlation_id = instance_id] and
    [run_id = run_id]. No causal claim is minted: the envelope never sets
    [caused_by]. Does nothing but warn when the bus is not installed. *)
