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

(** Drain interval: how often we poll the Event_bus subscription.
    Lower default keeps the dashboard close to real-time, while staying
    runtime-tunable for quieter deployments. *)
let drain_interval_s () = Env_config.Oas_sse.drain_interval_sec

let json_string_opt = function
  | Some value when String.trim value <> "" -> `String value
  | _ -> `Null

let payload_string_opt key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None)
  | _ -> None

let payload_int_opt key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int value) -> Some value
      | Some (`Intlit value) -> int_of_string_opt value
      | _ -> None)
  | _ -> None

let payload_agent_name payload =
  (* Check [agent_name], [agent], then [keeper_name] for Custom events
     whose publisher stores the per-agent attribution under the
     keeper-specific key (e.g. [masc:keeper:snapshot],
     [masc:keeper:lifecycle]).  Without this fallback the top-level
     envelope [agent_name] is Null for 9%+ of daily events, breaking
     per-agent filters on [.masc/oas-events/*.jsonl].  See #7827. *)
  match payload_string_opt "agent_name" payload with
  | Some _ as value -> value
  | None ->
    (match payload_string_opt "agent" payload with
     | Some _ as value -> value
     | None -> payload_string_opt "keeper_name" payload)

let emit_native_event_log (evt : Agent_sdk.Event_bus.event) (json : Yojson.Safe.t) =
  let log message =
    Log.emit Log.Info ~module_name:"oas:event" ~details:json message
  in
  match evt.payload with
  | Agent_sdk.Event_bus.AgentStarted { agent_name; task_id } ->
      log
        (Printf.sprintf "agent started agent=%s task_id=%s" agent_name task_id)
  | Agent_sdk.Event_bus.AgentCompleted { agent_name; task_id; elapsed; _ } ->
      log
        (Printf.sprintf
           "agent completed agent=%s task_id=%s elapsed_s=%.3f"
           agent_name task_id elapsed)
  | Agent_sdk.Event_bus.TurnStarted { agent_name; turn } ->
      log (Printf.sprintf "turn started agent=%s turn=%d" agent_name turn)
  | Agent_sdk.Event_bus.TurnCompleted { agent_name; turn } ->
      log (Printf.sprintf "turn completed agent=%s turn=%d" agent_name turn)
  | Agent_sdk.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
      log
        (Printf.sprintf "tool called agent=%s tool_name=%s" agent_name tool_name)
  | Agent_sdk.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
      log
        (Printf.sprintf
           "tool completed agent=%s tool_name=%s"
           agent_name tool_name)
  | Agent_sdk.Event_bus.ContextCompacted
      { agent_name; before_tokens; after_tokens; phase } ->
      log
        (Printf.sprintf
           "context compacted agent=%s before_tokens=%d after_tokens=%d phase=%s"
           agent_name before_tokens after_tokens phase)
  | Agent_sdk.Event_bus.ContextOverflowImminent
      { agent_name; estimated_tokens; limit_tokens; ratio } ->
      log
        (Printf.sprintf
           "context overflow imminent agent=%s estimated_tokens=%d limit_tokens=%d ratio=%.3f"
           agent_name estimated_tokens limit_tokens ratio)
  | Agent_sdk.Event_bus.ContextCompactStarted { agent_name; trigger } ->
      log
        (Printf.sprintf
           "context compact started agent=%s trigger=%s"
           agent_name trigger)
  | _ -> ()

(** Build the SSE JSON wrapper. [correlation_id] and [run_id] are
    mandatory (from the envelope); all other fields are optional. *)
let wrap_event ~ts ~correlation_id ~run_id ~event_type ~payload
    ?agent_name ?task_id ?turn ?tool_name () =
  `Assoc
    [
      ("type", `String ("oas:" ^ event_type));
      ("event_type", `String event_type);
      ("ts_unix", `Float ts);
      ("correlation_id", `String correlation_id);
      ("run_id", `String run_id);
      ("agent_name", json_string_opt agent_name);
      ("task_id", json_string_opt task_id);
      ("turn", Option.fold ~none:`Null ~some:(fun value -> `Int value) turn);
      ("tool_name", json_string_opt tool_name);
      ("payload", payload);
    ]

(** Serialize an OAS event to JSON for SSE relay + durable storage.
    Reads envelope metadata ([correlation_id], [run_id], [ts]) from
    [evt.meta] and includes them in every emitted JSON object. *)
let native_event_to_json (evt : Agent_sdk.Event_bus.event) : Yojson.Safe.t option =
  let { Agent_sdk.Event_bus.correlation_id; run_id; ts; _ } = evt.meta in
  let wrap = wrap_event ~ts ~correlation_id ~run_id in
  match evt.payload with
  | Agent_sdk.Event_bus.AgentStarted { agent_name; task_id } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("task_id", `String task_id);
          ]
      in
      Some (wrap ~event_type:"agent_started" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.AgentCompleted { agent_name; task_id; elapsed; result } ->
      let usage_fields =
        match result with
        | Ok resp -> (
            match resp.usage with
            | Some u ->
                [
                  ("input_tokens", `Int u.input_tokens);
                  ("output_tokens", `Int u.output_tokens);
                  ( "cost_usd",
                    match u.cost_usd with
                    | Some c -> `Float c
                    | None -> `Null );
                ]
            | None -> [])
        | Error _ -> []
      in
      let payload =
        `Assoc
          ([
             ("agent_name", `String agent_name);
             ("task_id", `String task_id);
             ("elapsed_s", `Float elapsed);
           ]
          @ usage_fields)
      in
      Some (wrap ~event_type:"agent_completed" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.AgentFailed { agent_name; task_id; error; elapsed } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("task_id", `String task_id);
            ("elapsed_s", `Float elapsed);
            ("error", `String (Agent_sdk.Error.to_string error));
          ]
      in
      Some (wrap ~event_type:"agent_failed" ~payload ~agent_name ~task_id ())
  | Agent_sdk.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("tool_name", `String tool_name);
          ]
      in
      Some (wrap ~event_type:"tool_called" ~payload ~agent_name ~tool_name ())
  | Agent_sdk.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("tool_name", `String tool_name);
          ]
      in
      Some (wrap ~event_type:"tool_completed" ~payload ~agent_name ~tool_name ())
  | Agent_sdk.Event_bus.TurnStarted { agent_name; turn } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("turn", `Int turn);
          ]
      in
      Some (wrap ~event_type:"turn_started" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.TurnCompleted { agent_name; turn } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("turn", `Int turn);
          ]
      in
      Some (wrap ~event_type:"turn_completed" ~payload ~agent_name ~turn ())
  | Agent_sdk.Event_bus.HandoffRequested { from_agent; to_agent; reason } ->
      let payload =
        `Assoc
          [
            ("from_agent", `String from_agent);
            ("to_agent", `String to_agent);
            ("reason", `String reason);
          ]
      in
      Some
        (wrap ~event_type:"handoff_requested" ~payload ~agent_name:from_agent ())
  | Agent_sdk.Event_bus.HandoffCompleted { from_agent; to_agent; elapsed } ->
      let payload =
        `Assoc
          [
            ("from_agent", `String from_agent);
            ("to_agent", `String to_agent);
            ("elapsed_s", `Float elapsed);
          ]
      in
      Some
        (wrap ~event_type:"handoff_completed" ~payload ~agent_name:from_agent ())
  | Agent_sdk.Event_bus.ContextCompacted
      { agent_name; before_tokens; after_tokens; phase } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("before_tokens", `Int before_tokens);
            ("after_tokens", `Int after_tokens);
            ("phase", `String phase);
          ]
      in
      Some (wrap ~event_type:"context_compacted" ~payload ~agent_name ())
  | Agent_sdk.Event_bus.ElicitationCompleted _ ->
    None  (* Internal; no SSE relay needed *)
  | Agent_sdk.Event_bus.ContextOverflowImminent
        { agent_name; estimated_tokens; limit_tokens; ratio } ->
      let payload =
        `Assoc [
          ("agent_name", `String agent_name);
          ("estimated_tokens", `Int estimated_tokens);
          ("limit_tokens", `Int limit_tokens);
          ("ratio", `Float ratio);
        ]
      in
      Some (wrap ~event_type:"context_overflow_imminent" ~payload
              ~agent_name ())
  | Agent_sdk.Event_bus.ContextCompactStarted { agent_name; trigger } ->
      let payload =
        `Assoc [
          ("agent_name", `String agent_name);
          ("trigger", `String trigger);
        ]
      in
      Some (wrap ~event_type:"context_compact_started" ~payload
              ~agent_name ())
  | Agent_sdk.Event_bus.ContentReplacementReplaced
      { tool_use_id; preview; original_chars; seen_count_after } ->
      let payload =
        `Assoc [
          ("tool_use_id", `String tool_use_id);
          ("preview", `String preview);
          ("original_chars", `Int original_chars);
          ("seen_count_after", `Int seen_count_after);
        ]
      in
      Some (wrap ~event_type:"content_replacement_replaced" ~payload ())
  | Agent_sdk.Event_bus.ContentReplacementKept { tool_use_id; seen_count_after } ->
      let payload =
        `Assoc [
          ("tool_use_id", `String tool_use_id);
          ("seen_count_after", `Int seen_count_after);
        ]
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
        `Assoc [
          ("max_slots", `Int max_slots);
          ("active", `Int active);
          ("available", `Int available);
          ("queue_length", `Int queue_length);
          ("state", `String state_str);
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
        if String.length name > 5 && String.sub name 0 5 = "masc."
        then String.map (fun c -> if c = '.' then ':' else c) name
        else name
      in
      Some
        (wrap ~event_type ~payload
           ?agent_name:(payload_agent_name payload)
           ?task_id:(payload_string_opt "task_id" payload)
           ?turn:(payload_int_opt "turn" payload)
           ?tool_name:(payload_string_opt "tool_name" payload)
           ())

let relay_max_attempts = 3
let relay_max_queue_depth = 256

type relay_stage =
  | Append
  | Broadcast

type pending_relay = {
  json : Yojson.Safe.t;
  attempts : int;
  appended : bool;
}

type relay_result =
  | Delivered
  | Retryable_failure of pending_relay * relay_stage * exn

let relay_stage_to_string = function
  | Append -> "append"
  | Broadcast -> "broadcast"

let json_field_string_opt key = function
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Some value
      | _ -> None)
  | _ -> None

let relay_event_type json =
  match json_field_string_opt "event_type" json with
  | Some value -> value
  | None ->
      (match json_field_string_opt "type" json with
       | Some value -> value
       | None -> "unknown")

let update_relay_queue_depth pending =
  Prometheus.set_gauge Prometheus.metric_oas_sse_relay_queue_depth
    (float_of_int (List.length pending))

let emit_relay_retry_log ~(pending : pending_relay) ~(stage : relay_stage)
    ~(attempt : int) exn =
  Log.Misc.warn
    "oas_sse_bridge: retrying event_type=%s stage=%s attempt=%d/%d correlation_id=%s run_id=%s error=%s"
    (relay_event_type pending.json)
    (relay_stage_to_string stage)
    attempt
    relay_max_attempts
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "correlation_id" pending.json))
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "run_id" pending.json))
    (Printexc.to_string exn)

let emit_relay_drop_log ~(pending : pending_relay) ~(stage_label : string)
    ~(attempts : int) =
  Log.Server.error
    "oas_sse_bridge: dropping event_type=%s stage=%s attempts=%d correlation_id=%s run_id=%s"
    (relay_event_type pending.json)
    stage_label
    attempts
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "correlation_id" pending.json))
    (Option.value
       ~default:"<none>"
       (json_field_string_opt "run_id" pending.json))

let broadcast_drop_marker ~(pending : pending_relay) ~(stage_label : string)
    ~(attempts : int) =
  let marker =
    `Assoc
      [
        ("type", `String "oas:relay_dropped");
        ("event_type", `String "relay_dropped");
        ("ts_unix", `Float (Time_compat.now ()));
        ( "correlation_id",
          match json_field_string_opt "correlation_id" pending.json with
          | Some value -> `String value
          | None -> `Null );
        ( "run_id",
          match json_field_string_opt "run_id" pending.json with
          | Some value -> `String value
          | None -> `Null );
        ( "agent_name",
          match json_field_string_opt "agent_name" pending.json with
          | Some value -> `String value
          | None -> `Null );
        ("failed_stage", `String stage_label);
        ("attempts", `Int attempts);
        ("original_event_type", `String (relay_event_type pending.json));
      ]
  in
  try
    Sse.broadcast_to All marker
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Misc.warn "oas_sse_bridge: drop marker broadcast failed: %s"
        (Printexc.to_string exn)

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
      Some { json; attempts = 0; appended = false; }

let deliver_pending_with
    ~(append_json : Yojson.Safe.t -> unit)
    ~(broadcast_json : Yojson.Safe.t -> unit)
    (pending : pending_relay) =
  let pending =
    if pending.appended then pending
    else begin
      append_json pending.json;
      { pending with appended = true; }
    end
  in
  try
    broadcast_json pending.json;
    Delivered
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Retryable_failure (pending, Broadcast, exn)

let deliver_pending ?store_ref (pending : pending_relay) =
  let append_json =
    match store_ref with
    | None -> (fun _json -> ())
    | Some store_ref ->
        (fun json ->
           let store = !store_ref in
           try
             Dated_jsonl.append store json
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               store_ref :=
                 Dated_jsonl.create ~base_dir:(Dated_jsonl.base_dir store) ();
               raise exn)
  in
  try
    deliver_pending_with
      ~append_json
      ~broadcast_json:(Sse.broadcast_to All)
      pending
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Retryable_failure (pending, Append, exn)

let enqueue_pending pending item =
  if List.length pending < relay_max_queue_depth then
    (pending @ [ item ], None)
  else
    match pending with
    | dropped :: rest -> (rest @ [ item ], Some dropped)
    | [] -> ([ item ], None)

let rec process_pending ?store_ref acc = function
  | [] -> List.rev acc
  | pending :: rest -> (
      match deliver_pending ?store_ref pending with
      | Delivered ->
          process_pending ?store_ref acc rest
      | Retryable_failure (pending, stage, exn) ->
          let attempt = pending.attempts + 1 in
          if attempt >= relay_max_attempts then begin
            Prometheus.inc_counter Prometheus.metric_oas_sse_relay_drops
              ~labels:[ ("stage", relay_stage_to_string stage) ] ();
            emit_relay_drop_log ~pending
              ~stage_label:(relay_stage_to_string stage)
              ~attempts:attempt;
            broadcast_drop_marker ~pending
              ~stage_label:(relay_stage_to_string stage)
              ~attempts:attempt;
            process_pending ?store_ref acc rest
          end else begin
            Prometheus.inc_counter Prometheus.metric_oas_sse_relay_retries
              ~labels:[ ("stage", relay_stage_to_string stage) ] ();
            emit_relay_retry_log ~pending ~stage ~attempt exn;
            process_pending ?store_ref
              ({ pending with attempts = attempt; } :: acc)
              rest
          end)

type bridge_pending_relay = pending_relay
type bridge_relay_stage = relay_stage
type bridge_relay_result = relay_result

let deliver_pending_with_impl = deliver_pending_with

module For_testing = struct
  type pending_relay = {
    json : Yojson.Safe.t;
    attempts : int;
    appended : bool;
  }

  type relay_stage =
    | Append
    | Broadcast

  type relay_result =
    | Delivered
    | Retryable_failure of pending_relay * relay_stage * exn

  let make_pending json = { json; attempts = 0; appended = false; }

  let to_pending (pending : pending_relay) : bridge_pending_relay =
    { json = pending.json;
      attempts = pending.attempts;
      appended = pending.appended; }

  let of_pending (pending : bridge_pending_relay) : pending_relay =
    { json = pending.json;
      attempts = pending.attempts;
      appended = pending.appended; }

  let of_stage (stage : bridge_relay_stage) =
    match relay_stage_to_string stage with
    | "append" -> Append
    | "broadcast" -> Broadcast
    | _ -> Broadcast

  let of_result (result : bridge_relay_result) =
    match result with
    | Delivered -> Delivered
    | Retryable_failure (pending, stage, exn) ->
        Retryable_failure (of_pending pending, of_stage stage, exn)

  let deliver_pending_with ~append_json ~broadcast_json pending =
    deliver_pending_with_impl
      ~append_json
      ~broadcast_json
      (to_pending pending)
    |> of_result
end

let start_impl ~interval_s ~sw ~clock ~(config : Coord.config) ~bus =
  let store =
    ref
      (Dated_jsonl.create
         ~base_dir:(Filename.concat (Coord.masc_root_dir config) "oas-events")
         ())
  in
  let sub =
    Oas_bus_instrument.subscribe
      ~purpose:"sse_bridge"
      ~filter:Agent_sdk.Event_bus.accept_all
      bus
  in
  Eio.Switch.on_release sw (fun () ->
    Oas_bus_instrument.unsubscribe bus sub);
  let pending = ref [] in
  update_relay_queue_depth !pending;
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         let events = Oas_bus_instrument.drain sub in
         List.iter
           (fun evt ->
              match prepare_pending_event evt with
              | None -> ()
              | Some item ->
                  let next_pending, dropped = enqueue_pending !pending item in
                  pending := next_pending;
                  (match dropped with
                   | None -> ()
                   | Some dropped ->
                       Prometheus.inc_counter Prometheus.metric_oas_sse_relay_drops
                         ~labels:[ ("stage", "queue") ] ();
                       emit_relay_drop_log ~pending:dropped
                         ~stage_label:"queue"
                         ~attempts:dropped.attempts;
                       broadcast_drop_marker ~pending:dropped
                         ~stage_label:"queue"
                         ~attempts:dropped.attempts))
           events;
         pending := process_pending ~store_ref:store [] !pending;
         update_relay_queue_depth !pending
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn
           "oas_sse_bridge: relay iteration failed: %s"
           (Printexc.to_string exn));
      Eio.Time.sleep clock interval_s;
      loop ()
    in
    loop ())

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~(config : Coord.config) ~bus =
  start_impl ~interval_s:(drain_interval_s ()) ~sw ~clock ~config ~bus

let start_with_interval ~drain_interval_s:interval_s ~sw ~clock
    ~(config : Coord.config) ~bus =
  start_impl ~interval_s ~sw ~clock ~config ~bus
