(** Versioned JSON codec for [Keeper_chat_events.keeper_chat_event]
    (RFC-0412 §4.1, stage 1: dual-write only; read paths unchanged).

    Task 1 ships the codec only; the per-operation JSONL journal
    ([journal_path], [open_journal], [append], [read_journal]) arrives with
    the journal writer task. *)

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
