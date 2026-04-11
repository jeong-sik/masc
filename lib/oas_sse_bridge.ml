(** OAS Event_bus → SSE Bridge.

    Subscribes to all events on the OAS Event_bus (both MASC Custom
    events and OAS native lifecycle events) and relays them as SSE
    broadcasts to connected dashboard clients.

    OAS native events (ToolCalled, TurnCompleted, etc.) are serialized
    to a uniform JSON format with an "oas:" prefix so consumers can
    distinguish them from MASC-originated events.

    @since 2.96.0
    @modified 2.255.0 — accept OAS native events (#5620) *)

(** Drain interval: how often we poll the Event_bus subscription.
    Lower default keeps the dashboard close to real-time, while staying
    runtime-tunable for quieter deployments. *)
let drain_interval_s () = Env_config.Oas_sse.drain_interval_sec

(** Serialize an OAS native event to JSON for SSE relay. *)
let native_event_to_json (evt : Agent_sdk.Event_bus.event) : Yojson.Safe.t option =
  let ts = Time_compat.now () in
  let wrap event_type payload =
    Some (`Assoc [
      ("type", `String ("oas:" ^ event_type));
      ("payload", payload);
      ("ts_unix", `Float ts);
    ])
  in
  match evt with
  | Agent_sdk.Event_bus.AgentStarted { agent_name; task_id } ->
    wrap "agent_started" (`Assoc [
      ("agent_name", `String agent_name);
      ("task_id", `String task_id);
    ])
  | Agent_sdk.Event_bus.AgentCompleted { agent_name; task_id; elapsed; _ } ->
    wrap "agent_completed" (`Assoc [
      ("agent_name", `String agent_name);
      ("task_id", `String task_id);
      ("elapsed_s", `Float elapsed);
    ])
  | Agent_sdk.Event_bus.ToolCalled { agent_name; tool_name; _ } ->
    wrap "tool_called" (`Assoc [
      ("agent_name", `String agent_name);
      ("tool_name", `String tool_name);
    ])
  | Agent_sdk.Event_bus.ToolCompleted { agent_name; tool_name; _ } ->
    wrap "tool_completed" (`Assoc [
      ("agent_name", `String agent_name);
      ("tool_name", `String tool_name);
    ])
  | Agent_sdk.Event_bus.TurnStarted { agent_name; turn } ->
    wrap "turn_started" (`Assoc [
      ("agent_name", `String agent_name);
      ("turn", `Int turn);
    ])
  | Agent_sdk.Event_bus.TurnCompleted { agent_name; turn } ->
    wrap "turn_completed" (`Assoc [
      ("agent_name", `String agent_name);
      ("turn", `Int turn);
    ])
  | Agent_sdk.Event_bus.ContextCompacted { agent_name; before_tokens; after_tokens; phase } ->
    wrap "context_compacted" (`Assoc [
      ("agent_name", `String agent_name);
      ("before_tokens", `Int before_tokens);
      ("after_tokens", `Int after_tokens);
      ("phase", `String phase);
    ])
  | Agent_sdk.Event_bus.TaskStateChanged { task_id; from_state; to_state } ->
    wrap "task_state_changed" (`Assoc [
      ("task_id", `String task_id);
      ("from_state", `String from_state);
      ("to_state", `String to_state);
    ])
  | Agent_sdk.Event_bus.ElicitationCompleted _ ->
    None  (* Internal; no SSE relay needed *)
  | Agent_sdk.Event_bus.Custom (name, payload) ->
    Some (`Assoc [
      ("type", `String ("oas:" ^ name));
      ("payload", payload);
      ("ts_unix", `Float ts);
    ])

(** Relay a single Event_bus event to SSE. *)
let relay_event evt =
  let json = native_event_to_json evt in
  match json with
  | None -> ()
  | Some j ->
    (try Sse.broadcast_to Coordinators j
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Server.error "oas_sse_bridge: broadcast failed: %s"
         (Printexc.to_string exn))

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~bus =
  let interval_s = drain_interval_s () in
  let sub = Agent_sdk.Event_bus.subscribe bus
    ~filter:Agent_sdk.Event_bus.accept_all
  in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      (try
         let events = Agent_sdk.Event_bus.drain sub in
         List.iter relay_event events
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
