(** Secret_patterns — structural secret masking shared by every sink.

    Pattern-based replacement of secret-shaped values with [\[REDACTED\]].
    This is masking only: patterns never classify, route, or gate behavior.
    Extracted from [Observability_redact] (which delegates here) so leaf
    sinks such as [masc_log] can mask without a dependency cycle. Exact
    secret *values* loaded from keeper secret roots are handled separately
    by [Keeper_secret_redaction]. *)

val redact_text : string -> string
(** Replace known secret-shaped substrings (URL credentials, [Bearer]
    values, HTTP Authorization fields, sensitive-key assignments, [sk-]/[AKIA]
    keys, GitHub tokens, PEM private-key blocks)
    with [\[REDACTED\]]. Never truncates or trims. *)

val is_sensitive_key : string -> bool
(** Case-insensitive exact match against the sensitive JSON key list
    (token, api_key, password, secret_key, access_key, ...). A key that
    matches here has its whole value masked, whatever the value's shape. *)

val key_suggests_secret : string -> bool
(** Case-insensitive fragment match: [true] when the key name contains a
    secret-bearing fragment (secret, token, passwd, credential, apikey,
    ...). A fallback for spellings the exact list never enumerated
    ([session_token], [api_secret], ...). Reference-shaped keys
    ([*_env] naming an environment variable, [*_type] naming a value
    kind) answer [false] so safe metadata stays readable. Callers mask
    every string in the subtree under such a key while non-string
    scalars keep their shape, so counts and flags survive while no
    secret-shaped string passes in clear. *)

val redact_json_strings : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively apply {!redact_text} to string leaves and to object keys,
    and replace the value of a sensitive key (judged on the key as it came)
    with [\[REDACTED\]], preserving structure and without truncation. Two
    keys that redact to the same text are both kept, in order. *)
