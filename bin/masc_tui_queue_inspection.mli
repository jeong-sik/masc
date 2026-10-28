(** One explicit snapshot of the server inbox; never a claim of delivery. *)
type action = Inspect | Pause | Resume | Clear | Cancel of string | Move_to_end of string | Edit of string * string
  | Cancel_event of string * int64 * string
  | Prioritize_event of string * int64 * Keeper_event_queue.urgency
  | Inspect_peers of unit ref
(** [Inspect_peers] is an explicit roster read; its token binds the result to
    the reader that requested it. It performs no queue mutation. *)

type peer_relation = {
  operation_id : string;
  sender : string;
  recipient : string;
  reply_to : string option;
}
type peer_snapshot = { queued_count : int; relations : peer_relation list }

val peer_snapshot : keeper_name:string -> Yojson.Safe.t -> (peer_snapshot, string) result
(** The exact recipient's first queued operation page. Only the durable,
    registered [sender_keeper] establishes a Keeper-to-Keeper edge; a
    submitter's spelling alone is not identity. Running and completed work
    are outside this observation. Repeated operation IDs are rejected. *)
val read_peer_page :
  keeper_name:string -> read_page:(unit -> (Yojson.Safe.t, string) result) ->
  (peer_snapshot, string) result
(** Ask for one server page; there may be additional queued operations. *)
val peer_lines : peer_snapshot -> string list
val parse : string -> (action, string) result
val waiting_lines : now:float -> Yojson.Safe.t -> (string list, string) result
val operation_lines : Yojson.Safe.t -> (string list, string) result
val edited_input : message:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
val next_sequence : Yojson.Safe.t -> (string option, string) result
