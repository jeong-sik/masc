(** Mention_inbox — JSONL-based persistent mention inbox

    Stores @mention events in `.masc/mention_inbox.jsonl`.
    Each mention is an append-only record with read/unread tracking.

    @since Phase 3A — Keeper Deliberation Engine
*)

(** A single mention record persisted to JSONL. *)
type mention_record = {
  id: string;              (** Unique ID: "m-" prefix + timestamp + random *)
  target_agent: string;    (** Who was mentioned *)
  source_agent: string;    (** Who mentioned them *)
  source_kind: string;     (** "room_message" | "board_post" | "board_comment" *)
  source_id: string;       (** room_id or post_id *)
  content_preview: string; (** First ~200 chars of the content *)
  created_at: float;       (** Unix timestamp *)
  read_at: float;          (** 0.0 = unread, otherwise Unix timestamp when read *)
}

val generate_mention_id : unit -> string
(** Generate a unique mention ID with "m-" prefix. *)

val mention_record_to_json : mention_record -> Yojson.Safe.t
(** Serialize a mention record to JSON. *)

val mention_record_of_json : Yojson.Safe.t -> mention_record option
(** Deserialize a mention record from JSON. Returns None on parse failure. *)

val inbox_path : Coord.config -> string
(** Returns the path to `.masc/mention_inbox.jsonl`. *)

val append_mention : ?task_id:string -> Coord.config -> mention_record -> unit
(** Append a mention record to the JSONL file.

    If [~task_id] is provided and the backlog reports the task as terminal
    (Done / Cancelled), the append is skipped and a [cache_desync.cleared]
    event is logged instead (fleet-wide invariant, issue #13397). *)

val read_mentions : Coord.config -> target_agent:string -> limit:int -> mention_record list
(** Read mentions for a target agent, newest first, up to [limit] items. *)

val unread_count : Coord.config -> target_agent:string -> int
(** Count unread mentions (where read_at = 0.0) for a target agent. *)

val mark_read : Coord.config -> mention_id:string -> unit
(** Set read_at to current time for the given mention ID. *)
