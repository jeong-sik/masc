(** Structured Logging — level-based structured log system.

    Provides typed log records with key-value fields, composable sinks,
    and zero-cost filtering for disabled levels.

    Design:
    - [sink] is [record -> unit] — composable and lightweight.
    - [field] is a closed variant for schema enforcement at call sites.
    - [J] acts as an escape hatch for arbitrary JSON payloads.
    - Disabled levels skip record allocation entirely.
    - [trace_id]/[span_id] are optional for OTel span correlation. *)

(* ── Level ────────────────────────────────────────────────────── *)

type level =
  | Debug
  | Info
  | Warn
  | Error

let level_to_int = function
  | Debug -> 0
  | Info -> 1
  | Warn -> 2
  | Error -> 3
;;

let level_to_string = function
  | Debug -> "debug"
  | Info -> "info"
  | Warn -> "warn"
  | Error -> "error"
;;

let level_of_string = function
  | "debug" -> Ok Debug
  | "info" -> Ok Info
  | "warn" -> Ok Warn
  | "error" -> Ok Error
  | s -> Error (Printf.sprintf "unknown log level: %s" s)
;;

let level_to_yojson l = `String (level_to_string l)

let level_of_yojson = function
  | `String s ->
    (match level_of_string s with
     | Ok l -> Ok l
     | Error msg -> Error msg)
  | _ -> Error "expected string for log level"
;;

let pp_level fmt l = Format.fprintf fmt "%s" (level_to_string l)
let show_level = level_to_string

(* ── Field ────────────────────────────────────────────────────── *)

type field =
  | S of string * string
  | I of string * int
  | F of string * float
  | B of string * bool
  | J of string * Yojson.Safe.t
  | Secret of string * Llm_provider.Secret.t

let field_to_json = function
  | S (k, v) -> k, `String v
  | I (k, v) -> k, `Int v
  | F (k, v) -> k, `Float v
  | B (k, v) -> k, `Bool v
  | J (k, v) -> k, v
  | Secret (k, _) -> k, `String "<redacted>"
;;

let redact = Llm_provider.Secret_redactor.redact_string

let redact_field_value = function
  | S (k, v) -> S (k, redact v)
  | J (k, v) -> J (k, Llm_provider.Secret_redactor.redact_json v)
  | (I _ | F _ | B _ | Secret _) as f -> f
;;

(* ── Record ───────────────────────────────────────────────────── *)

type record =
  { ts : float
  ; level : level
  ; module_name : string
  ; message : string
  ; fields : field list
  ; trace_id : string option
  ; span_id : string option
  }

let record_to_json r =
  let base =
    [ "ts", `Float r.ts
    ; "level", level_to_yojson r.level
    ; "module", `String r.module_name
    ; "msg", `String r.message
    ]
  in
  let fields_json = List.map field_to_json r.fields in
  let trace =
    match r.trace_id with
    | Some id -> [ "trace_id", `String id ]
    | None -> []
  in
  let span =
    match r.span_id with
    | Some id -> [ "span_id", `String id ]
    | None -> []
  in
  `Assoc (base @ fields_json @ trace @ span)
;;

(* ── Sink ─────────────────────────────────────────────────────── *)

type sink = record -> unit

(* ── Global state ─────────────────────────────────────────────── *)

(* Global logger configuration is shared across domains.
   Atomic.t keeps reads lock-free. [add_sink] linearizes through a CAS
   loop. [clear_sinks] first resets the no-sink drop counter, then
   publishes an empty sink set with an atomic store. When [add_sink] and
   [clear_sinks] race, the final sink set reflects whichever sink-set
   operation linearizes last; records emitted after the counter reset can
   still be counted if they observe no sinks. *)
let global_level = Atomic.make Info
let global_sinks : sink list Atomic.t = Atomic.make []
let dropped_without_sink = Atomic.make 0

let rec atomic_update atom ~f =
  let current = Atomic.get atom in
  let next = f current in
  if not (Atomic.compare_and_set atom current next) then atomic_update atom ~f
;;

let set_global_level level = Atomic.set global_level level
let add_sink sink = atomic_update global_sinks ~f:(fun sinks -> sink :: sinks)

let clear_sinks () =
  Atomic.set dropped_without_sink 0;
  Atomic.set global_sinks []
;;

let dropped_without_sink_count () = Atomic.get dropped_without_sink

(* ── Logger instance ──────────────────────────────────────────── *)

type t =
  { module_name : string
  ; trace_id : string option
  ; span_id : string option
  }

let create ~module_name () = { module_name; trace_id = None; span_id = None }
let with_trace_id t ~trace_id = { t with trace_id = Some trace_id }
let with_span_id t ~span_id = { t with span_id = Some span_id }

(* ── Core emit ────────────────────────────────────────────────── *)

let emit t level message fields =
  (* Zero-cost: skip record allocation if level is below threshold *)
  if level_to_int level >= level_to_int (Atomic.get global_level)
  then (
    match Atomic.get global_sinks with
    | [] -> ignore (Atomic.fetch_and_add dropped_without_sink 1 : int)
    | sinks ->
      let record =
        { ts = Unix.gettimeofday ()
        ; level
        ; module_name = t.module_name
        ; message
        ; fields
        ; trace_id = t.trace_id
        ; span_id = t.span_id
        }
      in
      List.iter (fun sink -> sink record) sinks)
;;

let debug t message fields = emit t Debug message fields
let info t message fields = emit t Info message fields
let warn t message fields = emit t Warn message fields
let error t message fields = emit t Error message fields

(* ── Built-in sinks ──────────────────────────────────────────── *)

let json_sink (flow : _ Eio.Flow.sink) : sink =
  fun record ->
  let record =
    { record with
      message = redact record.message
    ; fields = List.map redact_field_value record.fields
    }
  in
  let json = record_to_json record in
  let line = Yojson.Safe.to_string json ^ "\n" in
  Eio.Flow.copy_string line flow
;;

let stderr_sink () : sink =
  fun record ->
  let ts_str =
    let t = Unix.gmtime record.ts in
    Printf.sprintf
      "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (t.tm_year + 1900)
      (t.tm_mon + 1)
      t.tm_mday
      t.tm_hour
      t.tm_min
      t.tm_sec
  in
  let fields = List.map redact_field_value record.fields in
  let fields_str =
    match fields with
    | [] -> ""
    | fs ->
      let parts =
        List.map
          (fun f ->
             let k, v = field_to_json f in
             Printf.sprintf "%s=%s" k (Yojson.Safe.to_string v))
          fs
      in
      " " ^ String.concat " " parts
  in
  Printf.eprintf
    "%s [%s] %s: %s%s\n%!"
    ts_str
    (level_to_string record.level)
    record.module_name
    (redact record.message)
    fields_str
;;

(* ── Collector sink (for testing) ─────────────────────────────── *)

let collector_sink () : sink * (unit -> record list) =
  let records = Atomic.make [] in
  let sink record = atomic_update records ~f:(fun rs -> record :: rs) in
  let get () = List.rev (Atomic.get records) in
  sink, get
;;
