(** Keeper_efficiency — one month of per-Keeper turn and tool totals.

    The TUI Keepers view answers "what did each Keeper do for the turns it
    consumed" from these numbers: tool calls per turn, tool seconds per turn,
    output tokens per turn, failure share, and the same values as the
    run-weighted fleet row for comparison.

    Inputs are the two durable ledgers that already exist — the cost ledger
    ([Cost_ledger], [.masc/costs/]) and the Keeper tool-call ledger
    ([.masc/tool_calls/], written by [Keeper_tool_call_log]). This module
    only reads them; no write path changes. Counts are:

    - [turns]: distinct [(agent, keeper_turn_id)] pairs named by any cost
      ledger row of the day, whatever its projection. A turn id that two
      different days both record counts twice; the spend ledger writes one
      row per turn, so that needs a restart mid-turn.
    - token and cost sums: rows whose projection is [Resolved_delta] or
      [Resolved_attempt_delta] — the rows the ledger contract says add up.
      Raw observations ([per_request], [turn_total],
      [conversation_cumulative]) repeat spend and are not summed.
    - [calls]/[failed]/[deferred]/[tool_ms]: [record_kind = tool_call] rows,
      by their typed disposition when one is recorded.

    Per-day results and per-file read boundaries are cached under
    [<masc_root>/keeper-efficiency/YYYY-MM.json] following the RFC-0162
    boundary-cache shape: a closed day file is never re-read and the growing
    current-day file only reads bytes appended since the last call, so a
    call is O(appended bytes) with no staleness window. The cache is a
    rebuildable projection of the ledgers: a corrupt, missing or
    schema-mismatched cache is recomputed from the files, and a day file
    that shrank below its cached boundary (rewrite) is re-read from zero for
    that day alone.

    @since 0.67.0 — task-2944 *)

type keeper_month = {
  keeper : string;
  turns : int;
  input_tokens : int;
  output_tokens : int;
  cost_usd : float;
  calls : int;
  failed : int;
  deferred : int;
  tool_ms : float;
}
(** Month totals for one Keeper. [input_tokens] is the resolved spend's
    reported input total (cache-inclusive, as the runtime reported it);
    [cost_usd] is 0 for lanes that do not report money. *)

type fleet = {
  turns_total : int;
  calls_per_turn : float;
  tool_s_per_turn : float;
  output_tokens_per_turn : float;
  input_tokens_per_turn : float;
  cost_usd_per_turn : float;
}
(** Run-weighted fleet row: totals divided by the fleet's total turns. *)

type month_view = {
  month : string;  (** ["YYYY-MM"], as requested. *)
  generated_at : float;  (** Unix time of the aggregation that answered. *)
  days_covered : int;  (** Days of the month with at least one row. *)
  keepers : keeper_month list;  (** Sorted by keeper name. *)
  fleet : fleet;
}

val read_month : masc_root:string -> month:string -> (month_view, string) result
(** Aggregate the requested month, reusing and updating the boundary cache.
    An invalid month string is an [Error]. A missing ledger is an empty
    month, not an error: the view then carries zero totals. *)

val month_view_to_json : month_view -> Yojson.Safe.t
(** The wire/cache projection of a month view. The response schema is
    ["masc.keeper-efficiency/v1"]; the TUI decoder consumes the same shape. *)

val cache_path : masc_root:string -> month:string -> (string, string) result
(** Where the month's boundary cache lives. Exposed for tooling that wants
    to inspect or precompute it; [read_month] needs no help from it. *)
