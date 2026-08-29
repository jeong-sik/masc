(** AGENT_CORE Event_bus → SSE Bridge.

    Subscribes to all events on the AGENT_CORE Event_bus (both MASC Custom
    events and AGENT_CORE native lifecycle events) and relays them as SSE
    broadcasts to connected dashboard clients.

    AGENT_CORE native events (ToolCalled, TurnCompleted, etc.) are serialized
    to a uniform JSON format with an "agent_core:" prefix so consumers can
    distinguish them from MASC-originated events.

    Every event carries the canonical [Event_envelope] with a producer-owned
    [event_id], correlation/run scope, event and observation time, and causal
    pointers. The exact envelope is emitted into both durable JSONL and SSE so
    downstream consumers can join and deduplicate one occurrence without
    inspecting content.

    @since 2.96.0
    @modified 2.255.0 — accept AGENT_CORE native events (#5620)
    @modified 2.260.0 — emit canonical producer event identity *)

open Keeper_event_bridge_inference
open Keeper_event_bridge_error_json

(** Drain interval: how often we poll the Event_bus subscription.
    Lower default keeps the dashboard close to real-time, while staying
    runtime-tunable for quieter deployments. *)
let drain_interval_s () = Env_config.Agent_core_sse.drain_interval_sec

let payload_agent_name payload =
  (* Check [agent_name], [agent], then [keeper_name] for Custom events
     whose publisher stores the per-agent attribution under the
     keeper-specific key (for example [masc:keeper:lifecycle]).
     Without this fallback the top-level
     envelope [agent_name] is Null for 9%+ of daily events, breaking
     per-agent filters over the Dated_jsonl store under [.masc/agent-core-events/].
     See #7827. *)
  match Json_util.get_string payload "agent_name" with
  | Some _ as value -> value
  | None ->
    (match Json_util.get_string payload "agent" with
     | Some _ as value -> value
     | None -> Json_util.get_string payload "keeper_name")
;;

let tool_approval_label = function
  | Agent_core.Hooks.Approved -> "approved"
  | Agent_core.Hooks.Denied -> "denied"
  | Agent_core.Hooks.Timed_out -> "timed_out"
;;

let emit_native_event_log (evt : Agent_core.Event_bus.event) (json : Yojson.Safe.t) =
  let log_at level message =
    Log.Agent_core_event.emit level ~details:json message
  in
  let log_routine message =
    Log.Agent_core_event.routine ~details:json "%s" message
  in
  let log message = log_at Log.Info message in
  (* Per-turn and per-tool lifecycle is emitted at [routine] (default Debug), not
     Info, because it is a redundant TEXT rendering of events already carried by
     two authoritative planes: (1) for keeper agents, the keeper hook logs the
     richer "[Keeper] ... tool_call ... outcome=... out_len=" / "[Keeper/...] turn="
     lines at Info; (2) for every agent, [Sse.broadcast]
     (see [prepare_pending_event]) carries the structured stream the dashboard and
     REST/SSE subscribers actually consume. Demoting these four high-frequency
     arms removes the Info-level console doubling without losing the data — it
     stays retrievable at Debug and the structured/SSE planes are untouched. This
     is deduplication against an existing SSOT, not symptom suppression: there is
     no recurring failure being hidden. Agent- and context-level lifecycle below
     stay at Info (no keeper-hook duplicate, low frequency). [TurnReady] already
     uses [log_routine] for the same reason. *)
  match evt.payload with
  | Agent_core.Event_bus.AgentStarted { agent_name; task_id } ->
    log (Printf.sprintf "agent started agent=%s task_id=%s" agent_name task_id)
  | Agent_core.Event_bus.AgentCompleted { agent_name; task_id; elapsed; _ } ->
    log
      (Printf.sprintf
         "agent completed agent=%s task_id=%s elapsed_s=%.3f"
         agent_name
         task_id
         elapsed)
  | Agent_core.Event_bus.AgentYielded { agent_name; task_id; turn; elapsed } ->
    log
      (Printf.sprintf
         "agent yielded agent=%s task_id=%s turn=%d elapsed_s=%.3f"
         agent_name
         task_id
         turn
         elapsed)
  | Agent_core.Event_bus.AgentInputRequired { agent_name; task_id; request; _ } ->
    log
      (Printf.sprintf
         "agent input required agent=%s task_id=%s request_id=%s"
         agent_name
         task_id
         request.request_id)
  | Agent_core.Event_bus.TurnStarted { agent_name; turn } ->
    log_routine (Printf.sprintf "turn started agent=%s turn=%d" agent_name turn)
  | Agent_core.Event_bus.TurnCompleted { agent_name; turn } ->
    log_routine (Printf.sprintf "turn completed agent=%s turn=%d" agent_name turn)
  | Agent_core.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
    log_routine (Printf.sprintf "tool called agent=%s tool_name=%s" agent_name tool_name)
  | Agent_core.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
    log_routine
      (Printf.sprintf "tool completed agent=%s tool_name=%s" agent_name tool_name)
  | Agent_core.Event_bus.ToolApprovalCompleted
      { agent_name; tool_name; approval; _ } ->
    log_routine
      (Printf.sprintf
         "tool approval completed agent=%s tool_name=%s approval=%s"
         agent_name
         tool_name
         (tool_approval_label approval))
  | Agent_core.Event_bus.TurnReady { agent_name; turn; tool_names } ->
    (* [substrate:tool_surface] — deterministic per-turn snapshot of the
         tool list the LLM actually sees this turn (after guardrails,
         and operator policy).  Emitted as a single
         grep-friendly line with a stable hash so operators can confirm
         which tools were on the LLM's surface for a given turn without
         enabling verbose tool dumps. *)
    let names_hash =
      Digestif.SHA256.(digest_string (String.concat "\n" tool_names) |> to_hex)
    in
    log_routine
      (Printf.sprintf
         "[substrate:tool_surface] agent=%s turn=%d count=%d names_hash=%s"
         agent_name
         turn
         (List.length tool_names)
         (String.sub names_hash 0 16))
  (* Variants below previously absorbed by [_ -> ()] catch-all.  Each is
     enumerated explicitly so adding a new [Agent_core.Event_bus.payload]
     variant fails the build instead of silently dropping the log line. *)
  | Agent_core.Event_bus.AgentFailed _
  | Agent_core.Event_bus.HandoffRequested _
  | Agent_core.Event_bus.HandoffCompleted _
  | Agent_core.Event_bus.ElicitationCompleted _
  | Agent_core.Event_bus.InferenceTelemetry _
  | Agent_core.Event_bus.Custom _ -> ()
;;

(** Build the durable/SSE JSON wrapper from the canonical event envelope.
    [event_id], [correlation_id], and [run_id] are producer-owned mandatory
    identity; adapters must not reconstruct them from content or timestamps.
    [caused_by] is the envelope's causation pointer (agent-core boundary) — for
    [agent_core:tool_completed] it equals the matching [agent_core:tool_called] row's
    [run_id], the only key that pairs the two rows. *)
let wrap_event
      ~event_id
      ~event_time
      ~observed_at
      ~correlation_id
      ~run_id
      ?seq
      ?parent_event_id
      ?caused_by
      ~source_clock
      ~event_type
      ~payload
      ?agent_name
      ?task_id
      ?turn
      ?tool_name
      ()
  =
  `Assoc
    [ "type", `String ("agent_core:" ^ event_type)
    ; "event_type", `String event_type
    ; "event_id", `String event_id
    ; "ts_unix", `Float event_time
    ; "observed_at", `Float observed_at
    ; "correlation_id", `String correlation_id
    ; "run_id", `String run_id
    ; "seq", Option.fold ~none:`Null ~some:(fun value -> `Int value) seq
    ; "parent_event_id", Json_util.string_opt_to_json_trimmed parent_event_id
    ; "caused_by", Json_util.string_opt_to_json_trimmed caused_by
    ; "source_clock", `String (Agent_core.Event_envelope.source_clock_to_string source_clock)
    ; "agent_name", Json_util.string_opt_to_json_trimmed agent_name
    ; "task_id", Json_util.string_opt_to_json_trimmed task_id
    ; "turn", Option.fold ~none:`Null ~some:(fun value -> `Int value) turn
    ; "tool_name", Json_util.string_opt_to_json_trimmed tool_name
    ; "payload", payload
    ]
;;

(** Serialize an Agent Core event to JSON for SSE relay and durable storage.
    The exhaustive payload match makes every new Agent Core constructor a
    compile-time update requirement at this boundary. *)
let invocation_payload_fields invocation =
  let tool_use_id = Agent_core.Tool_contract.Invocation.tool_use_id invocation in
  let schedule = Agent_core.Tool_contract.Invocation.schedule invocation in
  [ "turn", `Int (Agent_core.Tool_contract.Invocation.turn invocation)
  ; "planned_index", `Int schedule.planned_index
  ; "batch_index", `Int schedule.batch_index
  ; "batch_size", `Int schedule.batch_size
  ; ( "execution_mode"
    , Agent_core.Tool_contract.execution_mode_to_yojson schedule.execution_mode )
  ]
  @ (if tool_use_id = "" then [] else [ "tool_use_id", `String tool_use_id ])
;;

let native_event_to_json (evt : Agent_core.Event_bus.event) : Yojson.Safe.t option =
  let
    { Agent_core.Event_envelope.event_id
    ; correlation_id
    ; run_id
    ; event_time
    ; observed_at
    ; seq
    ; parent_event_id
    ; caused_by
    ; source_clock
    }
    = evt.meta
  in
  let wrap =
    wrap_event
      ~event_id
      ~event_time
      ~observed_at
      ~correlation_id
      ~run_id
      ?seq
      ?parent_event_id
      ?caused_by
      ~source_clock
  in
  match evt.payload with
  | Agent_core.Event_bus.AgentStarted { agent_name; task_id } ->
    let payload =
      `Assoc [ "agent_name", `String agent_name; "task_id", `String task_id ]
    in
    Some (wrap ~event_type:"agent_started" ~payload ~agent_name ~task_id ())
  | Agent_core.Event_bus.AgentCompleted { agent_name; task_id; elapsed; response } ->
    let provider = inference_provider_bucket ~provider:"" ~model:response.model in
    let model_bucket = inference_model_bucket ~provider:"" ~model:response.model in
    let cost_usd =
      match response.usage with
      | Some usage -> usage.cost_usd
      | None -> None
    in
    observe_inference_cost ~provider ~model_bucket cost_usd;
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name
         ; "task_id", `String task_id
         ; "elapsed_s", `Float elapsed
         ]
         @ agent_completed_response_fields response)
    in
    Some (wrap ~event_type:"agent_completed" ~payload ~agent_name ~task_id ())
  | Agent_core.Event_bus.AgentYielded { agent_name; task_id; turn; elapsed } ->
    let payload =
      `Assoc
        [ "agent_name", `String agent_name
        ; "task_id", `String task_id
        ; "turn", `Int turn
        ; "elapsed_s", `Float elapsed
        ]
    in
    Some
      (wrap
         ~event_type:"agent_yielded"
         ~payload
         ~agent_name
         ~task_id
         ~turn
         ())
  | Agent_core.Event_bus.AgentInputRequired
      { agent_name; task_id; request; elapsed } ->
    let payload =
      `Assoc
        [ "agent_name", `String agent_name
        ; "task_id", `String task_id
        ; "elapsed_s", `Float elapsed
        ; "request_id", `String request.request_id
        ; "participant_name", Json_util.string_opt_to_json request.participant_name
        ; "question", `String request.question
        ; ( "schema"
          , match request.schema with
            | Some schema -> schema
            | None -> `Null )
        ; "timeout_s", Json_util.float_opt_to_json request.timeout_s
        ; "created_at", `Float request.created_at
        ]
    in
    Some
      (wrap ~event_type:"agent_input_required" ~payload ~agent_name ~task_id ())
  | Agent_core.Event_bus.AgentFailed { agent_name; task_id; error; elapsed } ->
    let projection = agent_failed_error_projection error in
    let payload =
      Sse_event.agent_failed_payload
        ~agent_name
        ~task_id
        ~elapsed_s:elapsed
        ~error:projection.error
        ~error_domain:projection.error_domain
        ~error_code:projection.error_code
        ~error_retryable:projection.error_retryable
        ~error_detail:projection.error_detail
    in
    Some
      (wrap ~event_type:"agent_failed" ~payload ~agent_name ~task_id ())
  | Agent_core.Event_bus.ToolCalled { invocation; agent_name; tool_name; _ } ->
    (* tool_called publishes before execution, so the keeper hook has not
       minted an execution_id yet — this row carries the provider call id
       only; the matching tool_completed row carries both. *)
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name; "tool_name", `String tool_name ]
         @ invocation_payload_fields invocation)
    in
    Some (wrap ~event_type:"tool_called" ~payload ~agent_name ~tool_name ())
  | Agent_core.Event_bus.ToolCompleted { invocation; agent_name; tool_name; _ } ->
    (* RFC-0233 PR-2: the keeper post_tool_use hook registered this exact
       immutable invocation before AGENT_CORE published the event. Physical
       invocation identity keeps blank/repeated provider ids distinct. *)
    let execution_id_fields =
      match Keeper_execution_join.take ~invocation with
      | Some execution_id -> [ "execution_id", `String execution_id ]
      | None -> []
    in
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name; "tool_name", `String tool_name ]
         @ invocation_payload_fields invocation
         @ execution_id_fields)
    in
    Some (wrap ~event_type:"tool_completed" ~payload ~agent_name ~tool_name ())
  | Agent_core.Event_bus.ToolApprovalCompleted
      { invocation; agent_name; tool_name; approval } ->
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name
         ; "tool_name", `String tool_name
         ; "approval", `String (tool_approval_label approval)
         ]
         @ invocation_payload_fields invocation)
    in
    Some
      (wrap
         ~event_type:"tool_approval_completed"
         ~payload
         ~agent_name
         ~tool_name
         ())
  | Agent_core.Event_bus.TurnStarted { agent_name; turn } ->
    let payload = `Assoc [ "agent_name", `String agent_name; "turn", `Int turn ] in
    Some (wrap ~event_type:"turn_started" ~payload ~agent_name ~turn ())
  | Agent_core.Event_bus.TurnCompleted { agent_name; turn } ->
    let payload = `Assoc [ "agent_name", `String agent_name; "turn", `Int turn ] in
    Some (wrap ~event_type:"turn_completed" ~payload ~agent_name ~turn ())
  | Agent_core.Event_bus.TurnReady { agent_name; turn; tool_names } ->
    let names_hash =
      Digestif.SHA256.(digest_string (String.concat "\n" tool_names) |> to_hex)
    in
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
  | Agent_core.Event_bus.HandoffRequested { from_agent; to_agent; reason } ->
    let payload =
      `Assoc
        [ "from_agent", `String from_agent
        ; "to_agent", `String to_agent
        ; "reason", `String reason
        ]
    in
    Some (wrap ~event_type:"handoff_requested" ~payload ~agent_name:from_agent ())
  | Agent_core.Event_bus.HandoffCompleted { from_agent; to_agent; elapsed } ->
    let payload =
      `Assoc
        [ "from_agent", `String from_agent
        ; "to_agent", `String to_agent
        ; "elapsed_s", `Float elapsed
        ]
    in
    Some (wrap ~event_type:"handoff_completed" ~payload ~agent_name:from_agent ())
  | Agent_core.Event_bus.ElicitationCompleted _ -> None (* Internal; no SSE relay needed *)
  | Agent_core.Event_bus.Custom (name, payload) ->
    (* Custom event names use dots internally.
         Translate dots to the public SSE separator for [masc.*] events.
         Internally MASC emits dot-separated names per AGENT_CORE Custom convention.
         Translate every dot so multi-segment names remain intact. *)
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
  | Agent_core.Event_bus.InferenceTelemetry
      { provider
      ; model
      ; prompt_tokens
      ; completion_tokens
      ; prompt_ms
      ; decode_ms
      ; decode_tok_s
      ; _
      } ->
    (* Per-token telemetry from agent-core boundary; not surfaced over SSE. Preserve
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
;;

let relay_max_attempts = 3

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

let broadcast_relay_json json =
  Sse.broadcast_to All json
;;

let update_relay_queue_depth pending =
  Otel_metric_store.set_gauge
    Otel_metric_store.metric_agent_core_sse_relay_queue_depth
    (float_of_int (List.length pending))
;;

let emit_relay_retry_log
      ~(pending : pending_relay)
      ~(stage : relay_stage)
      ~(attempt : int)
      exn
  =
  Log.Misc.warn
    "keeper_event_bridge: retrying event_type=%s stage=%s attempt=%d/%d correlation_id=%s \
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
    "keeper_event_bridge: dropping event_type=%s stage=%s attempts=%d correlation_id=%s \
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
      [ "type", `String "agent_core:relay_dropped"
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
      ; "attempts", `Int attempts
      ]
  in
  try Sse.broadcast_to All marker with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (* P2 silent-failure fix: previously only logged.  The drop
         marker is the operator-visible signal that an AGENT_CORE event was
         dropped after exhausting retries; if the drop marker also
         fails to broadcast, operators are blind to the drop entirely.
         Counter is distinct from masc_sse_broadcast_failures_total
         (PR-C #11075) so the recovery-path failure rate is visible
         in isolation from normal broadcast failures. *)
    Transport_metrics.inc_relay_drop_marker_failure ();
    Log.Misc.warn
      "keeper_event_bridge: drop marker broadcast failed: %s"
      (Printexc.to_string exn)
;;

let prepare_pending_event evt =
  match native_event_to_json evt with
  | None -> None
  | Some json ->
    (* AGENT_CORE event payloads may carry tool output or user-facing text that
         contains invalid UTF-8 bytes (e.g. truncated multi-byte sequences
         from subprocess captures). Scrub once before the event enters the
         retry queue so every retry uses the same sanitized payload. *)
    let json = Inference_utils.sanitize_json_utf8 json in
    emit_native_event_log evt json;
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

let agent_core_event_retention_days_default = 30

let resolve_agent_core_event_retention_days = function
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some days when days > 0 -> Some days
     | Some _ -> None
     | None -> Some agent_core_event_retention_days_default)
  | None -> Some agent_core_event_retention_days_default
;;

let agent_core_event_retention_days () =
  resolve_agent_core_event_retention_days (Sys.getenv_opt "MASC_AGENT_CORE_EVENTS_RETENTION_DAYS")
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
           let retention_days = agent_core_event_retention_days () in
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
  (* Do not move new AGENT_CORE bus events into the local retry queue while
     failed relays are still pending.  The AGENT_CORE subscriber stream is
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
       Keeper_fd_pressure.note_exception ~site:"keeper_event_bridge.relay" exn;
       Keeper_disk_pressure.note_exception ~site:"keeper_event_bridge.relay" exn;
       if attempt >= relay_max_attempts
       then (
         Otel_metric_store.inc_counter
           Otel_metric_store.metric_agent_core_sse_relay_drops
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
           Otel_metric_store.metric_agent_core_sse_relay_retries
           ~labels:[ "stage", relay_stage_to_string stage ]
           ();
         emit_relay_retry_log ~pending ~stage ~attempt exn;
         process_pending ?store_ref ({ pending with attempts = attempt } :: acc) rest))
;;

let agent_core_event_store ~config =
  let retention_days = agent_core_event_retention_days () in
  Dated_jsonl.create
    ~base_dir:(Filename.concat (Workspace.masc_root_dir config) "agent-core-events")
    ?retention_days
    ()
;;

let start_impl ~interval_s ~sw ~clock ~(config : Workspace.config) ~bus =
  let store = ref (agent_core_event_store ~config) in
  let sub =
    Runtime_event_bus.subscribe
      ~capacity:256
      ~overflow:Agent_core.Event_bus.Drop_oldest
      ~purpose:"sse_bridge"
      ~filter:Agent_core.Event_bus.accept_all
      bus
  in
  Eio.Switch.on_release sw (fun () -> Runtime_event_bus.unsubscribe bus sub);
  let pending = ref [] in
  update_relay_queue_depth !pending;
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         pending := process_pending ~store_ref:store [] !pending;
         if should_drain_subscription !pending
         then (
           let events = Runtime_event_bus.drain sub in
           pending := prepare_pending_events events;
           pending := process_pending ~store_ref:store [] !pending);
         update_relay_queue_depth !pending
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "keeper_event_bridge: relay iteration failed: %s"
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
