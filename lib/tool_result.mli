
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

val classify_from_dispatch_failure : string -> tool_failure_class
(** Classify a tool failure from a [(false, message)] dispatch result.
    SSOT for Phase 1 string-based classification at catch boundaries.
    Phase 2 replaces this with typed propagation from [Tool_*.dispatch]. *)

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

val wrap :
  ?failure_class:tool_failure_class option ->
  tool_name:string ->
  start_time:float ->
  (bool * string) ->
  t
(** [wrap ~tool_name ~start_time raw] converts a legacy [(bool * string)]
    tuple into a structured result.

    When [failure_class] is not provided and the result is a failure,
    {!classify_from_dispatch_failure} is called on the message to
    determine the class automatically. *)

val to_json : t -> Yojson.Safe.t

val message : t -> string

val failure_class : t -> tool_failure_class option
(** Accessor for the typed failure classification. *)

val to_legacy_compat : t -> bool * string
(** Converts back to [(bool * string)] for callers that have not yet
    migrated to the typed result interface.

    @deprecated Prefer consuming {!t} directly. *)
[@@alert legacy_tuple
  "This function exists for migration only. \
   Migrate the call site to use Tool_result.t directly."]
