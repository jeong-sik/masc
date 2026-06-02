(** P12 — Network egress policy for Docker sandbox execution.

    Pure module: domain allowlist loading, matching, and structured
    error generation.  No Docker or keeper internals. *)

type t
(** An egress policy: a set of allowed domains plus source provenance. *)

val empty : t
(** Policy with no allowed domains.  [check_command] blocks commands with
    extracted outbound domains and allows commands without extracted domains. *)

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

    Returns [Allowed] if no domains are extracted or all extracted domains
    are permitted.  Returns [Blocked] with the first non-permitted domain
    and the full allowlist otherwise. *)

val blocked_to_json : ?expected_policy_path:string -> check_result -> string
(** Format a check result as JSON.
    [Allowed] → [{"ok": true}].
    [Blocked] → structured error with [attempted] and [allowed].

    When [expected_policy_path] is supplied, the [Blocked] payload also
    carries [expected_policy_path] (so an operator can act on the
    structured error without grepping the codebase) and a humanish
    [reason] string aimed at the LLM caller — distinguishing the
    "allowlist empty / unreadable" failure mode (operator must seed
    the file) from the "domain not in allowlist" failure mode (operator
    must extend the file).  Omitting [expected_policy_path] preserves
    the legacy two-field schema for callers that have no path context. *)

val of_json_string : source:string -> string -> t
(** Parse a JSON domain array.  Returns [empty] on parse error.
    [empty] is fail-closed for commands with extracted outbound domains. *)

val of_file : string -> t
(** Load from a JSON file.  Returns [empty] if missing or unreadable.
    [empty] is fail-closed for commands with extracted outbound domains. *)

val to_allowed_domains : t -> string list
(** Return the list of allowed domains for inspection. *)
