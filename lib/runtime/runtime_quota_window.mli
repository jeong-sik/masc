(** Process-local provider quota windows for runtime lane failover.

    A hard-quota rejection that carries a provider [retry_after] is a fact
    with a stated end time: the account's quota window is exhausted until
    [resets_at].  Without remembering it, lane failover re-dispatches into
    the same provider on every turn until the window resets (measured
    2026-08-11: 103 keeper cycle failures in one day from exactly this).

    The table lives in process memory, so a restart forgets it and the next
    refusal teaches it again. An observation without a reset ends at the cap
    after it was noted or at the next success.

    This module remembers that fact and lets candidate ordering act on it.
    For a Keeper walk it is an ordering preference, not an admission gate — a
    demoted candidate is still attempted when it is all the lane has left.
    An Exact-output lane does not call a candidate before a reset the
    provider stated; it returns that candidate as held instead of dropping it
    (RFC-exact-lane-waits-for-a-stated-reset).  Sibling of {!Runtime_candidate_backpressure};
    the table is shared across keepers on purpose because provider quota
    windows are account-scoped.

    A window with a stated reset expires at that time, pruned lazily on read;
    there is no background sweeper.  A provider that stated no reset gets no
    invented one: {!note_observed_exhausted} records the observation, and it
    rests the scope for the hard-quota fallback the operator declared
    ([Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec], the same
    bound the failed cycle already waits) from the moment it was noted. After
    that the observation no longer orders anything; the next success on the
    scope clears it sooner (RFC-provider-path-rest §3.3, 2026-11-06).
    Coarse HTTP 429 / Provider.RateLimit does not establish credential
    ownership; it belongs to {!Runtime_candidate_backpressure}'s candidate-only
    observation instead. RFC-0370 §3.3, RFC-0433. *)

type scope
(** A non-secret quota ownership key.  The representation is deliberately
    abstract so provider row ids, environment references, and file references
    cannot be mixed accidentally at call sites. *)

type refusal = Keeper_runtime_failure_route.hard_quota_source =
  | Payment_refused  (** an HTTP 402: the account's balance or budget *)
  | Provider_quota_refused  (** the provider's typed hard quota, e.g. a spent usage window *)
(** The typed constructor a hard-quota refusal arrived as. *)

(** Who set the entry that rests a scope. *)
type cause =
  | Refused of refusal  (** a refused call *)
  | Usage_read  (** a usage read that found the gating window spent *)

val note_exhausted : scope:scope -> source:refusal -> resets_at:float -> unit
(** Remember that a refusal of kind [source] stated [scope] is exhausted until
    [resets_at] (Unix epoch seconds).  A later [resets_at] for the same
    scope extends the window and takes its cause; an earlier one is ignored
    so a stale retry hint cannot shorten a window a fresher response already
    established. *)

val note_read_spent_until : scope:scope -> resets_at:float -> unit
(** {!note_exhausted} for a usage read that found [scope]'s gating window
    spent until [resets_at]. *)

val note_observed_exhausted : scope:scope -> source:refusal -> unit
(** Remember that [scope] answered a hard quota rejection of kind [source]
    without stating when it resets.  No reset is claimed: the observation rests the scope from the
    wall-clock moment of this call for the hard-quota fallback cap, or until
    {!note_succeeded} clears it.  A scope that already has a stated window
    still ahead keeps it — the provider's own answer says more than an
    observation; a stated window that has already passed names no rest and
    gives way.  A scope a usage read found spent without a reset
    ({!note_read_without_reset}) keeps that answer while its rest lasts; a
    later refusal after it notes a new observation. *)

val note_read_without_reset : scope:scope -> unit
(** Remember that a usage read found [scope]'s gating window spent and stated
    no reset.  It rests the scope as {!note_observed_exhausted} does, and it
    answers the question that refusal leaves: {!answered_rest} reports it, so
    another read is not asked for the same scope while that rest lasts. *)

val note_observed_exhausted_at : now:float -> scope:scope -> source:refusal -> unit
(** {!note_observed_exhausted} with the moment of observation given as [now]
    instead of read from the wall clock.

    The wall clock is the default moment, not the only one: it dates the
    rest and tells whether a held entry has passed, so a caller that already
    holds the moment (a test, a replay of a captured answer) should not be
    forced to re-read it.  Real provider paths keep calling
    {!note_observed_exhausted}; this entry point exists so a fixture can be
    dated deterministically. *)

val note_read_without_reset_at : now:float -> scope:scope -> unit
(** {!note_read_without_reset} with the moment of observation given as [now].
    Same relation to its wall-clock sibling as
    {!note_observed_exhausted_at}. *)

val note_succeeded : scope:scope -> unit
(** A call on [scope] got through, so an observation recorded by
    {!note_observed_exhausted} no longer holds and is dropped.  A stated
    window is left alone: one call succeeding inside it does not make the
    provider's answer about a time untrue. *)

val is_exhausted : scope:scope -> now:float -> bool
(** Whether ordering should hold [scope] back at [now] — a stated window or
    an observation whose rest has not passed.  This is what {!demote_order}
    asks; {!active_until} answers the narrower question of when a stated
    window ends, and is [None] for an observation because the provider named
    no time. *)

type rest =
  | Reset_stated of float
      (** A reset the provider stated, in a refusal or a usage read. *)
  | Observed_until of float
      (** An observation without a reset, resting until its noted moment plus
          the hard-quota fallback cap. *)

val rest : scope:scope -> now:float -> rest option
(** When [scope]'s rest ends, and who set that time; [None] when nothing
    rests it at [now].  It reads the same entry {!is_exhausted} reads, so the
    two agree at every [now].  Passed entries are pruned on read. *)

type spent =
  { cause : cause
  ; rest : rest
  }

val spent : scope:scope -> now:float -> spent option
(** {!rest} together with who set it, for a surface that shows why [scope]
    rests. It reads the same entry, so [spent] is [Some] exactly when {!rest}
    is. Ordering does not read the cause. *)

val cause_to_wire_name : cause -> string
(** The word a cause is written as in a JSON projection. *)

val cause_of_wire_name : string -> cause option
(** Inverse of {!cause_to_wire_name}; [None] for any other word. *)

type answered_rest =
  | Stated_reset_ahead  (** a stated window that has not passed at [now] *)
  | Read_found_no_reset  (** {!note_read_without_reset}, not yet cleared *)

val answered_rest : scope:scope -> now:float -> answered_rest option
(** What a provider answer already says about [scope]'s rest, for a caller
    deciding whether a usage read could add to it. [None] when nothing rests
    the scope or only a refusal without a reset does: that refusal is the
    question a read answers. Expired entries are pruned on read. *)

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

(** The scope's own label for trusted diagnostics. File and official-client
    scopes can contain absolute paths; public projections must use opaque
    labels instead. *)
val scope_to_string : scope -> string

val scope_id : scope -> string
(** Opaque public ID shared by Setup groups, Runtime and Usage history. It
    preserves the existing history digest. The scope names a credential
    reference, client home or fallback provider row, not an authenticated
    provider account; replacing credentials in place does not change this ID.
    This is a correlation label, never an authentication or mutation token. *)

val scope_equal : scope -> scope -> bool
(** Whether two scopes name the same quota owner. *)

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

val scope_of_claude_code_home : string option -> scope
val scope_of_codex_home : string option -> scope
val scope_of_muse_home : string -> scope
(** Official-client quota identity is the selected CLI home, not the provider
    row id. Two rows selecting the same home share observations; selecting a
    different home under the same row id does not reuse prior observations.
    Without an explicit home, the process's CLI home environment is sampled
    at materialization, or the client's default directory under HOME is used.
    A missing or non-absolute home is rejected before execution. *)

val reset_for_testing : unit -> unit
(** Drop every remembered window.  Test-only. *)
