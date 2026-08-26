(** Attaching one Keeper to one work service, from a keypress to credentials
    the Keeper's next turn can read.

    Two requests with a browser between them. The first says which Keeper and
    which provider and hands back a URL; the operator consents there; the
    provider sends the browser to the second, which redeems the code and
    writes what came back into that Keeper's secret projection.

    This is where the layering turns over. {!Keeper_oauth_session} knows an
    exchange and refuses to know that Keepers have secret directories; this
    module knows both, because it is the part of masc that owns the
    workspace. *)

val callback_path : string
(** The path every provider sends the browser back to. One path for all of
    them: which login a callback belongs to is the state it echoes, and a
    state is unguessable and redeemable once. *)

val declarations_json : unit -> Yojson.Safe.t
(** Every provider declared under [config/identity/], as a screen would list
    them: [{id, label}] for one that reads, [{id, problem}] for one that does
    not. A declaration nobody can read is listed with what is wrong with it,
    because the alternative is an operator seeing a shorter list and no
    reason the provider they came for is missing. *)

val start :
  base_path:string ->
  keeper:string ->
  provider_id:string ->
  now:float ->
  (Yojson.Safe.t, string) result
(** Begin a login. Finds the declaration, asks the provider's server where
    its authorization lives, registers a client if this install has none, and
    returns the URL to open along with the state that identifies this login.

    Nothing is written to the Keeper yet -- an operator who closes the browser
    leaves no trace beyond a registered client, and that is reused. *)

type attached = {
  keeper : string;
  provider_id : string;
  provider_label : string;
  expires_at : float;
}

val finish :
  base_path:string ->
  state:string ->
  code:string ->
  now:float ->
  (attached, string) result
(** Redeem the code the browser carried and write the result into the
    Keeper's own secret scope: the access token and its expiry as env
    entries, the refresh token as a file entry, each at the name the
    declaration gives.

    Returns what an operator needs to read on the page they land on. Not the
    tokens: the browser that arrives here belongs to whoever followed the
    redirect, and the point of the exchange is that the credential goes to
    the Keeper rather than through a screen. *)
