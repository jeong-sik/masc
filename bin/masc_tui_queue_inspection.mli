(** One explicit snapshot of the server inbox; never a claim of delivery. *)
type action = Inspect | Pause | Resume | Clear | Cancel of string | Move_to_end of string | Run_next of string | Edit of string * string
  | Cancel_event of string * int64 * string
  | Prioritize_event of string * int64 * Keeper_event_queue.urgency
  | Inspect_peers of unit ref * string option
(** [Inspect_peers] is an explicit roster read; its token binds the result to
    the reader that requested it. It performs no queue mutation. *)

type peer_relation = {
  operation_id : string;
  sender : string;
  recipient : string;
  reply_to : string option;
}
type peer_snapshot = { queued_count : int; relations : peer_relation list }
type peer_page = { snapshot : peer_snapshot; next_sequence : string option }

val peer_snapshot : keeper_name:string -> Yojson.Safe.t -> (peer_snapshot, string) result
(** One page for the exact recipient. Only the durable,
    registered [sender_keeper] establishes a Keeper-to-Keeper edge; a
    submitter's spelling alone is not identity. Running and completed work
    are outside this observation. Repeated operation IDs are rejected. *)
val read_peer_page :
  keeper_name:string -> after_sequence:string option ->
  read_page:(unit -> (Yojson.Safe.t, string) result) -> (peer_page, string) result
(** One server page, validated against its requested sequence. A nonempty
    page offers another read. An empty page says no rows followed that
    boundary in this read; it does not identify the store generation. *)
val peer_lines : page_number:int -> peer_page -> string list
val parse : string -> (action, string) result
type item_id =
  | Local_message of string | Server_message of string | Running_message of string
  | Event of string * int64 | Schedule of string * string
type item = { id : item_id option; text : string }
type observation = {
  waiting : (item list, string) result;
  operations : (item list, string) result;
  peer_page : peer_page option;
}
(** A failed source is distinct from an observed empty source. An event ID
    addresses one exact pending incarnation; a grouped row exposes members
    only when all of their exact addresses are available and distinct. *)
val waiting_items : now:float -> Yojson.Safe.t -> (item list, string) result
val operation_items : Yojson.Safe.t -> (item list, string) result
val edited_input : message:string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
val next_sequence : Yojson.Safe.t -> (string option, string) result
