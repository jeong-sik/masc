(** Remembers an operator's answer that arrived after its wait was gone, so
    the identical retried call is settled by it once instead of asking again.

    {2 Why a late answer is preserved}

    The decision an operator makes is about the call, and the call outlives
    the turn that first made it: a timed-out wait ends the turn with
    [External_effect_pending], the next turn retries the same call under a
    fresh tool call id, and the gate asks again. Without this module the
    operator's first answer is dropped and they answer the same question
    twice.

    {2 How this squares with the registry's design}

    {!Keeper_tool_approval_registry} declares that a call whose waiter is
    gone is not held for later, "because an approval that outlives the turn
    it was asked about would authorize a call nobody is making." Nothing
    here authorizes a call nobody is making: a remembered answer settles
    nothing by itself. It is consulted only when the identical call — same
    keeper, same tool, same canonical-arguments fingerprint — actually
    arrives at the gate again, and that one arrival consumes it. A call the
    keeper never retries never runs, and a second identical call is asked
    about as usual.

    {2 Safety rules}

    - Only the exact call the operator was shown is matched: the identity is
      (keeper, tool, canonical-args fingerprint), the same fingerprint the
      durable approval rules use
      ({!Keeper_approval_queue_rules.request_fingerprint}). Different
      arguments miss and are asked about.
    - Deny is remembered exactly like approve: a remembered refusal spares
      the operator the same question twice too.
    - One use consumes the memory. *)

type t

val create : unit -> t

val shared : unit -> t
(** The store the running server uses.

    One instance rather than an installed slot: the gate that records a
    timed-out ask, the HTTP handler that receives the late answer, and the
    next turn's gate that consumes it must all reach the same store.
    [create] stays for tests, which want an empty one per case. *)

val note_timed_out :
  t ->
  keeper_name:string ->
  tool_call_id:string ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  unit
(** Record what a wait that ended unanswered was asking about, so a late
    answer can be attributed to it. Called by the gate when
    {!Keeper_tool_approval_registry.await} returns [Timed_out]; the
    description is taken from the ask itself, never from the answering
    client, so a late answer cannot attach itself to a call it was not
    shown. *)

(** What a late answer found. *)
type remember_outcome =
  | Remembered of { tool_name : string }
      (** The call id named a wait that timed out here; the answer now
          stands for the next identical call. *)
  | No_matching_ask
      (** The call id was never held, or was already answered. Nothing is
          remembered: an answer that cannot be attributed to an ask this
          process made is discarded, as before. *)

val remember_late :
  t ->
  keeper_name:string ->
  tool_call_id:string ->
  Keeper_tool_approval_registry.decision ->
  remember_outcome
(** Attribute an answer whose wait is gone. Only an ask that actually timed
    out here (recorded by {!note_timed_out}) matches, so the remembered
    decision always descends from a question the operator was really shown. *)

val take :
  t ->
  keeper_name:string ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_approval_registry.decision option
(** The remembered answer for this exact call, if one stands. A hit is
    removed: the operator approved this call once, not every call that
    looks like it. *)
