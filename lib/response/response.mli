(** Standardised API response envelope shared across MCP tools.

    Every MCP tool return value flows through a {!t} so clients get a
    uniform shape: a {!success} flag, a JSON payload, a human-readable
    {!message}, structured {!errors} with recovery hints, and an
    emission timestamp.

    Prefer the constructor helpers ({!ok}, {!error}, {!validation_error}
    …) over building a {!t} literal by hand — they stamp the timestamp
    and enforce the shape agreed upon with the tool host.

    Usage:
    {[
      Response.ok ~message:"Task claimed"
        (`Assoc [("task_id", `String "task-001")])
      |> Response.to_string
    ]}
*)

(** {1 Types} *)

(** Severity level on a structured error entry. *)
type severity =
  | Fatal    (** Operation completely failed. *)
  | Warning  (** Partial success or recoverable issue. *)
  | Info     (** Informational, no action needed. *)

(** One structured error produced by a tool, with machine-readable
    [code], a human-readable [message] and zero or more
    [recovery_hints]. *)
type error_detail = {
  code: string;
  severity: severity;
  message: string;
  recovery_hints: string list;
}

(** Canonical tool response envelope.  [success] is the quick-check
    flag; [data] is the tool-specific payload; [errors] carries fatal
    errors (when [success = false]) or warnings (when [success = true]
    via {!ok_with_warnings}). *)
type t = {
  success: bool;
  data: Yojson.Safe.t;
  message: string;
  errors: error_detail list;
  timestamp: float;
}

(** {1 Severity conversions} *)

val severity_to_string : severity -> string
(** Canonical lower-case name: ["fatal" | "warning" | "info"]. *)

val severity_of_string : string -> (severity, string) result
(** Parse the canonical lower-case name; returns [Error msg] on
    anything else (unknown inputs are not silently downgraded). *)

val severity_of_string_default : ?default:severity -> string -> severity
(** Parse like {!severity_of_string} but fall back to [default]
    ([Info] if not given) on any unknown input.  Retained for
    backwards-compatibility with callers that cannot surface a parse
    error. *)

val to_severity : severity -> Severity.t
(** Project the local {!severity} enum onto the cross-module
    [Severity.t] used by other subsystems ([Fatal -> Critical], etc.). *)

(** {1 Serialization} *)

val error_to_json : error_detail -> Yojson.Safe.t
val to_json : t -> Yojson.Safe.t
val to_string : t -> string
(** [to_string r] is the pretty-printed JSON of [r]. *)

(** {1 Constructors — success} *)

val ok : ?message:string -> Yojson.Safe.t -> t
(** [ok ~message data] builds a success response; default [message]
    is ["OK"]. *)

val ok_with_warnings :
  ?message:string -> warnings:error_detail list -> Yojson.Safe.t -> t
(** Success with attached non-fatal [warnings] carried on
    {!error_detail}s. *)

(** {1 Constructors — error} *)

val error :
  ?data:Yojson.Safe.t ->
  code:string ->
  message:string ->
  ?hints:string list ->
  unit -> t
(** [error ~code ~message ?hints ()] builds a single-error failure
    response at [Fatal] severity. *)

val errors :
  ?data:Yojson.Safe.t ->
  message:string ->
  error_detail list -> t
(** Failure response with multiple pre-built {!error_detail}s (each
    with its own severity). *)

(** {1 Constructors — individual [error_detail]s} *)

val make_error :
  code:string ->
  ?severity:severity ->
  message:string ->
  ?hints:string list ->
  unit -> error_detail
(** Default severity is [Fatal]. *)

val make_warning :
  code:string ->
  message:string ->
  ?hints:string list ->
  unit -> error_detail

val make_info :
  code:string ->
  message:string ->
  unit -> error_detail

(** {1 Common error kinds}

    These wrap {!error} with a canonical [code], a formatted
    [message], and curated recovery hints; prefer them over ad-hoc
    {!error} calls so codes stay consistent across tools. *)

val validation_error : field:string -> reason:string -> t
val not_found        : resource:string -> id:string -> t
val already_exists   : resource:string -> id:string -> t
val permission_denied : action:string -> resource:string -> t
val conflict         : resource:string -> reason:string -> t
val timeout          : operation:string -> t

(** {1 Drift-specific responses} *)

val drift_detected :
  similarity:float ->
  drift_type:string ->
  threshold:float ->
  details:string ->
  t
(** Emits a [Warning]-severity response whose recovery hints are
    selected by [drift_type] (["factual" | "semantic" | "structural"]
    — anything else gets generic hints). *)

val handoff_verified : similarity:float -> t
(** Success envelope for a verified handoff, reporting [similarity]. *)

(** {1 Task-specific responses}

    These route status strings through [Types.task_status_to_string]
    so the value returned here matches what other emitters/parsers
    see — see the comment in the implementation (issues #8364, #8412)
    for why this matters. *)

val task_claimed       : task_id:string -> agent:string -> t
val task_already_claimed : task_id:string -> claimed_by:string -> t
val task_completed     : task_id:string -> agent:string -> notes:string -> t
