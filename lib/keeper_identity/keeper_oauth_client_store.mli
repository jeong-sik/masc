(** The client id a provider handed back, kept so the next login reuses it.

    {!Keeper_oauth_session.start} registers a client when nobody configured
    one. Registering is cheap, but doing it every login leaves a client
    record behind each time on a server this install does not administer,
    and none of them can be cleaned up from here. So the first one is
    written down.

    Kept next to the workspace rather than in a Keeper's secret projection,
    because one masc install has one client per
    {!Keeper_oauth_provider.client_group}, whichever Keeper happens to log in
    first. Providers behind the same authorization server share a group, so
    one Google app answers for all eight of its resources.

    The id is not a secret -- it travels in a browser URL on every login. A
    secret sometimes comes with it: registration asks for a public client and
    some servers answer with one anyway, meaning their token endpoint will
    refuse a redemption without it. That one is written 0600 beside the id
    and is never rendered. *)

type credentials = {
  client_id : string;
  client_secret : string option;
      (** [None] is a public client, which is what most providers answer
          with. It is not "unknown": the id is written after the secret, so
          an id on disk means whatever secret came with it is already
          beside it. *)
}

val load :
  dir:string ->
  provider:Keeper_oauth_provider.t ->
  (credentials option, string) result
(** Read what this install registered, if it registered. [Ok None] means no
    login has; an [Error] means the directory answered in a way that reading
    again would answer the same, and is not the same as having none --
    registering over it would strand whatever is there. *)

val save :
  dir:string ->
  provider:Keeper_oauth_provider.t ->
  credentials ->
  (unit, string) result
(** Write what a registration just produced. Replaces what is there:
    [start] only registers when nothing was loaded, so arriving here with an
    existing file means that read failed or the file appeared during the
    login, and the credentials in hand are the ones the pending exchange was
    built with.

    The secret is written before the id, so a failure between them leaves no
    id and the next login registers again -- rather than leaving an id whose
    secret never arrived, which fails at the token endpoint with nothing here
    saying why. *)
