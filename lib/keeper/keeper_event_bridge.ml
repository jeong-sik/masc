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

(** Delay between failed relay attempts. Idle subscriptions wait for events. *)
let retry_interval_s () = Env_config.Agent_core_sse.drain_interval_sec

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
  let turn_id =
    Option.bind evt.meta.caller_scope (fun scope ->
      Result.to_option (Keeper_turn_scope.keeper_turn_id scope))
  in
  let log_at ~keeper_name level message =
    Log.Agent_core_event.emit level ~keeper_name ?turn_id ~details:json message
  in
  let log_routine ~keeper_name message =
    Log.Agent_core_event.routine ~keeper_name ?turn_id ~details:json "%s" message
  in
  let log ~keeper_name message = log_at ~keeper_name Log.Info message in
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
    log ~keeper_name:agent_name (Printf.sprintf "agent started agent=%s task_id=%s" agent_name task_id)
  | Agent_core.Event_bus.AgentCompleted { agent_name; task_id; elapsed; _ } ->
    log ~keeper_name:agent_name
      (Printf.sprintf
         "agent completed agent=%s task_id=%s elapsed_s=%.3f"
         agent_name
         task_id
         elapsed)
  | Agent_core.Event_bus.AgentYielded { agent_name; task_id; turn; elapsed } ->
    log ~keeper_name:agent_name
      (Printf.sprintf
         "agent yielded agent=%s task_id=%s turn=%d elapsed_s=%.3f"
         agent_name
         task_id
         turn
         elapsed)
  | Agent_core.Event_bus.AgentInputRequired { agent_name; task_id; request; _ } ->
    log ~keeper_name:agent_name
      (Printf.sprintf
         "agent input required agent=%s task_id=%s request_id=%s"
         agent_name
         task_id
         request.request_id)
  | Agent_core.Event_bus.TurnStarted { agent_name; turn } ->
    log_routine ~keeper_name:agent_name (Printf.sprintf "turn started agent=%s turn=%d" agent_name turn)
  | Agent_core.Event_bus.TurnCompleted { agent_name; turn } ->
    log_routine ~keeper_name:agent_name (Printf.sprintf "turn completed agent=%s turn=%d" agent_name turn)
  | Agent_core.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
    log_routine ~keeper_name:agent_name (Printf.sprintf "tool called agent=%s tool_name=%s" agent_name tool_name)
  | Agent_core.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
    log_routine ~keeper_name:agent_name
      (Printf.sprintf "tool completed agent=%s tool_name=%s" agent_name tool_name)
  | Agent_core.Event_bus.ToolApprovalCompleted
      { agent_name; tool_name; approval; _ } ->
    log_routine ~keeper_name:agent_name
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
      Agent_core_sha256.(digest_string (String.concat "\n" tool_names) |> to_hex)
    in
    log_routine ~keeper_name:agent_name
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

(* The only scope masc hands an agent's bus is the keeper turn
   ([Keeper_turn_scope.bus]), so the row carries it as [keeper_turn_id] and
   the key is always present. A scope that does not read as one is a masc
   invariant broken by whoever scoped the bus, not a shape the row admits:
   it is logged here and the row says null, the same as no scope. *)
let caller_scope_fields = function
  | None -> [ "keeper_turn_id", `Null ]
  | Some scope ->
    (match Keeper_turn_scope.keeper_turn_id scope with
     | Ok keeper_turn_id -> [ "keeper_turn_id", `Int keeper_turn_id ]
     | Error detail ->
       Log.Server.error "keeper event bridge: %s; the row carries no keeper turn" detail;
       [ "keeper_turn_id", `Null ])
;;

(** Build the durable/SSE JSON wrapper from the canonical event envelope.
    [event_id], [correlation_id], and [run_id] are producer-owned mandatory
    identity; adapters must not reconstruct them from content or timestamps.
    [caused_by] is the envelope's causation pointer (agent-core boundary) — for
    [agent_core:tool_completed] it equals the matching [agent_core:tool_called] row's
    [run_id], the only key that pairs the two rows. The envelope's
    [caller_scope] is written as [keeper_turn_id] ({!caller_scope_fields}). *)
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
      ~caller_scope
      ~event_type
      ~payload
      ?agent_name
      ?task_id
      ?turn
      ?tool_name
      ()
  =
  `Assoc
    ([ "type", `String ("agent_core:" ^ event_type)
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
    ]
     @ caller_scope_fields caller_scope
     @ [ "payload", payload ])
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

(* Custom event names use dots internally, per the AGENT_CORE Custom
   convention. On the SSE wire a [masc.*] name uses the public separator, and
   every dot is translated so a multi-segment name stays intact. *)
let public_custom_event_type name =
  if String.length name > 5 && String.starts_with ~prefix:"masc." name then
    String.map (fun c -> if c = '.' then ':' else c) name
  else name

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
    ; caller_scope
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
      ~caller_scope
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
    (* Admission precedes the keeper result row. The completion payload adds
       the product execution association after post-effect observers finish. *)
    let payload =
      `Assoc
        ([ "agent_name", `String agent_name; "tool_name", `String tool_name ]
         @ invocation_payload_fields invocation)
    in
    Some (wrap ~event_type:"tool_called" ~payload ~agent_name ~tool_name ())
  | Agent_core.Event_bus.ToolCompleted { invocation; agent_name; tool_name; _ } ->
    (* Durable occurrences carry canonical run/node identity before Gate and
       execution. Non-journalled calls use their live product association. *)
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
      Agent_core_sha256.(digest_string (String.concat "\n" tool_names) |> to_hex)
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
    let event_type = public_custom_event_type name in
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

type relay_class =
  | Source_event
  | Subscription_loss

let subscription_loss_event_type = "relay_subscription_loss"

type pending_relay =
  { json : Yojson.Safe.t
  ; attempts : int
  ; appended : bool
  ; broadcasted : bool
  ; relay_class : relay_class
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
  let attempt_label =
    match pending.relay_class with
    | Source_event -> Printf.sprintf "%d/%d" attempt relay_max_attempts
    | Subscription_loss when not pending.broadcasted -> string_of_int attempt
    | Subscription_loss -> Printf.sprintf "%d/%d" attempt relay_max_attempts
  in
  Log.Misc.warn
    "keeper_event_bridge: retrying event_type=%s stage=%s attempt=%s correlation_id=%s \
     run_id=%s error=%s"
    (relay_event_type pending.json)
    (relay_stage_to_string stage)
    attempt_label
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
    Some { json; attempts = 0; appended = false; broadcasted = false
         ; relay_class = Source_event }
;;

let subscription_loss_notice ~source_id ~sequence count =
  let json =
    `Assoc
      [ "type", `String ("agent_core:" ^ subscription_loss_event_type)
      ; "event_type", `String subscription_loss_event_type
      ; "ts_unix", `Float (Time_compat.now ())
      ; "payload", `Assoc [ "dropped_count", `Int count
                           ; "source_id", `String source_id
                           ; "sequence", `Int sequence ]
      ]
  in
  { json; attempts = 0; appended = false; broadcasted = false
  ; relay_class = Subscription_loss }
;;

let deliver_pending_with
      ~(append_json : Yojson.Safe.t -> unit)
      ~(broadcast_json : on_committed:(unit -> unit) -> Yojson.Safe.t -> unit)
      (pending : pending_relay)
  =
  let append pending =
    if pending.appended then Ok pending
    else
      try
        append_json pending.json;
        Ok { pending with appended = true }
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Retryable_failure (pending, Append, exn))
  in
  let broadcast pending =
    if pending.broadcasted then Ok pending
    else begin
      let committed = ref false in
      let confirmed () =
        { pending with broadcasted = true
                     ; attempts = (match pending.relay_class with
                         | Subscription_loss -> 0
                         | Source_event -> pending.attempts) }
      in
      try
        broadcast_json ~on_committed:(fun () -> committed := true) pending.json;
        Ok (confirmed ())
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn when pending.relay_class = Subscription_loss && !committed ->
        (* The observer queues and replay buffer already own the notice.
           External fanout is a separate boundary and may have failed. *)
        Log.Misc.warn
          "keeper_event_bridge: loss notice committed before external fanout failed: %s"
          (Printexc.to_string exn);
        Ok (confirmed ())
      | exn -> Error (Retryable_failure (pending, Broadcast, exn))
    end
  in
  (* A loss notice must reach live and replaying observers even if the
     event-store append is failing. Publish it ahead of later relayed events.
     Ordinary source events keep their append-before-broadcast contract. *)
  let first, second =
    match pending.relay_class with
    | Source_event -> append, broadcast
    | Subscription_loss -> broadcast, append
  in
  match first pending with
  | Error failure -> failure
  | Ok pending ->
    (match second pending with
     | Error failure -> failure
     | Ok _ -> Delivered)
;;


(* The reference keeps the location beside the handle so a failed append can
   open the same store again. *)
let deliver_pending ?store_ref ~loss_target (pending : pending_relay) =
  let append_json =
    match store_ref with
    | None -> fun _json -> ()
    | Some store_ref ->
      fun json ->
        let base_path, location, store = !store_ref in
        (try Fun.protect ~finally:(fun () ->
            Dashboard_observation_commit.written ~base_path ~scope:`Workspace `Telemetry)
            (fun () -> Dated_jsonl.append store json) with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           store_ref := base_path, location, Dated_jsonl.open_store location;
           raise exn)
  in
  let target = match pending.relay_class with
    | Source_event -> Sse.All
    | Subscription_loss -> loss_target
  in
  let broadcast_json ~on_committed json =
    Sse.broadcast_to_with_commit target ~on_committed json
  in
  try deliver_pending_with ~append_json ~broadcast_json pending with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Retryable_failure (pending, Append, exn)
;;

let should_drain_subscription pending =
  (* Do not move new AGENT_CORE bus events into the local retry queue while
     failed relays are still pending. The bounded subscriber may drop its
     oldest events during this wait; its next batch reports that loss. *)
  pending = []
;;

let report_subscription_loss = function
  | Runtime_event_bus.Nothing_dropped -> ()
  | Dropped count ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_agent_core_sse_relay_drops
      ~labels:[ "stage", "queue" ] ~delta:(float_of_int count) ();
    Log.Server.error
      "keeper_event_bridge: subscriber queue dropped %d events before relay"
      count
;;

let prepare_pending_events events = List.filter_map prepare_pending_event events

let rec process_pending ?store_ref ~loss_target ~next_loss acc = function
  | [] -> List.rev acc
  | pending :: rest ->
    (match deliver_pending ?store_ref ~loss_target pending with
     | Delivered -> process_pending ?store_ref ~loss_target ~next_loss acc rest
     | Retryable_failure (pending, stage, exn) ->
       let attempt = if pending.attempts = max_int then max_int else pending.attempts + 1 in
       Keeper_fd_pressure.note_exception ~site:"keeper_event_bridge.relay" exn;
       Keeper_disk_pressure.note_exception ~site:"keeper_event_bridge.relay" exn;
       if pending.relay_class = Subscription_loss && not pending.broadcasted then (
         Otel_metric_store.inc_counter
           Otel_metric_store.metric_agent_core_sse_relay_retries
           ~labels:[ "stage", relay_stage_to_string stage ] ();
         emit_relay_retry_log ~pending ~stage ~attempt exn;
         List.rev_append acc ({ pending with attempts = attempt } :: rest))
       else if pending.relay_class = Subscription_loss && attempt >= relay_max_attempts then (
         (* Observers already have the notice. A persistently unavailable
            debug store must not hold every later event indefinitely. *)
         Otel_metric_store.inc_counter
           Otel_metric_store.metric_agent_core_sse_relay_drops
           ~labels:[ "stage", relay_stage_to_string stage ] ();
         emit_relay_drop_log ~pending ~stage_label:(relay_stage_to_string stage) ~attempts:attempt;
         process_pending ?store_ref ~loss_target ~next_loss acc rest)
       else if attempt >= relay_max_attempts
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
           ~attempts:attempt;
         (* The diagnostic marker is best effort and is not the observer's
            continuity contract. Queue the scoped loss notice ahead of later
            source events; it retries until SSE has committed it. *)
         process_pending ?store_ref ~loss_target ~next_loss acc
           (next_loss 1 :: rest))
       else (
         Otel_metric_store.inc_counter
           Otel_metric_store.metric_agent_core_sse_relay_retries
           ~labels:[ "stage", relay_stage_to_string stage ]
           ();
         emit_relay_retry_log ~pending ~stage ~attempt exn;
         let retry = { pending with attempts = attempt } in
         (match pending.relay_class with
          | Source_event ->
            (* Later events in this batch cannot pass the failed source:
               if it exhausts retries, observers must see the loss first. *)
            List.rev_append acc (retry :: rest)
          | Subscription_loss ->
            (* The notice already reached observers; a failing debug-store
               append may be retried without holding up later events. *)
            process_pending ?store_ref ~loss_target ~next_loss (retry :: acc) rest)))
;;

let agent_core_event_store ~config =
  let location =
    Dated_jsonl.Store.at
      (Workspace.dated_store_root config)
      Dated_jsonl.Store.Root.Agent_core_events
  in
  config.base_path, location, Dated_jsonl.open_store location
;;

let start_impl ~before_prepare ~interval_s ~sw ~clock ~(config : Workspace.config) ~bus =
  let store = ref (agent_core_event_store ~config) in
  let loss_target =
    Sse.Runtime_observers (Sse.runtime_authority_exn ~base_path:config.base_path)
  in
  let loss_source_id = ref (Random_id.uuid_v7 ()) in
  let loss_sequence = ref 0 in
  let next_loss count =
    if !loss_sequence = max_int then (
      loss_source_id := Random_id.uuid_v7 ();
      loss_sequence := 0);
    incr loss_sequence;
    subscription_loss_notice ~source_id:!loss_source_id
      ~sequence:!loss_sequence count
  in
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
      let retry_iteration = ref false in
      let continue =
        try
         pending := process_pending ~store_ref:store ~loss_target ~next_loss [] !pending;
         update_relay_queue_depth !pending;
         if should_drain_subscription !pending
         then (
           match Runtime_event_bus.await_reporting_drops sub with
           | Unsubscribed -> false
           | Batch { events; overflow_loss } ->
           (* Install the loss notice before logging or converting the rest
              of the drained batch, so it remains pending across retryable
              failures. It is published before later events. *)
           pending := (match overflow_loss with
             | Runtime_event_bus.Nothing_dropped -> []
             | Runtime_event_bus.Dropped count -> [ next_loss count ]);
           let prepared =
           try
           report_subscription_loss overflow_loss;
           before_prepare ();
           (* A wake is optional, coalesced metadata. It never moves source
              bodies into this relay or waits for an Add-on to observe them. *)
           let compare_activity (a : Lane_addon_sources.activity) (b : Lane_addon_sources.activity) =
             match a, b with
             | Tool_completed, Tool_completed -> 0
             | Tool_completed, (Machine_changed _ | Browser_changed | Fusion_changed _) -> -1
             | (Machine_changed _ | Browser_changed | Fusion_changed _), Tool_completed -> 1
             | Machine_changed a, Machine_changed b ->
               let rank = function Machine_lane.Msx -> 0 | Machine_lane.Dos -> 1 in
               Int.compare (rank a) (rank b)
             | Machine_changed _, (Browser_changed | Fusion_changed _) -> -1
             | (Browser_changed | Fusion_changed _), Machine_changed _ -> 1
             | Browser_changed, Browser_changed -> 0
             | Browser_changed, Fusion_changed _ -> -1
             | Fusion_changed _, Browser_changed -> 1
             | Fusion_changed a, Fusion_changed b -> String.compare a b
           in
           let activities = List.filter_map (fun (event : Agent_core.Event_bus.event) ->
             match event.payload with
             | Agent_core.Event_bus.ToolCompleted {tool_name;_} ->
                 (* The mapping lives beside the activity type and names every
                    operation; a tool outside the misc table is a completion
                    with no source of its own. *)
                 Some (match Tool_schemas_misc.misc_operation_of_tool_name tool_name with
                   | Some operation -> Lane_addon_sources.activity_of_misc_operation operation
                   | None -> Lane_addon_sources.Tool_completed)
             | Agent_core.Event_bus.AgentStarted _ | Agent_core.Event_bus.AgentCompleted _
             | Agent_core.Event_bus.AgentYielded _ | Agent_core.Event_bus.AgentInputRequired _
             | Agent_core.Event_bus.AgentFailed _ | Agent_core.Event_bus.ToolCalled _
             | Agent_core.Event_bus.TurnStarted _ | Agent_core.Event_bus.TurnReady _
             | Agent_core.Event_bus.TurnCompleted _ | Agent_core.Event_bus.HandoffRequested _
             | Agent_core.Event_bus.HandoffCompleted _ | Agent_core.Event_bus.ElicitationCompleted _
             | Agent_core.Event_bus.ToolApprovalCompleted _
             | Agent_core.Event_bus.InferenceTelemetry _ | Agent_core.Event_bus.Custom (_, _) -> None) events |> List.sort_uniq compare_activity in
           List.iter (fun activity -> Lane_addon_runtime.notify_activity ~config ~activity) activities;
           prepare_pending_events events
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn ->
             (* The subscription has already handed this batch to us. If
                conversion or an activity wake fails, none of the prepared
                list was installed. Record the loss before diagnostics, which
                must not be able to make the batch disappear a second time. *)
             (match events with
              | [] -> ()
              | _ ->
                let count = List.length events in
                pending := !pending @ [ next_loss count ];
                Otel_metric_store.inc_counter
                  Otel_metric_store.metric_agent_core_sse_relay_drops
                  ~labels:[ "stage", "prepare" ] ~delta:(float_of_int count) ());
             Keeper_fd_pressure.note_exception ~site:"keeper_event_bridge.prepare" exn;
             Keeper_disk_pressure.note_exception ~site:"keeper_event_bridge.prepare" exn;
             Log.Misc.warn "keeper_event_bridge: failed to prepare event batch";
             []
           in
           pending := !pending @ prepared;
           pending := process_pending ~store_ref:store ~loss_target ~next_loss [] !pending;
           update_relay_queue_depth !pending;
           true)
         else (
           update_relay_queue_depth !pending;
           true)
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "keeper_event_bridge: relay iteration failed: %s"
           (Printexc.to_string exn);
         retry_iteration := true;
         true
      in
      if continue then (
        if !retry_iteration || !pending <> [] then Eio.Time.sleep clock interval_s;
        loop ())
    in
    loop ())
;;

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~(config : Workspace.config) ~bus =
  start_impl ~before_prepare:(fun () -> ())
    ~interval_s:(retry_interval_s ()) ~sw ~clock ~config ~bus
;;

module For_testing = struct
  let emit_native_event_log = emit_native_event_log
  let start_with_preparation_hook = start_impl
end
