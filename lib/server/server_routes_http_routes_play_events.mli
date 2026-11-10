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

type change = Snapshot | Machine | Seats | Room
val change_of_payload : machine:Machine_lane.t -> Yojson.Safe.t -> change option
(** Decode typed workspace dataset and Keeper lifecycle notifications relevant to Play.
    Machine observations belong to the selected machine; room changes are
    shared. Unrelated/private event payloads are never forwarded. *)
val frame : change -> string
val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val next_seat_expiry :
    now:float -> Masc_domain.agent_credential list ->
    (float option, Masc_domain.Credential_expiry.error) result
  (** The first instant at which a currently live seat credential becomes
      expired, using the same whole-second boundary as bearer admission.
      Worker credentials do not form Play seats. *)
end
