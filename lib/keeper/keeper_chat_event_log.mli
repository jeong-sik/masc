(** Versioned JSON codec and per-operation JSONL journal for
    [Keeper_chat_events.keeper_chat_event] (RFC-0412 §4.1, stage 1:
    dual-write only; read paths unchanged; the journal is fail-open — a
    journal failure must never break the live turn). *)

(** One journaled event: the bus-assigned sequence number, the publish-time
    timestamp (Unix epoch seconds), and the event itself. *)
type journaled_event =
  { seq : int  (** 0-based, monotonically increasing within one operation. *)
  ; ts : float
  ; event : Keeper_chat_events.keeper_chat_event
  }

val codec_version : int
(** Current envelope version. Written as ["v"]; decode rejects any other. *)

val keeper_chat_event_to_json : Keeper_chat_events.keeper_chat_event -> Yojson.Safe.t
(** Tagged-object encoding: [{"type": <snake_case tag>, ...payload}]. *)

val keeper_chat_event_of_json :
  Yojson.Safe.t -> (Keeper_chat_events.keeper_chat_event, string) result
(** Strict inverse of {!keeper_chat_event_to_json}. Unknown tags are an
    [Error]. *)

val journaled_event_to_json : journaled_event -> Yojson.Safe.t
val journaled_event_of_json : Yojson.Safe.t -> (journaled_event, string) result

val journaled_event_to_string : journaled_event -> string
(** Single journal line payload (no trailing newline). *)

val journaled_event_of_string : string -> (journaled_event, string) result
(** Strict decode of one journal line. [Yojson.Json_error] is caught and
    returned as [Error]. *)

(** {1 Journal} *)

type journal
(** An open per-operation journal: a resolved path plus the clock. *)

val journal_path :
  base_dir:string -> keeper_name:string -> operation_id:string -> string
(** [<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl], with both
    segments passed through
    [Workspace_utils_backend_setup.sanitize_namespace_segment] (the
    [Keeper_chat_store.sanitize_name] precedent); [operation_id] is
    client-derived, so it is sanitized too. *)

val open_journal :
  ?now:(unit -> float) ->
  base_dir:string ->
  keeper_name:string ->
  operation_id:string ->
  unit ->
  journal
(** Resolves the path and creates the parent directory. Fail-open: directory
    creation failure is logged, not raised. [now] defaults to
    [Time_compat.now] and is injectable for deterministic tests. *)

val append : journal -> seq:int -> Keeper_chat_events.keeper_chat_event -> unit
(** Synchronously appends one envelope line (fsync + truncate-rollback via
    [Fs_compat.append_private_jsonl_durable_locked_result]). Fail-open: every
    failure is logged via [Log.Keeper.error] and swallowed — including raw
    [Unix.Unix_error]s the transaction layer does not convert into its result
    type — so journaling never breaks the live turn. A non-finite float
    ([ts], [cost_usd], [duration_sec]) would emit invalid JSON, so such an
    event is logged and skipped instead of appended. Only
    [Eio.Cancel.Cancelled] propagates. *)

val read_journal : journal -> journaled_event list
(** Reads and strictly decodes every line. Raises [Invalid_argument] on a
    corrupt line and [Sys_error] if the journal file does not exist. Test
    support in stage 1. *)
