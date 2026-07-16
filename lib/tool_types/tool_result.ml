module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Structured tool result type for MASC. *)

type tool_failure_class =
  | Transient_error (** Network/timeout/rate-limit — retryable *)
  | Policy_rejection
      (** Permission, guardrail, validation reject (RFC-0062 §3.2) — permanent.
          Covers caller-input/argument validation, not only auth/boundary. *)
  | Runtime_failure (** Internal error/bug — non-retryable *)
  | Workflow_rejection (** Business rule violation — non-retryable *)
[@@deriving yojson, show]

let tool_failure_class_to_string = function
  | Transient_error -> "transient_error"
  | Policy_rejection -> "policy_rejection"
  | Runtime_failure -> "runtime_failure"
  | Workflow_rejection -> "workflow_rejection"
;;

let tool_failure_class_of_string = function
  | "transient_error" -> Some Transient_error
  | "policy_rejection" -> Some Policy_rejection
  | "runtime_failure" -> Some Runtime_failure
  | "workflow_rejection" -> Some Workflow_rejection
  | _ -> None
;;

let is_retryable = function
  | Transient_error -> true
  | Policy_rejection | Runtime_failure | Workflow_rejection -> false
;;

let log_level_of_failure_class = function
  | Workflow_rejection | Policy_rejection | Transient_error -> Log.Warn
  | Runtime_failure -> Log.Error
;;

(** Lightweight observation of an MCP/OAS wire response.  This is not a MASC
    execution disposition: the external protocol cannot represent [Deferred],
    so callers must never use this projection as the internal outcome SSOT. *)
type tool_call_outcome = Ok | Error | Unknown

let string_of_tool_call_outcome = function
  | Ok -> "ok"
  | Error -> "error"
  | Unknown -> "unknown"
;;

let log_level_of_tool_call_outcome = function
  | Error -> Log.Error
  | Ok | Unknown -> Log.Info
;;

(** Classify a tool failure from an exception raised during execution.
    Constructor-only fallback.  Semantic classes from exception messages must
    be passed explicitly at the catch boundary. *)
let classify_from_exception (exn : exn) : tool_failure_class =
  match exn with
  | Eio.Time.Timeout -> Transient_error
  | Eio.Cancel.Cancelled _ -> Transient_error
  | Invalid_argument _ -> Runtime_failure
  | Failure _ -> Runtime_failure
  | _ -> Runtime_failure
;;

type ('completed, 'deferred, 'failed) disposition =
  | Completed of 'completed
  | Deferred of 'deferred
  | Failed of 'failed

let string_of_disposition = function
  | Completed _ -> "completed"
  | Deferred _ -> "deferred"
  | Failed _ -> "failed"
;;

let unit_disposition_of_string = function
  | "completed" -> Result.Ok (Completed ())
  | "deferred" -> Result.Ok (Deferred ())
  | "failed" -> Result.Ok (Failed ())
  | value -> Result.Error (Printf.sprintf "unknown tool disposition: %S" value)
;;

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

type result =
  (output_payload, output_payload, failure_payload) disposition

(** {1 Accessors}

    Take [result] directly; pattern-match on its canonical disposition so
    callers can keep the bare [Tool_result.message r] form. *)

let message : result -> string = function
  | Completed { data; _ } | Deferred { data; _ } ->
    (match data with
     | `String s -> s
     | other -> Yojson.Safe.to_string other)
  | Failed { message; _ } -> message
;;

let failure_class : result -> tool_failure_class option = function
  | Completed _ | Deferred _ -> None
  | Failed { class_; _ } -> Some class_
;;

let to_json (result : result) : Yojson.Safe.t =
  let disposition = string_of_disposition result in
  match result with
  | Completed { data; metadata; tool_name; duration_ms } ->
    `Assoc
      ([ "disposition", `String disposition
      ; "data", data
      ; "tool_name", `String tool_name
      ; "duration_ms", `Float duration_ms
      ]
       @ Option.fold ~none:[] ~some:(fun value -> [ "metadata", value ]) metadata)
  | Deferred { data; metadata; tool_name; duration_ms } ->
    `Assoc
      ([ "disposition", `String disposition
       ; "data", data
       ; "tool_name", `String tool_name
       ; "duration_ms", `Float duration_ms
       ]
       @ Option.fold ~none:[] ~some:(fun value -> [ "metadata", value ]) metadata)
  | Failed { class_; message; data; tool_name; duration_ms } ->
    `Assoc
      [ "failure_class", `String (tool_failure_class_to_string class_)
      ; "disposition", `String disposition
      ; "data", data
      ; "message", `String message
      ; "tool_name", `String tool_name
      ; "duration_ms", `Float duration_ms
      ]
;;

let tool_name : result -> string = function
  | Completed { tool_name; _ }
  | Deferred { tool_name; _ }
  | Failed { tool_name; _ } -> tool_name
;;

let duration_ms : result -> float = function
  | Completed { duration_ms; _ }
  | Deferred { duration_ms; _ }
  | Failed { duration_ms; _ } -> duration_ms
;;

let data : result -> Yojson.Safe.t = function
  | Completed { data; _ } | Deferred { data; _ } | Failed { data; _ } -> data
;;

let metadata : result -> Yojson.Safe.t option = function
  | Completed { metadata; _ } | Deferred { metadata; _ } -> metadata
  | Failed _ -> None
;;

let is_success : result -> bool = function
  | Completed _ -> true
  | Deferred _ | Failed _ -> false
;;

let is_deferred : result -> bool = function
  | Deferred _ -> true
  | Completed _ | Failed _ -> false
;;

let is_failed : result -> bool = function
  | Failed _ -> true
  | Completed _ | Deferred _ -> false
;;

(** {1 Constructors}

    Bodies return [result] directly.  Callers must provide execution
    metadata at the boundary instead of falling back to zero-duration
    compatibility constructors. *)

let ok ~tool_name ~start_time message_str : result =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  Completed { data = `String message_str; metadata = None; tool_name; duration_ms }
;;

let error ?(failure_class = None) ~tool_name ~start_time message_str : result =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let class_ = Option.value ~default:Runtime_failure failure_class in
  Failed
    { class_
    ; message = message_str
    ; data = `String message_str
    ; tool_name
    ; duration_ms
    }
;;

let of_exn ?failure_class ~tool_name ~start_time exn : result =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let class_ =
    match failure_class with
    | Some cls -> cls
    | None -> classify_from_exception exn
  in
  let message =
    Printf.sprintf
      "dispatch handler error for %s: %s"
      tool_name
      (Stdlib.Printexc.to_string exn)
  in
  Failed { class_; message; data = `String message; tool_name; duration_ms }
;;

(** {1 Typed constructors (RFC-0189)}

    Same intent as {!ok}/{!error} but with the [class_] requirement
    enforced positionally for new code that wants to commit to a
    classification at the catch boundary. *)

let make_ok ~tool_name ~start_time ?(data = `Null) ?metadata () : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Completed { data; metadata; tool_name; duration_ms }
;;

let make_deferred ~tool_name ~start_time ?(data = `Null) ?metadata () : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Deferred { data; metadata; tool_name; duration_ms }
;;

let make_err ~tool_name ~class_ ~start_time ?(data = `Null) message_str : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Failed { class_; message = message_str; data; tool_name; duration_ms }
;;

let make_err_of_exn ?class_ ~tool_name ~start_time exn : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  let class_ =
    match class_ with
    | Some c -> c
    | None -> classify_from_exception exn
  in
  let message =
    Printf.sprintf
      "dispatch handler error for %s: %s"
      tool_name
      (Stdlib.Printexc.to_string exn)
  in
  Failed { class_; message; data = `String message; tool_name; duration_ms }
;;
