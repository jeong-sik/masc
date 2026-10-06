(** Per-keeper autonomous practice summary over the decision-log tail.

    Folds the tailed [keepers/<name>.decisions.jsonl] turn rows (written by
    {!Keeper_unified_metrics_decision.append_decision_record}) into window
    counts that answer "does this Keeper practice its role, or only wake":
    turn-mode mix, outcome mix, terminal-code histogram, wake-trigger
    histogram, and tool-use histogram for autonomous turns.

    Read-only observability: counts only, no flow control. Unknown wire
    labels are never defaulted into a known bucket (constitution
    [strict_parse_no_default]); turn rows that fail the closed parse land
    in [unrecognized_turn_rows], and lines that fail JSON parsing land in
    [malformed_lines], so writer drift and log corruption show up as
    numbers instead of silently reshaping the known buckets. *)

(** Closed turn-outcome vocabulary of the decision log writer:
    [Keeper_unified_turn_success.decision_outcome_to_label] plus the
    ["error"] label [Keeper_unified_turn] writes on failure. *)
type turn_outcome =
  | Success
  | Checkpoint
  | Input_required
  | Error

val turn_outcome_to_string : turn_outcome -> string
val turn_outcome_of_string : string -> turn_outcome option
(** Exact match on the writer label. [None] for anything else, including
    padded or empty strings; callers count [None] as unrecognized, never
    as success. *)

type summary
(** One keeper's folded window. Opaque: readers consume {!to_json}. *)

val summarize_rows : keeper_name:string -> Yojson.Safe.t list -> summary
(** Pure fold over already-parsed decision-log rows. Rows whose [event]
    member is not exactly ["turn"] are expected log siblings (tool_exec,
    memory_search, ...) and are skipped without counting. A ["turn"] row
    whose [execution_path] does not exactly parse counts as
    unrecognized, as does an autonomous row whose [outcome] does not
    exactly parse. A path-known direct row counts on its path even when
    its outcome label drifted: direct outcomes never enter a bucket, so
    no strictness is lost. A recognized autonomous row without a
    parseable [turn_mode] counts as mode-absent (error turns normally
    carry no mode; mode strictness inherits
    {!Turn_mode_codec.turn_mode_of_string}). *)

val summarize_keeper :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?limit:int ->
  unit ->
  summary
(** Tail this keeper's decision log (bounded like the K2 feed: same
    [max_bytes], [max_lines] is [limit] itself rather than the K2 feed's
    doubled stream bound, since a fold keeps no per-event rows) and fold
    it. [limit] clamps to the K2 feed bound. A missing or unreadable log
    folds to the zero summary, never an exception. Lines that fail JSON
    parsing count as [malformed_lines]; [tail_rows] counts parsed rows,
    so tailed lines = [tail_rows] + [malformed_lines]. *)

val to_json : summary -> Yojson.Safe.t
(** [schema = "keeper.practice.v1"]. Fixed objects for the closed mode
    and outcome buckets; open label lists (sorted by count desc, label
    asc) for terminal codes, triggers, and tool names. The window bounds
    ([since_unix]/[until_unix]) cover recognized turns on any path. *)

val fleet_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** One [to_json] per keeper plus the limit/generated_at envelope, like
    [keeper_decisions_json]. *)
