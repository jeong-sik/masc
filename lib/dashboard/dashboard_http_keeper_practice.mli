(** Per-keeper autonomous practice summary over the decision-log tail.

    Folds the tailed [keepers/<name>.decisions.jsonl] turn rows (written by
    {!Keeper_unified_metrics_decision.append_decision_record}) into window
    counts that answer "does this Keeper practice its role, or only wake":
    turn-mode mix, outcome mix, terminal-code histogram, wake-trigger
    histogram, and tool-use histogram for autonomous turns.

    Read-only observability: counts only, no flow control. Unknown wire
    labels are never defaulted into a known bucket (constitution
    [strict_parse_no_default]); unparseable turn rows land in
    [unrecognized_turn_rows] so a writer change shows up as a number
    instead of silently reshaping the known buckets. *)

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
(** Strict parse of the writer label. [None] for anything else, including
    the empty string; callers count [None] as unrecognized, never as success. *)

type summary
(** One keeper's folded window. Opaque: readers consume {!to_json}. *)

val summarize_rows : keeper_name:string -> Yojson.Safe.t list -> summary
(** Pure fold over already-parsed decision-log rows. Rows whose [event]
    member is not exactly ["turn"] are expected log siblings (tool_exec,
    memory_search, ...) and are skipped without counting. A ["turn"] row
    whose [execution_path] or [outcome] member does not strictly parse
    counts as unrecognized. A turn row without a parseable [turn_mode]
    counts as mode-absent (error turns normally carry no mode). *)

val summarize_keeper :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  ?limit:int ->
  unit ->
  summary
(** Tail this keeper's decision log (bounded like the K2 feed) and fold it.
    [limit] clamps to the K2 feed bound. A missing or unreadable log folds
    to the zero summary, never an exception. *)

val to_json : summary -> Yojson.Safe.t
(** [schema = "keeper.practice.v1"]. Fixed objects for the closed mode and
    outcome buckets; open label lists (sorted by count desc, label asc)
    for terminal codes, triggers, and tool names. *)

val fleet_json :
  Workspace.config ->
  Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** One [to_json] per keeper plus [window_minutes]-style envelope fields
    ([limit], [generated_at]); mirrors [keeper_decisions_json]. *)
