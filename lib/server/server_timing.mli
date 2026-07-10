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
  | Json_serialize
  | Custom of string

val phase_token : phase -> string
(** Lowercase RFC 8673 token-safe identifier.  Total. *)

type t
(** Mutable accumulator.  Single-fiber by design — see top-level note.
    Callers should not share a [t] across fibers. *)

val create : unit -> t

val measure : t -> phase -> (unit -> 'a) -> 'a
(** [measure t phase f] runs [f ()], accumulates the elapsed
    wall-clock duration under [phase], and returns [f]'s result.  If
    [f] raises, the elapsed time is still recorded and the exception
    re-raised (so failure paths are still attributed). *)

val record_ms : t -> phase -> float -> unit
(** Manually record [ms] under [phase].  Use when a measurement is
    produced by a callback or pre-existing instrumentation that
    already returned an elapsed value. *)

val to_header_value : t -> string
(** RFC 8673 [Server-Timing] field value, comma-separated.  Returns
    [""] if no phases were recorded. *)

val extra_header : t -> (string * string) list
(** [\[("Server-Timing", v)\]] when non-empty, otherwise [\[\]].
    Use directly with [Http.Response.json ~extra_headers]. *)
