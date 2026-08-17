(** Secret_patterns — structural secret masking shared by every sink.

    Pattern-based replacement of secret-shaped values with [\[REDACTED\]].
    This is masking only: patterns never classify, route, or gate behavior.
    Extracted from [Observability_redact] (which delegates here) so leaf
    sinks such as [masc_log] can mask without a dependency cycle. Exact
    secret *values* loaded from keeper secret roots are handled separately
    by [Keeper_secret_redaction]. *)

val redact_text : string -> string
(** Replace known secret-shaped substrings (URL credentials, [Bearer]
    values, [sk-]/[AKIA] keys, GitHub tokens, PEM private-key blocks)
    with [\[REDACTED\]]. Never truncates or trims. *)

val is_sensitive_key : string -> bool
(** Case-insensitive exact match against the sensitive JSON key list
    (token, api_key, password, ...). *)

val redact_json_strings : Yojson.Safe.t -> Yojson.Safe.t
(** Recursively apply {!redact_text} to string leaves and replace
    sensitive-key fields with [\[REDACTED\]], preserving structure and
    without truncation. *)
