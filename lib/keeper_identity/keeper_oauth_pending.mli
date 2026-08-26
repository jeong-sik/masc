(** The exchanges waiting for their operator to come back from the browser.

    Between {!Keeper_oauth_flow.begin_authorization} and the callback there is
    a verifier that has to survive, and nothing else does: the provider
    returns a code, and only the verifier proves that code belongs to the
    request that asked for it.

    In memory, on purpose. A verifier is the one secret in this flow that is
    supposed to be short-lived, and writing it to disk would keep it past the
    minute it is useful for. A server restart during a login loses that
    login, which is the correct outcome -- the operator starts again, and a
    code arriving with no verifier to match it could not have been proven to
    belong to anyone.

    There is no sweeper. Expiry is checked when a state is looked up, so a
    login nobody finishes costs one entry until the next lookup walks past
    it, and no fiber exists to wake up and find nothing. *)

type in_flight = {
  pending : Keeper_oauth_flow.pending;
  discovered : Keeper_oauth_discovery.t;
      (** What the server answered when this exchange started. Kept rather
          than asked again: the callback has to redeem at the same token
          endpoint the authorize call was built from, and a server that
          moved between the two would otherwise be redeemed at the new one
          with a code minted by the old. *)
  client_id : string;
  client_secret : string option;
      (** Held with the exchange rather than looked up again at the
          callback: what redeems this code is what registered for it. *)
      (** Which client asked. Kept for the same reason -- the redemption has
          to name the client the code was issued to. *)
}

type t

val create : unit -> t

val remember : t -> now:float -> ttl_sec:float -> in_flight -> unit
(** Hold an exchange until [now + ttl_sec]. Keyed by the pending's own state,
    which is what the callback will carry back. *)

val take : t -> now:float -> state:string -> in_flight option
(** Look up an exchange by the state a callback echoed, and remove it.

    Removed, not read: a state is redeemed once. A second callback carrying
    the same state finds nothing, which is what a replayed callback should
    find. An entry past its expiry is also nothing, and is dropped on the way
    past. *)

val waiting : t -> now:float -> int
(** How many exchanges are still inside their window. For an operator screen
    that wants to say a login is in progress; expired entries do not count
    even if they have not been walked past yet. *)
