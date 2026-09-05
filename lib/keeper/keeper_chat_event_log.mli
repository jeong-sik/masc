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

val page_default_limit : int
(** How many lines one read of the journal returns when the reader names no
    count (RFC-0412 §3.2, the v2 events endpoint). *)

val page_max_limit : int
(** The most lines one read may ask for. Defined once, here, for both sides
    of the wire: the endpoint admits [1..page_max_limit], and a client that
    pages at the ceiling reads this same value, so its ask can never exceed
    what the endpoint admits. *)

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

(** {1 Journal} *)

type journal
(** An open per-operation journal: a resolved path. *)

val events_dirname : string
(** The store's directory name under [.masc] — the one literal behind
    {!events_dir}, the audit sweep, and the retention pruner (which walks a
    masc root it already holds). *)

val events_dir : base_dir:string -> string
(** [<base>/.masc/keeper_chat_events]: the root every keeper's journals live
    under, [<events_dir>/<keeper>/<operation_id>.jsonl]. *)

val journal_path :
  base_dir:string -> keeper_name:string -> operation_id:string -> string
(** [<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl], with both
    segments passed through
    [Workspace_utils_backend_setup.sanitize_namespace_segment] (the
    [Keeper_chat_store.sanitize_name] precedent); [operation_id] is
    client-derived, so it is sanitized too. *)

val open_journal :
  base_dir:string -> keeper_name:string -> operation_id:string -> unit -> journal
(** Resolves the path and creates the parent directory. Fail-open: directory
    creation failure is logged, not raised. *)

val append :
  journal -> seq:int -> ts:float -> Keeper_chat_events.keeper_chat_event -> unit
(** Synchronously appends one envelope line (fsync + truncate-rollback via
    [Fs_compat.append_private_jsonl_durable_locked_result]). [seq] and [ts]
    are the bus stamps ({!Keeper_chat_events.published}): the journal never
    reads a clock of its own, so the line and the live projection of the same
    event agree. Installed as the bus hook it is exactly
    [Keeper_chat_events.create ~on_publish:(append journal)]. Fail-open: every
    failure is logged via [Log.Keeper.error] and swallowed — including raw
    [Unix.Unix_error]s the transaction layer does not convert into its result
    type — so journaling never breaks the live turn. A non-finite float
    ([ts], [cost_usd], [duration_sec]) would emit invalid JSON, so such an
    event is logged and skipped instead of appended. Only
    [Eio.Cancel.Cancelled] propagates. *)

(** Why a read of a journal produced no entries. *)
type read_failure =
  | Journal_missing  (** No file at the path: nothing journaled yet, or pruned. *)
  | Journal_unreadable of string
      (** The file exists but could not be opened or read (the exception's
          text). *)
  | Journal_corrupt of string  (** A complete row failed the strict decode. *)

val read_journal_path_result : string -> (journaled_event list, read_failure) result
(** Every complete row of the journal at an already-resolved path, strictly
    decoded, creating nothing on disk — unlike {!open_journal}, which mkdirs
    the parent. The read goes through
    [Fs_compat.read_private_jsonl_rows_locked_result]: it holds the per-path
    mutex and a shared file lock against the exclusive lock {!append} takes,
    so it never observes a write in flight, and it runs in a systhread when
    called from an Eio fiber. The writer's framing rule is applied on the
    way out: a final fragment with no trailing newline is the remains of an
    append that never completed, not a row — it is logged, the complete rows
    before it are returned, and the writer refuses to append after it, so
    those rows are the journal's final content. A bad complete row is
    [Journal_corrupt]. Never raises except [Eio.Cancel.Cancelled]. *)

val read_journal : journal -> (journaled_event list, read_failure) result
(** {!read_journal_path_result} over an open journal's path. *)

(** {1 Replay position} *)

(** Where a client wants a journal read to start: the whole turn, or only the
    entries after the seq it already holds. On the wire ([since_seq] on the
    chat-stream POST body and the v2 events query) the field is absent for
    the whole turn and a non-negative integer otherwise; a negative integer
    is rejected at the boundary. Decoded once there, at the boundary, and
    passed through replay as this type. *)
type replay_position =
  | Whole_turn
  | After_seq of int

val replay_position_of_wire : int option -> replay_position option
(** The request-side spelling: an absent field is [Whole_turn], [n >= 0] is
    [After_seq n], a negative integer is [None]. The only place the wire's
    absence rule is read. *)

val replay_position_to_wire : replay_position -> int option
(** Inverse of {!replay_position_of_wire}: the field to write, or nothing. *)

val replay_position_to_string : replay_position -> string
(** For log lines: ["whole_turn"], or the held seq. *)

val replay_position_to_yojson : replay_position -> Yojson.Safe.t
(** The response-side spelling ([next_since_seq] on the v2 events page): a
    response field cannot be absent the way a request field can, so
    [Whole_turn] is [`Null] and [After_seq n] is [`Int n]. *)

val replay_position_of_yojson : Yojson.Safe.t -> replay_position option
(** Inverse of {!replay_position_to_yojson}, for a client reading a page:
    [`Null] is [Whole_turn], [`Int n] with [n >= 0] is [After_seq n], anything
    else is [None]. *)

val seq_is_after : replay_position -> int -> bool
(** Whether an entry with this seq lies past the position: every seq for
    [Whole_turn], [seq > held] for [After_seq held]. *)

val replay_position_advance : replay_position -> int -> replay_position
(** The position after an entry with this seq was received: [After_seq seq]
    when it lies past the position ({!seq_is_after}), the position unchanged
    otherwise. *)
