(** RFC-0084 §3.3, §6 D3 — Typed 5-arm tool dispatch outcome.

    Replaces the [string] outcome label ("handled" / "no_handler") used
    by PR-3 / PR-7 / PR-8 / PR-9 with a typed sum so post-hooks, metrics,
    and audit emitters can pattern-match exhaustively on the dispatch
    result.

    PR-10 introduces the type + helpers + tests. The 5 post-hook
    registration sites
    ([tool_output_validation:65], [tool_usage_log:272],
    [tool_metrics:127], [otel_dispatch_hook:103],
    [server_bootstrap_loops:968]) keep their existing
    [Tool_result.t -> Tool_result.t] signatures during PR-10 — they
    receive typed outcomes through a wrapper bridge added in PR-11
    (legacy removal). This staged approach avoids the 5-site
    signature-change-in-one-PR risk noted in plan §7.

    PR-14 property test measures runtime emission rate per
    {!arm} and pins the North Star invariant (every dispatch produces
    exactly one outcome). *)

(** 5-arm typed sum of dispatch outcomes. *)
type t =
  | Handled
      (** Handler returned a non-error [Tool_result.t] and produced a result. *)
  | Rejected_by_capability of { missing : string list }
      (** Capability gate rejected the dispatch.  [missing] enumerates
          the capability kinds the caller lacked (e.g.
          ["destructive"; "requires_join"]).  PR-10 introduces the
          variant; PR-7 still treats capability as advisory.  PR-12+
          may wire enforcement on top of this variant. *)
  | Rejected_by_pre_hook of { reason : string }
      (** Pre-hook chain (governance / tool_input_validation / mcp
          server) blocked the call with a structured error. *)
  | No_handler
      (** [Tool_dispatch.dispatch] returned [None] (handler registry
          miss).  Today's string outcome ["no_handler"] maps to this
          arm.  This arm closes the silent-emit-skip bug noted in
          RFC-0084 §1.2 (line 127-129): emission now happens regardless
          of handler-return shape. *)
  | Handler_error of { exn : string }
      (** Handler raised a non-cancelled exception.  Reported via
          [Tool_result.of_exn] in [Tool_dispatch.dispatch] today; PR-10
          captures the same condition as a typed arm. *)
[@@deriving show, eq]

(** [to_string t] returns the label used by Prometheus counters /
    [Tool_telemetry.with_span] outcome strings.  Matches the existing
    vocabulary so PR-7/PR-8/PR-9 wraps continue to emit identical
    counter labels until PR-11 migrates them. *)
val to_string : t -> string

(** [of_string s] is the inverse parse.  Returns [None] for unknown
    labels so callers may fail-closed on drift. *)
val of_string : string -> t option

(** [all_arms] enumerates every variant constructor in declaration
    order.  Used by tests to assert exhaustiveness and by
    [Tool_telemetry] to register the counter label set up front. *)
val all_arms : t list

(** [classify_result_option ~exn r] maps the current string-outcome
    contract to a typed [t]:
    {ul
    {- [r = Some _] → [Handled]}
    {- [r = None]   → [No_handler]}
    {- [exn = Some s] → [Handler_error \{ exn = s \}]}}
    Used during the PR-10 ↔ PR-11 migration window where post-hooks
    still receive [Tool_result.t] but [Tool_telemetry] internally
    classifies the outcome. *)
val classify_result_option
  :  ?exn:string
  -> 'a option
  -> t
