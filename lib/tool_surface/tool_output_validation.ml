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

(** Tool_output_validation — Memory-protection cap.

    Context budget management belongs to OAS [context_reducer].
    This module only prevents OOM from unbounded tool output
    (e.g. a shell command that dumps a large file).

    The cap is intentionally generous (64 KB): it guards against
    runaway allocations, not against context window pressure.
    OAS handles context-level truncation via its compression phases.

    @since #5807 — originally JSON-aware; simplified to boundary-
    respecting cap in #5821. *)

(* ── Cap ────────────────────────────────────────────────────── *)

(** Hard cap: any tool output beyond this is an OOM risk, not a
    context budget concern.  64 KB covers any reasonable structured
    result while preventing multi-MB shell dumps from persisting
    in the message list. *)
let max_output_chars = Common.max_tool_output_bytes

let cap (output : string) : string =
  let len = String.length output in
  if len <= max_output_chars then output
  else
    let kept = String.sub output 0 max_output_chars in
    Printf.sprintf "%s\n[capped: %d/%d chars]" kept max_output_chars len

(* ── Result transformer for Tool_dispatch ───────────────────── *)

let transform_result (result : Tool_result.result) : Tool_result.result =
  let cap_data (data : Yojson.Safe.t) : Yojson.Safe.t option =
    match data with
    | `String s when String.length s > max_output_chars ->
      Some (`String (cap s))
    | `List _ | `Assoc _ ->
      let serialized = Yojson.Safe.to_string data in
      if String.length serialized <= max_output_chars then None
      else Some (`String (cap serialized))
    | _ -> None
  in
  match result with
  | Tool_result.Completed output ->
    (match cap_data output.data with
     | Some data -> Tool_result.Completed { output with data }
     | None -> result)
  | Tool_result.Deferred output ->
    (match cap_data output.data with
     | Some data -> Tool_result.Deferred { output with data }
     | None -> result)
  | Tool_result.Failed err ->
    (match cap_data err.data with
     | Some data -> Tool_result.Failed { err with data }
     | None -> result)

(* ── Installation ───────────────────────────────────────────── *)

let installed = Atomic.make false

let install () =
  if not (Atomic.get installed) then begin
    (* Keep output capping in the transformer step so dispatch observers
       remain observer-only. *)
    Tool_dispatch.set_result_transformer transform_result;
    Atomic.set installed true
  end
