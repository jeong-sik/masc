(** Typed tool dispatch outcome.

    Replaces the [string] outcome label ("handled" / "no_handler") used
    by earlier dispatch wiring with a typed sum so observers, metrics, and
    audit emitters can pattern-match exhaustively on the dispatch result.

    The sum has exactly the two arms the dispatch paths produce.  Earlier
    revisions carried three further arms ([Rejected_by_capability],
    [Rejected_by_pre_hook], [Handler_error]) that never had a producer:
    capability rejection, pre-hook [Reject], and handler exceptions all
    resolve to [Some error] and are classified [Handled].  They were
    removed so the type matches observed behaviour (RFC-0084 §6 D3;
    CLAUDE.md anti-pattern #4). *)

(** Typed sum of dispatch outcomes. *)
type t =
  | Handled
      (** Handler returned a [Tool_result.result] (success or error) and
          produced a result.  The result rides in the separate
          [Tool_result.result option] argument observers receive. *)
  | No_handler
      (** [Tool_dispatch.dispatch] returned [None] (handler registry
          miss).  The string outcome ["no_handler"] maps to this arm. *)
[@@deriving show, eq]

(** [to_string t] returns the label used by Otel_metric_store counters /
    [Tool_telemetry.with_span] outcome strings ("handled" / "no_handler"). *)
val to_string : t -> string

(** [of_string s] is the inverse parse.  Returns [None] for unknown
    labels so callers may fail-closed on drift. *)
val of_string : string -> t option

(** [all_arms] enumerates every variant constructor in declaration
    order.  Used by tests to assert exhaustiveness and by
    [Tool_telemetry] to register the counter label set up front. *)
val all_arms : t list

(** [classify_result_option r] maps an optional handler result to a
    typed [t]:
    {ul
    {- [r = Some _] → [Handled]}
    {- [r = None]   → [No_handler]}}
    Used by dispatch finalization and tests that need to classify optional
    handler results without reimplementing the outcome mapping. *)
val classify_result_option : 'a option -> t
