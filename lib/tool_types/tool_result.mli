(** Structured tool result type for MASC

    RFC-0189 PR-2 (2026-05-26): the legacy [t] record and its
    [to_legacy]/[of_legacy] converters were removed.  The typed
    [(success_payload, failure_payload) Stdlib.Result.t] is the SSOT.
    Callers pattern-match on [Ok | Error] rather than reading [.success]
    + [.failure_class] off a record.

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

(** {1 Tool call outcome (wire-level)} *)

(** Lightweight tri-state for MCP/keeper tool call logging.
    Maps from JSONRPC wire format or [result] variant. *)
type tool_call_outcome = Ok | Error | Unknown

val string_of_tool_call_outcome : tool_call_outcome -> string
val log_level_of_tool_call_outcome : tool_call_outcome -> Log.level

(** Classify a tool failure from an exception raised during execution.
    Constructor-only fallback.  Semantic classes from exception messages must
    be passed explicitly at the catch boundary. *)
val classify_from_exception : exn -> tool_failure_class

(** {1 Structured result (SSOT)} *)

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
    rather than reading [.success] / [.failure_class] off a record. *)
type result = (success_payload, failure_payload) Stdlib.Result.t

type structured_payload_location =
  | Complete_message
  | Message_suffix of { byte_offset : int }

type structured_payload_decode_error =
  | Structured_payload_json_error of
      { location : structured_payload_location
      ; message : string
      }

type structured_payload_decode_report =
  { payload : Yojson.Safe.t option
  ; errors : structured_payload_decode_error list
  }

val structured_payload_decode_error_to_string :
  structured_payload_decode_error -> string

val structured_payload_of_message_report :
  string -> structured_payload_decode_report

val structured_payload_of_message : string -> Yojson.Safe.t option

(** {2 Accessors} *)

(** [Ok ok] returns the JSON-stringified [ok.data] (or the bare string
    if [data] is [`String]); [Error err] returns [err.message]. *)
val message : result -> string

(** [Ok _] → [None]; [Error err] → [Some err.class_]. *)
val failure_class : result -> tool_failure_class option

val to_json : result -> Yojson.Safe.t
val tool_name : result -> string
val duration_ms : result -> float
val data : result -> Yojson.Safe.t

(** [true] iff [Ok _]. *)
val is_success : result -> bool

(** {1 Handler constructors}

    Direct constructors for [Tool_*.dispatch] functions.  Callers provide
    execution metadata at the boundary; zero-duration compatibility
    constructors have been removed. *)

(** Successful result.  [data] is parsed from the message when it
    contains structured JSON, otherwise [`String message]. *)
val ok : tool_name:string -> start_time:float -> string -> result

(** Failure result.  Classifies from the structured message when no
    explicit class is provided; defaults to [Runtime_failure]. *)
val error
  :  ?failure_class:tool_failure_class option
  -> tool_name:string
  -> start_time:float
  -> string
  -> result

(** Build a failure result from a caught exception.  When [failure_class]
    is provided it is trusted as the catch boundary's typed decision;
    otherwise {!classify_from_exception} supplies a constructor-only
    fallback. *)
val of_exn
  :  ?failure_class:tool_failure_class
  -> tool_name:string
  -> start_time:float
  -> exn
  -> result

(** {1 Typed constructors (RFC-0189)}

    Same intent as {!ok}/{!error} but with the [class_] requirement
    enforced positionally for new code that wants to commit to a
    classification at the catch boundary. *)

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
