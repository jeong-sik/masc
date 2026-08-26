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

val declarations_json : base_path:string -> Yojson.Safe.t
(** Every provider declared under [config/identity/], as a screen would list
    them: [{id, label}] for one that reads, [{id, problem}] for one that does
    not. A declaration nobody can read is listed with what is wrong with it,
    because the alternative is an operator seeing a shorter list and no
    reason the provider they came for is missing. *)

val set_client :
  base_path:string ->
  provider_id:string ->
  client_id:string ->
  client_secret:string option ->
  scopes:string ->
      (** Space-separated, and empty to ask for whatever the resource
          publishes. An app an operator brought is the authority on what it
          may be granted: asking for a scope it does not declare is refused,
          and adding that scope means reinstalling an app other people may
          depend on. *)
  (Yojson.Safe.t, string) result
(** Record an app an operator made themselves.

    For a provider whose authorization server offers no registration
    endpoint there is no other way in: Slack, GitHub and Figma all publish
    one client per app and expect the operator to have made it. {!start}
    already prefers what is on file over registering, so this is the road in.

    One per provider for this install rather than one per Keeper, matching
    where a registered client is kept.

    The answer says whether a secret is on file and never what it is. It does
    say the scopes, which are not a credential and are the thing an operator
    most needs to check. *)

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
  tool_discovery : (int, string) result;
      (** How many tools the provider named, or why asking did not work.

          Asked right here, because an operator who just consented wants to
          know whether it took, and a first tool call is a slow way to find
          out. A failure does not undo the attachment: the credentials are
          written either way, and {!refresh_tools} can be asked again. *)
}

val refresh_tools :
  base_path:string ->
  keeper:string ->
  provider_id:string ->
  now:float ->
  (Yojson.Safe.t, string) result
(** Ask an attached provider what tools it has, and write the answer down.

    Done when a Keeper attaches, and whenever an operator asks. Not on a
    timer: a stale catalog is visible and fixable, while a timer is a
    network call nobody asked for. *)

val attached_tools_json : base_path:string -> keeper:string -> Yojson.Safe.t
(** What every declared provider currently offers this Keeper, as a screen
    would list it: when it was found out, and the tool names. A provider this
    Keeper never attached to is listed as such rather than left out, because
    "not attached" and "attached with no tools" are different things to
    whoever is looking. *)

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
