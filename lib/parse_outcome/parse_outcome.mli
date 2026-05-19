(** Parse_outcome — canonical helper for parse-with-failure boundaries.

    Replaces the [try f s with _ -> None / [] / default] pattern documented
    as Cluster A "telemetry-as-fix" in
    [~/me/.tmp/pr-audit-2026-05-20/AUDIT-REPORT.md].

    Design constraints (RFC-0145):
    - Cancellation [Eio.Cancel.Cancelled] is re-raised, never absorbed.
    - The base library has no Yojson dependency; callers that need
      Yojson-aware classification pass the exception to [of_exn].
    - Caller is forced to dispatch on the [error] payload — wildcard
      [| _ -> None] is no longer the cheap path. *)

type error =
  [ `Json_parse_error of string
  | `Other of exn ]
(** Classification of a parse failure.
    - [`Json_parse_error msg]: structured parse error with a redacted
      caller-supplied message (no payload).
    - [`Other exn]: any other exception that was *not* cancellation.
      Cancellation is re-raised, not represented here. *)

type 'a t = (('a, error) result)
(** Outcome of a partial parse. *)

val parse_safe : (string -> 'a) -> string -> 'a t
(** [parse_safe f s] runs [f s] and classifies failures.

    Semantics:
    - Returns [Ok x] when [f s] returns [x].
    - Returns [Error (`Other exn)] for any non-cancellation exception.
    - Re-raises [Eio.Cancel.Cancelled _] (Eio cancellation protocol).

    The base helper does *not* attempt to classify Yojson exceptions —
    callers that already link Yojson should post-process via [of_exn]. *)

val of_exn : exn -> error
(** [of_exn e] classifies a raised exception into [error].

    Recognises [Yojson.Json_error] by name without taking a Yojson
    dependency (string match on [Printexc.exn_slot_name]). Callers that
    already link Yojson can wrap to a typed Yojson error themselves. *)

val bind : 'a t -> ('a -> 'b t) -> 'b t
(** Monadic bind. Cancellation re-raise is structural to [parse_safe];
    [bind] only chains pure outcomes. *)

val map : ('a -> 'b) -> 'a t -> 'b t
(** Functorial map over [Ok]. *)

val to_option : 'a t -> 'a option
(** [to_option o] discards the error payload.
    Provided as a *migration shim* for sites that currently return
    [option] — new code should pattern-match on the [error] instead. *)
