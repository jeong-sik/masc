(** P12 — Network egress policy for Docker sandbox execution.

    Pure module: domain allowlist loading, matching, and structured
    error generation.  No Docker or keeper internals. *)

type t
(** An egress policy: a set of allowed domains plus source provenance. *)

val empty : t
(** Policy with no allowed domains.  [check_command] returns [Allowed]
    for all commands (no restriction applied). *)

val of_allowed : source:string -> string list -> t
(** Build a policy from an explicit domain list. *)

val domain_allowed : t -> string -> bool
(** Check whether a single domain is permitted.

    Matching rules:
    - Exact match (case-insensitive)
    - Wildcard prefix ["*.x.com"] matches ["sub.x.com"] and ["x.com"] *)

val extract_domains_from_command : string -> string list
(** Extract host names from URLs appearing in a command string. *)

type check_result =
  | Allowed
  | Blocked of { attempted : string; allowed : string list }

val check_command : t -> string -> check_result
(** Check a command against the policy.

    Returns [Allowed] if the policy has no domains or all extracted
    domains are permitted.  Returns [Blocked] with the first
    non-permitted domain and the full allowlist otherwise. *)

val blocked_to_json : check_result -> string
(** Format a check result as JSON.
    [Allowed] → [{"ok": true}].
    [Blocked] → structured error with [attempted] and [allowed]. *)

val of_json_string : source:string -> string -> t
(** Parse a JSON domain array.  Returns [empty] on parse error. *)

val of_file : string -> t
(** Load from a JSON file.  Returns [empty] if missing or unreadable. *)

val to_allowed_domains : t -> string list
(** Return the list of allowed domains for inspection. *)
