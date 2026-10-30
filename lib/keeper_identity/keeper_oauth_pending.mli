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
    login nobody finishes keeps only non-secret terminal metadata after the next lookup
    expires it, and no fiber exists to wake up and find nothing. *)

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

type admission
(** Where one start request stands among the starts this table has admitted.
    Taken when the request arrives, before discovery or registration, so two
    starts for one Keeper and provider keep the order they were asked in even
    when the earlier one's network calls finish last. The order is per
    Keeper and provider: a start for another scope neither outranks nor is
    outranked by this one. *)

val admit : t -> keeper:string -> provider_id:string -> admission

type stale_start =
  | Newer_start_admitted
      (** A start for the same Keeper and provider was admitted after this
          one and is already held. Its operator was shown that start's
          consent URL, so this earlier one must not replace it. *)

val remember :
  t -> admission -> now:float -> ttl_sec:float -> in_flight -> (string, stale_start) result
(** Hold an exchange until [now + ttl_sec]. Keyed by the pending's own state,
    which is what the callback will carry back. Returns an independent non-secret
    attempt id for authenticated completion observation.

    The held exchange supersedes any earlier consent still waiting for the
    same Keeper and provider. It is refused instead when a later-admitted
    start for that scope is already held. *)

val take : t -> now:float -> state:string -> in_flight option
(** Look up an exchange by the state a callback echoed, and atomically admit its callback, removing the verifier.

    Removed, not read: a state is redeemed once. A second callback carrying
    the same state finds nothing, which is what a replayed callback should
    find. An entry past its expiry is also nothing, and becomes [Expired] on the way
    past. *)

val waiting : t -> now:float -> int
(** How many exchanges are still inside their window. For an operator screen
    that wants to say a login is in progress; expired entries do not count
    even if they have not been walked past yet. *)

(** A non-secret handle, generated independently from callback state. *)
type completion = Tools_discovered of int | Credentials_published_discovery_failed
type status = Awaiting_consent of float | Callback_admitted
  | Completed of completion | Failed | Expired | Superseded
val status : t -> now:float -> attempt_id:string -> keeper:string -> provider_id:string -> status option
(** [None] means unavailable in this process/scope, never inferred expiry. *)
val while_admitted : t -> state:string -> (unit -> 'a) -> 'a option
(** Run [f] only while the exchange echoed as [state] is still an admitted
    callback, and keep the table locked for the whole of [f]: a newer start
    for the same scope cannot supersede it until [f] returns, so a publication
    that reaches its writes is never overtaken by a later attempt's writes.
    [None] means the exchange was superseded (or never admitted) and [f] did
    not run. [f] must be short and must not call back into this table; it is
    for the credential writes, not for network discovery. *)

val finish : t -> state:string -> (completion, unit) result -> unit
(** Only admitted callbacks can become terminal. Replay cannot replace a result. *)
