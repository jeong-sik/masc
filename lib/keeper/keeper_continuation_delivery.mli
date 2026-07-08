(** Keeper_continuation_delivery — RFC-0320 W3c.

    Deterministic delivery of a wake-turn's response to the originating chat
    channel captured on a [Hitl_resolved] wake (see {!Keeper_continuation_channel}).

    This is the deterministic floor that complements the W3b prompt steer: when a
    keeper resumes on a [Hitl_resolved] wake and does not itself post a reply
    (the steer is best-effort), the response is delivered to the captured channel
    here so the conversation is always answered. Routing is deterministic (the
    captured channel); only the reply text is model-authored. *)

type outcome =
  | Delivered of { kind : string }  (** posted to the channel; [kind] is the connector tag *)
  | Skipped_unrouted  (** channel is [Unrouted]; fail-closed, no fabricated target *)
  | Skipped_already_replied  (** the keeper already posted on a surface this turn (dedup with W3b) *)
  | Skipped_empty  (** no visible response text to deliver *)
  | Failed of { kind : string; error : string }  (** the connector send returned an error *)

(** [describe_outcome o] is a stable one-line tag for logs/observability. *)
val describe_outcome : outcome -> string

(** The pure delivery decision, separated from the I/O so it can be tested
    without a live connector. *)
type gate =
  | Deliver  (** the channel is routable and no dedup/empty skip applies *)
  | Skip of outcome  (** delivery is skipped; carries the reason *)

(** [gate_decision ~channel ~already_replied ~content] is the fail-closed gate:
    empty content, an already-replied turn, or an [Unrouted] channel each yield
    [Skip] with the matching outcome; a routable channel yields [Deliver]. Pure
    (no I/O), so tests can assert the gate without a connector. *)
val gate_decision :
  channel:Keeper_continuation_channel.t ->
  already_replied:bool ->
  content:string ->
  gate

(** [maybe_deliver ~config ~keeper_name ~channel ~already_replied ~content]
    delivers [content] to [channel] via the existing send infrastructure, gated:

    - empty [content] -> [Skipped_empty];
    - [already_replied] (keeper called a surface-post tool this turn) ->
      [Skipped_already_replied] (avoids a double reply with the W3b steer);
    - [Unrouted] channel -> [Skipped_unrouted] (fail-closed);
    - otherwise dispatches to Dashboard / Discord / Slack and returns
      [Delivered] or [Failed].

    The gate branches ([Skipped_*]) perform no I/O. *)
val maybe_deliver :
  config:Workspace.config ->
  keeper_name:string ->
  channel:Keeper_continuation_channel.t ->
  already_replied:bool ->
  content:string ->
  outcome
