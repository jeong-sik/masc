
(** Dashboard_tool_source_freshness — source-freshness metadata
    helpers for the dashboard tool-quality panel.

    Each "source" is a JSONL store under
    [<MASC_BASE_PATH>/.masc/<store-name>/]. The dashboard's
    tool-quality panel renders a freshness card per source with:
    fresh-rate ([latest_age_s] vs [freshness_slo_s]),
    entry count, last-seen timestamp, and any active coverage
    gaps surfaced through {!Telemetry_coverage_gap}.

    Internal helper [numeric_ts_field] (which extracts a unix
    timestamp from [`Float] / [`Int] JSON shapes) is hidden —
    callers consume the higher-level
    {!latest_ts_of_record} / {!freshness_fields} /
    {!health_fields} composition layer instead. *)

val latest_ts_of_record : Yojson.Safe.t -> float option
(** Extract the most recent timestamp from a JSON record,
    trying [ts_unix] / [ts] / [timestamp] (numeric) first and
    [ts_iso] (ISO-8601) as a fallback via
    [Masc_domain.parse_iso8601_opt]. Returns [None] for non-object
    JSON, missing fields, and unparseable ISO strings. *)

val freshness_fields :
  now:float ->
  float option ->
  (string * Yojson.Safe.t) list
(** Render the [(latest_ts_unix, latest_ts_iso, latest_age_s)]
    triplet for the freshness card.

    When [latest_ts] is [Some ts], the three fields are populated
    with the unix timestamp, the ISO-8601 string, and
    [max 0.0 (now -. ts)] respectively. When [None], all three
    fields render as [`Null] so dashboard consumers can
    distinguish "missing" from "deliberately blank". *)

val health_fields :
  now:float ->
  exists:bool ->
  entry_count:int ->
  latest_ts:float option ->
  freshness_slo_s:float ->
  ?coverage_gap:Yojson.Safe.t ->
  unit ->
  (string * Yojson.Safe.t) list
(** Compute the [(health, stale_reason)] pair for a source card.

    Decision order:
    - [coverage_gap = Some _] → [health = "coverage_gap"],
      [stale_reason] read from the gap's [stale_reason] field.
    - [exists = false] → [(missing, store_missing)]
    - [entry_count = 0] → [(empty, no_entries)]
    - [latest_ts = None] → [(empty, no_entries)]
    - [latest_age_s > freshness_slo_s] →
      [(stale, freshness_slo_exceeded)]
    - otherwise → [(ok, "")]

    The empty-string [stale_reason] for healthy sources renders
    as [`Null] (Null-vs-missing pattern preserved per cycle 69). *)

val active_coverage_gaps :
  latest_ts:float option -> Yojson.Safe.t list -> Yojson.Safe.t list
(** Filter coverage gaps down to the entries still active for the
    current source timestamp. *)

val keeper_tool_call_io_fields :
  dashboard_surface:string ->
  unit ->
  (string * Yojson.Safe.t) list
(** Convenience wrapper around [metadata_fields] for the keeper
    tool-call I/O source:
    - [source_name = "tool_call_io"]
    - [source_producer = "keeper_hooks_agent_core|mcp_server_eio_call_tool"]
    - [freshness_slo_s = 300.0] (5 minutes)
    - [durable_store] resolved via
      [Keeper_tool_call_log.store_dir] (defaulting to ["" ] when
      the store is unavailable)
    - [latest_record] from [Keeper_tool_call_log.read_latest].

    The producer string uses ["|"] as an OR-separator because
    two different code paths persist into the same store; the
    UI displays it verbatim so the operator can grep either
    side. *)
