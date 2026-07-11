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

(** Structured tool result type for MASC

    RFC-0189 PR-2 (2026-05-26): the legacy [t] record and its
    [to_legacy]/[of_legacy] converters are gone.  [result] is the SSOT;
    every constructor returns [result] and every accessor takes
    [result].  Callers pattern-match on [Ok | Error] instead of reading
    [.success] / [.failure_class] off a record. *)

type tool_failure_class =
  | Transient_error (** Network/timeout/rate-limit — retryable *)
  | Policy_rejection
      (** Permission, guardrail, or visibility boundary — permanent. *)
  | Runtime_failure (** Execution/infrastructure error — non-retryable *)
  | Workflow_rejection
      (** Input/schema contract or business-rule violation — non-retryable *)
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

(** Lightweight outcome classification for MCP/keeper tool call logging.
    Unlike {!tool_failure_class} (which carries retry/telemetry semantics),
    this tri-state maps directly from the wire format or result variant. *)
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

let classify_from_structured_failure_message message =
  try
    match Yojson.Safe.from_string message with
    | `Assoc fields ->
      (match List.assoc_opt "failure_class" fields with
       | Some (`String value) -> tool_failure_class_of_string value
       | _ -> None)
    | _ -> None
  with
  | Yojson.Json_error _ -> None
;;

let structured_payload_of_message (message : string) : Yojson.Safe.t option =
  let parse_json raw =
    try Some (Yojson.Safe.from_string raw) with
    | Yojson.Json_error _ -> None
  in
  let trimmed = String.trim message in
  let ensure_object = function
    | `Assoc _ as obj -> Some obj
    | `List _ as arr -> Some (`Assoc [ "items", arr ])
    | _ -> None
  in
  match parse_json trimmed with
  | Some json -> ensure_object json
  | None ->
    let len = String.length message in
    let rec loop from =
      match String.index_from_opt message from '\n' with
      | None -> None
      | Some newline_idx ->
        let suffix =
          String.sub message (newline_idx + 1) (len - newline_idx - 1) |> String.trim
        in
        if String.equal suffix ""
        then loop (newline_idx + 1)
        else (
          match suffix.[0] with
          | '{' | '[' ->
            (match parse_json suffix with
             | Some json -> ensure_object json
             | None -> loop (newline_idx + 1))
          | _ -> loop (newline_idx + 1))
    in
    loop 0
;;

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
    rather than reading [.success] + [.failure_class] off a record. *)
type result = (success_payload, failure_payload) Result.t

(** {1 Accessors}

    Take [result] directly; pattern-match on [Ok | Error] internally so
    callers can keep the bare [Tool_result.message r] form. *)

let message : result -> string = function
  | Ok { data; _ } ->
    (match data with
     | `String s -> s
     | other -> Yojson.Safe.to_string other)
  | Error { message; _ } -> message
;;

let failure_class : result -> tool_failure_class option = function
  | Ok _ -> None
  | Error { class_; _ } -> Some class_
;;

let to_json : result -> Yojson.Safe.t = function
  | Ok { data; tool_name; duration_ms } ->
    `Assoc
      [ "success", `Bool true
      ; "data", data
      ; "tool_name", `String tool_name
      ; "duration_ms", `Float duration_ms
      ]
  | Error { class_; message; data; tool_name; duration_ms } ->
    `Assoc
      [ "failure_class", `String (tool_failure_class_to_string class_)
      ; "success", `Bool false
      ; "data", data
      ; "message", `String message
      ; "tool_name", `String tool_name
      ; "duration_ms", `Float duration_ms
      ]
;;

let tool_name : result -> string = function
  | Ok { tool_name; _ } -> tool_name
  | Error { tool_name; _ } -> tool_name
;;

let duration_ms : result -> float = function
  | Ok { duration_ms; _ } -> duration_ms
  | Error { duration_ms; _ } -> duration_ms
;;

let data : result -> Yojson.Safe.t = function
  | Ok { data; _ } -> data
  | Error { data; _ } -> data
;;

let is_success : result -> bool = function
  | Ok _ -> true
  | Error _ -> false
;;

(** {1 Constructors}

    Bodies return [result] directly.  Callers must provide execution
    metadata at the boundary instead of falling back to zero-duration
    compatibility constructors. *)

let ok ~tool_name ~start_time message_str : result =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let data =
    match structured_payload_of_message message_str with
    | Some json -> json
    | None -> `String message_str
  in
  Ok { data; tool_name; duration_ms }
;;

let error ?(failure_class = None) ~tool_name ~start_time message_str : result =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let data =
    match structured_payload_of_message message_str with
    | Some json -> json
    | None -> `String message_str
  in
  let class_ =
    match failure_class with
    | Some cls -> cls
    | None ->
      (match classify_from_structured_failure_message message_str with
       | Some cls -> cls
       | None -> Runtime_failure)
  in
  Error { class_; message = message_str; data; tool_name; duration_ms }
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
  Error { class_; message; data = `String message; tool_name; duration_ms }
;;

(** {1 Typed constructors (RFC-0189)}

    Same intent as {!ok}/{!error} but with the [class_] requirement
    enforced positionally for new code that wants to commit to a
    classification at the catch boundary. *)

let make_ok ~tool_name ~start_time ?(data = `Null) () : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Ok { data; tool_name; duration_ms }
;;

let make_err ~tool_name ~class_ ~start_time ?(data = `Null) message_str : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Error { class_; message = message_str; data; tool_name; duration_ms }
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
  Error { class_; message; data = `String message; tool_name; duration_ms }
;;
