(** Sealed frame protocol for collab rooms (RFC-0471 §2.3–2.5).

    Frames travel as JSON sealed with the room key ({!Collab_seal}) inside
    {!Collab_envelope} envelopes. Guest to host: [Hello], [Prompt], [Abort],
    [Fetch_transcript]. Host to guest: [Welcome], [Snapshot_chunk], [Entry],
    [Live_state], [Transcript], [Bye], [Error_frame]. Later stacks extend
    this variant (ui-request, agent registry); decode stays strict. *)

type hello = {
  proto : int;
  write_token : string option;
      (** Base64url (unpadded) write token on a control link, [None] on a
          view link. Shape only; the host decides validity. *)
  label : string option;
      (** Guest display name, carriage only: the host trims it, drops
          overlong ones, and otherwise stamps it on the guest's prompts
          as the speaker name. *)
}

type header = {
  keeper : string;
  operation : string;
}

type live_state = {
  active : bool;
  guests : int;
}

type welcome = {
  proto : int;
  header : header;
  state : live_state;
  entry_count : int;
  read_only : bool;
}

type snapshot_chunk = {
  entries : Yojson.Safe.t list;
  final : bool;
}

type entry = {
  seq : int;  (** Room-relative sequence, 1 and up. Never reused. *)
  op : string;  (** The keeper operation that published it (sanitized). *)
  op_seq : int;  (** The operation journal sequence, for snapshot overlap. *)
  ts : float;  (** Bus publish time (Unix epoch seconds). *)
  event : Yojson.Safe.t;  (** Opaque [keeper_chat_event] JSON. *)
}
(** Live entries join the snapshot stream by [(op, op_seq)]: the host sends
    unfiltered broadcasts, and guests drop live entries their snapshot
    already holds. *)

type fetch_transcript = {
  req_id : int;
  max_bytes : int;
}

type transcript = {
  req_id : int;
  text : string;
  new_size : int;
  error : string option;
}

type frame =
  | Hello of hello
  | Welcome of welcome
  | Snapshot_chunk of snapshot_chunk
  | Entry of entry
  | Live_state of live_state
  | Prompt of string
  | Abort
  | Fetch_transcript of fetch_transcript
  | Transcript of transcript
  | Bye of string
  | Error_frame of string

val frame_to_json : frame -> Yojson.Safe.t
(** Tagged-object encoding: [{"t": <kebab-case tag>, ...payload}]. Entry
    payloads ([event], chunk [entries]) pass through untouched. *)

val frame_to_string : frame -> string
(** {!frame_to_json} serialized. *)

val frame_of_json : Yojson.Safe.t -> frame option
(** Strict inverse of {!frame_to_json}: [None] on an unknown [t], a missing
    or mistyped field, or a negative int where only non-negative is valid.
    [proto] takes any int (a mismatch is reported, not a decode failure).
    Unknown extra fields are ignored. *)

val frame_of_string : string -> frame option
(** [None] on malformed JSON as well as on [!frame_of_json] refusals. *)
