(** One public game conversation per workspace, shared by MSX/DOS viewers,
    invited players, operators and Keepers. No private transcript is read.
    SQLite calls run off the Eio scheduler. Messages survive process restarts. *)
type speaker = Keeper | Participant
type message = {
  id : int; at : float; who : string; speaker : speaker;
  machine : Machine_lane.t; text : string;
}
type member = { name : string; speaker : speaker; machine : Machine_lane.t; seen_at : float }
type snapshot = { messages : message list; members : member list; has_more : bool }
type error = Invalid_request of string | Conflict of string | Unavailable of string
type action

val history_page_size : int
val presence_seconds : float
val parse_action : Yojson.Safe.t -> (action, error) result
(** Strict object: action=[join|read|say|leave], client_id, machine=[msx|dos].
    [say] also requires message_id and text (1..4096 UTF-8 bytes).
    [read] accepts a positive [before] message id for older history.
    Read/join/say renew this client's presence for [presence_seconds]. *)
val perform : base_path:string -> who:string -> speaker:speaker -> now:float ->
  action -> (snapshot, error) result
(** Identity comes from the authenticated request/tool principal, never the body.
    An identical (actor, client_id, message_id) retry returns the existing
    message; reusing the id with different contents conflicts without a write. *)
val read : base_path:string -> now:float -> before:int option -> (snapshot, error) result
(** Read only; does not renew presence. [None] reads the most recent page. *)
val snapshot_json : snapshot -> Yojson.Safe.t
val snapshot_of_json : Yojson.Safe.t -> (snapshot, string) result
(** Decode an HTTP snapshot without treating malformed/unavailable data as an empty room. *)
val error_message : error -> string
