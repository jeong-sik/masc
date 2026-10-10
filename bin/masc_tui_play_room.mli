(** Public spectator conversation state. One in-flight operation owns its
    receipt; drafts and retry ids survive leaving/reopening the spectator. *)
type t
type request
type intent = Repaint | Send
val create : unit -> t
val focused : t -> bool
val focus : t -> bool -> t
val active : t -> bool -> t
val suspend : t -> t
(** Retire responses after workspace authority withdrawal, preserving this
    workspace's draft, unknown-send receipt and possible presence. Once the
    same workspace is confirmed, an inactive view must still issue Leave. *)
val is_read : request -> bool
(** A [Read] observes the room; [Say] and [Leave] change it and own their
    receipts. *)
val retire_read : t -> t
(** Release a pending [Read] whose reply will be discarded because the
    workspace reading that issued it was retired; the next poll reads again.
    A pending [Say] or [Leave] keeps its receipt. *)
val key : t -> string -> t * intent
val paste : t -> string -> t
(** [now] is monotonic elapsed seconds, from the same clock as [receive]. *)
val poll : t -> now:float -> machine:Masc.Machine_lane.t -> t * request option
(** An inactive view retries an unconfirmed leave at the normal polling cadence
    until a successful response confirms that presence has been removed. *)
val send : t -> machine:Masc.Machine_lane.t -> t * request option
(** A new send transfers the composer to a separate pending receipt and clears
    the composer for the next message. An unconfirmed send keeps its client,
    id, machine and text even
    after the composer changes. The next send retries that payload first;
    its acknowledgment preserves the edited draft for a subsequent send.
    Transport/refusal details are not typed at this boundary, so [Error]
    remains uncertain and cannot discard the receipt. *)
val request_json : request -> Yojson.Safe.t
val receive : ?viewer:string -> t -> request -> now:float -> (Masc.Play_room.snapshot, string) result -> t
(** [viewer] is the authenticated response principal, committed only with a
    successful response owned by this request. It identifies local messages. *)
val layout : t -> width:int -> height:int -> t * string list
(** Pure layout and its normalized navigation state. Commit the returned state
    only after the terminal write succeeds. PgUp/PgDn use these actual row
    bounds; history is anchored by message id and wrapped line, so appended
    messages do not move the reader. An anchor removed from the snapshot
    clamps to the first remaining message at or after it. *)
val footer : t -> string
