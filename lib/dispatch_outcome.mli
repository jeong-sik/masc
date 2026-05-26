(** Typed 5-arm tool dispatch outcome.

    Replaces the [string] outcome label ("handled" / "no_handler") used
    by earlier dispatch wiring with a typed sum so observers, metrics, and
    audit emitters can pattern-match exhaustively on the dispatch result. *)

(** 5-arm typed sum of dispatch outcomes. *)
type t =
  | Handled
      (** Handler returned a non-error [Tool_result.result] and produced a result. *)
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
          [Tool_result.make_err_of_exn] in [Tool_dispatch.dispatch] today;
          PR-10 captures the same condition as a typed arm. *)
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
    Used by dispatch finalization and tests that need to classify optional
    handler results without reimplementing the outcome mapping. *)
val classify_result_option
  :  ?exn:string
  -> 'a option
  -> t
