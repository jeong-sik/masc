
(** Structured tool result type for MASC

    Replaces the untyped [(bool * string)] return convention with a
    structured record carrying tool name, timing, and typed payload.

    Backward compatible: existing handlers keep returning [(bool * string)];
    {!wrap} converts at the dispatch boundary.

    @since 2.95.0 *)

(** {1 Failure classification} *)

type tool_failure_class =
  | Transient_error     (** Network/timeout/rate-limit — retryable *)
  | Policy_rejection    (** Auth/permission/boundary — permanent *)
  | Runtime_failure     (** Internal error/bug — non-retryable *)
  | Workflow_rejection  (** Business rule violation — non-retryable *)
(** Closed sum type for tool failure classification.  Each constructor
    maps to a distinct retry/log/telemetry policy; the compiler enforces
    exhaustive handling at every match site.

    @since 2.96.0 *)

val tool_failure_class_to_string : tool_failure_class -> string

val is_retryable : tool_failure_class -> bool
(** [Transient_error] is the only retryable class. *)

val log_level_of_failure_class : tool_failure_class -> Log.level
(** [Runtime_failure] maps to [Error]; all others to [Warn]. *)

val classify_from_exception : exn -> tool_failure_class
(** Classify a tool failure from an exception raised during execution.
    Typed exception inspection — no string matching on exception messages
    except for [Failure] where the message carries the diagnostic. *)

(** {1 Structured result} *)

type t = {
  success : bool;
  data : Yojson.Safe.t;
  legacy_message : string;
  tool_name : string;
  duration_ms : float;
  failure_class : tool_failure_class option;
}
(** Structured result from a tool invocation.  [failure_class] is
    [None] on success and [Some _] on failure once classified.

    @since 2.96.0 — [failure_class] field added *)

val structured_payload_of_message : string -> Yojson.Safe.t option

val to_json : t -> Yojson.Safe.t

val message : t -> string

val failure_class : t -> tool_failure_class option
(** Accessor for the typed failure classification. *)

(** {1 Handler constructors}

    Direct constructors for [Tool_*.dispatch] functions to build
    structured results without the legacy [wrap] intermediary. *)

val ok : tool_name:string -> start_time:float -> string -> t
(** Successful result. [failure_class] is [None]. *)

val error :
  ?failure_class:tool_failure_class option ->
  tool_name:string ->
  start_time:float ->
  string -> t
(** Failure result.  When [failure_class] is not provided,
    the message is classified by an internal heuristic. *)

val of_exn : tool_name:string -> start_time:float -> exn -> t
(** Build a failure result from an exception caught during dispatch.
    Uses {!classify_from_exception} for typed classification. *)

(** {1 Test helpers}

    Quick constructors for tests and one-liner handlers.
    [duration_ms] is set to [0.0] and [tool_name] defaults to [""].

    @since 2.260.0 *)

val quick_ok : ?tool_name:string -> string -> t
val quick_error : ?tool_name:string -> string -> t
