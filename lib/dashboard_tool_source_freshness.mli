open Base

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
    [Types.parse_iso8601_opt]. Returns [None] for non-object
    JSON, missing fields, and unparseable ISO strings. *)

val count_source_entries : string -> int
(** Count entries in the [Dated_jsonl] store rooted at [dir].
    Returns 0 when [dir] does not exist; [Eio.Cancel.Cancelled]
    is propagated, any other exception during entry counting is
    logged at [Log.Dashboard.warn] and the count falls back to
    0 so a partial filesystem failure cannot blank the
    dashboard panel. *)

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

val coverage_gaps_for_store :
  source_name:string ->
  durable_store:string ->
  Yojson.Safe.t list
(** Read the most recent 50 telemetry coverage-gap entries
    (via {!Telemetry_coverage_gap.read_recent}) under
    [<dirname durable_store>] and filter them down to entries
    whose [source] field equals [source_name]. Returns the
    empty list when [durable_store] is empty. *)

val metadata_fields :
  source_name:string ->
  source_producer:string ->
  dashboard_surface:string ->
  freshness_slo_s:float ->
  durable_store:string ->
  latest_record:Yojson.Safe.t option ->
  unit ->
  (string * Yojson.Safe.t) list
(** Compose the full metadata block for a single source card:
    9 identity / count fields ([source] / [producer] /
    [durable_store] / [dashboard_surface] / [freshness_slo_s] /
    [entry_count] / [exists] / [coverage_gaps] /
    [coverage_gap_count]), then the {!freshness_fields} triplet,
    then the {!health_fields} pair.

    [now] is captured once at the start of the call so the
    freshness and health computations use the same reference
    timestamp; a future "let's parameterise [now]" refactor must
    extend this contract explicitly. *)

val keeper_tool_call_io_fields :
  dashboard_surface:string ->
  unit ->
  (string * Yojson.Safe.t) list
(** Preset wrapper around {!metadata_fields} for the keeper
    tool-call I/O source:
    - [source_name = "tool_call_io"]
    - [source_producer = "keeper_hooks_oas|mcp_server_eio_call_tool"]
    - [freshness_slo_s = 300.0] (5 minutes)
    - [durable_store] resolved via
      [Keeper_tool_call_log.store_dir] (defaulting to ["" ] when
      the store is unavailable)
    - [latest_record] from [Keeper_tool_call_log.read_latest].

    The producer string uses ["|"] as an OR-separator because
    two different code paths persist into the same store; the
    UI displays it verbatim so the operator can grep either
    side. *)
