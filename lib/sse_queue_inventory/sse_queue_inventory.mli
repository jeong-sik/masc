(** An incremental view of SSE client queues. A session name is reusable;
    its client id identifies the particular registration that owns a change. *)

type kind = Observer | Agent_stream | Presence

type entry = {
  session_id : string;
  client_id : int;
  kind : kind;
  queue_depth : int;
  last_event_id : int;
  last_seen_at : float;
}

type t

val empty : t

val register :
  t -> session_id:string -> client_id:int -> kind:kind -> last_event_id:int ->
  last_seen_at:float -> t
(** Install an empty queue, replacing the prior owner of this session name. *)

val remove : t -> session_id:string -> client_id:int -> t
(** Remove only the specified registration. *)

val observe :
  t -> session_id:string -> client_id:int -> queue_depth:int ->
  last_event_id:int -> last_seen_at:float -> t
(** Replace one current registration's reading. A retired registration cannot
    change its successor. [queue_depth] must be nonnegative. *)

val count : t -> int
val count_kind : t -> kind -> int
val total_queue_depth : t -> int
val max_queue_depth : t -> int
val hot : limit:int -> t -> entry list
(** Nonempty queues ordered by depth descending, last-seen time ascending,
    and session name ascending. Obtaining a fixed number does not walk the
    complete client registry. *)
