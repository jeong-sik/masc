(** Provider quota windows for runtime lane failover.

    A hard-quota rejection that carries a provider [retry_after] is a fact
    with a stated end time: the account's quota window is exhausted until
    [resets_at].  Without remembering it, lane failover re-dispatches into
    the same provider on every turn until the window resets (measured
    2026-08-11: 103 keeper cycle failures in one day from exactly this).

    The table lives in process memory. Each stated window it takes also goes
    to the sink the server installs ({!set_stated_window_sink}), and the
    server reads those windows back before any Keeper walks
    ({!Runtime_quota_window_journal}), so a restart does not forget a reset
    the provider stated. An observation without a reset is not passed on: it
    ends at the cap after it was noted or at the next success, and the sink
    sees neither.

    This module remembers that fact and lets candidate ordering act on it.
    It is an ordering preference, not an admission gate — a demoted
    candidate is still attempted when it is all the lane has left, so no
    new fail-closed path exists.  Sibling of {!Runtime_candidate_backpressure};
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

val note_exhausted : scope:scope -> resets_at:float -> unit
(** Remember that [scope]'s quota window is exhausted until
    [resets_at] (Unix epoch seconds).  A later [resets_at] for the same
    scope extends the window; an earlier one is ignored so a stale
    retry hint cannot shorten a window a fresher response already
    established. A window the table takes goes to the stated-window sink. *)

type stated_window =
  { scope : scope
  ; resets_at : float  (** Unix epoch seconds, as {!note_exhausted} took it. *)
  }
(** A reset time a provider stated for a scope's quota. *)

val set_stated_window_sink : (stated_window -> unit) -> unit
(** Install the server's durable sink. {!note_exhausted} passes it each window
    the table takes: the scope's first stated reset, or a later one than it
    held. An equal or earlier reset changes nothing and is not passed. The sink
    runs on the writer's fiber after the lock is released and after
    {!Runtime_path_rest_signal.recorded}; it must log its own failures and not
    raise, because the table already holds the window. *)

type stated_window_decode_error =
  | Not_an_object of { path : string }
  | Missing_field of { path : string }
  | Unexpected_field of { path : string }
  | Duplicate_field of { path : string }
  | Wrong_type of
      { path : string
      ; expected : string
      }
  | Empty_string of { path : string }
  | Not_finite of { path : string }
  | Unknown_scope_kind of string

val stated_window_decode_error_to_string : stated_window_decode_error -> string

val stated_window_to_json : stated_window -> Yojson.Safe.t
(** [{"scope": {"kind": ..., ...}, "resets_at": <float>}]. The scope carries
    its non-secret name: a provider row id, a credential env name or file
    path, or an official client and its home. *)

val stated_window_of_json :
  Yojson.Safe.t -> (stated_window, stated_window_decode_error) result
(** The inverse of {!stated_window_to_json}. Every field is required, no other
    field is accepted, no field may repeat, strings must be non-empty and
    [resets_at] must be a
    finite float. A [kind] this build does not write is
    {!Unknown_scope_kind}. *)

val note_observed_exhausted : scope:scope -> unit
(** Remember that [scope] answered a hard quota rejection without stating when
    it resets.  No reset is claimed: the observation rests the scope from the
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
