(** CanPlayMachine-only observation. The bearer stays in the Authorization
    header. Subscribe precedes the initial invalidation; every reconnection
    sends a new initial invalidation, so readers need no durable replay cursor.
    Only public machine/seat/room invalidations leave this route. A supplied
    room client owns an exact presence lease, renewed by transport keepalive,
    never after departure, revocation or expiry. MSX time uses the existing
    server spectator and ends with the connection. Seat authority is refreshed
    at relevant credential expiry boundaries and Keeper lifecycle changes,
    including when no machine frame changes. *)
val path : string

type change = Snapshot | Machine | Seats | Room | Keeper of string
val change_of_payload : machine:Machine_lane.t -> Yojson.Safe.t -> change option
(** Decode typed workspace dataset and Keeper lifecycle notifications relevant to Play.
    Machine observations belong to the selected machine; room changes are
    shared. A Keeper hint carries only the same identity visible in the public
    Play roster, so unrelated fleet activity cannot retire holder authority.
    Unrelated/private event payloads are never forwarded. *)
val frame : change -> string
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val next_seat_expiry :
    now:float -> Masc_domain.agent_credential list ->
    float option
  (** The first instant at which a currently live seat credential becomes
      expired, using the same whole-second boundary as bearer admission.
      Worker credentials and malformed expiry values do not supply a deadline.
      Excluding a malformed deadline does not grant a seat or change bearer
      admission; one damaged credential cannot retire unrelated observers. *)

  val observe_seat_expiry : base_path:string -> (float option, unit) result
  (** Read the actual credential transaction used by the stream's deadline
      worker. An unreadable credential store remains [Error ()]; a malformed
      expiry on one readable credential does not fail the store observation. *)
end
