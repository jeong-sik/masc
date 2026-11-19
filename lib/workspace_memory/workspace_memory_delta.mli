(** Keeper-facing world memory delta feed over {!Workspace_memory_log} and
    {!Workspace_memory_reader}.

    Provides locked, crash-safe per-Keeper cursor planning, progressive
    [Full -> Half -> Reference_only] context-overflow bisection, formatted
    delta blocks for prompt injection, and durable cursor acknowledgement. *)

type delivery_granularity =
  | Full
      (** Complete unseen committed entries including structured payload. *)
  | Half
      (** Bisected prefix of unseen committed entries with compact summary
          lines (omitting payload) after context-overflow narrowing. *)
  | Reference_only
      (** Single-entry reference pointer carrying [{ "entry": seq }] when a
          single full entry overflows context. *)

val granularity_to_string : delivery_granularity -> string

type pending_feed =
  { state : Workspace_memory_reader.reader_state
  ; entries : Workspace_memory_log.change_entry list
  ; granularity : delivery_granularity
  ; formatted_block : string
  ; last_committed_seq : Workspace_memory_log.seq
  }

val format_entries :
  granularity:delivery_granularity ->
  Workspace_memory_log.change_entry list ->
  string
(** Render [entries] according to [granularity]. Empty [entries] renders [""]. *)

val read_pending_for_keeper :
  base_path:string ->
  keeper_name:string ->
  ?max_entries:int ->
  unit ->
  (pending_feed, string) result
(** Read pending committed world-memory entries after [keeper_name]'s persisted
    cursor under {!File_lock_eio.with_lock}. When unseen entries are planned
    for delivery, the pending slice is persisted atomically before returning so
    crash recovery or transient failures re-deliver the exact same slice. A
    malformed persisted reader state or corrupt log fails closed as [Error]. *)

val record_turn_outcome :
  base_path:string ->
  keeper_name:string ->
  Workspace_memory_reader.turn_outcome ->
  (Workspace_memory_reader.reader_state, string) result
(** Apply a turn outcome ([Turn_succeeded], [Turn_failed_transient], or
    [Context_overflow] bisection) under {!File_lock_eio.with_lock} and persist
    the updated reader state atomically. *)

val acknowledge_cursor :
  base_path:string ->
  keeper_name:string ->
  ?to_seq:Workspace_memory_log.seq ->
  unit ->
  (Workspace_memory_reader.reader_state, string) result
(** Advance and persist [keeper_name]'s acknowledged cursor under
    {!File_lock_eio.with_lock}. When [to_seq] is omitted, acknowledges the
    currently planned pending delivery (idempotent when nothing is pending).
    When [to_seq] is supplied, validates [acknowledged_seq <= to_seq <=
    last_committed_seq] before persisting. *)

val read_entry_by_seq :
  base_path:string ->
  seq:Workspace_memory_log.seq ->
  (Workspace_memory_log.change_entry option, string) result
(** Look up a single committed change entry by [seq] (for resolving a
    [Reference_only] notice). Returns [Ok None] when no committed entry has
    [seq]. *)
