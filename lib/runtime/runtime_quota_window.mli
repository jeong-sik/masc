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

    A window with a stated reset expires at that time, pruned lazily on read;
    there is no background sweeper and no TTL knob.  Inventing a cooldown for
    a provider that stated none would be a synthesized default, so
    {!note_observed_exhausted} records the observation instead and claims no
    end: it is cleared by the next success on the scope, not by a clock.
    Both metered providers this fleet reaches answer 429 with no Retry-After
    (2026-09-06: ollama.com and api.z.ai), so without that second form the
    table stays empty and every lane re-dispatches into a spent account for
    as long as it is spent.  RFC-0370 §3.3, RFC-0433. *)

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

val note_observed_exhausted : scope:scope -> unit
(** Remember that [scope] answered a hard quota rejection without stating when
    it resets.  No end time is claimed and none is invented: the record stands
    until {!note_succeeded} clears it.  A scope that already has a stated
    window keeps it — the provider's own answer says more than an
    observation. *)

val note_succeeded : scope:scope -> unit
(** A call on [scope] got through, so an observation recorded by
    {!note_observed_exhausted} no longer holds and is dropped.  A stated
    window is left alone: one call succeeding inside it does not make the
    provider's answer about a time untrue. *)

val is_exhausted : scope:scope -> now:float -> bool
(** Whether ordering should hold [scope] back at [now] — a stated window that
    has not passed, or an observation no success has cleared.  This is what
    {!demote_order} asks; {!active_until} answers the narrower question of
    when a stated window ends, and is [None] for an observation because an
    observation names no time. *)

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
