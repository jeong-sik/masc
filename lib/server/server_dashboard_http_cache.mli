(** Server_dashboard_http_cache — cached_surface type and dashboard
    cache lifecycle helpers.

    A {!cached_surface} is a mutable record carrying the most recent
    successful JSON snapshot for a dashboard endpoint plus three
    timestamp triples (success / attempt / error) used to render
    cache-state diagnostics in the response payload.  All accessors
    mutate the record in place — there is no implicit thread-safety;
    callers serialise access through a per-cache mutex when they
    need it.

    The module also provides
    {!cached_surface_or_first_success_json} — a "compute on first
    miss, return cached afterwards" wrapper around
    {!Dashboard_cache.get_or_compute_with_timeout}.  This pairs the
    cache-key/TTL machinery with the per-surface attempt/success/
    error tracking. *)

type cached_surface = {
  mutable json : Yojson.Safe.t;
  mutable last_success_at : string option;
  mutable last_success_unix : float option;
  mutable last_attempt_at : string option;
  mutable last_attempt_unix : float option;
  mutable last_error : string option;
  mutable last_error_at : string option;
  mutable last_error_unix : float option;
}
(** Concrete record because dashboard tests mutate it directly
    ({!Test_dashboard_namespace_truth}, {!Test_dashboard_execution})
    via {!mark_cached_surface_success} / {!invalidate_cached_surface}.
    The three timestamp triples are paired (ISO + Unix) so callers
    do not have to re-format on every render. *)

val create_cached_surface : Yojson.Safe.t -> cached_surface
(** [create_cached_surface json] returns a fresh surface seeded
    with [json] and all six timestamps set to [None].  Callers
    typically seed with a synthetic "initializing" envelope so
    {!cached_surface_json} can render a cache_state of
    ["initializing"] before the first attempt completes. *)

val mark_cached_surface_attempt : cached_surface -> unit
(** [mark_cached_surface_attempt s] stamps [last_attempt_*] with
    the current wall-clock + ISO time.  Called at the start of a
    compute cycle. *)

val mark_cached_surface_success : cached_surface -> Yojson.Safe.t -> unit
(** [mark_cached_surface_success s json] stamps [last_success_*]
    with the current time, replaces [s.json] with [json], and
    {b clears} the [last_error_*] triple.  The error clear is
    deliberate — a successful refresh resolves the previous
    failure.  A future "let's keep the last error around for
    debugging" change must touch this contract. *)

val mark_cached_surface_error : cached_surface -> exn -> unit
(** [mark_cached_surface_error s exn] stamps [last_error_*] with
    [Printexc.to_string exn] and the current time.  Does NOT
    touch [last_success_*] or [s.json] — the previous successful
    snapshot remains served until the next success refreshes it. *)

val invalidate_cached_surface : cached_surface -> unit
(** [invalidate_cached_surface s] clears all six timestamps but
    leaves [s.json] intact.  Used by tests to reset surface state
    between scenarios while preserving the seeded JSON envelope. *)

val cached_surface_has_success : cached_surface -> bool
(** [cached_surface_has_success s] returns [true] iff
    [s.last_success_unix] is [Some _] (at least one successful
    refresh has occurred). *)

val cached_surface_json : cached_surface -> Yojson.Safe.t
(** [cached_surface_json s] returns [s.json] augmented with a
    [projection_diagnostics] sub-object carrying the cache state.

    {2 cache_state values}

    | Condition | [cache_state] | [stale_age_ms] |
    |---|---|---|
    | [last_success_unix = None] | [["initializing"]] | [`Null] |
    | [error_ts > success_ts] | [["stale"]] | success age |
    | otherwise | [["fresh"]] | [`Null] |

    [stale_reason] mirrors [last_error] when stale,
    [`Null] otherwise.  This is the operator-visible cache-health
    surface — dashboard CSS keys off the literal [["initializing"]]
    / [["stale"]] / [["fresh"]] strings. *)

val cached_surface_or_first_success_json :
  cached_surface ->
  cache_key:string ->
  ttl:float ->
  clock:_ Eio.Time.clock ->
  timeout_sec:float ->
  (unit -> Yojson.Safe.t) ->
  Yojson.Safe.t
(** [cached_surface_or_first_success_json s ~cache_key ~ttl ~clock
    ~timeout_sec compute] returns the cached JSON when the surface
    has at least one successful refresh, otherwise drives
    [compute] through {!Dashboard_cache.get_or_compute_with_timeout}
    with the surface's attempt/success/error tracking bound around
    the call.

    [Eio.Cancel.Cancelled] is re-raised verbatim (no error
    tracking) so a fiber cancellation does not pollute the surface
    with a synthetic error. *)

(** {1 Assoc-list helper}

    Exposed because sister dashboard surface modules
    ({!Server_dashboard_http_execution_surfaces}) layer fields onto
    [`Assoc] payloads via this helper and the canonical
    cache-state augmentation pipeline. *)

val upsert_assoc_field :
  string ->
  Yojson.Safe.t ->
  (string * Yojson.Safe.t) list ->
  (string * Yojson.Safe.t) list
(** [upsert_assoc_field key value fields] returns [fields] with
    [(key, value)] prepended and any prior occurrence of [key]
    removed.  Last-write-wins on duplicate keys. *)

(** {1 Projection-diagnostics builders} *)

val attach_projection_diagnostics :
  Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** [attach_projection_diagnostics json diagnostics] prepends
    [("projection_diagnostics", diagnostics)] to an [`Assoc]
    payload, returning [json] unchanged for non-objects.  Used by
    {!with_projection_diagnostics}. *)

val extend_projection_diagnostics :
  Yojson.Safe.t -> (string * Yojson.Safe.t) list -> Yojson.Safe.t
(** [extend_projection_diagnostics json extra_fields] merges
    [extra_fields] into the existing [projection_diagnostics] sub-
    object (or creates one when absent).  Existing keys are
    overwritten by [extra_fields] (last-write-wins).  Used by
    {!cached_surface_json} to layer cache-state fields onto an
    existing diagnostic block. *)

val projection_diagnostics_json :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** [projection_diagnostics_json ~surface ~started_at ~extra json]
    builds the diagnostic [`Assoc] with [surface] / [build_ms]
    (computed from [started_at]) / [payload_bytes] (computed from
    [json] serialised length) / [generated_at] (current ISO time)
    plus the caller-supplied [extra] fields.  Pure — does not
    mutate any cached surface. *)

val with_projection_diagnostics :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** [with_projection_diagnostics ~surface ~started_at ~extra json]
    is {!projection_diagnostics_json} composed with
    {!attach_projection_diagnostics}: returns [json] with the
    diagnostic block prepended.  The convenience wrapper most
    dashboard handlers use. *)

val initialized_json_opt :
  ?allow_initializing:bool -> Yojson.Safe.t -> Yojson.Safe.t option
(** [initialized_json_opt ?allow_initializing json] returns
    [Some json] when [json] is an [`Assoc] with no
    [status: "initializing"] field (or when
    [allow_initializing = true], even with that field).  Returns
    [None] for non-objects or initializing payloads.

    Used to defer rendering an "initializing" envelope while the
    cache is still warming up.  [allow_initializing] defaults to
    [false] — the safe choice for callers that want to surface
    "no data yet" as a 404 rather than an empty card. *)
