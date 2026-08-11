(** Process-local provider quota windows for runtime lane failover.

    A hard-quota rejection that carries a provider [retry_after] is a fact
    with a stated end time: the account's quota window is exhausted until
    [resets_at].  Without remembering it, lane failover re-dispatches into
    the same provider on every turn until the window resets (measured
    2026-08-11: 103 keeper cycle failures in one day from exactly this).

    This module remembers that fact and lets candidate ordering act on it.
    It is an ordering preference, not an admission gate — a demoted
    candidate is still attempted when it is all the lane has left, so no
    new fail-closed path exists.  Sibling of {!Runtime_lane_preference};
    the table is shared across keepers on purpose because provider quota
    windows are account-scoped.

    Windows are recorded only when the provider stated a reset time.  A
    quota failure without [retry_after] records nothing: inventing a
    cooldown here would be a synthesized default the provider never
    reported.  Expiry is the provider-stated [resets_at] itself, pruned
    lazily on read; there is no background sweeper and no TTL knob.
    RFC-0370 §3.3. *)

type scope
(** A non-secret quota ownership key.  The representation is deliberately
    abstract so provider row ids, environment references, and file references
    cannot be mixed accidentally at call sites. *)

val note_exhausted : scope:scope -> resets_at:float -> unit
(** Remember that [scope]'s quota window is exhausted until
    [resets_at] (Unix epoch seconds).  A later [resets_at] for the same
    scope extends the window; an earlier one is ignored so a stale
    retry hint cannot shorten a window a fresher response already
    established. *)

val active_until : scope:scope -> now:float -> float option
(** [Some resets_at] when [scope] has a recorded window that has not
    yet passed at [now]; [None] otherwise.  Expired entries are pruned on
    read. *)

val demote_order :
  now:float ->
  quota_scope_of:('a -> scope option) ->
  'a list ->
  'a list
(** Stable-partition [candidates]: those whose quota scope (via
    [quota_scope_of]) has an active window at [now] move to the tail,
    preserving declared relative order within both partitions.  Candidates
    whose scope is unknown ([quota_scope_of] returns [None]) are left in
    place — an unresolved id is not evidence of exhaustion.  Returns the
    input unchanged when no candidate is demoted. *)

val scope_of_credential :
  provider_id:string -> Runtime_schema.credential option -> scope
(** Non-secret quota-scope identity for a provider row.  Provider hard quota
    is credential-account-owned, not provider-row-owned: two rows sharing one
    credential share one window (PR #28202 review).  [Env]/[File] carriers
    are keyed by their non-secret reference without encoding the carrier kind
    into a string prefix;
    [Inline] carries the secret itself, so it cannot serve as a shared name
    and falls back to the row's [provider_id], as does an absent
    credential. *)

val reset_for_testing : unit -> unit
(** Drop every remembered window.  Test-only. *)
