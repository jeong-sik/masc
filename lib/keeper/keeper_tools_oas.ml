(** Keeper_tools_oas — Wrap keeper tools as OAS Tool.t for Agent.run().

    Bridges [Keeper_tool_dispatch_runtime.execute_keeper_tool_call_with_outcome] dispatch
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

let record_keeper_internal_tool_call ~tool_name ~disposition ~duration_ms =
  Tool_registry.record_call
    ~source:Agent_internal
    ~tool_name
    ~disposition
    ~duration_ms
    ()
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

   Each tool delegates to [execute_keeper_tool_call_with_outcome] with the current
   [ctx_snapshot] value. Tools that raise exceptions return error results
   instead of crashing the agent loop.

   @param config Workspace configuration for tool dispatch
   @param meta Keeper metadata (determines which tools are allowed)
   @param ctx_snapshot Immutable snapshot of current working context *)

(** Project a producer-owned outcome into the model-facing envelope.

    [raw] is always opaque text.  Only [data], supplied explicitly by the
    producer, can become structured JSON.  No field name or string content can
    alter success/failure or synthesize metadata. *)
let normalize_tool_result
      (execution : Keeper_tool_execution.t)
  : Yojson.Safe.t
  =
  let raw = execution.Keeper_tool_execution.raw_output in
  let data = execution.data in
  let disposition = Tool_result.string_of_disposition execution.disposition in
  let result =
    match data with
    | Some data -> data
    | None -> `String raw
  in
  match execution.disposition with
  | Tool_result.Completed () ->
    `Assoc
      [ "disposition", `String disposition
      ; "result", result
      ]
  | Tool_result.Deferred () ->
    `Assoc
      [ "disposition", `String disposition
      ; "result", result
      ]
  | Tool_result.Failed class_ ->
    `Assoc
      [ "disposition", `String disposition
      ; "failure_class", `String (Tool_result.tool_failure_class_to_string class_)
      ; "error", `String raw
      ; "detail", Option.value ~default:`Null data
      ]
;;

(** RFC-0006 Phase A.2: build the per-tool handler closure.

    Extracted from the original anonymous closure inside [make_tools] so
    that alias [Tool.t] entries (e.g. [Execute]) can reuse
    the exact same telemetry/decision-log pipeline by
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
