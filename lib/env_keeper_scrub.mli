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

val filter_environment_c_messages : string array -> string array
(** Like {!filter_environment}, but pins system messages to the C locale:
    drops any host [LC_ALL] / [LC_MESSAGES] and appends [LC_ALL=] (empty,
    treated by POSIX as unset) and [LC_MESSAGES=C]. Character encoding
    ([LC_CTYPE] / [LANG]) is left to the host. Use for subprocesses whose
    textual output MASC classifies — e.g. the EINTR retry marker in
    [Keeper_turn_sandbox_runtime] depends on [strerror] being English. *)
