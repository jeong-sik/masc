(** Closed-enum classification of [Masc_domain.t] for auth-related logging
    and prometheus metric labels. See [auth_error_kind.ml] for the
    rationale and migration scope. *)

type t =
  | Token_mismatch
  | Token_expired
  | Unauthorized
  | Forbidden
  | Agent_not_found
  | Io_error
  | Invalid_json
  | Other

(** Stable string label used in prometheus metric dimensions and log lines.
    Round-trips with [of_string]. *)
val to_string : t -> string

(** Inverse of [to_string]. Returns [None] for unrecognised labels rather
    than collapsing to [Other], so callers can detect contract drift. *)
val of_string : string -> t option

(** Map a [Masc_domain.t] value to its label. Constructors not modelled here
    fall through to [Other]; add an explicit arm rather than relying on
    that fallback when introducing a new auth-relevant error. *)
val classify : Masc_domain.t -> t

(** All inhabitants in declaration order. Used by exhaustiveness tests. *)
val all : t list

(** {1 Dashboard actor fallback typed surface}

    The dashboard actor resolution path in [lib/server/server_auth.ml]
    falls back to the request-actor hint when the bearer token cannot be
    mapped to a credential. Two structurally distinct failure modes share
    a single counter ([metric_silent_dashboard_actor_fallback]):

    - [Outcome_none]: token resolution returned [Ok None] (no matching
      credential on file).
    - [Outcome_error]: token resolution raised a classified
      [Masc_domain.t] (the variant carries the typed [t] in the
      [err_kind] field, alongside the request-actor hint and the raw
      error string).

    Previously these two branches were inline at two adjacent call
    sites with hardcoded format strings, so callers had no typed handle
    on *why* the fallback fired — a counter is not a fix
    (see CLAUDE.md §Workaround Rejection Bar §1 Counter-as-Fix). The
    fallback path itself is preserved as a production safety net
    (dashboard cannot go dark on token churn); this surface adds the
    typed kind that downstream reducers need without removing the
    safety net.

    Reference: ~/Downloads/MASC-MCP Reverse Engineering Design Map.html
    §Gap "Auth identity is spread across several layers" + §개선 #2
    (request identity state machine). *)

(** Why the dashboard actor fallback path was taken. *)
type dashboard_actor_fallback_outcome =
  | Outcome_none
      (** Token resolution returned [Ok None]: the bearer token is
          syntactically valid but matches no credential on file. *)
  | Outcome_error of
      { err : Masc_domain.t
      ; err_kind : t
      ; actor_hint : string option
      }
      (** Token resolution raised a classified domain error. [err_kind]
          is the closed-enum classification of [err]; [actor_hint] is
          the request actor hint (header / query param) that the
          callsite is about to fall back to, captured for the log line. *)

(** Full record of a single dashboard actor fallback event. *)
type dashboard_actor_fallback =
  { outcome : dashboard_actor_fallback_outcome
  ; token_hash_prefix : string
        (** First 8 hex chars of SHA-256(bearer_token) — see
            [server_auth.ml:281-291] for the security rationale. *)
  }

(** Render the byte-equivalent warn-log message for a fallback event.
    Used by the consolidated helper at the callsite; the format strings
    match the prior inline [Log.Auth.warn] templates so prometheus log
    queries and alerting rules keyed on the [silent:dashboard_actor_fallback]
    prefix continue to fire unchanged. *)
val dashboard_actor_fallback_log_message : dashboard_actor_fallback -> string

(** Prometheus counter labels for a fallback event. Always includes the
    [outcome] dimension; the [Outcome_error] case additionally carries
    the [err_kind] dimension. *)
val dashboard_actor_fallback_prometheus_labels :
  dashboard_actor_fallback -> (string * string) list
