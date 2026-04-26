(** P12 — Network egress policy for Docker sandbox execution.

    Pure module: domain allowlist loading, matching, and structured
    error generation.  No Docker or keeper internals. *)

(** An egress policy: a set of allowed domains plus source provenance. *)
type t

(** Policy with no allowed domains.  [check_command] blocks commands with
    extracted outbound domains and allows commands without extracted domains. *)
val empty : t

(** Build a policy from an explicit domain list. *)
val of_allowed : source:string -> string list -> t

(** Check whether a single domain is permitted.

    Matching rules:
    - Exact match (case-insensitive)
    - Wildcard prefix ["*.x.com"] matches ["sub.x.com"] and ["x.com"] *)
val domain_allowed : t -> string -> bool

(** Extract host names from URLs appearing in a command string. *)
val extract_domains_from_command : string -> string list

type check_result =
  | Allowed
  | Blocked of
      { attempted : string
      ; allowed : string list
      }

(** Check a command against the policy.

    Returns [Allowed] if no domains are extracted or all extracted domains
    are permitted.  Returns [Blocked] with the first non-permitted domain
    and the full allowlist otherwise. *)
val check_command : t -> string -> check_result

(** Format a check result as JSON.
    [Allowed] → [{"ok": true}].
    [Blocked] → structured error with [attempted] and [allowed]. *)
val blocked_to_json : check_result -> string

(** Parse a JSON domain array.  Returns [empty] on parse error.
    [empty] is fail-closed for commands with extracted outbound domains. *)
val of_json_string : source:string -> string -> t

(** Load from a JSON file.  Returns [empty] if missing or unreadable.
    [empty] is fail-closed for commands with extracted outbound domains. *)
val of_file : string -> t

(** Return the list of allowed domains for inspection. *)
val to_allowed_domains : t -> string list
