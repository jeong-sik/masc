(** What bearer credentials a workspace holds, for [masc token].

    {!Auth.list_credentials} and {!Auth.delete_credential} have always been
    here; nothing reached them from a command line, so an operator wanting to
    know what tokens exist, or to retire one, edited files under
    [.masc/auth/] by hand. This is the reading and the ordering that command
    needs, kept out of the CLI so it runs under a test without a workspace. *)

type expiry =
  | Never  (** No [expires_at] — minted with [--no-expiry]. *)
  | Valid_until of string  (** Expires, and has not yet. *)
  | Expired_at of string  (** The stamp has passed; the credential authenticates nothing. *)

val classify : now:float -> Types_auth.agent_credential -> expiry
(** An unparseable [expires_at] classifies as {!Valid_until}, not as expired: a
    stamp nothing can read is not evidence a credential is dead, and reading it
    as dead would let a prune delete a working token. *)

val is_expired : expiry -> bool

val row : now:float -> raw_present:bool -> Types_auth.agent_credential -> string
(** One listing line: agent, role, expiry, and whether the raw secret is still
    on disk at [.masc/auth/<agent>.token]. The store keeps only a SHA-256 of
    the token, so that file is the one place the bearer itself survives. *)

val expired : now:float -> Types_auth.agent_credential list -> Types_auth.agent_credential list
(** The credentials a prune may delete. Only expired ones: removing a
    credential that already authenticates nothing is garbage collection, not a
    security decision, so it needs no confirmation of its own. *)

val ordered : now:float -> Types_auth.agent_credential list -> Types_auth.agent_credential list
(** Expired first, then by agent name — the set an operator is looking for, and
    the same order on every run. *)
