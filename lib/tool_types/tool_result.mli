(** Structured tool result type for MASC.

    The closed {!disposition} sum is the semantic SSOT for every MASC tool
    execution.  Keeper dispatch and observation layers may attach different
    payloads to it, but they must not introduce parallel success/failure
    enums or boolean outcome authorities.

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

(** Lightweight observation of an MCP/OAS wire response.  This external
    projection cannot represent {!Deferred}; it is not an internal execution
    outcome authority. *)
type tool_call_outcome = Ok | Error | Unknown

val string_of_tool_call_outcome : tool_call_outcome -> string
val log_level_of_tool_call_outcome : tool_call_outcome -> Log.level

(** Classify a tool failure from an exception raised during execution.
    Constructor-only fallback.  Semantic classes from exception messages must
    be passed explicitly at the catch boundary. *)
val classify_from_exception : exn -> tool_failure_class

(** {1 Structured result (SSOT)} *)

(** One authoritative execution disposition.  The type parameters let each
    execution layer attach its own payload without copying the semantic
    state into another enum. *)
type ('completed, 'deferred, 'failed) disposition =
  | Completed of 'completed
  | Deferred of 'deferred
  | Failed of 'failed

val string_of_disposition : ('completed, 'deferred, 'failed) disposition -> string

(** Strict wire decoder for persisted observation records. *)
val unit_disposition_of_string
  : string -> ((unit, unit, unit) disposition, string) Stdlib.Result.t

(** Payload carried by a completed or deferred tool invocation.  [metadata]
    is an opaque one-way boundary projection; MASC consumers must branch on
    {!disposition}, never recover semantics by inspecting it. *)
type output_payload =
  { data : Yojson.Safe.t
  ; metadata : Yojson.Safe.t option
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

(** Typed result of a tool invocation. *)
type result =
  (output_payload, output_payload, failure_payload) disposition

(** {2 Accessors} *)

(** [Completed output] and [Deferred output] return the JSON-stringified
    [output.data] (or the bare string if [data] is [`String]); [Failed err]
    returns [err.message]. *)
val message : result -> string

(** [Completed _] and [Deferred _] return [None]; [Failed err] returns
    [Some err.class_]. *)
val failure_class : result -> tool_failure_class option

val to_json : result -> Yojson.Safe.t
val tool_name : result -> string
val duration_ms : result -> float
val data : result -> Yojson.Safe.t

val metadata : result -> Yojson.Safe.t option

(** Explicit predicates.  Use all three when recording or serializing an
    outcome; do not collapse {!Deferred} into a success boolean inside MASC. *)
(** [true] only for [Completed].  This is a derived query, not an outcome value;
    registries and serializers must consume the full {!disposition}. *)
val is_success : result -> bool
val is_deferred : result -> bool
val is_failed : result -> bool

(** {1 Handler constructors}

    Direct constructors for [Tool_*.dispatch] functions.  Callers provide
    execution metadata at the boundary; zero-duration compatibility
    constructors have been removed. *)

(** Completed result with an opaque string body.  Producers with typed JSON
    must use {!make_ok} and pass [~data] directly. *)
val ok : tool_name:string -> start_time:float -> string -> result

(** Failure result with an opaque string body.  An absent explicit class
    defaults to [Runtime_failure]; message contents never affect the class. *)
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

(** {1 Typed constructors} *)

(** Typed success constructor.  [data] defaults to [`Null]. *)
val make_ok
  :  tool_name:string
  -> start_time:float
  -> ?data:Yojson.Safe.t
  -> ?metadata:Yojson.Safe.t
  -> unit
  -> result

(** Typed deferred constructor.  [metadata] is forwarded opaquely at the OAS
    boundary; the constructor itself is the only semantic authority. *)
val make_deferred
  :  tool_name:string
  -> start_time:float
  -> ?data:Yojson.Safe.t
  -> ?metadata:Yojson.Safe.t
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
