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
let normalize_tool_result ~(success : bool) (raw : string)
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
  let structured_error_payload error_msg =
    try
      match Yojson.Safe.from_string error_msg with
      | `Assoc fields -> Some fields
      | _ -> None
    with
    | Yojson.Json_error _ -> None
  in
  let merge_metadata primary secondary =
    let primary_keys = List.map fst primary in
    primary
    @ List.filter
        (fun (key, _) -> not (List.mem key primary_keys))
        secondary
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
        match structured_error_payload error_msg with
        | Some fields ->
          let nested_error =
            match List.assoc_opt "error" fields with
            | Some (`String msg) when String.trim msg <> "" -> msg
            | _ -> error_msg
          in
          nested_error, metadata_from_assoc fields
        | None -> error_msg, []
      in
      let preserved_fields =
        (match json with
         | `Assoc fields -> merge_metadata (metadata_from_assoc fields) nested_fields
         | _ -> nested_fields)
      in
      Yojson.Safe.to_string
        (`Assoc
          ([ "ok", `Bool false; "error", `String error_msg; "detail", json ]
           @ preserved_fields)))
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
