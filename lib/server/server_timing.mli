(** RFC 8673 Server-Timing header builder for dashboard endpoints.

    Each request handler creates a fresh [t], wraps measured phases with
    {!measure}, and threads the resulting [(string * string) list] from
    {!extra_header} into the existing [~extra_headers] argument of
    [Http_server_eio.Response.json].  Browser DevTools (Network tab ->
    Timing -> Server Timing) renders the bars directly; curl shows them
    via [-D -].

    The aim is *attribution* — turning "the request took 30s" into
    "cache=12ms compute=850ms json=2ms" without a separate APM stack.

    Phase names are a closed variant so a new phase requires a compile-
    time edit of {!phase_token}; magic strings would let typos through
    and DevTools silently drops malformed entries. *)

(** Concrete phases used across dashboard endpoints.

    Add a constructor here (and update {!phase_token}) when a new
    measurement site is introduced.  Use {!Custom} sparingly for one-
    off ad-hoc measurements (e.g. exploratory profiling) — its body is
    sanitised to token characters per RFC 8673 §3.2.1, so invalid input
    is dropped to ['_']. *)
type phase =
  | Cache_lookup
  | Cache_compute
  | Projection_status
  | Projection_agents
  | Projection_tasks
  | Projection_keepers
  | Projection_configured_keepers
  | Projection_config_resolution
  | Projection_runtime_resolution
  | Project_snapshot_shell_refresh
  | Project_snapshot_runtime
  | Tools_compute
  | Telemetry_query
  | Telemetry_filter
  | Telemetry_summary_per_keeper
  | Telemetry_summary_aggregate
  | Health_build_identity (** Request-local [Build_identity.current]. *)
  | Health_paths (** Request-local base-path diagnostics. *)
  | Health_internal_auth (** Internal credential readiness JSON. *)
  | Health_dashboard_surface (** Dashboard artifact health JSON. *)
  | Health_response
      (** Entire request health JSON builder, overlapping its child phases;
          excludes JSON serialization and background full-health refresh. *)
  | Json_serialize
  | Mcp_http_auth (** HTTP credential admission, before reading the body. *)
  | Mcp_identity (** Canonical actor and internal Keeper verification. *)
  | Mcp_dispatch (** Protocol handler elapsed time; excludes response serialization. *)
  | Custom of string

val phase_token : phase -> string
(** Lowercase RFC 8673 token-safe identifier.  Total. *)

type t
(** Mutable accumulator.  Single-fiber by design — see top-level note.
    Callers should not share a [t] across fibers. *)

val create : unit -> t

val measure : t -> phase -> (unit -> 'a) -> 'a
(** [measure t phase f] runs [f ()], accumulates the elapsed
    monotonic duration under [phase], and returns [f]'s result.  If
    [f] raises, the elapsed time is still recorded and the exception
    re-raised (so failure paths are still attributed). Durations include
    suspension and rescheduling time; nested phases overlap their parents. *)

val record_ms : t -> phase -> float -> unit
(** Manually record [ms] under [phase].  Use when a measurement is
    produced by a callback or pre-existing instrumentation that
    already returned an elapsed value. *)

val to_header_value : t -> string
(** RFC 8673 [Server-Timing] field value, comma-separated.  Returns
    [""] if no phases were recorded. Durations are milliseconds with
    three fractional digits. *)

val extra_header : t -> (string * string) list
(** [\[("server-timing", v)\]] when non-empty, otherwise [\[\]].
    The lowercase name is valid on both H1 and H2. Use directly with
    [Http.Response.json ~extra_headers]. *)
