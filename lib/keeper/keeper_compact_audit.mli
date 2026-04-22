(** Compaction audit: Event_bus subscriber + paired JSONL persistence +
    rolling retention.

    Subscribes to OAS {!Oas.Event_bus} for [ContextCompactStarted]
    and [ContextCompacted] payloads, synthesizes a stable [compaction_id]
    correlating start/complete pairs per keeper, and appends each event
    to [{base_path}/data/harness-compact/YYYY-MM/DD.jsonl].

    Retention: on each write the oldest files beyond
    [retention_days] (default 14, override via
    [MASC_COMPACTION_AUDIT_RETENTION_DAYS]) are deleted. Self-healing,
    no external cron. The CLI [bin/masc_compaction_audit] can also
    trigger prune manually.

    {1 Design notes}

    - Start/Complete pairing uses subscriber-local state
      ([Hashtbl] keyed by keeper/agent name) — OAS event_bus does not
      carry a compaction-scoped correlation id.
    - Loose string fields from OAS payload ([trigger], [phase_hint])
      are parsed into variants with [Unknown] fallback. Unknown tags
      are preserved, not rejected, so forward compat with OAS is
      automatic.
    - Legacy reader: [Dashboard_harness_health] previously wrote to
      [{base_path}/data/harness-pre-compact/*.jsonl]; that path is
      read as a fallback so existing dashboards keep working during
      the transition. New writes go only to the new path. *)

(** {1 Types} *)

type trigger =
  | Proactive          (** OAS string ["proactive"] *)
  | Emergency          (** OAS string ["emergency"] *)
  | Operator           (** OAS string ["operator"] *)
  | Unknown_trigger of string

val parse_trigger : string -> trigger

val trigger_to_string : trigger -> string

type start_record = {
  compaction_id : string;   (** Synthesized: ulid-like per-start *)
  ts_unix : float;
  keeper_name : string;
  trigger : trigger;
  correlation_id : string;  (** From OAS envelope *)
  run_id : string;          (** From OAS envelope *)
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

(** Read events from both the new [harness-compact/] path and the
    legacy [harness-pre-compact/] path (Start rows only, since the
    legacy format had no post event). Results merged and sorted by
    [ts_unix] ascending. *)
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
    (** Should be rare — indicates subscriber missed the Start event
        (e.g. server restart mid-compaction). *)

(** Pair Start and Complete rows by [compaction_id]. *)
val pair_events : row list -> pair_result list

(** {1 Subscriber wireup} *)

(** Spawn a background Eio fiber bound to [sw] that subscribes to
    [bus], converts compaction events into records, and persists them.
    Fiber is cancelled on switch release; subscription is unsubscribed.

    [drain_interval_s] controls the poll period (default 0.25s,
    matching [docs/spec/13-oas-integration.md] §322). *)
val spawn_subscriber
  :  sw:Eio.Switch.t
  -> clock:[> float Eio.Time.clock_ty ] Eio.Std.r
  -> base_path:string
  -> retention_days:int
  -> ?drain_interval_s:float
  -> Oas.Event_bus.t
  -> unit
