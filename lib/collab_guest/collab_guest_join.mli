(** Guest join core for collab rooms (RFC-0471 stack 6).

    Pure: link/relay resolution and the welcome/snapshot/live assembly
    the host's protocol demands — live entries may arrive before their
    welcome, and the snapshot overlaps them, so guests buffer
    pre-barrier entries and join them against the snapshot by
    [(op, op_seq)], dropping both sides' duplicates. Transport lives in
    {!Collab_guest_session}; rendering lives in the join UI. *)

(** {1 Resolution} *)

type target = {
  room_id : string;  (** Raw 16 bytes. *)
  key : Collab_seal.key;
  capability : Collab_link.capability;
  write_token : string option;
      (** Raw 16 bytes iff [capability = Control], else [None]. *)
  ws_secure : bool;
  ws_host : string;
  ws_port : int;
}

type resolve_error =
  | Bad_link of string
  | Bad_relay of string
  | Relay_missing
      (** A terminal link names no relay; [--relay] was not given. *)

val resolve_error_to_string : resolve_error -> string

val resolve : link:string -> relay:string option -> (target, resolve_error) result
(** [resolve ~link ~relay] reads a terminal link or a web link (the
    fragment after the last ['#']) plus the relay to dial: [relay] wins
    when given, else the web link's base. Relay origins admit
    [http/https/ws/wss] and map to ws(s); default ports are 80/443. *)

val resource : target -> string
(** [/r/<b64url-room>?role=guest]. *)

(** {1 Assembly} *)

type event =
  | Snapshot_row of Yojson.Safe.t
  | Live_entry of Collab_frame.entry
  | State of Collab_frame.live_state
  | Transcript of Collab_frame.transcript
  | Bye of string
  | Error_frame of string

type t

val create : unit -> t

val feed : t -> Collab_frame.frame -> event list
(** [feed join frame] folds one host frame into join events. Entries
    arriving before the snapshot completes buffer; when the final chunk
    lands, buffered entries join the snapshot by [(op, op_seq)] and
    only the unseen ones emit. A second welcome updates state without
    resetting the join. Guest-bound frames (hello, prompt, abort,
    fetch) never come from the host and are ignored. *)
