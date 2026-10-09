(** Remembers an operator's answer that arrived after its wait was gone, so
    the identical retried call is settled by it once instead of asking again.

    {2 Why a late answer is preserved}

    The decision an operator makes is about the call, and the call outlives
    the wait that first asked about it: a wait that times out blocks that one
    call and the Keeper carries on, the identical call comes back under a
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
      ({!Keeper_approval_request_fingerprint.request_fingerprint}). Different
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

val bind_to_journal :
  ?now:float -> base_path:string -> t -> unit
(** Bind the store to the gate root's decision journal
    ({!Keeper_gate_path.late_approval_log}) and restore its view from the
    journal synchronously, before any turn can consult the store (design
    D2): a remembered answer must already stand when the first identical
    retry after a restart arrives, and a lazy restore could answer an ask
    the operator already settled.

    Restore validates every complete v2 row before replay. Invalid rows or
    unavailable storage fence mutations until a successful explicit restore.
    A bound store durably appends every mutation; a known commit receipt
    survives cleanup failure, while an unconfirmed append fences the store. The server binds the shared
    store once at boot; tests bind per-store temp directories. Calling it
    twice rebinds and re-restores (the second read is the journal plus
    whatever the first bound period appended). The [?now] injection exists
    so tests can restore with a fixed clock, matching the other
    operations. *)

type journal_error = Corrupt_journal of string | Journal_unavailable of string
val journal_error : t -> journal_error option
(** A restore error fences all journal mutations; no uncertain count establishes health. *)
type uncertain_attempt =
  { consume_id : string; base_path : string; keeper_name : string
  ; tool_name : string; args_fingerprint : string; consumed_at : float }
val uncertain_attempts : t -> base_path:string -> (uncertain_attempt list, journal_error) result
(** Authenticated workspace projection; every acknowledgement names one consume. *)

val journal_uncertain : t -> int
(** The count of consumed late answers whose deliver row is missing — the
    outcome-unknown window design D2 names. [take] attempts [op=deliver] before returning the decision; if
    that append fails it still returns, so consume-only evidence cannot
    establish whether the caller subsequently dispatched. Restores surface that window here, and health's
    [keeper_hitl_gate.late_uncertain] carries the count to the operator
    (acked by {!ack_uncertain}; an ack is a warning acknowledgement, never a
    re-authorization). Uncertain attempts do not expire with authorization TTL. *)

type ack_outcome =
  | Acked
      (** The named consume-only tail is now acknowledged; [journal_uncertain]
          drops by one and the ack stands in the journal across restarts. *)
  | Ack_not_journaled
      (** The journal append failed: the count is unchanged, so the tail
          keeps asking to be acknowledged. *)
  | Not_uncertain
      (** No consume-only tail stands for this identity — already delivered,
          already acked, or never consumed here. *)

val ack_uncertain :
  t ->
  ?now:float ->
  base_path:string ->
  keeper_name:string ->
  consume_id:string ->
  unit ->
  ack_outcome
(** Acknowledge one consume-only tail by authenticated workspace, Keeper and consume ID;
    tool/fingerprint are read from the stored attempt (design D4/§7): the operator has seen the outcome-unknown
    warning. An ack is a warning acknowledgement and never a
    re-authorization — nothing is re-applied, no remembered answer is
    restored, no new attempt is permitted by it, and the
    execution-ledger readback stays the only basis for any manual
    disposition. The ack is durably appended before the count drops, so it
    survives restarts the same way the consume it answers does. *)

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
  base_path:string ->
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

    [base_path] is the asking workspace the gate runs under, part of the
    ask's identity: workspaces that share the gate root cannot have their
    asks answered by each other's operators (design D2). When the store is
    {!bind_to_journal}-bound, the record is durably appended first and the
    memory only holds what the journal acknowledged; an append failure
    keeps no memory, so the identical retry is asked about again.

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
          discarded. *)

val remember_late :
  t ->
  ?now:float ->
  base_path:string ->
  keeper_name:string ->
  tool_call_id:string ->
  actor:string ->
  Keeper_tool_approval_registry.decision ->
  unit ->
  remember_outcome
(** Attribute an answer whose wait is gone. Only an ask that actually timed
    out here (recorded by {!note_timed_out}) under the same [base_path], and
    is no older than {!ttl_sec}
    matches, so the remembered decision always descends from a question the
    operator was really shown. Timed-out asks
    are matched newest-first: if
    a provider recycles a call id, the answer attaches to the most recent
    ask that carried it, which is the prompt the operator saw last. When
    bound, the decision is journaled before it
    stands; an append failure reports [No_matching_ask] so the caller tells
    the operator the answer could not be kept rather than silently dropping
    it.

    [actor] is the authenticated caller recorded at the HTTP boundary
    (task-1662) — who made this decision outlives the HTTP request, so it is
    threaded here rather than read back from the answering client. *)

val take :
  t ->
  ?now:float ->
  base_path:string ->
  keeper_name:string ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_approval_registry.decision option
(** The remembered answer for this exact call under this [base_path], if one
    stands. A hit is removed: the operator approved this call once, not
    every call that looks like it.

    The consume is durably journaled before the decision is returned (design
    D2's order contract): an append failure reads as [None] and changes
    nothing, so a restart re-offers the decision rather than silently
    dropping it — the safe side of "duplicate authorization is worse than
    re-asking". Before returning the decision, an [op=deliver] row is attempted;
    a failure still returns the decision and leaves the consume in
    {!journal_uncertain}'s outcome-unknown window. Entries older than
    {!ttl_sec} are reaped before the lookup, so a stale memory reads as
    [None] — no memory — and the call is asked about again. *)

(** {1 Decision attribution}

    Who made a remembered decision. The stamp is taken from the
    authenticated HTTP caller, never from the answering client's own
    accounting of itself (task-1662): a self-reported identity would let the
    answering client write any name into the ledger. Consumed entries are
    gone by the time {!take} returns, so the stamp is visible only through
    the module's own log lines and for as long as the memory stands. *)

(* No [For_testing] seam here. The operator review of task-1665 removed the
   only one ([fail_next_deliver]): a store-internal mutable flag that a
   production append branch checked on every call is test-only state living
   in the shipped type. Tests now write consume-only tails straight to the
   journal file and restore, which is the real crash shape anyway. *)
