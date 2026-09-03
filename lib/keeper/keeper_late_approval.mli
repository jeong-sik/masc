(** Remembers an operator's answer that arrived after its wait was gone, so
    the identical retried call is settled by it once instead of asking again.

    {2 Why a late answer is preserved}

    The decision an operator makes is about the call, and the call outlives
    the turn that first made it: a wait that times out leaves the ask
    unanswered, the next turn retries the same call under a fresh tool call
    id, and the gate asks again. Without this module the
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
    - One use consumes the memory. The operator approved this call once, not
      every call that looks like it.
    - The memory is bounded in time: a remembered answer counts for
      {!ttl_sec}, and an entry older than that is reaped on the next
      operation and treated as no memory — the call is asked about again.
      A 180-second-window human decision must not become a permanent
      credential: days later, the identical call arrives in a context the
      operator never saw. This is a safety bound on how long one decision
      can authorize, the class of bound the constitution's budget_gate
      prohibition explicitly exempts.
    - The age bound is also what makes the yolo stance safe to flip. While a
      keeper stands in [Yolo] the gate never asks and never consumes, so
      entries would pile up unconsumed; without the age check a memory
      banked before the flip would fire on the first gated call after the
      flip back. With it, a stale entry reads as no memory. *)

type t

val create : unit -> t

val shared : unit -> t
(** The store the running server uses.

    One instance rather than an installed slot: the gate that records a
    timed-out ask, the HTTP handler that receives the late answer, and the
    next turn's gate that consumes it must all reach the same store.
    [create] stays for tests, which want an empty one per case. *)

val ttl_sec : float
(** How long a remembered answer still counts as the decision the operator
    just made: 900s.

    The live wait gives an operator 180s to answer (the server's
    [keeper_tool_approval_timeout_sec]); a remembered answer extends that
    same moment to the retry the operator already knows is coming. Fifteen
    minutes is that order — minutes past the live window, nowhere near
    days. Inside it, the identical call arriving is recognizably the retry
    that prompted the answer; past it, the conversation has moved on and
    the answer was about a moment that no longer holds. *)

val note_timed_out :
  t ->
  ?now:float ->
  keeper_name:string ->
  tool_call_id:string ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  unit ->
  unit
(** Record what a wait that ended unanswered was asking about, so a late
    answer can be attributed to it. Called by the gate when
    {!Keeper_tool_approval_registry.await} returns [Timed_out]; the
    description is taken from the ask itself, never from the answering
    client, so a late answer cannot attach itself to a call it was not
    shown.

    [now] defaults to the wall clock at this I/O boundary; the gate passes
    its own clock's reading so ages are measured against the same clock
    family the wait ran on, and tests inject it. *)

(** What a late answer found. *)
type remember_outcome =
  | Remembered of { tool_name : string }
      (** The call id named a wait that timed out here; the answer now
          stands for the next identical call. *)
  | No_matching_ask
      (** The call id was never held, was already answered, or timed out
          longer ago than {!ttl_sec}. Nothing is remembered: an answer that
          cannot be attributed to an ask this process made — recently — is
          discarded, as before. *)

val remember_late :
  t ->
  ?now:float ->
  keeper_name:string ->
  tool_call_id:string ->
  Keeper_tool_approval_registry.decision ->
  unit ->
  remember_outcome
(** Attribute an answer whose wait is gone. Only an ask that actually timed
    out here (recorded by {!note_timed_out}) and is no older than {!ttl_sec}
    matches, so the remembered decision always descends from a question the
    operator was really shown.

    Expired asks are matched newest-first: if a provider ever recycles a
    tool call id, the answer attaches to the newest ask that carried it.
    That is the safe direction — it is the prompt the operator was shown
    most recently, and any older entry with the same id describes an ask
    its own timeout already ended. *)

val take :
  t ->
  ?now:float ->
  keeper_name:string ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_approval_registry.decision option
(** The remembered answer for this exact call, if one stands. A hit is
    removed: the operator approved this call once, not every call that
    looks like it.

    Entries older than {!ttl_sec} are reaped before the lookup, so a stale
    memory reads as [None] — no memory — and the call is asked about
    again. *)
