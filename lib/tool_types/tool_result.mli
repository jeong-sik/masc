(** Structured tool result type for MASC

    Replaces the untyped [(bool * string)] return convention with a
    structured record carrying tool name, timing, and typed payload.

    @since 2.95.0 *)

(** {1 Failure classification} *)

(** Closed sum type for tool failure classification.  Each constructor
    maps to a distinct retry/log/telemetry policy; the compiler enforces
    exhaustive handling at every match site.

    @since 2.96.0 *)
type tool_failure_class =
  | Transient_error (** Network/timeout/rate-limit — retryable *)
  | Policy_rejection (** Auth/permission/boundary — permanent *)
  | Runtime_failure (** Internal error/bug — non-retryable *)
  | Workflow_rejection (** Business rule violation — non-retryable *)

val tool_failure_class_to_yojson : tool_failure_class -> Yojson.Safe.t
val tool_failure_class_of_yojson :
  Yojson.Safe.t -> (tool_failure_class, string) result

val pp_tool_failure_class : Format.formatter -> tool_failure_class -> unit
val show_tool_failure_class : tool_failure_class -> string

val tool_failure_class_to_string : tool_failure_class -> string
val tool_failure_class_of_string : string -> tool_failure_class option

(** [Transient_error] is the only retryable class. *)
val is_retryable : tool_failure_class -> bool

(** [Runtime_failure] maps to [Error]; all others to [Warn]. *)
val log_level_of_failure_class : tool_failure_class -> Log.level

(** Classify a tool failure from an exception raised during execution.
    Constructor-only fallback.  Semantic classes from exception messages must
    be passed explicitly at the catch boundary. *)
val classify_from_exception : exn -> tool_failure_class

(** {1 Structured result} *)

(** Structured result from a tool invocation.  [failure_class] is
    [None] on success and [Some _] on failure once classified.

    @since 2.96.0 — [failure_class] field added *)
type t =
  { success : bool
  ; data : Yojson.Safe.t
  ; message : string
  ; tool_name : string
  ; duration_ms : float
  ; failure_class : tool_failure_class option
  }

val structured_payload_of_message : string -> Yojson.Safe.t option
val to_json : t -> Yojson.Safe.t
val message : t -> string

(** Accessor for the typed failure classification. *)
val failure_class : t -> tool_failure_class option

(** {1 Handler constructors}

    Direct constructors for [Tool_*.dispatch] functions to build
    structured results without the legacy [wrap] intermediary. *)

(** Successful result. [failure_class] is [None]. *)
val ok : tool_name:string -> start_time:float -> string -> t

(** Failure result.  When [failure_class] is not provided, only a structured
    JSON [failure_class] payload is honored; free-form message text defaults to
    [Runtime_failure]. *)
val error
  :  ?failure_class:tool_failure_class option
  -> tool_name:string
  -> start_time:float
  -> string
  -> t

(** Build a failure result from an exception caught during dispatch.  When
    [failure_class] is provided, it is trusted as the catch boundary's typed
    decision; otherwise {!classify_from_exception} supplies a constructor-only
    fallback. *)
val of_exn : ?failure_class:tool_failure_class -> tool_name:string -> start_time:float -> exn -> t

(** {1 Test helpers}

    Quick constructors for tests and one-liner handlers.
    [duration_ms] is set to [0.0] and [tool_name] defaults to [""].

    @since 2.260.0 *)

val quick_ok : ?tool_name:string -> string -> t
val quick_error : ?tool_name:string -> string -> t

(** {1 RFC-0189 — Typed Result variant (SSOT-in-progress)}

    Adds [(success_payload, failure_payload) Stdlib.Result.t] alongside the
    legacy record {!t}. New code should use {!result} + {!make_ok} /
    {!make_err} and {!of_legacy} / {!to_legacy} at boundaries with
    un-migrated callers.

    The legacy {!t} makes four illegal states representable that the
    compiler cannot rule out:

      - [{success = true;  failure_class = Some _}]  — contradiction
      - [{success = false; failure_class = None}]    — silent failure
      - caller does [if r.success then ... else ...] — boolean blindness
      - {!error}'s [?failure_class:tool_failure_class option] — option-of-option

    {!result} collapses all four by construction.

    Migration plan:
      - PR-1a (this commit): introduce surface, no caller changes
      - PR-1b: migrate 285 constructor sites to {!make_ok} / {!make_err}
      - PR-2: drop legacy {!t} and converters; {!result} becomes SSOT

    Related: RFC-0062, RFC-0044, RFC-0077, RFC-0088.

    @since 2.262.0 *)

(** Payload carried by a successful tool invocation. *)
type success_payload =
  { data : Yojson.Safe.t
  ; tool_name : string
  ; duration_ms : float
  }

(** Payload carried by a failed tool invocation.  [class_] is required
    (not an [option]): callers must commit to a typed classification at
    the catch boundary. *)
type failure_payload =
  { class_ : tool_failure_class
  ; message : string
  ; data : Yojson.Safe.t
  ; tool_name : string
  ; duration_ms : float
  }

(** Typed result of a tool invocation.  Pattern-match on [Ok] / [Error]
    rather than reading [.success] + [.failure_class] off the legacy
    record. *)
type result = (success_payload, failure_payload) Stdlib.Result.t

(** Lossless projection onto the legacy record. *)
val to_legacy : result -> t

(** Lift the legacy record into the typed variant.  Illegal states (#1, #2
    above) are coerced to [Error] with a [Log.warn]. *)
val of_legacy : t -> result

(** Typed success constructor.  [data] defaults to [`Null]. *)
val make_ok
  :  tool_name:string
  -> start_time:float
  -> ?data:Yojson.Safe.t
  -> unit
  -> result

(** Typed failure constructor.  [~class_] is REQUIRED. *)
val make_err
  :  tool_name:string
  -> class_:tool_failure_class
  -> start_time:float
  -> ?data:Yojson.Safe.t
  -> string
  -> result

(** Typed failure constructor from a caught exception.  When [~class_] is
    not provided, {!classify_from_exception} supplies the
    constructor-only fallback. *)
val make_err_of_exn
  :  ?class_:tool_failure_class
  -> tool_name:string
  -> start_time:float
  -> exn
  -> result
