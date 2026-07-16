(** Closed-enum classification of [Masc_domain.t] for auth-related logging
    and otel_metric_store metric labels. See [auth_error_kind.ml] for the
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

(** Stable string label used in otel_metric_store metric dimensions and log lines.
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
    rejects the request-actor hint when the bearer token cannot be
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
    public reads remain available on token churn, but rejected credentials
    project to the unparameterized namespace instead of adopting the request
    hint. This surface provides the typed rejection reason.

    Reference: ~/Downloads/MASC Reverse Engineering Design Map.html
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
          callsite rejected, captured for the log line. *)

(** Full record of a single dashboard actor fallback event. *)
type dashboard_actor_fallback =
  { outcome : dashboard_actor_fallback_outcome
  ; token_hash_prefix : string
        (** First 8 hex chars of SHA-256(bearer_token) — see
            [server_auth.ml:281-291] for the security rationale. *)
  }

(** Render the warn-log message for a rejected credential event. The
    historical [silent:dashboard_actor_fallback] event key remains stable for
    existing log queries, while the message explicitly states that the actor
    hint was ignored. *)
val dashboard_actor_fallback_log_message : dashboard_actor_fallback -> string

(** Otel_metric_store counter labels for a fallback event. Always includes the
    [outcome] dimension; the [Outcome_error] case additionally carries
    the [err_kind] dimension. *)
val dashboard_actor_fallback_metric_labels :
  dashboard_actor_fallback -> (string * string) list
