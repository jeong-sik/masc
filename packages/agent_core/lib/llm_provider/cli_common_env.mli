(** Minimal environment lookup helpers for provider bootstrap boundaries.

    Runtime behavior is configured through typed records. This module only
    centralizes the few conventional provider/discovery lookups that must read
    process state and exposes an injected reader for deterministic callers and
    tests. It does not define numeric, boolean, retry, budget, or feature-gate
    environment policy.

    @since 0.159.0 *)

val default_getenv : string -> string option

(** [get ?getenv name] returns [Some v] if [name] is set to a non-empty
    string, [None] otherwise.  Whitespace-only values are treated as unset.
    [?getenv] (default [Sys.getenv_opt]) is a dependency-injection seam
    (RFC-OAS-024 §6 cut 5): the pure core receives a resolved reader from
    boot rather than reading the process environment directly. *)
val get : ?getenv:(string -> string option) -> string -> string option

(** Split on [sep], trim each fragment, discard empty results. *)
val split_on_char_trim : char -> string -> string list

(** [trim_non_empty s] trims [s] and returns [Some trimmed] if non-empty,
    [None] otherwise. *)
val trim_non_empty : string -> string option

(** [trim_non_empty_opt opt] maps [trim_non_empty] over an option. *)
val trim_non_empty_opt : string option -> string option
