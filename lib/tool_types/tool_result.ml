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

(** Structured tool result type for MASC *)

type tool_failure_class =
  | Transient_error (** Network/timeout/rate-limit — retryable *)
  | Policy_rejection (** Auth/permission/boundary — permanent *)
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

type t =
  { success : bool
  ; data : Yojson.Safe.t
  ; message : string
  ; tool_name : string
  ; duration_ms : float
  ; failure_class : tool_failure_class option
  }

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

let to_json t =
  let base =
    [ "success", `Bool t.success
    ; "data", t.data
    ; "tool_name", `String t.tool_name
    ; "duration_ms", `Float t.duration_ms
    ]
  in
  let fields =
    match t.failure_class with
    | Some cls -> ("failure_class", `String (tool_failure_class_to_string cls)) :: base
    | None -> base
  in
  `Assoc fields
;;

let message t = t.message
let failure_class t = t.failure_class

(** Handler constructors — used by Tool_*.dispatch functions
    to build structured results directly. *)

let ok ~tool_name ~start_time message =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let data =
    match structured_payload_of_message message with
    | Some json -> json
    | None -> `String message
  in
  { success = true
  ; data
  ; message = message
  ; tool_name
  ; duration_ms
  ; failure_class = None
  }
;;

let error ?(failure_class = None) ~tool_name ~start_time message =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let data =
    match structured_payload_of_message message with
    | Some json -> json
    | None -> `String message
  in
  let failure_class =
    match failure_class with
    | Some _ -> failure_class
    | None ->
      Some
        (match classify_from_structured_failure_message message with
         | Some cls -> cls
         | None -> Runtime_failure)
  in
  { success = false
  ; data
  ; message = message
  ; tool_name
  ; duration_ms
  ; failure_class
  }
;;

let of_exn ?failure_class ~tool_name ~start_time exn =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let cls =
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
  { success = false
  ; data = `String message
  ; message = message
  ; tool_name
  ; duration_ms
  ; failure_class = Some cls
  }
;;

let quick_ok ?(tool_name = "") message =
  { success = true
  ; data = `String message
  ; message = message
  ; tool_name
  ; duration_ms = 0.0
  ; failure_class = None
  }
;;

let quick_error ?(tool_name = "") message =
  { success = false
  ; data = `String message
  ; message = message
  ; tool_name
  ; duration_ms = 0.0
  ; failure_class = Some Runtime_failure
  }
;;

(* ─────────────────────────────────────────────────────────────────────────
   RFC-0189 — Typed Result variant (SSOT-in-progress)

   Adds [(success_payload, failure_payload) Stdlib.Result.t] alongside the
   legacy record [t]. New code should use [result] + [make_ok]/[make_err]
   and [of_legacy]/[to_legacy] at boundaries with un-migrated callers.

   Why: the legacy [t] makes four illegal states representable that the
   compiler cannot rule out:

     1. {success = true;  failure_class = Some _}        — contradiction
     2. {success = false; failure_class = None}          — silent failure
     3. caller does [if r.success then ... else ...]     — boolean blindness
        and must re-parse [r.message] (JSON) to recover [failure_class]
     4. [error ?(failure_class = None)] (option of option) — confusing API

   The [result] variant collapses (1) and (2) by construction (the [Error]
   carries a typed [class_] field, no [option]), eliminates (3) by forcing
   callers to pattern-match on [Ok | Error], and dissolves (4) by giving
   [make_err] a required (non-optional) [~class_] parameter.

   Migration plan:
     - PR-1a (this commit): introduce [result], converters, and
       [make_ok]/[make_err]. Legacy [t] and 285 constructor call sites
       unchanged. Zero compile-time regression.
     - PR-1b: migrate 285 [Tool_result.ok / .error / .of_exn / .quick_*]
       call sites to [make_ok / make_err], category by category
       (board → task → library → plan → run → ...).
     - PR-2: drop legacy [t], [to_legacy], [of_legacy],
       [classify_from_structured_failure_message]. Make [result] the SSOT.

   Related: RFC-0062 (typed Tool_result.t, original design), RFC-0044/0077
   (sibling typed-reason patterns on read/write side), RFC-0088 (umbrella).
   ───────────────────────────────────────────────────────────────────── *)

type success_payload =
  { data : Yojson.Safe.t
  ; tool_name : string
  ; duration_ms : float
  }

type failure_payload =
  { class_ : tool_failure_class
  ; message : string
  ; data : Yojson.Safe.t
  ; tool_name : string
  ; duration_ms : float
  }

type result = (success_payload, failure_payload) Result.t

(** [to_legacy r] projects the typed variant onto the legacy record [t].
    Lossless. Used at boundaries with un-migrated callers. Removed in PR-2. *)
let to_legacy : result -> t = function
  | Ok { data; tool_name; duration_ms } ->
    { success = true
    ; data
    ; message =
        (match data with
         | `String s -> s
         | other -> Yojson.Safe.to_string other)
    ; tool_name
    ; duration_ms
    ; failure_class = None
    }
  | Error { class_; message; data; tool_name; duration_ms } ->
    { success = false
    ; data
    ; message
    ; tool_name
    ; duration_ms
    ; failure_class = Some class_
    }
;;

(** [of_legacy t] reconstructs a typed variant from the legacy record.

    Defensive in two corners: the legacy record permits
    [{success=true; failure_class=Some _}] and [{success=false; failure_class=None}]
    — illegal states the new variant rules out by construction. We coerce
    those into the closest meaningful [Error] and emit a [Log.warn] so the
    illegal state is observable. This branch fires only while legacy callers
    remain. Removed in PR-2 along with [t]. *)
let of_legacy (t : t) : result =
  match t.success, t.failure_class with
  | true, None ->
    Ok { data = t.data; tool_name = t.tool_name; duration_ms = t.duration_ms }
  | false, Some class_ ->
    Error
      { class_
      ; message = t.message
      ; data = t.data
      ; tool_name = t.tool_name
      ; duration_ms = t.duration_ms
      }
  | true, Some cls ->
    Log.warn
      ~ctx:"tool_result"
      "illegal legacy state #1: success=true with failure_class=%s on tool=%s; \
       coercing to Error (RFC-0189)"
      (tool_failure_class_to_string cls)
      t.tool_name;
    Error
      { class_ = cls
      ; message = t.message
      ; data = t.data
      ; tool_name = t.tool_name
      ; duration_ms = t.duration_ms
      }
  | false, None ->
    Log.warn
      ~ctx:"tool_result"
      "illegal legacy state #2: success=false with failure_class=None on tool=%s; \
       defaulting class to Runtime_failure (RFC-0189)"
      t.tool_name;
    Error
      { class_ = Runtime_failure
      ; message = t.message
      ; data = t.data
      ; tool_name = t.tool_name
      ; duration_ms = t.duration_ms
      }
;;

(** [make_ok] — typed success constructor. *)
let make_ok ~tool_name ~start_time ?(data = `Null) () : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Ok { data; tool_name; duration_ms }
;;

(** [make_err] — typed failure constructor. [~class_] is REQUIRED (not an
    option); callers must commit to a typed classification at the catch
    boundary rather than deferring to string parsing. *)
let make_err ~tool_name ~class_ ~start_time ?(data = `Null) message : result =
  let duration_ms = (Time_compat.now () -. start_time) *. 1000.0 in
  Error { class_; message; data; tool_name; duration_ms }
;;

(** [make_err_of_exn] — typed failure constructor from a caught exception.
    Uses [classify_from_exception] for the constructor-only fallback when
    [~class_] is not supplied. *)
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
