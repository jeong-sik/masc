(** RFC-0232 P2 — producer-typed turn outcome.

    The keeper reply payload declares at the write boundary whether its
    [reply] text is model output ([Visible_reply]), absent from the
    visible surface ([No_visible_reply]), or the synthetic continuation
    notice substituted when a run stops at a checkpoint boundary
    ([Continuation_checkpoint]).  Consumers (lane persistence, stream
    terminal, direct-reply surface, dashboard) match on the decoded
    variant; the legacy ["Continuation checkpoint saved;"] prefix sniff
    is deleted. *)

type t =
  | Visible_reply
  | Continuation_checkpoint
  | No_visible_reply

val equal : t -> t -> bool

val to_label : t -> string
(** Closed wire labels: ["visible_reply"] / ["continuation_checkpoint"] /
    ["no_visible_reply"]. *)

val of_label : string -> t option
(** Inverse of {!to_label}; [None] on any other string. *)

val wire_key : string
(** JSON field name carrying the label in the keeper reply payload:
    ["turn_outcome"]. *)

val turn_ref_wire_key : string
(** JSON field name carrying the turn's join key in the keeper reply
    payload: ["turn_ref"] (RFC-0233 §7).  Shared by the producer
    ({!Keeper_turn} reply_json) and the consumer
    ({!turn_ref_of_reply_payload}) so the wire name cannot drift. *)

val of_stop_reason : Runtime_agent.stop_reason -> t
(** Stop-reason-only classifier. [Completed] may carry model output. Use
    {!of_result_surface} at payload production sites where the actual
    [response_text] is available. *)

val of_result_surface : response_text:string -> Runtime_agent.stop_reason -> t
(** Classify the reply-surface contract for a completed keeper run.
    [Completed] with blank [response_text] is [No_visible_reply], not
    [Visible_reply].  This keeps hidden read-only/tool-only runtime turns
    from being reported as user-visible replies while preserving the
    explicit continuation checkpoint outcome for control-yield stops. A
    runtime execution-limit observation does not create a MASC lifecycle gate. *)

val of_reply_payload : Yojson.Safe.t option -> t
(** Decode from a parsed keeper reply payload.  Known labels decode to
    their declared variant.  Absent payload, absent field, or unknown
    label decodes to [Visible_reply] (unknown labels are logged at WARN):
    the bitten failure mode (#20870) was a reply silently {e not}
    persisted — the lane watermark stalled and the keeper re-answered
    the same message — so decode failure must fail toward persisting,
    never toward dropping. *)

val turn_ref_of_reply_payload : Yojson.Safe.t option -> Ids.Turn_ref.t option
(** Decode the turn's join key ([turn_ref_wire_key]) from a parsed keeper
    reply payload (RFC-0233 §7).  Parse, don't repair: absent payload,
    absent field, or a malformed value all decode to [None]
    ([Ids.Turn_ref.of_string] never raises).  The server stamps the
    result on the persisted chat row via {!Keeper_chat_store.append_turn}
    [?turn_ref]. *)
