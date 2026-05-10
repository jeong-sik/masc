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
  | Transient_error     (** Network/timeout/rate-limit — retryable *)
  | Policy_rejection    (** Auth/permission/boundary — permanent *)
  | Runtime_failure     (** Internal error/bug — non-retryable *)
  | Workflow_rejection  (** Business rule violation — non-retryable *)

let tool_failure_class_to_string = function
  | Transient_error -> "transient_error"
  | Policy_rejection -> "policy_rejection"
  | Runtime_failure -> "runtime_failure"
  | Workflow_rejection -> "workflow_rejection"

let is_retryable = function
  | Transient_error -> true
  | Policy_rejection | Runtime_failure | Workflow_rejection -> false

let log_level_of_failure_class = function
  | Workflow_rejection | Policy_rejection | Transient_error -> Log.Warn
  | Runtime_failure -> Log.Error

(** Case-insensitive substring check for classification heuristics.
    Phase 1 bridge: string-based heuristics at catch boundaries.
    Phase 2 replaces this with typed propagation from Tool_*.dispatch. *)
let contains_casefold haystack needle =
  String.length needle = 0
  || String_util.contains_substring_ci haystack needle

(** Classify a tool failure from an exception raised during execution.
    Typed exception inspection — no string matching on exception messages
    except for [Failure] where the message carries the diagnostic. *)
let classify_from_exception (exn : exn) : tool_failure_class =
  match exn with
  | Eio.Time.Timeout -> Transient_error
  | Eio.Cancel.Cancelled _ -> Transient_error
  | Invalid_argument _ -> Policy_rejection
  | Failure msg -> (
      (* Some Failure messages carry diagnostic content worth classifying.
         This is the Phase 1 bridge — Phase 2 pushes classification into
         each Tool_*.dispatch handler where the error originates. *)
      if contains_casefold msg "MASC not initialized" then Policy_rejection
      else if contains_casefold msg "not found" then Policy_rejection
      else if contains_casefold msg "unknown tool" then Policy_rejection
      else if contains_casefold msg "timeout" then Transient_error
      else if contains_casefold msg "connection" then Transient_error
      else Runtime_failure)
  | _ -> Runtime_failure

(** Classify a tool failure from a [(false, message)] dispatch result.
    SSOT for Phase 1: single classification point replacing the
    duplicated [is_retryable_message] and [classify_tool_failure_class]. *)
let classify_from_dispatch_failure (message : string) : tool_failure_class =
  if contains_casefold message "awaiting_approval"
     || contains_casefold message "join required"
  then Workflow_rejection
  else if
    contains_casefold message "egress_blocked"
    || contains_casefold message "path_outside_sandbox"
  then Policy_rejection
  else if contains_casefold message "Tool timed out" then
    (* Tool-level timeouts are NOT retryable — retrying a 30s timeout
       causes 60-90s total wait, amplifying the original issue. *)
    Runtime_failure
  else if
    contains_casefold message "timeout"
    || contains_casefold message "temporary"
    || contains_casefold message "temporarily"
    || contains_casefold message "econn"
    || contains_casefold message "connection"
    || contains_casefold message "unavailable"
    || contains_casefold message "rate limit"
    || contains_casefold message "502"
    || contains_casefold message "503"
  then Transient_error
  else Runtime_failure

type t = {
  success : bool;
  data : Yojson.Safe.t;
  legacy_message : string;
  tool_name : string;
  duration_ms : float;
  failure_class : tool_failure_class option;
}

let structured_payload_of_message (message : string) : Yojson.Safe.t option =
  let parse_json raw =
    try Some (Yojson.Safe.from_string raw)
    with Yojson.Json_error _ -> None
  in
  let trimmed = String.trim message in
  let ensure_object = function
    | `Assoc _ as obj -> Some obj
    | `List _ as arr -> Some (`Assoc [ ("items", arr) ])
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
              String.sub message (newline_idx + 1) (len - newline_idx - 1)
              |> String.trim
            in
            if String.equal suffix "" then loop (newline_idx + 1)
            else
              match suffix.[0] with
              | '{' | '[' -> (
                  match parse_json suffix with
                  | Some json -> ensure_object json
                  | None -> loop (newline_idx + 1))
              | _ -> loop (newline_idx + 1)
      in
      loop 0

let wrap ?(failure_class = None) ~tool_name ~start_time (success, message) =
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
        if success then None
        else Some (classify_from_dispatch_failure message)
  in
  { success; data; legacy_message = message; tool_name; duration_ms; failure_class }

let to_json t =
  let base =
    [ ("success", `Bool t.success)
    ; ("data", t.data)
    ; ("tool_name", `String t.tool_name)
    ; ("duration_ms", `Float t.duration_ms)
    ]
  in
  let fields = match t.failure_class with
    | Some cls -> ("failure_class", `String (tool_failure_class_to_string cls)) :: base
    | None -> base
  in
  `Assoc fields

let message t = t.legacy_message

let failure_class t = t.failure_class

let to_legacy_compat t = (t.success, message t)

(** Handler constructors — used by Tool_*.dispatch functions
    to build structured results directly without going through [wrap]. *)

let ok ~tool_name ~start_time message =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let data =
    match structured_payload_of_message message with
    | Some json -> json
    | None -> `String message
  in
  { success = true; data; legacy_message = message; tool_name; duration_ms; failure_class = None }

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
    | None -> Some (classify_from_dispatch_failure message)
  in
  { success = false; data; legacy_message = message; tool_name; duration_ms; failure_class }

let of_exn ~tool_name ~start_time exn =
  let end_time = Time_compat.now () in
  let duration_ms = (end_time -. start_time) *. 1000.0 in
  let cls = classify_from_exception exn in
  let message =
    Printf.sprintf "dispatch handler error for %s: %s" tool_name
      (Stdlib.Printexc.to_string exn)
  in
  { success = false
  ; data = `String message
  ; legacy_message = message
  ; tool_name
  ; duration_ms
  ; failure_class = Some cls
  }

let quick_ok ?(tool_name = "") message =
  { success = true
  ; data = `String message
  ; legacy_message = message
  ; tool_name
  ; duration_ms = 0.0
  ; failure_class = None
  }

let quick_error ?(tool_name = "") message =
  { success = false
  ; data = `String message
  ; legacy_message = message
  ; tool_name
  ; duration_ms = 0.0
  ; failure_class = Some Runtime_failure
  }
