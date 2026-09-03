(** RFC-0232 P2 — producer-typed turn outcome.

    The keeper reply payload declares at the write boundary whether its
    [reply] text is model output ([Visible_reply]), absent from the
    visible surface ([No_visible_reply]), a continuation boundary
    ([Continuation_checkpoint]), a completed terminal external delivery
    ([Terminal_effect_settled]), or a durable external-effect wait
    ([External_effect_pending]). Consumers (lane persistence, stream
    terminal, direct-reply surface, dashboard) match on the decoded
    variant; control state is never synthesized into assistant prose. *)

type t =
  | Visible_reply
  | Continuation_checkpoint
  | Terminal_effect_settled
  | External_effect_pending
  | No_visible_reply

val equal : t -> t -> bool

val to_label : t -> string
(** Closed wire labels: ["visible_reply"] / ["continuation_checkpoint"] /
    ["external_effect_completed"] / ["external_effect_pending"] /
    ["no_visible_reply"].

    [Terminal_effect_settled] keeps the label ["external_effect_completed"]
    it was born with. The constructor was renamed to what the outcome is —
    a terminal tool finished delivering the reply, which has nothing to do
    with the Gate — while the label stays where its readers already look:
    the dashboard decoder and the cross-language parity test that reads
    these strings out of this file. *)

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
    explicit continuation checkpoint outcome for control-yield stops.
    [Awaiting_external_effect] is [External_effect_pending] regardless of
    response text; the dashboard renders that typed state outside the assistant
    speech surface. A runtime execution-limit observation does not create a
    MASC lifecycle gate. *)

type decode_error =
  | Payload_missing
  | Payload_not_object
  | Turn_outcome_missing
  | Turn_outcome_duplicate
  | Turn_outcome_not_string
  | Turn_outcome_unknown of string

val decode_error_to_string : decode_error -> string

val of_reply_payload : Yojson.Safe.t option -> (t, decode_error) result
(** Decode the required current [turn_outcome] contract. Missing, malformed,
    duplicate, or unknown values are explicit errors; there is no legacy
    visible-reply default. *)

val turn_ref_of_reply_payload : Yojson.Safe.t option -> Ids.Turn_ref.t option
(** Decode the turn's join key ([turn_ref_wire_key]) from a parsed keeper
    reply payload (RFC-0233 §7).  Parse, don't repair: absent payload,
    absent field, or a malformed value all decode to [None]
    ([Ids.Turn_ref.of_string] never raises).  The server stamps the
    result on the persisted chat row via {!Keeper_chat_store.append_turn}
    [?turn_ref]. *)
