(** RFC-0232 P2 — producer-typed turn outcome.

    The keeper reply payload declares at the write boundary whether its
    [reply] text is model output ([Visible_reply]) or the synthetic
    continuation notice substituted when a run stops at a budget /
    mutation boundary ([Continuation_checkpoint]).  Consumers (lane
    persistence, stream terminal, direct-reply surface, dashboard)
    match on the decoded variant; the legacy
    ["Continuation checkpoint saved;"] prefix sniff is deleted. *)

type t =
  | Visible_reply
  | Continuation_checkpoint

val equal : t -> t -> bool

val to_label : t -> string
(** Closed wire labels: ["visible_reply"] / ["continuation_checkpoint"]. *)

val of_label : string -> t option
(** Inverse of {!to_label}; [None] on any other string. *)

val wire_key : string
(** JSON field name carrying the label in the keeper reply payload:
    ["turn_outcome"]. *)

val of_stop_reason : Runtime_agent.stop_reason -> t
(** [Completed] is the only stop reason whose reply text is model
    output.  [TurnBudgetExhausted] replaces the reply with the synthetic
    continuation notice ({!Runtime_agent} MaxTurnsExceeded arm);
    [MutationBoundaryReached] shares the resume-next-cycle contract
    (currently unreachable: no production caller passes
    [exit_condition_result]). *)

val of_reply_payload : Yojson.Safe.t option -> t
(** Decode from a parsed keeper reply payload.  Absent payload, absent
    field, or unknown label decodes to [Visible_reply] (unknown labels
    are logged at WARN): the bitten failure mode (#20870) was a reply
    silently {e not} persisted — the lane watermark stalled and the
    keeper re-answered the same message — so decode failure must fail
    toward persisting, never toward dropping. *)
