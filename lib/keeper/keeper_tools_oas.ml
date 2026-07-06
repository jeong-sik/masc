(** Keeper_tools_oas — Wrap keeper tools as OAS Tool.t for Agent.run().

    Bridges [Keeper_tool_dispatch_runtime.execute_keeper_tool_call] dispatch
    to [Agent_sdk.Tool.t] list via [Tool_bridge.oas_tool_of_masc].

    Tool execution reads current context from [ctx_snapshot] (immutable),
    enabling Agent.run() to manage messages while keeper tools
    access the working context for status/metrics.

    @since Phase 4 — Keeper → Agent.run() migration *)

type tool_bundle =
  { tools : Agent_sdk.Tool.t list
  ; cleanup : unit -> unit
  }

(** Tool usage now lives in Keeper_registry (per-entry tool_usage Hashtbl).
    These public functions expose the registry view without re-exporting
    the entry record type. *)

let tool_usage_for_keeper keeper_name : (string * Keeper_types.tool_call_entry) list =
  Keeper_registry_lookup.tool_usage_of_by_name keeper_name
;;

let tool_usage_json keeper_name : Yojson.Safe.t =
  `List
    (List.map
       (fun (name, e) ->
          `Assoc
            [ "tool_name", `String name
            ; "count", `Int e.Keeper_types.count
            ; "successes", `Int e.Keeper_types.successes
            ; "failures", `Int e.Keeper_types.failures
            ; "last_used_at", `Float e.Keeper_types.last_used_at
            ])
       (tool_usage_for_keeper keeper_name))
;;

let record_keeper_internal_tool_call ~tool_name ~success ~duration_ms =
  Tool_registry.record_call ~source:Agent_internal ~tool_name ~success ~duration_ms ()
;;

let recent_tools_for_keeper ?(limit = 5) keeper_name : string list =
  tool_usage_for_keeper keeper_name
  |> List.sort (fun (_, a) (_, b) ->
    Float.compare b.Keeper_types.last_used_at a.Keeper_types.last_used_at)
  |> fun l ->
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | (name, _) :: rest -> take (n - 1) (name :: acc) rest
  in
  take limit [] l
;;

(* ── end tracking ────────────────────────────────────────────── *)

(* Build OAS Tool.t list from keeper's allowed tools.

   Each tool delegates to [execute_keeper_tool_call] with the current
   [ctx_snapshot] value. Tools that raise exceptions return error results
   instead of crashing the agent loop.

   @param config Workspace configuration for tool dispatch
   @param meta Keeper metadata (determines which tools are allowed)
   @param ctx_snapshot Immutable snapshot of current working context *)

(** Repeated-failure guardrail: blocks a tool after [max_consecutive]
    consecutive failures with the same (tool_name, args_hash) key.
    Resets on success. Prevents infinite retry loops (e.g. keeper
    reading a non-existent file 400+ times). *)
let max_consecutive_failures = Env_config.KeeperToolExec.max_consecutive_tool_failures

type workflow_rejection_info = Keeper_tools_oas_workflow.workflow_rejection_info

(* TTL for per-(tool, args_hash) failure counters (#18501).
   After this many seconds since the last failure, the counter
   resets — transient errors no longer cause a permanent ban. *)
let failure_count_ttl_seconds = 1800.

type failure_counts =
  { table : (string, int) Hashtbl.t
  ; failure_timestamps : (string, float) Hashtbl.t
  ; workflow_table : (string, int) Hashtbl.t
  ; mutex : Mutex.t
  }

let create_failure_counts () =
  { table = Hashtbl.create 16
  ; failure_timestamps = Hashtbl.create 16
  ; workflow_table = Hashtbl.create 16
  ; mutex = Mutex.create ()
  }
;;

let reset_tool_retry_dedupe_for_testing = Keeper_tool_retry_state.reset_for_test

let failure_count_get counts key =
  Mutex.protect counts.mutex (fun () ->
    match Hashtbl.find_opt counts.table key with
    | None -> 0
    | Some count ->
      let now = Time_compat.now () in
      match Hashtbl.find_opt counts.failure_timestamps key with
      | Some ts when now -. ts <= failure_count_ttl_seconds -> count
      | _ ->
        Hashtbl.remove counts.table key;
        Hashtbl.remove counts.failure_timestamps key;
        0)
;;

let failure_count_record_failure counts key =
  Mutex.protect counts.mutex (fun () ->
    let next =
      match Hashtbl.find_opt counts.table key with
      | Some n -> n + 1
      | None -> 1
    in
    Hashtbl.replace counts.table key next;
    Hashtbl.replace counts.failure_timestamps key (Time_compat.now ());
    next)
;;

let failure_count_reset counts key =
  Mutex.protect counts.mutex (fun () ->
    Hashtbl.remove counts.table key;
    Hashtbl.remove counts.failure_timestamps key)
;;

(* MASC/OAS Error-Warn Reduction Goal 2026-05-18, P2 reducer:
   force the per-(tool,args) counter up to [target] on the first
   deterministic policy/shape block. Returns the new value so the
   caller can use it in log lines (always [target]). Idempotent for
   subsequent matching calls — [Hashtbl.replace] does not stack. *)
let failure_count_jump_to counts key ~target =
  Mutex.protect counts.mutex (fun () ->
    Hashtbl.replace counts.table key target;
    Hashtbl.replace counts.failure_timestamps key (Time_compat.now ());
    target)
;;

let workflow_rejection_count_record counts key =
  Mutex.protect counts.mutex (fun () ->
    let next =
      match Hashtbl.find_opt counts.workflow_table key with
      | Some n -> n + 1
      | None -> 1
    in
    Hashtbl.replace counts.workflow_table key next;
    next)
;;

let workflow_rejection_count_reset counts =
  Mutex.protect counts.mutex (fun () -> Hashtbl.clear counts.workflow_table)
;;

(* Test-only: inject a failure counter with a stale timestamp so the
   TTL expiry path in [failure_count_get] can be exercised. *)
let inject_stale_failure_count_for_test counts key count =
  Mutex.protect counts.mutex (fun () ->
    Hashtbl.replace counts.table key count;
    Hashtbl.replace counts.failure_timestamps key
      (Time_compat.now () -. (failure_count_ttl_seconds +. 60.)))
;;

open Keeper_tools_oas_workflow
open Keeper_tools_oas_deterministic_error

type structured_error_payload_parse_error =
  | Structured_error_payload_json_decode_error of string
  | Structured_error_payload_non_object of { received : string }

let structured_error_payload_parse_error_to_string = function
  | Structured_error_payload_json_decode_error message ->
    "json_decode_error: " ^ message
  | Structured_error_payload_non_object { received } ->
    Printf.sprintf "non_object: %s" received
;;

let structured_error_payload_fields_result error_msg =
  match Yojson.Safe.from_string error_msg with
  | exception Yojson.Json_error message ->
    Error (Structured_error_payload_json_decode_error message)
  | `Assoc fields -> Ok fields
  | other ->
    Error (Structured_error_payload_non_object { received = Json_util.kind_name other })
;;

(** Normalize a raw tool result string into a consistent JSON envelope.

    The LLM sees this output directly. Without normalization, tool results
    use 6+ different schemas ({ok,error,status,...} in various combinations),
    making it hard for the LLM to parse success/failure reliably.

    After normalization, all results follow:
    - Success: {"ok": true, "result": <original_json_or_string>}
    - Success with changes: {"ok": true, "result": ..., "changes": <delta>}
    - Failure: {"ok": false, "error": <message>, "detail": <original_json|null>}

    The [success] flag comes from the typed outcome returned by
    [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome]. *)
let normalize_tool_result
      ?(workflow_rejection_recovery_fields = [])
      ~(success : bool)
      (raw : string)
  : string
  =
  let metadata_from_assoc fields =
    fields
    |> List.filter (fun (key, _) ->
      not
        (List.mem
           key
           [ "ok"; "error"; "detail"; "result"; "output"; "message"; "status" ]))
  in
  let merge_metadata primary secondary =
    let primary_keys = List.map fst primary in
    primary
    @ List.filter
        (fun (key, _) -> not (List.mem key primary_keys))
        secondary
  in
  let ensure_workflow_self_correction fields =
    match List.assoc_opt "failure_class" fields with
    | Some (`String "workflow_rejection")
      when not (List.mem_assoc "self_correction_required" fields) ->
      fields @ [ "self_correction_required", `Bool true ]
    | _ -> fields
  in
  try
    let json = Yojson.Safe.from_string raw in
    if success
    then
      (* Success: wrap original JSON under "result" key.
         If original already has "ok":true, the normalized envelope
         is still consistent — "ok" at the top level is authoritative. *)
      Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "result", json ])
    else (
      (* Failure: extract error message from whichever field is present,
         preserve original JSON as "detail" for debugging. *)
      let error_msg =
        match Safe_ops.json_string_opt "error" json with
        | Some msg when String.trim msg <> "" -> msg
        | _ ->
          (match Safe_ops.json_string_opt "output" json with
           | Some msg when String.trim msg <> "" -> msg
           | _ ->
             (match Safe_ops.json_string_opt "message" json with
              | Some msg when String.trim msg <> "" -> msg
              | _ ->
                (match Safe_ops.json_string_opt "status" json with
                 | Some s when String.lowercase_ascii (String.trim s) = "error" ->
                   "tool returned error status"
                 | _ -> "tool call failed")))
      in
      let error_msg, nested_fields =
        match structured_error_payload_fields_result error_msg with
        | Ok fields ->
          let nested_error =
            match List.assoc_opt "error" fields with
            | Some (`String msg) when String.trim msg <> "" -> msg
            | _ -> error_msg
          in
          nested_error, metadata_from_assoc fields
        | Error (Structured_error_payload_json_decode_error _)
        | Error (Structured_error_payload_non_object _) ->
          error_msg, []
      in
      let preserved_fields =
        (match json with
         | `Assoc fields -> merge_metadata (metadata_from_assoc fields) nested_fields
         | _ -> nested_fields)
        |> ensure_workflow_self_correction
      in
      Yojson.Safe.to_string
        (`Assoc
          ([ "ok", `Bool false; "error", `String error_msg; "detail", json ]
           @ preserved_fields
           @ workflow_rejection_recovery_fields)))
  with
  | Yojson.Json_error _ ->
    (* Raw is not JSON (e.g. plain text from keeper_tasks_list).
       Wrap as-is. *)
    if success
    then Yojson.Safe.to_string (`Assoc [ "ok", `Bool true; "result", `String raw ])
    else
      Yojson.Safe.to_string
        (`Assoc [ "ok", `Bool false; "error", `String raw; "detail", `Null ])
;;

let record_deterministic_tool_failure_metric ~tool_name reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ToolsOasDeterministicFailures)
    ~labels:
      [ "tool", tool_name
      ; "reason", Keeper_tool_deterministic_error.to_telemetry_key reason
      ]
    ()
;;

let transient_mutex_contention_error_class = "transient_mutex_contention"

let transient_mutex_contention_tool_error
      ~(tool_name : string)
      ~(error_text : string)
      ?backtrace
      ()
  : string
  =
  let message =
    Printf.sprintf
      "tool %s hit transient mutex contention (EDEADLK); not counted toward \
       consecutive-failure budget. Retry the same call or wait for the contending \
       operation to finish."
      tool_name
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "ok", `Bool false
        ; "error", `String message
        ; "error_class", `String transient_mutex_contention_error_class
        ; "failure_class", `String "transient_error"
        ; "recoverable", `Bool true
        ; "transient", `Bool true
        ; "retry_recommended", `Bool true
        ; ( "detail"
          , `Assoc
              [ "tool_name", `String tool_name
              ; "exception", `String error_text
              ; "operator_action", `String "retry_same_call_or_wait"
              ; "backtrace_available", `Bool (Option.is_some backtrace)
              ] )
        ])
;;

(** RFC-0006 Phase A.2: build the per-tool handler closure.

    Extracted from the original anonymous closure inside [make_tools] so
    that alias [Tool.t] entries (e.g. [Execute]) can reuse
    the exact same telemetry/circuit-breaker/decision-log pipeline by
    instantiating this helper with the INTERNAL name as [~name].

    Telemetry SSOT contract: [~name] flows into every observability
    sink (Keeper_registry.record_tool_use, SSE broadcast tool_name,
    decision-log "tool" field, Tool_registry). The LLM-facing
    public name (Execute/Read/...) only appears as the [Tool.schema.name]
    set by [Tool_bridge.oas_tool_of_masc] above this helper.

    Public aliases validate the LLM-facing payload before translation to the
    internal tool's expected payload. Identity by default. *)

(* Handlers moved to [Keeper_tools_oas_handler] — see
   keeper_tools_oas_handler.mli for [make_keeper_tool_handler],
   [make_tool_bundle], and [make_tools]. *)
