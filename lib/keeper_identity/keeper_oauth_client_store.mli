(** The client id a provider handed back, kept so the next login reuses it.

    {!Keeper_oauth_session.start} registers a client when nobody configured
    one. Registering is cheap, but doing it every login leaves a client
    record behind each time on a server this install does not administer,
    and none of them can be cleaned up from here. So the first one is
    written down.

    Not a secret: this is a public client, the id travels in a browser URL
    on every login, and there is no secret beside it. Kept next to the
    workspace rather than in a Keeper's secret projection for the same
    reason -- and because one masc install has one client, whichever Keeper
    happens to log in first. *)

val load :
  dir:string -> provider:Keeper_oauth_provider.t -> (string option, string) result
(** Read the stored id, if this install has one. [Ok None] means no login has
    registered yet; an [Error] means the directory answered in a way that
    reading again would answer the same, and is not the same as having none
    -- registering over it would strand whatever is there. *)

val save :
  dir:string ->
  provider:Keeper_oauth_provider.t ->
  client_id:string ->
  (unit, string) result
(** Write the id a registration just produced. Replaces what is there:
    [start] only registers when nothing was loaded, so arriving here with an
    existing file means that read failed or the file appeared during the
    login, and the id in hand is the one the pending exchange was built
    with. *)
