(** OAS Event_bus → SSE Bridge.

    Subscribes to all events on the OAS Event_bus (both MASC Custom
    events and OAS native lifecycle events) and relays them as SSE
    broadcasts to connected dashboard clients.

    OAS native events (ToolCalled, TurnCompleted, etc.) are serialized
    to a uniform JSON format with an "oas:" prefix so consumers can
    distinguish them from MASC-originated events.

    Since OAS 0.123.0 every event carries an envelope with
    [correlation_id], [run_id], and [ts]. These are always emitted
    in the SSE JSON so downstream consumers can join events into
    causal chains offline.

    @since 2.96.0
    @modified 2.255.0 — accept OAS native events (#5620)
    @modified 2.260.0 — emit envelope correlation_id/run_id (oas#845) *)

open Keeper_event_bridge_inference
open Keeper_event_bridge_error_json

(** Drain interval: how often we poll the Event_bus subscription.
    Lower default keeps the dashboard close to real-time, while staying
    runtime-tunable for quieter deployments. *)
let drain_interval_s () = Env_config.Oas_sse.drain_interval_sec

let payload_agent_name payload =
  (* Check [agent_name], [agent], then [keeper_name] for Custom events
     whose publisher stores the per-agent attribution under the
     keeper-specific key (e.g. [masc:keeper:snapshot],
     [masc:keeper:lifecycle]).  Without this fallback the top-level
     envelope [agent_name] is Null for 9%+ of daily events, breaking
     per-agent filters over the Dated_jsonl store under [.masc/oas-events/].
     See #7827. *)
  match Json_util.get_string payload "agent_name" with
  | Some _ as value -> value
  | None ->
    (match Json_util.get_string payload "agent" with
     | Some _ as value -> value
     | None -> Json_util.get_string payload "keeper_name")
;;

let emit_native_event_log (evt : Agent_sdk.Event_bus.event) (json : Yojson.Safe.t) =
  let log_at level message =
    Log.Oas_event.emit level ~details:json message
  in
  let log_routine message =
    Log.Oas_event.routine ~details:json "%s" message
  in
  let log message = log_at Log.Info message in
  (* Per-turn and per-tool lifecycle is emitted at [routine] (default Debug), not
     Info, because it is a redundant TEXT rendering of events already carried by
     two authoritative planes: (1) for keeper agents, the keeper hook logs the
     richer "[Keeper] ... tool_call ... outcome=... out_len=" / "[Keeper/...] turn="
     lines at Info; (2) for every agent, [Event_log.publish] + [Sse.broadcast]
     (see [prepare_pending_event]) carry the structured stream the dashboard and
     REST/SSE subscribers actually consume. Demoting these four high-frequency
     arms removes the Info-level console doubling without losing the data — it
     stays retrievable at Debug and the structured/SSE planes are untouched. This
     is deduplication against an existing SSOT, not symptom suppression: there is
     no recurring failure being hidden. Agent- and context-level lifecycle below
     stay at Info (no keeper-hook duplicate, low frequency). [TurnReady] already
     uses [log_routine] for the same reason. *)
  match evt.payload with
  | Agent_sdk.Event_bus.AgentStarted { agent_name; task_id } ->
    log (Printf.sprintf "agent started agent=%s task_id=%s" agent_name task_id)
  | Agent_sdk.Event_bus.AgentCompleted { agent_name; task_id; elapsed; _ } ->
    log
      (Printf.sprintf
         "agent completed agent=%s task_id=%s elapsed_s=%.3f"
         agent_name
         task_id
         elapsed)
  | Agent_sdk.Event_bus.TurnStarted { agent_name; turn } ->
    log_routine (Printf.sprintf "turn started agent=%s turn=%d" agent_name turn)
  | Agent_sdk.Event_bus.TurnCompleted { agent_name; turn } ->
    log_routine (Printf.sprintf "turn completed agent=%s turn=%d" agent_name turn)
  | Agent_sdk.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
    log_routine (Printf.sprintf "tool called agent=%s tool_name=%s" agent_name tool_name)
  | Agent_sdk.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
    log_routine
      (Printf.sprintf "tool completed agent=%s tool_name=%s" agent_name tool_name)
  | Agent_sdk.Event_bus.TurnReady { agent_name; turn; tool_names } ->
    (* [substrate:tool_surface] — deterministic per-turn snapshot of the
         tool list the LLM actually sees this turn (after guardrails,
         operator policy, tool_filter_override).  Emitted as a single
         grep-friendly line with a stable hash so operators can confirm
         which tools were on the LLM's surface for a given turn without
         enabling verbose tool dumps. *)
    let names_hash = Digest.to_hex (Digest.string (String.concat "\n" tool_names)) in
    log_routine
      (Printf.sprintf
         "[substrate:tool_surface] agent=%s turn=%d count=%d names_hash=%s"
         agent_name
         turn
         (List.length tool_names)
         (String.sub names_hash 0 16))
  | Agent_sdk.Event_bus.ContextCompacted
      { agent_name; before_tokens; after_tokens; phase } ->
    log
      (Printf.sprintf
         "context compacted agent=%s before_tokens=%d after_tokens=%d phase=%s"
         agent_name
         before_tokens
         after_tokens
         phase)
  | Agent_sdk.Event_bus.ContextOverflowImminent
      { agent_name; estimated_tokens; limit_tokens; ratio } ->
    log
      (Printf.sprintf
         "context overflow imminent agent=%s estimated_tokens=%d limit_tokens=%d \
          ratio=%.3f"
         agent_name
         estimated_tokens
         limit_tokens
         ratio)
  | Agent_sdk.Event_bus.ContextCompactStarted { agent_name; trigger } ->
    log (Printf.sprintf "context compact started agent=%s trigger=%s" agent_name trigger)
  (* Variants below previously absorbed by [_ -> ()] catch-all.  Each is
     enumerated explicitly so adding a new [Agent_sdk.Event_bus.payload]
     variant fails the build instead of silently dropping the log line. *)
  | Agent_sdk.Event_bus.AgentFailed _
  | Agent_sdk.Event_bus.HandoffRequested _
  | Agent_sdk.Event_bus.HandoffCompleted _
  | Agent_sdk.Event_bus.ElicitationCompleted _
  | Agent_sdk.Event_bus.ContentReplacementReplaced _
  | Agent_sdk.Event_bus.ContentReplacementKept _
  | Agent_sdk.Event_bus.SlotSchedulerObserved _
  | Agent_sdk.Event_bus.InferenceTelemetry _
  | Agent_sdk.Event_bus.Custom _ -> ()
;;

(** Build the SSE JSON wrapper. [correlation_id] and [run_id] are
    mandatory (from the envelope); all other fields are optional.
    [caused_by] is the envelope's causation pointer (OAS #877) — for
    [oas:tool_completed] it equals the matching [oas:tool_called] row's
    [run_id], the only key that pairs the two rows. *)
let wrap_event
      ~ts
      ~correlation_id
      ~run_id
      ?caused_by
      ~event_type
      ~payload
      ?agent_name
      ?task_id
      ?turn
      ?tool_name
      ()
  =
  `Assoc
    [ "type", `String ("oas:" ^ event_type)
    ; "event_type", `String event_type
    ; "ts_unix", `Float ts
    ; "correlation_id", `String correlation_id
    ; "run_id", `String run_id
    ; "caused_by", Json_util.string_opt_to_json_trimmed caused_by
    ; "agent_name", Json_util.string_opt_to_json_trimmed agent_name
    ; "task_id", Json_util.string_opt_to_json_trimmed task_id
    ; "turn", Option.fold ~none:`Null ~some:(fun value -> `Int value) turn
    ; "tool_name", Json_util.string_opt_to_json_trimmed tool_name
    ; "payload", payload
    ]
;;

(** Serialize an OAS event to JSON for SSE relay + durable storage.
    Reads envelope metadata ([correlation_id], [run_id], [ts]) from
    [evt.meta] and includes them in every emitted JSON object.

    The match below intentionally combines explicit per-variant arms
    with a final [other] catch-all that produces a kind-only fallback
    via [Agent_sdk.Event_bus.payload_kind].  The catch-all is "redundant" at
    every individual snapshot of the OAS variant set (warning 11), but
    it is a deliberate future-proof against the OAS pin-bump P0 class
    (#10490, #10574, #10584).  Without the catch-all, every new
    upstream variant breaks main with [-warn-error +8] until the
    consumer is migrated; with it, the relay degrades to a
    kind-labelled placeholder while emitting three operator signals:

    - WARN log [oas_event_bridge: SSE-degraded ...] including the
      offending [kind], correlation ids, timestamp, and the explicit
      file:function where the migration arm should be added.
    - Counter [masc_oas_bridge_unmigrated_payload_kind_total{kind}]
      ({!Otel_metric_store.metric_oas_bridge_unmigrated_payload_kind}) so the
      degradation rate is visible to Otel_metric_store without log scraping.
    - SSE payload [note] + [migration_target] fields so dashboard code
      can render the partial-data row distinctly and link the operator
      back to the file that needs editing.

    Suppressing warning 11 ([@warning "-11"]) is therefore the entire
    point of this function's shape — do not remove it without also
    removing the catch-all. *)
let native_event_to_json (evt : Agent_sdk.Event_bus.event) : Yojson.Safe.t option =
  let { Agent_sdk.Event_bus.correlation_id; run_id; ts; caused_by; _ } = evt.meta in
  let wrap = wrap_event ~ts ~correlation_id ~run_id ?caused_by in
  match[@warning "-11"] evt.payload with
  | Agent_sdk.Event_bus.AgentStarted { agent_name; task_id } ->
    let payload =
      `Assoc [ "agent_name", `String agent_name; "task_id", `String task_id ]
    in
    Some (wrap ~event_type:"agent_started" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.AgentCompleted { agent_name; task_id; elapsed; result } ->
    (match result with
     | Ok (response : Agent_sdk.Types.api_response) ->
       let provider =
         inference_provider_bucket ~provider:"" ~model:response.model
       in
       let model_bucket = inference_model_bucket ~provider:"" ~model:response.model in
       let cost_usd =
         match response.usage with
         | Some usage -> usage.cost_usd
         | None -> None
       in
       observe_inference_cost ~provider ~model_bucket cost_usd
     | Error error ->
       Log.Oas_event.routine
         "agent completion has no inference cost observation because the run failed: %s"
         (Agent_sdk.Error.to_string error));
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name
         ; "task_id", `String task_id
         ; "elapsed_s", `Float elapsed
         ]
         @ agent_completed_result_fields result)
    in
    Some (wrap ~event_type:"agent_completed" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.AgentFailed { agent_name; task_id; error; elapsed } ->
    let projection = agent_failed_error_projection error in
    Some
      (Sse_event.agent_failed
         ?caused_by
         ~ts_unix:ts
         ~correlation_id
         ~run_id
         ~agent_name
         ~task_id
         ~elapsed_s:elapsed
         ~error:projection.error
         ~error_domain:projection.error_domain
         ~error_code:projection.error_code
         ~error_retryable:projection.error_retryable
         ~error_detail:projection.error_detail
         ())
  | Agent_sdk.Event_bus.ToolCalled { agent_name; tool_name; tool_use_id; _ } ->
    (* tool_called publishes before execution, so the keeper hook has not
       minted an execution_id yet — this row carries the provider call id
       only; the matching tool_completed row carries both. *)
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name; "tool_name", `String tool_name ]
         @ (if tool_use_id = "" then [] else [ "tool_use_id", `String tool_use_id ]))
    in
    Some (wrap ~event_type:"tool_called" ~payload ~agent_name ~tool_name ())
  | Agent_sdk.Event_bus.ToolCompleted { agent_name; tool_name; tool_use_id; _ } ->
    (* RFC-0233 PR-2: the keeper post_tool_use hook registered the
       tool_use_id ↔ execution_id pair before OAS published this event,
       so the lookup is deterministic. A miss means the execution did not
       go through a keeper hook (worker/eval lanes), not a failure. *)
    let execution_id_fields =
      match
        if tool_use_id = "" then None
        else Keeper_execution_join.take ~tool_use_id
      with
      | Some execution_id -> [ "execution_id", `String execution_id ]
      | None -> []
    in
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name; "tool_name", `String tool_name ]
         @ (if tool_use_id = "" then [] else [ "tool_use_id", `String tool_use_id ])
         @ execution_id_fields)
    in
    Some (wrap ~event_type:"tool_completed" ~payload ~agent_name ~tool_name ())
  | Agent_sdk.Event_bus.TurnStarted { agent_name; turn } ->
    let payload = `Assoc [ "agent_name", `String agent_name; "turn", `Int turn ] in
    Some (wrap ~event_type:"turn_started" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.TurnCompleted { agent_name; turn } ->
    let payload = `Assoc [ "agent_name", `String agent_name; "turn", `Int turn ] in
    Some (wrap ~event_type:"turn_completed" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.TurnReady { agent_name; turn; tool_names } ->
    let names_hash = Digest.to_hex (Digest.string (String.concat "\n" tool_names)) in
    let payload =
      `Assoc
        [ "agent_name", `String agent_name
        ; "turn", `Int turn
        ; "count", `Int (List.length tool_names)
        ; "names_hash", `String (String.sub names_hash 0 16)
        ; "tool_names", `List (List.map (fun name -> `String name) tool_names)
        ]
    in
    Some (wrap ~event_type:"turn_ready" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.HandoffRequested { from_agent; to_agent; reason } ->
    let payload =
      `Assoc
        [ "from_agent", `String from_agent
        ; "to_agent", `String to_agent
        ; "reason", `String reason
        ]
    in
    Some (wrap ~event_type:"handoff_requested" ~payload ~agent_name:from_agent ())
  | Agent_sdk.Event_bus.HandoffCompleted { from_agent; to_agent; elapsed } ->
    let payload =
      `Assoc
        [ "from_agent", `String from_agent
        ; "to_agent", `String to_agent
        ; "elapsed_s", `Float elapsed
        ]
    in
    Some (wrap ~event_type:"handoff_completed" ~payload ~agent_name:from_agent ())
  | Agent_sdk.Event_bus.ContextCompacted
      { agent_name; before_tokens; after_tokens; phase } ->
    (* #9935: compaction completed — clears any pending
         imminent and fires action-taken counter. *)
    Context_overflow_action_tracker.record_action ~keeper_name:agent_name;
    let payload =
      `Assoc
        [ "agent_name", `String agent_name
        ; "before_tokens", `Int before_tokens
        ; "after_tokens", `Int after_tokens
        ; "phase", `String phase
        ]
    in
    Some (wrap ~event_type:"context_compacted" ~payload ~agent_name ())
  | Agent_sdk.Event_bus.ElicitationCompleted _ -> None (* Internal; no SSE relay needed *)
  | Agent_sdk.Event_bus.ContextOverflowImminent
      { agent_name; estimated_tokens; limit_tokens; ratio } ->
    (* #9935: track imminent→action pairing so an unanswered
         overflow (no compact_started/compacted within grace
         window) is observable via metric + warn log, rather
         than silently burning out as provider_timeout. *)
    Otel_metric_store.set_gauge
      Otel_metric_store.metric_oas_context_overflow_ratio
      ~labels:[ "agent_name", agent_name ]
      ratio;
    Context_overflow_action_tracker.record_imminent
      ~keeper_name:agent_name
      ~ts:(Time_compat.now ());
    let payload =
      `Assoc
        [ "agent_name", `String agent_name
        ; "estimated_tokens", `Int estimated_tokens
        ; "limit_tokens", `Int limit_tokens
        ; "ratio", `Float ratio
        ]
    in
    Some (wrap ~event_type:"context_overflow_imminent" ~payload ~agent_name ())
  | Agent_sdk.Event_bus.ContextCompactStarted { agent_name; trigger } ->
    (* #9935: compaction started — clears pending imminent
         and fires action-taken counter. *)
    Context_overflow_action_tracker.record_action ~keeper_name:agent_name;
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_oas_context_compaction_total
      ~labels:[ "agent_name", agent_name; "trigger", trigger ]
      ();
    let payload =
      `Assoc [ "agent_name", `String agent_name; "trigger", `String trigger ]
    in
    Some (wrap ~event_type:"context_compact_started" ~payload ~agent_name ())
  | Agent_sdk.Event_bus.ContentReplacementReplaced
      { tool_use_id; preview; original_chars; seen_count_after } ->
    let payload =
      `Assoc
        [ "tool_use_id", `String tool_use_id
        ; "preview", `String preview
        ; "original_chars", `Int original_chars
        ; "seen_count_after", `Int seen_count_after
        ]
    in
    Some (wrap ~event_type:"content_replacement_replaced" ~payload ())
  | Agent_sdk.Event_bus.ContentReplacementKept { tool_use_id; seen_count_after } ->
    let payload =
      `Assoc
        [ "tool_use_id", `String tool_use_id; "seen_count_after", `Int seen_count_after ]
    in
    Some (wrap ~event_type:"content_replacement_kept" ~payload ())
  | Agent_sdk.Event_bus.SlotSchedulerObserved
      { max_slots; active; available; queue_length; state } ->
    let state_str =
      match state with
      | Agent_sdk.Event_bus.Idle -> "idle"
      | Agent_sdk.Event_bus.Queued -> "queued"
      | Agent_sdk.Event_bus.Saturated -> "saturated"
    in
    let payload =
      `Assoc
        [ "max_slots", `Int max_slots
        ; "active", `Int active
        ; "available", `Int available
        ; "queue_length", `Int queue_length
        ; "state", `String state_str
        ]
    in
    Some (wrap ~event_type:"slot_scheduler_observed" ~payload ())
  | Agent_sdk.Event_bus.Custom (name, payload) ->
    (* Wire compatibility: dashboard consumers historically decoded
         [masc:broadcast] / [masc:keeper:snapshot] (all colons).
         Internally MASC now emits dot-separated names per OAS Custom
         convention ([masc.broadcast], [masc.keeper.snapshot]).
         Translate EVERY dot to colon for [masc.*] events so existing
         SSE consumers continue to decode the full multi-segment name. *)
    let event_type =
      if String.length name > 5 && String.starts_with ~prefix:"masc." name
      then String.map (fun c -> if c = '.' then ':' else c) name
      else name
    in
    Some
      (wrap
         ~event_type
         ~payload
         ?agent_name:(payload_agent_name payload)
         ?task_id:(Json_util.assoc_string_opt "task_id" payload)
         ?turn:(Json_util.assoc_int_opt "turn" payload)
         ?tool_name:(Json_util.assoc_string_opt "tool_name" payload)
         ())
  | Agent_sdk.Event_bus.InferenceTelemetry
      { provider
      ; model
      ; prompt_tokens
      ; completion_tokens
      ; prompt_ms
      ; decode_ms
      ; decode_tok_s
      ; _
      } ->
    (* Per-token telemetry from OAS#1202; not surfaced over SSE. Preserve
         the aggregate signal with bounded Otel_metric_store labels so operators can
         see model-family/token-bin trends without flooding SSE consumers or
         creating raw-model cardinality. *)
    observe_inference_telemetry
      ~provider
      ~model
      ~prompt_tokens
      ~completion_tokens
      ~prompt_ms
      ~decode_ms
      ~decode_tok_s;
    None
  | other ->
    (* Graceful fallback for OAS variants that ship before this consumer
         is migrated to an explicit shape (#10584).  Pre-fix, the match
         above was exhaustive and the OAS pin bump that introduced
         [InferenceTelemetry] (#10490) and [Stale_turn_timeout] (#10574)
         broke main with [-warn-error +8] partial-match errors.

         [Agent_sdk.Event_bus.payload_kind] is co-located with the [payload]
         variant in OAS — adding a new variant upstream forces an
         entry there in the same patch, so the snake_case label is
         always accurate.  Emit a kind-only SSE event so subscribers
         see *something happened* (with stable [event_type] for
         filtering) instead of having the whole stream fail to parse.

         [note] + [migration_target] flag the partial-data shape so
         dashboards can render it as a placeholder rather than treating
         it as a complete payload, and tell the operator *where* to add
         the explicit arm.  The warn log gives operators a per-process
         signal that an OAS variant has shipped without a masc
         consumer migration; the
         [masc_oas_bridge_unmigrated_payload_kind_total{kind}] counter
         gives them the per-process *rate*, surfaced by Otel_metric_store
         export so dashboards can alert without log scraping. *)
    let kind = Agent_sdk.Event_bus.payload_kind other in
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_oas_bridge_unmigrated_payload_kind
      ~labels:[ "kind", kind ]
      ();
    Log.Misc.warn
      "oas_event_bridge: SSE-degraded to kind-only payload for unmigrated OAS \
       variant kind=%s correlation_id=%s run_id=%s ts=%f fix: add explicit arm in \
       lib/keeper/keeper_event_bridge.ml::native_event_to_json for this kind"
      kind
      correlation_id
      run_id
      ts;
    let payload =
      `Assoc
        [ "kind", `String kind
        ; ( "note"
          , `String
              "kind-only fallback; explicit arm not yet wired in \
               keeper_event_bridge.native_event_to_json" )
        ; ( "migration_target"
          , `String "lib/keeper/keeper_event_bridge.ml::native_event_to_json" )
        ]
    in
    Some (wrap ~event_type:kind ~payload ())
;;

let relay_max_attempts = 3
let relay_max_queue_depth = 256

type relay_stage =
  | Append
  | Broadcast

type pending_relay =
  { json : Yojson.Safe.t
  ; attempts : int
  ; appended : bool
  }

type relay_result =
  | Delivered
  | Retryable_failure of pending_relay * relay_stage * exn

let relay_stage_to_string = function
  | Append -> "append"
  | Broadcast -> "broadcast"
;;

let relay_event_type json =
  match Json_util.assoc_string_opt "event_type" json with
  | Some value -> value
  | None ->
    (match Json_util.assoc_string_opt "type" json with
     | Some value -> value
     | None -> "unknown")
;;

let relay_event_is_presence_class json =
  match relay_event_type json with
  | "masc:keeper:snapshot" -> true
  | _ -> false
;;

let broadcast_relay_json json =
  Sse.broadcast_to All json;
  if relay_event_is_presence_class json
  then (
    try Sse.broadcast_presence json with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Misc.warn "oas_event_bridge: presence relay failed: %s" (Printexc.to_string exn))
;;

let update_relay_queue_depth pending =
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_oas_sse_relay_queue_depth
    (float_of_int (List.length pending))
;;

let emit_relay_retry_log
      ~(pending : pending_relay)
      ~(stage : relay_stage)
      ~(attempt : int)
      exn
  =
  Log.Misc.warn
    "oas_event_bridge: retrying event_type=%s stage=%s attempt=%d/%d correlation_id=%s \
     run_id=%s error=%s"
    (relay_event_type pending.json)
    (relay_stage_to_string stage)
    attempt
    relay_max_attempts
    (Option.value ~default:"<none>" (Json_util.assoc_string_opt "correlation_id" pending.json))
    (Option.value ~default:"<none>" (Json_util.assoc_string_opt "run_id" pending.json))
    (Printexc.to_string exn)
;;

let emit_relay_drop_log
      ~(pending : pending_relay)
      ~(stage_label : string)
      ~(attempts : int)
  =
  Log.Server.error
    "oas_event_bridge: dropping event_type=%s stage=%s attempts=%d correlation_id=%s \
     run_id=%s"
    (relay_event_type pending.json)
    stage_label
    attempts
    (Option.value ~default:"<none>" (Json_util.assoc_string_opt "correlation_id" pending.json))
    (Option.value ~default:"<none>" (Json_util.assoc_string_opt "run_id" pending.json))
;;

let broadcast_drop_marker
      ~(pending : pending_relay)
      ~(stage_label : string)
      ~(attempts : int)
  =
  let marker =
    `Assoc
      [ "type", `String "oas:relay_dropped"
      ; "event_type", `String "relay_dropped"
      ; "ts_unix", `Float (Time_compat.now ())
      ; ( "correlation_id"
        , Json_util.string_opt_to_json
            (Json_util.assoc_string_opt "correlation_id" pending.json) )
      ; ( "run_id"
        , Json_util.string_opt_to_json
            (Json_util.assoc_string_opt "run_id" pending.json) )
      ; ( "agent_name"
        , Json_util.string_opt_to_json
            (Json_util.assoc_string_opt "agent_name" pending.json) )
      ; "failed_stage", `String stage_label
      ; "attempts", `Int attempts
      ; "original_event_type", `String (relay_event_type pending.json)
      ]
  in
  try Sse.broadcast_to All marker with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (* P2 silent-failure fix: previously only logged.  The drop
         marker is the operator-visible signal that an OAS event was
         dropped after exhausting retries; if the drop marker also
         fails to broadcast, operators are blind to the drop entirely.
         Counter is distinct from masc_sse_broadcast_failures_total
         (PR-C #11075) so the recovery-path failure rate is visible
         in isolation from normal broadcast failures. *)
    Transport_metrics.inc_relay_drop_marker_failure ();
    Log.Misc.warn
      "oas_event_bridge: drop marker broadcast failed: %s"
      (Printexc.to_string exn)
;;

let prepare_pending_event evt =
  match native_event_to_json evt with
  | None -> None
  | Some json ->
    (* OAS event payloads may carry tool output or user-facing text that
         contains invalid UTF-8 bytes (e.g. truncated multi-byte sequences
         from subprocess captures). Scrub once before the event enters the
         retry queue so every retry uses the same sanitized payload. *)
    let json = Inference_utils.sanitize_json_utf8 json in
    emit_native_event_log evt json;
    (* P2-2: canonical in-memory event log. OAS events are published here so
       REST/SSE subscribers and future replay tools have a single ordered
       stream to consume. The log is bounded (10k events). *)
    let (_ : Event_log.event_id) =
      Event_log.publish ~source:"oas_event_bridge" ~kind:(relay_event_type json) json
    in
    Some { json; attempts = 0; appended = false }
;;

let deliver_pending_with
      ~(append_json : Yojson.Safe.t -> unit)
      ~(broadcast_json : Yojson.Safe.t -> unit)
      (pending : pending_relay)
  =
  let pending =
    if pending.appended
    then pending
    else (
      append_json pending.json;
      { pending with appended = true })
  in
  try
    broadcast_json pending.json;
    Delivered
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Retryable_failure (pending, Broadcast, exn)
;;

let oas_event_retention_days_default = 30

let resolve_oas_event_retention_days = function
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some days when days > 0 -> Some days
     | Some _ -> None
     | None -> Some oas_event_retention_days_default)
  | None -> Some oas_event_retention_days_default
;;

let oas_event_retention_days () =
  resolve_oas_event_retention_days (Sys.getenv_opt "MASC_OAS_EVENTS_RETENTION_DAYS")
;;

let deliver_pending ?store_ref (pending : pending_relay) =
  let append_json =
    match store_ref with
    | None -> fun _json -> ()
    | Some store_ref ->
      fun json ->
        let store = !store_ref in
        (try Dated_jsonl.append store json with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           let retention_days = oas_event_retention_days () in
           store_ref :=
             Dated_jsonl.create
               ~base_dir:(Dated_jsonl.base_dir store)
               ?retention_days
               ();
           raise exn)
  in
  try deliver_pending_with ~append_json ~broadcast_json:broadcast_relay_json pending with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Retryable_failure (pending, Append, exn)
;;

let should_drain_subscription pending =
  (* Do not move new OAS bus events into the local retry queue while
     failed relays are still pending.  The OAS subscriber stream is
     bounded, so leaving it undrained applies publisher backpressure
     instead of dropping the oldest local relay event. *)
  pending = []
;;

let prepare_pending_events events = List.filter_map prepare_pending_event events

let rec process_pending ?store_ref acc = function
  | [] -> List.rev acc
  | pending :: rest ->
    (match deliver_pending ?store_ref pending with
     | Delivered -> process_pending ?store_ref acc rest
     | Retryable_failure (pending, stage, exn) ->
       let attempt = pending.attempts + 1 in
       Keeper_fd_pressure.note_exception ~site:"oas_event_bridge.relay" exn;
       Keeper_disk_pressure.note_exception ~site:"oas_event_bridge.relay" exn;
       if attempt >= relay_max_attempts
       then (
         Otel_metric_store.inc_counter
           Otel_metric_store.metric_oas_sse_relay_drops
           ~labels:[ "stage", relay_stage_to_string stage ]
           ();
         emit_relay_drop_log
           ~pending
           ~stage_label:(relay_stage_to_string stage)
           ~attempts:attempt;
         broadcast_drop_marker
           ~pending
           ~stage_label:(relay_stage_to_string stage)
           ~attempts:attempt;
         process_pending ?store_ref acc rest)
       else (
         Otel_metric_store.inc_counter
           Otel_metric_store.metric_oas_sse_relay_retries
           ~labels:[ "stage", relay_stage_to_string stage ]
           ();
         emit_relay_retry_log ~pending ~stage ~attempt exn;
         process_pending ?store_ref ({ pending with attempts = attempt } :: acc) rest))
;;

type bridge_pending_relay = pending_relay
type bridge_relay_stage = relay_stage
type bridge_relay_result = relay_result

let oas_event_store ~config =
  let retention_days = oas_event_retention_days () in
  Dated_jsonl.create
    ~base_dir:(Filename.concat (Workspace.masc_root_dir config) "oas-events")
    ?retention_days
    ()
;;

let deliver_pending_with_impl = deliver_pending_with

module For_testing = struct
  type pending_relay =
    { json : Yojson.Safe.t
    ; attempts : int
    ; appended : bool
    }

  type relay_stage =
    | Append
    | Broadcast

  type relay_result =
    | Delivered
    | Retryable_failure of pending_relay * relay_stage * exn

  let make_pending json = { json; attempts = 0; appended = false }
  let relay_max_queue_depth = relay_max_queue_depth
  let resolve_oas_event_retention_days = resolve_oas_event_retention_days

  let to_pending (pending : pending_relay) : bridge_pending_relay =
    { json = pending.json; attempts = pending.attempts; appended = pending.appended }
  ;;

  let of_pending (pending : bridge_pending_relay) : pending_relay =
    { json = pending.json; attempts = pending.attempts; appended = pending.appended }
  ;;

  (* Issue #8676: convert directly between the outer [relay_stage] and the
     [For_testing.relay_stage] mirror. The previous string-roundtrip carried
     a permissive [_ -> Broadcast] catch-all that would silently misclassify
     any future outer constructor as [Broadcast] in test stage assertions
     (#8605 anti-pattern). Direct match makes adding a constructor a
     compile error here, forcing the test mirror to stay in sync. *)
  let of_stage : bridge_relay_stage -> relay_stage = function
    | Append -> Append
    | Broadcast -> Broadcast
  ;;

  let of_result (result : bridge_relay_result) =
    match result with
    | Delivered -> Delivered
    | Retryable_failure (pending, stage, exn) ->
      Retryable_failure (of_pending pending, of_stage stage, exn)
  ;;

  let deliver_pending_with ~append_json ~broadcast_json pending =
    deliver_pending_with_impl ~append_json ~broadcast_json (to_pending pending)
    |> of_result
  ;;

  let should_drain_subscription pending =
    should_drain_subscription (List.map to_pending pending)
  ;;
end

let start_impl ~interval_s ~sw ~clock ~(config : Workspace.config) ~bus =
  let store = ref (oas_event_store ~config) in
  let sub =
    Agent_sdk_metrics_bridge.subscribe
      ~purpose:"sse_bridge"
      ~filter:Agent_sdk.Event_bus.accept_all
      bus
  in
  Eio.Switch.on_release sw (fun () -> Agent_sdk_metrics_bridge.unsubscribe bus sub);
  let pending = ref [] in
  update_relay_queue_depth !pending;
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         pending := process_pending ~store_ref:store [] !pending;
         if should_drain_subscription !pending
         then (
           let events = Agent_sdk_metrics_bridge.drain sub in
           pending := prepare_pending_events events;
           pending := process_pending ~store_ref:store [] !pending);
         update_relay_queue_depth !pending
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "oas_event_bridge: relay iteration failed: %s"
           (Printexc.to_string exn));
      Eio.Time.sleep clock interval_s;
      loop ()
    in
    loop ())
;;

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~(config : Workspace.config) ~bus =
  start_impl ~interval_s:(drain_interval_s ()) ~sw ~clock ~config ~bus
;;

let start_with_interval
      ~drain_interval_s:interval_s
      ~sw
      ~clock
      ~(config : Workspace.config)
      ~bus
  =
  start_impl ~interval_s ~sw ~clock ~config ~bus
;;
