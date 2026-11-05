(** Redaction of the userinfo of a URL-shaped string.

    Userinfo is the [user] or [user:password] before the last [@] of the
    authority. [redact] replaces it so the value can be logged, printed or
    passed to a child process without the credential. *)

val redact : string -> string
(** [redact value] replaces the userinfo of [value] with [[REDACTED]] and
    returns every other byte unchanged. [value] can be an absolute URL
    ([http://user:pw@host/p]), a protocol-relative one ([//user@host/p]) or
    a bare authority ([user:pw@host:8080]).

    The authority ends at the first [/], [?] or [#]. When it holds more than
    one [@], the last one separates userinfo from host, so a password with a
    raw [@] is redacted whole. A value without [@] in its authority is
    returned as is, even when its path or query holds [@] or [://]. *)

val redact_text : string -> string
(** [redact_text text] replaces the userinfo of every [scheme://userinfo@host]
    in [text] with [[REDACTED]] and returns every other byte unchanged. Use it
    for text that holds URLs among other words, such as a command line or a log
    line. {!redact} is for a value that is one URL.

    Each [://] opens an authority. The authority ends at the first [/], [?],
    [#] or ASCII whitespace, and its last [@] separates userinfo from host. A
    [://] whose authority has no [@] is left as it is, and so is a bare
    authority without a scheme ([user:pw@host]). *)
