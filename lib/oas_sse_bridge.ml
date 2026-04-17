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
  match payload_string_opt "agent_name" payload with
  | Some _ as value -> value
  | None -> payload_string_opt "agent" payload

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
  let { Agent_sdk.Event_bus.correlation_id; run_id; ts } = evt.meta in
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
      Some
        (wrap ~event_type:name ~payload
           ?agent_name:(payload_agent_name payload)
           ?task_id:(payload_string_opt "task_id" payload)
           ?turn:(payload_int_opt "turn" payload)
           ?tool_name:(payload_string_opt "tool_name" payload)
           ())

(** Relay a single Event_bus event to SSE. *)
let relay_event ?store evt =
  let json = native_event_to_json evt in
  match json with
  | None -> ()
  | Some j ->
      (* OAS event payloads may carry tool output or user-facing text that
         contains invalid UTF-8 bytes (e.g. truncated multi-byte sequences
         from subprocess captures).  Scrub before persisting or broadcasting
         so that JSONL consumers and SSE clients receive well-formed UTF-8. *)
      let j = Inference_utils.sanitize_json_utf8 j in
      emit_native_event_log evt j;
      (match store with
       | Some store ->
           (try Dated_jsonl.append store j
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Misc.warn "oas_sse_bridge: durable append failed: %s"
                  (Printexc.to_string exn))
       | None -> ());
      (try Sse.broadcast_to All j
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Server.error "oas_sse_bridge: broadcast failed: %s"
             (Printexc.to_string exn))

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~(config : Coord.config) ~bus =
  let interval_s = drain_interval_s () in
  let store =
    Dated_jsonl.create
      ~base_dir:(Filename.concat (Coord.masc_root_dir config) "oas-events")
      ()
  in
  let sub = Agent_sdk.Event_bus.subscribe bus
    ~filter:Agent_sdk.Event_bus.accept_all
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         let events = Agent_sdk.Event_bus.drain sub in
         List.iter (relay_event ~store) events
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
