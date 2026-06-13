(** Keeper subprocess env scrub / pass policy (RFC-0007 PR-1 / #9639 Cluster B).

    Default-deny (allowlist) model: only explicitly permitted env vars cross
    the keeper subprocess boundary. New secrets are blocked by default.
    Operators can extend the allowlist via [MASC_KEEPER_ALLOW_EXTRA].

    Keeper GitHub execution must use the selected MASC credential bundle,
    never the operator's ambient GitHub token/config or SSH agent. *)

val is_allowed : string -> bool
(** [is_allowed key] returns [true] if the given env-var key is on the
    allowlist (exact or prefix match) and is not blocked by a credential
    suffix or a secret-bearing prefix such as [MASC_ADMIN_]. *)

val filter_environment : string array -> string array
(** Return a copy of the given [Unix.environment]-shaped array with only
    allowed keys retained. Entries that do not contain ['='] are kept iff
    their key is allowed. *)
