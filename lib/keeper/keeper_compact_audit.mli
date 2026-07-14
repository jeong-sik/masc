(** MASC compaction audit: paired JSONL persistence + rolling retention.

    MASC compaction owners persist explicit start/complete records to
    [{base_path}/data/harness-compact/YYYY-MM/DD.jsonl].

    Retention: on each write the oldest files beyond
    [retention_days] (default 14, override via
    [MASC_COMPACTION_AUDIT_RETENTION_DAYS]) are deleted. Self-healing,
    no external cron. The CLI [bin/masc_compaction_audit] can also
    trigger prune manually.

    {1 Design notes}

    - Start/Complete rows carry an explicit [compaction_id].
    - Loose persisted trigger strings are preserved through [Unknown_trigger].
    - Reads and writes use only the paired audit store. Historical
      [harness-pre-compact/] rows are not projected into this API. *)

(** {1 Types} *)

type trigger =
  | Proactive          (** MASC proactive compaction *)
  | Emergency          (** MASC typed-overflow recovery *)
  | Operator           (** Explicit operator request *)
  | Unknown_trigger of string

val parse_trigger : string -> trigger

val trigger_to_string : trigger -> string

type start_record = {
  compaction_id : string;   (** Synthesized: ulid-like per-start *)
  ts_unix : float;
  keeper_name : string;
  trigger : trigger;
  correlation_id : string;  (** Supplied by the MASC compaction owner *)
  run_id : string;          (** Supplied by the MASC compaction owner *)
}

type complete_record = {
  compaction_id : string;   (** Same as paired start; empty if orphan *)
  ts_unix : float;
  keeper_name : string;
  before_tokens : int;
  after_tokens : int;
  tokens_freed : int;       (** before_tokens - after_tokens, clamped >= 0 *)
  phase_hint : string;      (** OAS raw phase string, e.g. ["proactive(85%)"] *)
  correlation_id : string;
  run_id : string;
}

type write_error =
  | Io_failure        of string
  | Serialize_failure of string

(** {1 Write API} *)

(** Append a start record as a JSONL line. Triggers rolling retention
    via [prune_older_than ~retention_days] after successful append. *)
val persist_start
  :  base_path:string
  -> retention_days:int
  -> start_record
  -> (unit, write_error) result

(** Append a complete record as a JSONL line. Triggers rolling retention
    via [prune_older_than ~retention_days] after successful append. *)
val persist_complete
  :  base_path:string
  -> retention_days:int
  -> complete_record
  -> (unit, write_error) result

(** {1 Retention} *)

(** Accepted retention-day bounds for
    [MASC_COMPACTION_AUDIT_RETENTION_DAYS] and manual prune arguments. *)
val retention_min_days : int
val retention_max_days : int

(** Resolve [MASC_COMPACTION_AUDIT_RETENTION_DAYS] without side effects,
    returning the typed outcome. Reads from process env at call time. *)
val resolve_retention_outcome
  :  default:int
  -> Keeper_compact_audit_retention_outcome.t

(** Extract the effective day count from a retention resolution outcome. *)
val effective_days_of_outcome
  :  Keeper_compact_audit_retention_outcome.t
  -> int

(** Delete [.jsonl] day-files in [{base_path}/data/harness-compact/]
    whose date is older than [retention_days] days ago. Thin wrapper
    over {!Dated_jsonl.prune}; returns the count of files deleted. *)
val prune_older_than
  :  base_path:string
  -> retention_days:int
  -> int

(** {1 Read API} *)

type row =
  | Start    of start_record
  | Complete of complete_record

(** Read events from the [harness-compact/] paired audit path. Results
    are sorted by [ts_unix] ascending. *)
val read_events
  :  base_path:string
  -> since:float
  -> until:float
  -> ?keeper:string
  -> unit
  -> (row list, write_error) result

type pair_result =
  | Paired          of { start : start_record; complete : complete_record }
  | Orphan_start    of start_record
  | Orphan_complete of complete_record
    (** Indicates that the MASC compaction owner persisted only completion. *)

(** Pair Start and Complete rows by [compaction_id]. *)
val pair_events : row list -> pair_result list

(** Test-only retention resolver. *)
module For_testing : sig
  (** Resolve [MASC_COMPACTION_AUDIT_RETENTION_DAYS] without side effects,
      returning the typed outcome. Reads from process env at call time. *)
  val resolve_retention_outcome
    :  default:int
    -> Keeper_compact_audit_retention_outcome.t
end
