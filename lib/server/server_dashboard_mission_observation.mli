(** Captured-scope Mission cache and canonical completion owner.

    Canonical [mission_snapshot] uses the existing Mission JSON contract
    (summary/incidents/actions/briefs/listing) plus top-level
    [observer_instance_id], [mission_publication_generation],
    [mission_publication_sequence] and [mission_observation_state]. State is
    exactly [initializing], [ready] or [error]. Failure retains this owner's
    last-good rows with error diagnostics; it cannot borrow another scope's
    rows or attest a response with a later scope's instance.

    The worker's SSE envelope is [{type:"mission_snapshot", payload:<Mission JSON>,
    ts_unix:<publication time>}], addressed only to the captured scoped runtime
    observers. Payloads are immutable observations. The consumer checks their
    instance and generation/sequence before using its existing Mission
    normalizer; no follow-up HTTP read is required. *)

type owner
type attempt
type origin = Source_read | Default_request
type completion = Installed of origin | Failed of origin | Invalidated
type publication_status = Current | Superseded | Source_pending | Retired

type publication = {
  json : Yojson.Safe.t;
  source : Server_dashboard_http_cache.surface_snapshot;
  generation : int;
}

val owner_for_scope :
  state:Mcp_server.server_state -> Mcp_server.workspace_scope -> owner
(** A delayed lookup of a retired scope returns a private owner and cannot
    retire the current owner's cache. These owner/publication guards perform
    no filesystem or transport operation. The worker resolves its captured
    runtime target before attempting canonical fanout. *)

val cache : owner -> Server_dashboard_http_cache.cached_surface
val is_current : owner -> bool
val has_observation : owner -> bool
(** A complete or partial source body has been retained. First partial results
    can be served without turning each GET into a retry ahead of backoff. *)
val has_terminal_answer : owner -> bool
(** A current-scope actual read has completed or failed. A no-result error
    answers default GET without bypassing the source worker's failure retry;
    it does not become a successful observation. A new owner is still cold. *)
val begin_attempt : owner -> origin:origin -> attempt
val publish_observation : attempt -> Dashboard_briefing.observation -> bool
val publish_failure_message : attempt -> string -> bool
(** Completion admits only the captured scope and ordered attempt.
    A successful attempt cannot later degrade its own result when the outer
    timeout window also closes. A source notification during an actual read
    preserves trailing read debt, but does not discard that read's completed
    observation. A partial read replaces the body with its actual readable
    rows in [error] state and retains failure-only retry; it never stamps a
    full success. Generation fences prepared publications; it does not claim
    an atomic read of every source. Callback failures cannot change admission. *)

val invalidate : owner -> unit
(** Fence already prepared publications and notify read debt, retaining the
    last-good rows. A read completing after this notice may publish its actual
    observation while the worker retains one coalesced trailing read. *)

val next_deadline_unix : owner -> float option
val subscribe_completed : owner -> (completion -> unit) -> (unit -> unit)
(** Synchronous non-I/O callback. Consumers may enqueue bounded debt only. *)

val publication : owner -> publication
(** Assemble current Keeper observations outside the publication lock while
    retaining one immutable source cache observation and captured instance. *)

val publication_is_current : owner -> publication -> bool
val publication_status : owner -> publication -> publication_status
(** Superseded cache preparation retains bounded publication debt; only an
    input frontier with no subsequent read completion is [Source_pending]. An
    older preparation becomes [Superseded] once the current read completes.
    This distinction prevents both a lost first completion after a cancelled
    request's attempt stamp and a busy publisher during a long source read. *)

val cache_identity : owner -> string
(** Process/workspace incarnation partition for actual HTTP SWR keys. *)
