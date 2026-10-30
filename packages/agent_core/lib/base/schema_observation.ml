type object_id = int64
type mode = Disabled | Identity_only | Timed
type completion = Returned | Returned_error | Raised | Cancelled
type site =
  | Bridge_plain_constructor | Bridge_execution_env_constructor
  | Sdk_prepare_json | Sdk_wire_json | Sdk_byte_count_lookup
  | Sdk_byte_count_encode | Sdk_byte_count_publication
  | Reserve_encode | Prefix_digest_encode | Prompt_metrics_encode | Provider_snapshot_encode
  | Phase0_bytes | Final_attribution_bytes
  | Built_surface | Agent_core_surface | Request_surface
  | Worker_queue_and_await | Worker_work
type json_lookup = Existing_json | Created_json
type byte_lookup = Existing_byte_count | Missing_byte_count
type publication = Published_byte_count | Concurrent_byte_count_won
type cache_outcome =
  | Json_lookup of json_lookup
  | Byte_lookup of { json : json_lookup; count : byte_lookup }
  | Byte_publication of publication

type wake =
  { wake_id : object_id; keeper : string; trace_id : string; absolute_turn : int
  ; execution_scope : string option; cause : string option }
type attempt =
  { routing_run_id : string; lane_attempt_index : int; runtime_id : string }
type provider_turn = { candidate_id : object_id; ordinal : int }
type definition = { descriptor_id : object_id; addon_owner_id : object_id option }
type scope =
  { observer_id : object_id; wake : wake option; attempt : attempt option
  ; provider_turn : provider_turn option; definition : definition option
  ; parent_site : site option }
type measurement =
  { started_ns : int64; finished_ns : int64; elapsed_ns : int64
  ; entry_domain : int; exit_domain : int; allocated_bytes : float option }
type operation_kind = Measured | Constructor | Encoding
type payload =
  | Span_started of
      { span_id : object_id; operation_kind : operation_kind
      ; site : site; schema_id : object_id option }
  | Span_finished of
      { span_id : object_id; operation_kind : operation_kind
      ; site : site; schema_id : object_id option
      ; completion : completion; byte_count : int option
      ; measurement : measurement option }
  | Surface of { site : site; schema_ids : object_id option list }
  | Cache of { schema_id : object_id option; outcome : cache_outcome }
type event = { sequence : int; scope : scope; payload : payload }
type bookkeeping =
  { calls : int; elapsed_ns : int64; allocated_bytes : float }
type report =
  { report_observer_id : object_id; report_mode : mode
  ; clock_origin_ns : int64 option; failures : int; active_spans : int
  ; probe_calls : int; bookkeeping : bookkeeping; events : event list }
type t =
  { id : object_id; mode : mode; origin : int64 option
  ; mutex : Stdlib.Mutex.t; failures_count : int Atomic.t
  ; probes : int Atomic.t; mutable sequence : int; mutable active : int
  ; mutable work : bookkeeping; mutable events_rev : event list }
type binding = { owner : t; scope : scope }

let next_identity = ref 0L
let identity_mutex = Stdlib.Mutex.create ()
let allocate_identity () =
  Stdlib.Mutex.protect identity_mutex (fun () ->
    if !next_identity = Int64.max_int then None
    else (next_identity := Int64.succ !next_identity; Some !next_identity))
;;

let binding_key : binding Eio.Fiber.key = Eio.Fiber.create_key ()
(* Monotonic: an inherited or captured child may still own a binding after its
   parent's [within] returns. Disabled never flips this guard. *)
let ever_bound = Atomic.make false
let binding_opt () =
  (* This catch surrounds only the diagnostic key read, never product work. *)
  if not (Atomic.get ever_bound) then None
  else try Eio.Fiber.get binding_key with Effect.Unhandled _ -> None
;;
let empty_scope observer_id =
  { observer_id; wake = None; attempt = None; provider_turn = None
  ; definition = None; parent_site = None }
;;
let failed owner = Atomic.incr owner.failures_count
let diagnostic owner fallback operation =
  match operation () with
  | value -> value
  | exception error ->
    Llm_provider.Reserved_exn.reraise_if_reserved error;
    failed owner;
    fallback
;;
let domain_id () = (Domain.self () :> int)
let finite_nonnegative value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> value >= 0.
  | FP_infinite | FP_nan -> false
;;

let create ~mode =
  let id = match allocate_identity () with
    | Some id -> id
    | None -> invalid_arg "schema observation identity space exhausted" in
  let failures_count = Atomic.make 0 in
  let origin = match mode with
    | Disabled | Identity_only -> None
    | Timed ->
      (try Some (Mtime_clock.now_ns ()) with
       | Sys_error _ -> Atomic.incr failures_count; None) in
  { id; mode; origin; mutex = Stdlib.Mutex.create (); failures_count
  ; probes = Atomic.make 0; sequence = 0; active = 0
  ; work = { calls = 0; elapsed_ns = 0L; allocated_bytes = 0. }
  ; events_rev = [] }
;;

let within owner operation =
  match owner.mode with
  | Disabled ->
    (match binding_opt () with
     | None -> operation ()
     | Some _ -> Eio.Fiber.without_binding binding_key operation)
  | Identity_only | Timed ->
    Atomic.set ever_bound true;
    Eio.Fiber.with_binding binding_key
      { owner; scope = empty_scope owner.id } operation
;;
let enabled () = Option.is_some (binding_opt ())
let object_id_to_string = Int64.to_string

(* This estimate excludes its own final aggregate update and probe costs. The
   report exposes probe count and states these limits, rather than subtracting
   a calibration constant from product durations. *)
let bookkeeping owner fallback operation =
  match owner.mode with
  | Disabled -> fallback
  | Identity_only -> diagnostic owner fallback (fun () ->
      let value = operation () in
      Stdlib.Mutex.protect owner.mutex (fun () ->
        owner.work <- {owner.work with calls = owner.work.calls + 1});
      value)
  | Timed ->
    diagnostic owner fallback (fun () ->
      Atomic.incr owner.probes;
      let start_domain = domain_id () in
      let start_bytes = Gc.allocated_bytes () in
      let start_ns = Mtime_clock.now_ns () in
      let value = operation () in
      let finish_ns = Mtime_clock.now_ns () in
      let finish_bytes = Gc.allocated_bytes () in
      Atomic.incr owner.probes;
      let elapsed = Int64.sub finish_ns start_ns in
      let allocated = finish_bytes -. start_bytes in
      if elapsed >= 0L && start_domain = domain_id ()
         && finite_nonnegative allocated then
        Stdlib.Mutex.protect owner.mutex (fun () ->
          owner.work <-
            { calls = owner.work.calls + 1
            ; elapsed_ns = Int64.add owner.work.elapsed_ns elapsed
            ; allocated_bytes = owner.work.allocated_bytes +. allocated })
      else failed owner;
      value)
;;

let new_id owner =
  match allocate_identity () with
  | Some _ as id -> id
  | None -> failed owner; None
;;
let observer_work operation =
  match binding_opt () with
  | None -> None
  | Some {owner; _} -> bookkeeping owner None operation
;;
let fresh_object_id () =
  match binding_opt () with
  | None -> None
  | Some { owner; _ } -> bookkeeping owner None (fun () -> new_id owner)
;;

module Schema_ids = Ephemeron.K1.Make (struct
  type t = Types.tool_schema
  let equal = ( == )
  let hash (value : t) = Hashtbl.hash value.name
end)
let schema_ids = Schema_ids.create 0
let schema_ids_mutex = Stdlib.Mutex.create ()
let identify_schema owner key =
  bookkeeping owner None (fun () ->
    let found = Stdlib.Mutex.protect schema_ids_mutex (fun () ->
      Schema_ids.find_opt schema_ids key) in
    match found with
    | Some _ as id -> id
    | None ->
      (match new_id owner with
       | None -> None
       | Some fresh ->
         Stdlib.Mutex.protect schema_ids_mutex (fun () ->
           match Schema_ids.find_opt schema_ids key with
           | Some winner -> Some winner
           | None -> Schema_ids.add schema_ids key fresh; Some fresh)))
;;
let schema key =
  match binding_opt () with
  | None -> None
  | Some { owner; _ } -> identify_schema owner key
;;

let change_scope transform operation =
  match binding_opt () with
  | None -> operation ()
  | Some binding ->
    let scope = diagnostic binding.owner (empty_scope binding.owner.id)
        (fun () -> transform binding.owner binding.scope) in
    Eio.Fiber.with_binding binding_key { binding with scope } operation
;;
let with_wake ~keeper ~trace_id ~absolute_turn ~execution_scope ~cause operation =
  change_scope (fun owner scope ->
    match new_id owner with
    | None -> empty_scope scope.observer_id
    | Some wake_id ->
      { (empty_scope scope.observer_id) with
        wake = Some {wake_id; keeper; trace_id; absolute_turn; execution_scope; cause} }) operation
;;
let with_attempt ~routing_run_id ~lane_attempt_index ~runtime_id operation =
  change_scope (fun _ scope ->
    { scope with attempt = Some {routing_run_id; lane_attempt_index; runtime_id}
    ; provider_turn = None; definition = None; parent_site = None }) operation
;;
let with_provider_turn ~ordinal operation =
  change_scope (fun owner scope ->
    let provider_turn = Option.map (fun candidate_id -> {candidate_id; ordinal})
        (new_id owner) in
    { scope with provider_turn; definition = None }) operation
;;
let with_definition ~descriptor_id ~addon_owner_id operation =
  change_scope (fun _ scope ->
    {scope with definition = Some {descriptor_id; addon_owner_id}}) operation
;;
let with_site site operation =
  change_scope (fun _ scope -> {scope with parent_site = Some site}) operation
;;
let current_scope () = Option.map (fun binding -> binding.scope) (binding_opt ())
let with_scope scope operation =
  match binding_opt () with
  | None -> operation ()
  | Some binding ->
    let scope = if scope.observer_id = binding.owner.id then scope else (
      failed binding.owner; empty_scope binding.owner.id) in
    Eio.Fiber.with_binding binding_key {binding with scope} operation
;;
let capture operation =
  match binding_opt () with
  | None -> operation
  | Some binding -> fun () -> Eio.Fiber.with_binding binding_key binding operation
;;

let emit binding payload =
  bookkeeping binding.owner false (fun () ->
    Stdlib.Mutex.protect binding.owner.mutex (fun () ->
      binding.owner.sequence <- binding.owner.sequence + 1;
      let event = {sequence = binding.owner.sequence; scope = binding.scope; payload} in
      binding.owner.events_rev <- event :: binding.owner.events_rev;
      (match payload with
       | Span_started _ -> binding.owner.active <- binding.owner.active + 1
       | Span_finished _ -> binding.owner.active <- binding.owner.active - 1
       | Surface _ | Cache _ -> ());
      true))
;;

type probe = { ns : int64; domain : int; bytes : float }
let probe owner =
  match owner.mode with
  | Disabled | Identity_only -> None
  | Timed -> diagnostic owner None (fun () ->
      Atomic.incr owner.probes;
      let ns = Mtime_clock.now_ns () in
      let domain = domain_id () in
      let bytes = Gc.allocated_bytes () in
      Some {ns; domain; bytes})
;;
let measurement owner before after =
  match before, after with
  | Some before, Some after ->
    let elapsed_ns = Int64.sub after.ns before.ns in
    if elapsed_ns < 0L then (failed owner; None)
    else
      let allocated = after.bytes -. before.bytes in
      let allocated_bytes =
        if before.domain = after.domain && finite_nonnegative allocated
        then Some allocated else None in
      Some {started_ns = before.ns; finished_ns = after.ns; elapsed_ns
           ; entry_domain = before.domain; exit_domain = after.domain; allocated_bytes}
  | None, None | None, Some _ | Some _, None -> None
;;

let observe_operation ~operation_kind ~site ?key classify operation =
  match binding_opt () with
  | None -> operation ()
  | Some binding ->
    let schema_id = Option.bind key (identify_schema binding.owner) in
    let span_id = bookkeeping binding.owner None (fun () -> new_id binding.owner) in
    let started = match span_id with
      | None -> false
      | Some span_id -> emit binding (Span_started {span_id; operation_kind; site; schema_id}) in
    let before = probe binding.owner in
    match operation () with
    | value ->
      let after = probe binding.owner in
      let completion, returned_key, byte_count = classify value in
      let returned_schema_id = match returned_key with
        | None -> schema_id
        | Some returned -> identify_schema binding.owner returned in
      (match started, span_id with
       | true, Some span_id ->
         ignore (emit binding (Span_finished
           {span_id; operation_kind; site; schema_id = returned_schema_id; completion; byte_count
           ; measurement = measurement binding.owner before after}))
       | false, (None | Some _) | true, None -> ());
      value
    | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      let after = probe binding.owner in
      let completion = match error with Eio.Cancel.Cancelled _ -> Cancelled | _ -> Raised in
      (match started, span_id with
       | true, Some span_id ->
         ignore (emit binding (Span_finished
           {span_id; operation_kind; site; schema_id; completion; byte_count = None
           ; measurement = measurement binding.owner before after}))
       | false, (None | Some _) | true, None -> ());
      Printexc.raise_with_backtrace error backtrace
;;
let measure ~site ?schema operation =
  observe_operation ~operation_kind:Measured ~site ?key:schema
    (fun _ -> Returned, None, None) operation
;;
let constructor ~site operation =
  observe_operation ~operation_kind:Constructor ~site (function
    | Ok key -> Returned, Some key, None
    | Error _ -> Returned_error, None, None) operation
;;
let encode ~site ~schema operation =
  observe_operation ~operation_kind:Encoding ~site ~key:schema
    (fun bytes -> Returned, None, Some (String.length bytes)) operation
;;
let surface ~site keys =
  match binding_opt () with
  | None -> ()
  | Some binding ->
    diagnostic binding.owner () (fun () ->
      let schema_ids = List.map (identify_schema binding.owner) (keys ()) in
      ignore (emit binding (Surface {site; schema_ids})))
;;
let cache ~schema outcome =
  match binding_opt () with
  | None -> ()
  | Some binding ->
    let schema_id = identify_schema binding.owner schema in
    ignore (emit binding (Cache {schema_id; outcome}))
;;

let snapshot owner =
  let active_spans, bookkeeping, events =
    Stdlib.Mutex.protect owner.mutex (fun () ->
      owner.active, owner.work, List.rev owner.events_rev) in
  {report_observer_id = owner.id; report_mode = owner.mode; clock_origin_ns = owner.origin
  ; failures = Atomic.get owner.failures_count; active_spans
  ; probe_calls = Atomic.get owner.probes; bookkeeping; events}
;;

let mode_name = function Disabled -> "disabled" | Identity_only -> "identity_only" | Timed -> "timed"
let completion_name = function
  | Returned -> "returned" | Returned_error -> "returned_error"
  | Raised -> "raised" | Cancelled -> "cancelled"
let site_name = function
  | Bridge_plain_constructor -> "bridge_plain_constructor"
  | Bridge_execution_env_constructor -> "bridge_execution_env_constructor"
  | Sdk_prepare_json -> "sdk_prepare_json" | Sdk_wire_json -> "sdk_wire_json"
  | Sdk_byte_count_lookup -> "sdk_byte_count_lookup"
  | Sdk_byte_count_encode -> "sdk_byte_count_encode"
  | Sdk_byte_count_publication -> "sdk_byte_count_publication"
  | Reserve_encode -> "reserve_encode" | Prefix_digest_encode -> "prefix_digest_encode"
  | Prompt_metrics_encode -> "prompt_metrics_encode"
  | Provider_snapshot_encode -> "provider_snapshot_encode"
  | Phase0_bytes -> "phase0_bytes" | Final_attribution_bytes -> "final_attribution_bytes"
  | Built_surface -> "built_surface" | Agent_core_surface -> "agent_core_surface"
  | Request_surface -> "request_surface" | Worker_queue_and_await -> "worker_queue_and_await"
  | Worker_work -> "worker_work"
let option_json encode = function None -> `Null | Some value -> encode value
let id_json value = `String (Int64.to_string value)
let string_json value = `String value
let int_json value = `Int value
let wake_json wake =
  `Assoc ["wake_id", id_json wake.wake_id; "keeper", `String wake.keeper
    ; "trace_id", `String wake.trace_id; "absolute_turn", `Int wake.absolute_turn
    ; "execution_scope", option_json string_json wake.execution_scope
    ; "cause", option_json string_json wake.cause]
let attempt_json attempt =
  `Assoc ["routing_run_id", `String attempt.routing_run_id
    ; "lane_attempt_index", `Int attempt.lane_attempt_index; "runtime_id", `String attempt.runtime_id]
let provider_turn_json turn =
  `Assoc ["candidate_id", id_json turn.candidate_id; "ordinal", `Int turn.ordinal]
let definition_json definition =
  `Assoc ["descriptor_id", id_json definition.descriptor_id
    ; "addon_owner_id", option_json id_json definition.addon_owner_id]
let scope_to_json scope =
  `Assoc ["observer_id", id_json scope.observer_id; "wake", option_json wake_json scope.wake
    ; "attempt", option_json attempt_json scope.attempt
    ; "provider_turn", option_json provider_turn_json scope.provider_turn
    ; "definition", option_json definition_json scope.definition
    ; "parent_site", option_json (fun site -> `String (site_name site)) scope.parent_site]
let measurement_json measurement =
  `Assoc ["started_ns", id_json measurement.started_ns; "finished_ns", id_json measurement.finished_ns
    ; "elapsed_ns", id_json measurement.elapsed_ns; "entry_domain", `Int measurement.entry_domain
    ; "exit_domain", `Int measurement.exit_domain
    ; "calling_domain_allocated_bytes", option_json (fun n -> `Float n) measurement.allocated_bytes]
let json_lookup_name = function Existing_json -> "existing_json" | Created_json -> "created_json"
let cache_json = function
  | Json_lookup outcome ->
    `Assoc ["kind", `String "json_lookup"; "json", `String (json_lookup_name outcome)]
  | Byte_lookup {json; count} ->
    `Assoc ["kind", `String "byte_lookup"; "json", `String (json_lookup_name json)
      ; "count", `String (match count with Existing_byte_count -> "existing_byte_count" | Missing_byte_count -> "missing_byte_count")]
  | Byte_publication outcome ->
    `Assoc ["kind", `String "byte_publication"
      ; "publication", `String (match outcome with Published_byte_count -> "published_byte_count" | Concurrent_byte_count_won -> "concurrent_byte_count_won")]
let operation_kind_name = function
  | Measured -> "measured" | Constructor -> "constructor" | Encoding -> "encoding"
let payload_json = function
  | Span_started {span_id; operation_kind; site; schema_id} ->
    `Assoc ["kind", `String "span_started"; "span_id", id_json span_id
      ; "operation", `String (operation_kind_name operation_kind)
      ; "site", `String (site_name site); "schema_id", option_json id_json schema_id]
  | Span_finished {span_id; operation_kind; site; schema_id; completion; byte_count; measurement} ->
    `Assoc ["kind", `String "span_finished"; "span_id", id_json span_id
      ; "operation", `String (operation_kind_name operation_kind)
      ; "site", `String (site_name site); "schema_id", option_json id_json schema_id
      ; "completion", `String (completion_name completion); "byte_count", option_json int_json byte_count
      ; "measurement", option_json measurement_json measurement]
  | Surface {site; schema_ids} ->
    `Assoc ["kind", `String "surface"; "site", `String (site_name site)
      ; "schema_ids", `List (List.map (option_json id_json) schema_ids)]
  | Cache {schema_id; outcome} ->
    `Assoc ["kind", `String "cache"; "schema_id", option_json id_json schema_id; "outcome", cache_json outcome]
let event_json (event : event) =
  `Assoc ["sequence", `Int event.sequence; "scope", scope_to_json event.scope; "payload", payload_json event.payload]
let allocation_scope = "calling_domain_interval_not_process_or_exclusive_operation"
let overhead_scope = "bookkeeping_estimate_inclusive_nested_calls_excludes_its_probes_and_final_update_and_report_io"
let report_header_fields report =
  ["schema_version", `Int 1; "observer_id", id_json report.report_observer_id
    ; "mode", `String (mode_name report.report_mode)
    ; "clock_origin_ns", option_json id_json report.clock_origin_ns
    ; "clock_domain", `String "process_monotonic_ns"
    ; "allocation_scope", `String allocation_scope; "overhead_scope", `String overhead_scope
    ; "coverage", `String (if report.failures = 0 && report.active_spans = 0 then "complete" else "incomplete")
    ; "failures", `Int report.failures; "active_spans", `Int report.active_spans
    ; "probe_calls", `Int report.probe_calls
    ; "bookkeeping", `Assoc ["calls", `Int report.bookkeeping.calls
      ; "elapsed_ns", id_json report.bookkeeping.elapsed_ns
      ; "calling_domain_allocated_bytes", `Float report.bookkeeping.allocated_bytes]]
;;

let events_field = "events"

let report_to_json report =
  `Assoc (report_header_fields report
    @ [events_field, `List (List.map event_json report.events)])
;;

let write_report_json ~write report =
  let json value = write (Yojson.Safe.to_string value) in
  write "{";
  List.iter (fun (name, value) ->
    json (`String name);
    write ":";
    json value;
    write ",") (report_header_fields report);
  json (`String events_field);
  write ":[";
  let first = ref true in
  List.iter (fun event ->
    if !first then first := false else write ",";
    json (event_json event)) report.events;
  write "]}\n"
;;

(* Strict inverse. Field equality rejects duplicates as well as unknown fields. *)
open Result.Syntax
let fields expected = function
  | `Assoc values when List.sort String.compare (List.map fst values) = List.sort String.compare expected -> Ok values
  | _ -> Error "schema observation object has missing, duplicate or unknown fields"
let get = List.assoc
let string = function `String value -> Ok value | _ -> Error "expected string"
let nonempty json = let* value = string json in if value = "" then Error "empty identity" else Ok value
let integer = function `Int value when value >= 0 -> Ok value | _ -> Error "expected nonnegative integer"
let int64 json =
  let* text = string json in
  match Int64.of_string_opt text with
  | Some value when Int64.to_string value = text -> Ok value
  | Some _ | None -> Error "expected canonical int64 decimal string"
let positive_id json = let* value = int64 json in if value > 0L then Ok value else Error "expected positive identity"
let nonnegative_ns json = let* value = int64 json in if value >= 0L then Ok value else Error "negative duration"
let number = function
  | `Float value when finite_nonnegative value -> Ok value
  | `Int value when value >= 0 -> Ok (float_of_int value)
  | _ -> Error "expected finite nonnegative number"
let optional decode = function `Null -> Ok None | json -> Result.map Option.some (decode json)
let decode_list decode values =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest -> let* value = decode value in loop (value :: reversed) rest
  in
  loop [] values
let list decode = function `List values -> decode_list decode values | _ -> Error "expected list"
let mode_of_json = function
  | `String "disabled" -> Ok Disabled | `String "identity_only" -> Ok Identity_only
  | `String "timed" -> Ok Timed | _ -> Error "unknown observer mode"
let completion_of_json = function
  | `String "returned" -> Ok Returned | `String "returned_error" -> Ok Returned_error
  | `String "raised" -> Ok Raised | `String "cancelled" -> Ok Cancelled
  | _ -> Error "unknown completion"
let operation_kind_of_json = function
  | `String "measured" -> Ok Measured | `String "constructor" -> Ok Constructor
  | `String "encoding" -> Ok Encoding | _ -> Error "unknown measured operation"
let site_of_json = function
  | `String "bridge_plain_constructor" -> Ok Bridge_plain_constructor
  | `String "bridge_execution_env_constructor" -> Ok Bridge_execution_env_constructor
  | `String "sdk_prepare_json" -> Ok Sdk_prepare_json | `String "sdk_wire_json" -> Ok Sdk_wire_json
  | `String "sdk_byte_count_lookup" -> Ok Sdk_byte_count_lookup
  | `String "sdk_byte_count_encode" -> Ok Sdk_byte_count_encode
  | `String "sdk_byte_count_publication" -> Ok Sdk_byte_count_publication
  | `String "reserve_encode" -> Ok Reserve_encode | `String "prefix_digest_encode" -> Ok Prefix_digest_encode
  | `String "prompt_metrics_encode" -> Ok Prompt_metrics_encode
  | `String "provider_snapshot_encode" -> Ok Provider_snapshot_encode
  | `String "phase0_bytes" -> Ok Phase0_bytes | `String "final_attribution_bytes" -> Ok Final_attribution_bytes
  | `String "built_surface" -> Ok Built_surface | `String "agent_core_surface" -> Ok Agent_core_surface
  | `String "request_surface" -> Ok Request_surface
  | `String "worker_queue_and_await" -> Ok Worker_queue_and_await | `String "worker_work" -> Ok Worker_work
  | _ -> Error "unknown observation site"
let wake_of_json json =
  let* f = fields ["wake_id"; "keeper"; "trace_id"; "absolute_turn"; "execution_scope"; "cause"] json in
  let* wake_id = positive_id (get "wake_id" f) in
  let* keeper = nonempty (get "keeper" f) in let* trace_id = nonempty (get "trace_id" f) in
  let* absolute_turn = integer (get "absolute_turn" f) in
  let* execution_scope = optional nonempty (get "execution_scope" f) in
  let* cause = optional nonempty (get "cause" f) in
  if absolute_turn = 0 then Error "original absolute turn must be positive"
  else Ok {wake_id; keeper; trace_id; absolute_turn; execution_scope; cause}
let attempt_of_json json =
  let* f = fields ["routing_run_id"; "lane_attempt_index"; "runtime_id"] json in
  let* routing_run_id = nonempty (get "routing_run_id" f) in
  let* lane_attempt_index = integer (get "lane_attempt_index" f) in
  let* runtime_id = nonempty (get "runtime_id" f) in Ok {routing_run_id; lane_attempt_index; runtime_id}
let provider_turn_of_json json =
  let* f = fields ["candidate_id"; "ordinal"] json in
  let* candidate_id = positive_id (get "candidate_id" f) in let* ordinal = integer (get "ordinal" f) in
  Ok {candidate_id; ordinal}
let definition_of_json json =
  let* f = fields ["descriptor_id"; "addon_owner_id"] json in
  let* descriptor_id = positive_id (get "descriptor_id" f) in
  let* addon_owner_id = optional positive_id (get "addon_owner_id" f) in Ok {descriptor_id; addon_owner_id}
let scope_of_json json =
  let* f = fields ["observer_id"; "wake"; "attempt"; "provider_turn"; "definition"; "parent_site"] json in
  let* observer_id = positive_id (get "observer_id" f) in
  let* wake = optional wake_of_json (get "wake" f) in
  let* attempt = optional attempt_of_json (get "attempt" f) in
  let* provider_turn = optional provider_turn_of_json (get "provider_turn" f) in
  let* definition = optional definition_of_json (get "definition" f) in
  let* parent_site = optional site_of_json (get "parent_site" f) in
  Ok {observer_id; wake; attempt; provider_turn; definition; parent_site}
let measurement_of_json json =
  let* f = fields ["started_ns"; "finished_ns"; "elapsed_ns"; "entry_domain"; "exit_domain"; "calling_domain_allocated_bytes"] json in
  let* started_ns = int64 (get "started_ns" f) in let* finished_ns = int64 (get "finished_ns" f) in
  let* elapsed_ns = nonnegative_ns (get "elapsed_ns" f) in
  let* entry_domain = integer (get "entry_domain" f) in let* exit_domain = integer (get "exit_domain" f) in
  let* allocated_bytes = optional number (get "calling_domain_allocated_bytes" f) in
  if Int64.sub finished_ns started_ns <> elapsed_ns then Error "contradictory monotonic duration"
  else if entry_domain <> exit_domain && Option.is_some allocated_bytes then Error "allocation crosses domains"
  else Ok {started_ns; finished_ns; elapsed_ns; entry_domain; exit_domain; allocated_bytes}
let json_lookup_of_json = function
  | `String "existing_json" -> Ok Existing_json | `String "created_json" -> Ok Created_json
  | _ -> Error "unknown JSON lookup outcome"
let cache_of_json json =
  match json with
  | `Assoc values ->
    (match List.assoc_opt "kind" values with
     | Some (`String "json_lookup") ->
       let* f = fields ["kind"; "json"] json in
       Result.map (fun outcome -> Json_lookup outcome) (json_lookup_of_json (get "json" f))
     | Some (`String "byte_lookup") ->
       let* f = fields ["kind"; "json"; "count"] json in
       let* json = json_lookup_of_json (get "json" f) in
       let* count = match get "count" f with
         | `String "existing_byte_count" -> Ok Existing_byte_count
         | `String "missing_byte_count" -> Ok Missing_byte_count
         | _ -> Error "unknown byte-count lookup outcome" in
       if json = Created_json && count = Existing_byte_count then Error "new JSON already has byte count"
       else Ok (Byte_lookup {json; count})
     | Some (`String "byte_publication") ->
       let* f = fields ["kind"; "publication"] json in
       let* outcome = match get "publication" f with
         | `String "published_byte_count" -> Ok Published_byte_count
         | `String "concurrent_byte_count_won" -> Ok Concurrent_byte_count_won
         | _ -> Error "unknown byte-count publication outcome" in Ok (Byte_publication outcome)
     | Some _ | None -> Error "unknown cache outcome")
  | _ -> Error "expected cache outcome object"
let payload_of_json json =
  match json with
  | `Assoc values ->
    (match List.assoc_opt "kind" values with
     | Some (`String "span_started") ->
       let* f = fields ["kind"; "span_id"; "operation"; "site"; "schema_id"] json in
       let* operation_kind = operation_kind_of_json (get "operation" f) in
       let* span_id = positive_id (get "span_id" f) in let* site = site_of_json (get "site" f) in
       let* schema_id = optional positive_id (get "schema_id" f) in
       if operation_kind = Constructor && Option.is_some schema_id then Error "constructor entry already has a schema"
       else Ok (Span_started {span_id; operation_kind; site; schema_id})
     | Some (`String "span_finished") ->
       let* f = fields ["kind"; "span_id"; "operation"; "site"; "schema_id"; "completion"; "byte_count"; "measurement"] json in
       let* operation_kind = operation_kind_of_json (get "operation" f) in
       let* span_id = positive_id (get "span_id" f) in let* site = site_of_json (get "site" f) in
       let* schema_id = optional positive_id (get "schema_id" f) in
       let* completion = completion_of_json (get "completion" f) in
       let* byte_count = optional integer (get "byte_count" f) in
       let* measurement = optional measurement_of_json (get "measurement" f) in
       if operation_kind <> Constructor && completion = Returned_error then Error "non-constructor claims returned error"
       else if operation_kind = Constructor && completion <> Returned && Option.is_some schema_id then
         Error "failed constructor claims returned schema"
       else if operation_kind <> Encoding && Option.is_some byte_count then Error "non-encoder claims encoded bytes"
       else if operation_kind = Encoding && completion = Returned && Option.is_none byte_count then Error "returned encoder has no byte count"
       else (match completion, byte_count with
        | (Returned_error | Raised | Cancelled), Some _ -> Error "failed span claims output bytes"
        | (Returned | Returned_error | Raised | Cancelled), _ ->
          Ok (Span_finished {span_id; operation_kind; site; schema_id; completion; byte_count; measurement}))
     | Some (`String "surface") ->
       let* f = fields ["kind"; "site"; "schema_ids"] json in
       let* site = site_of_json (get "site" f) in
       let* schema_ids = list (optional positive_id) (get "schema_ids" f) in Ok (Surface {site; schema_ids})
     | Some (`String "cache") ->
       let* f = fields ["kind"; "schema_id"; "outcome"] json in
       let* schema_id = optional positive_id (get "schema_id" f) in
       let* outcome = cache_of_json (get "outcome" f) in Ok (Cache {schema_id; outcome})
     | Some _ | None -> Error "unknown observation payload")
  | _ -> Error "expected observation payload object"
let event_of_json json =
  let* f = fields ["sequence"; "scope"; "payload"] json in
  let* sequence = integer (get "sequence" f) in let* scope = scope_of_json (get "scope" f) in
  let* payload = payload_of_json (get "payload" f) in Ok {sequence; scope; payload}
let bookkeeping_of_json json =
  let* f = fields ["calls"; "elapsed_ns"; "calling_domain_allocated_bytes"] json in
  let* calls = integer (get "calls" f) in let* elapsed_ns = nonnegative_ns (get "elapsed_ns" f) in
  let* allocated_bytes = number (get "calling_domain_allocated_bytes" f) in Ok {calls; elapsed_ns; allocated_bytes}

module Span_map = Map.Make (Int64)
let bind_identity identities id value =
  match Span_map.find_opt id identities with
  | None -> Ok (Span_map.add id value identities)
  | Some original when original = value -> Ok identities
  | Some _ -> Error "scope identity has contradictory provenance"
;;
let validate_scope failures identities (scope : scope) =
  let* identities = match scope.wake with
    | None -> Ok identities
    | Some wake -> bind_identity identities wake.wake_id
        (`Assoc ["kind", `String "wake"; "value", wake_json wake]) in
  let* identities = match scope.provider_turn with
    | None -> Ok identities
    | Some turn -> bind_identity identities turn.candidate_id
        (`Assoc ["kind", `String "candidate"; "value", provider_turn_json turn
          ; "wake_id", option_json id_json (Option.map (fun wake -> wake.wake_id) scope.wake)
          ; "attempt", option_json attempt_json scope.attempt]) in
  match scope.definition with
  | None -> Ok identities
  | Some {addon_owner_id = None; _} when failures > 0 ->
    (* An incomplete observation may learn an add-on owner on a later lookup.
       [None] is not contradictory positive evidence in that report. *)
    Ok identities
  | Some definition -> bind_identity identities definition.descriptor_id
      (`Assoc ["kind", `String "definition"; "value", definition_json definition])
;;
let validate_events observer mode failures origin events =
  let rec loop sequence open_spans seen identities = function
    | [] -> Ok (Span_map.cardinal open_spans)
    | (event : event) :: rest ->
      if event.sequence <> sequence || event.scope.observer_id <> observer then
        Error "event sequence or observer identity mismatch"
      else
        let* identities = validate_scope failures identities event.scope in
        match event.payload with
        | Span_started {span_id; operation_kind; site; schema_id} ->
          if Span_map.mem span_id seen then Error "duplicate span identity"
          else if failures = 0 && operation_kind = Encoding && Option.is_none schema_id then
            Error "complete encoder entry has no schema identity"
          else loop (sequence + 1)
              (Span_map.add span_id (operation_kind, site, schema_id, event.scope) open_spans)
              (Span_map.add span_id () seen) identities rest
        | Span_finished {span_id; operation_kind; site; schema_id; completion; measurement; _} ->
          (match Span_map.find_opt span_id open_spans with
           | None -> Error "span completion has no original entry"
           | Some (original_kind, original_site, original_schema, original_scope) ->
             if original_kind <> operation_kind || original_site <> site || original_scope <> event.scope then Error "span ownership changed"
             else if operation_kind <> Constructor && original_schema <> schema_id then Error "span schema identity changed"
             else if mode <> Timed && Option.is_some measurement then Error "untimed observer claims timing"
             else if failures = 0 && mode = Timed && Option.is_none measurement then
               Error "complete timed span has no measurement"
             else if (match origin, measurement with
               | Some origin, Some measurement ->
                 Int64.unsigned_compare measurement.started_ns origin < 0
               | None, None | None, Some _ | Some _, None -> false) then
               Error "span predates its observer clock"
             else if failures = 0 && operation_kind = Constructor && completion = Returned
                     && Option.is_none schema_id then Error "complete constructor has no returned schema"
             else loop (sequence + 1) (Span_map.remove span_id open_spans) seen identities rest)
        | Surface {schema_ids; _} ->
          if failures = 0 && List.exists Option.is_none schema_ids then
            Error "complete surface has unavailable schema identities"
          else loop (sequence + 1) open_spans seen identities rest
        | Cache {schema_id; _} ->
          if failures = 0 && Option.is_none schema_id then Error "complete cache row has no schema identity"
          else loop (sequence + 1) open_spans seen identities rest
  in
  loop 1 Span_map.empty Span_map.empty Span_map.empty events
;;
let report_of_json json =
  let* f = fields ["schema_version"; "observer_id"; "mode"; "clock_origin_ns"; "clock_domain"
    ; "allocation_scope"; "overhead_scope"; "coverage"; "failures"; "active_spans"
    ; "probe_calls"; "bookkeeping"; "events"] json in
  let* () = match get "schema_version" f with `Int 1 -> Ok () | _ -> Error "unsupported observation version" in
  let* report_observer_id = positive_id (get "observer_id" f) in
  let* report_mode = mode_of_json (get "mode" f) in
  let* clock_origin_ns = optional int64 (get "clock_origin_ns" f) in
  let* failures = integer (get "failures" f) in let* active_spans = integer (get "active_spans" f) in
  let* probe_calls = integer (get "probe_calls" f) in
  let* bookkeeping = bookkeeping_of_json (get "bookkeeping" f) in
  let* events = list event_of_json (get "events" f) in
  let* actual_active = validate_events report_observer_id report_mode failures clock_origin_ns events in
  let expected_coverage = if failures = 0 && active_spans = 0 then "complete" else "incomplete" in
  if get "clock_domain" f <> `String "process_monotonic_ns"
     || get "allocation_scope" f <> `String allocation_scope
     || get "overhead_scope" f <> `String overhead_scope then Error "unknown measurement semantics"
  else if get "coverage" f <> `String expected_coverage || active_spans <> actual_active then
    Error "contradictory coverage or active span count"
  else if report_mode = Disabled &&
      (events <> [] || failures <> 0 || probe_calls <> 0 || bookkeeping.calls <> 0) then
    Error "disabled observer claims observation work"
  else if report_mode <> Timed &&
      (Option.is_some clock_origin_ns || probe_calls <> 0 || bookkeeping.elapsed_ns <> 0L
       || bookkeeping.allocated_bytes <> 0.) then Error "untimed observer claims timing work"
  else if report_mode = Timed && Option.is_none clock_origin_ns && failures = 0 then
    Error "timed observer has no original clock"
  else Ok {report_observer_id; report_mode; clock_origin_ns; failures; active_spans
          ; probe_calls; bookkeeping; events}
;;
