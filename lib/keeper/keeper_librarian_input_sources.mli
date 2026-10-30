(** Durable inputs a Librarian pass reads from disk: counterpart evidence for
    the range-based consumer and the Goal context of a task. *)

type read_error =
  | Chat_store_unreadable of Keeper_chat_store.strict_decode_error
  | External_attention_unreadable of Keeper_external_attention.read_error
  | External_cursor_failed of string

val read_error_to_string : read_error -> string

(** Immutable data from the same strict chat/external reads. Captures the raw
    selected chat rows before delivery deduplication and the complete original
    external log, including out-of-range identities used to deduplicate chat.
    This observation grants no acknowledgement or dispatch authority. *)
type counterpart_snapshot
val capture_counterparts : external_after:int -> base_dir:string -> keeper_name:string ->
  after:float option -> before:float -> (counterpart_snapshot, read_error) result
val counterpart_observations : counterpart_snapshot -> Keeper_counterpart_observation.t list
val external_through : counterpart_snapshot -> int
val counterpart_snapshot_matches_selection : counterpart_snapshot -> external_after:int ->
  after:float option -> before:float -> bool
val counterpart_snapshot_to_json : counterpart_snapshot -> Yojson.Safe.t
val counterpart_snapshot_of_json : Yojson.Safe.t -> (counterpart_snapshot, string) result
val snapshot_extends : original:counterpart_snapshot -> current:counterpart_snapshot -> (unit, string) result
val validate_original_selection : counterpart_snapshot -> base_dir:string -> keeper_name:string ->
  (unit, read_error) result
(** Compare the original complete external log and selected raw chat rows as
    ordered prefixes under the same original interval/offset. Later appends do
    not extend the original frontier or recompute its dedup/projection. The
    caller holds the actual source serialization through publication; this read
    alone does not establish a source lock or any commit/ACK authority. *)
(** Strict, complete data codec. Does not reread current stores. *)

(** Complete counterpart evidence after [after] through [before], inclusive of
    [before]. [after = None] means
    that the selected range starts with this trace's current atom history.
    Both append-only stores are read fail-closed: a cursor must not advance
    over a bounded tail or an unreadable row. *)
val counterpart_observations_between
  :  base_dir:string
  -> keeper_name:string
  -> after:float option
  -> before:float
  -> (Keeper_counterpart_observation.t list, read_error) result

val counterpart_observations_between_offloaded
  :  base_dir:string
  -> keeper_name:string
  -> after:float option
  -> before:float
  -> (Keeper_counterpart_observation.t list, read_error) result

(** The Goal criteria linked to [task], read from the authoritative
    goal-task link index and the Goal store. [None] is [No_task]. A task with
    no linked Goal is [Task_goals] with [Ok []]; an unreadable index, an
    unreadable store, or a link naming a missing Goal is [Task_goals] with
    [Error], so a read failure never looks like a goalless task. Reads disk;
    a caller on the main domain offloads it. *)
val goal_context_for_task
  :  config:Workspace.config
  -> Keeper_id.Task_id.t option
  -> Keeper_librarian.goal_context

val counterpart_observations_from : external_after:int -> base_dir:string -> keeper_name:string ->
  after:float option -> before:float -> (Keeper_counterpart_observation.t list * int, read_error) result
(** External rows follow durable append order from [external_after] and stop
    at the first row admitted after [before]; chat rows retain their existing
    turn-time interval. Both are interleaved by time without reordering the
    external rows. The returned count is the external snapshot boundary. *)
