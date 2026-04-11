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

let wrap_event ~ts ~event_type ~payload ?agent_name ?session_id ?worker_run_id
    ?task_id ?turn ?tool_name () =
  `Assoc
    [
      ("type", `String ("oas:" ^ event_type));
      ("event_type", `String event_type);
      ("ts_unix", `Float ts);
      ("agent_name", json_string_opt agent_name);
      ("session_id", json_string_opt session_id);
      ("worker_run_id", json_string_opt worker_run_id);
      ("task_id", json_string_opt task_id);
      ("turn", Option.fold ~none:`Null ~some:(fun value -> `Int value) turn);
      ("tool_name", json_string_opt tool_name);
      ("payload", payload);
    ]

(** Serialize an OAS event to JSON for SSE relay + durable storage. *)
let native_event_to_json (evt : Agent_sdk.Event_bus.event) : Yojson.Safe.t option =
  let ts = Time_compat.now () in
  match evt with
  | Agent_sdk.Event_bus.AgentStarted
      { agent_name; task_id; session_id; worker_run_id } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("task_id", `String task_id);
            ("session_id", json_string_opt session_id);
            ("worker_run_id", json_string_opt worker_run_id);
          ]
      in
      Some
        (wrap_event ~ts ~event_type:"agent_started" ~payload ~agent_name
           ~task_id ?session_id ?worker_run_id ())
  | Agent_sdk.Event_bus.AgentCompleted
      { agent_name; task_id; elapsed; session_id; worker_run_id; _ } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("task_id", `String task_id);
            ("elapsed_s", `Float elapsed);
            ("session_id", json_string_opt session_id);
            ("worker_run_id", json_string_opt worker_run_id);
          ]
      in
      Some
        (wrap_event ~ts ~event_type:"agent_completed" ~payload ~agent_name
           ~task_id ?session_id ?worker_run_id ())
  | Agent_sdk.Event_bus.ToolCalled
      { agent_name; tool_name; session_id; worker_run_id; _ } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("tool_name", `String tool_name);
            ("session_id", json_string_opt session_id);
            ("worker_run_id", json_string_opt worker_run_id);
          ]
      in
      Some
        (wrap_event ~ts ~event_type:"tool_called" ~payload ~agent_name
           ~tool_name ?session_id ?worker_run_id ())
  | Agent_sdk.Event_bus.ToolCompleted
      { agent_name; tool_name; session_id; worker_run_id; _ } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("tool_name", `String tool_name);
            ("session_id", json_string_opt session_id);
            ("worker_run_id", json_string_opt worker_run_id);
          ]
      in
      Some
        (wrap_event ~ts ~event_type:"tool_completed" ~payload ~agent_name
           ~tool_name ?session_id ?worker_run_id ())
  | Agent_sdk.Event_bus.TurnStarted
      { agent_name; turn; session_id; worker_run_id } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("turn", `Int turn);
            ("session_id", json_string_opt session_id);
            ("worker_run_id", json_string_opt worker_run_id);
          ]
      in
      Some
        (wrap_event ~ts ~event_type:"turn_started" ~payload ~agent_name ~turn
           ?session_id ?worker_run_id ())
  | Agent_sdk.Event_bus.TurnCompleted
      { agent_name; turn; session_id; worker_run_id } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("turn", `Int turn);
            ("session_id", json_string_opt session_id);
            ("worker_run_id", json_string_opt worker_run_id);
          ]
      in
      Some
        (wrap_event ~ts ~event_type:"turn_completed" ~payload ~agent_name ~turn
           ?session_id ?worker_run_id ())
  | Agent_sdk.Event_bus.ContextCompacted
      {
        agent_name;
        before_tokens;
        after_tokens;
        phase;
        session_id;
        worker_run_id;
      } ->
      let payload =
        `Assoc
          [
            ("agent_name", `String agent_name);
            ("before_tokens", `Int before_tokens);
            ("after_tokens", `Int after_tokens);
            ("phase", `String phase);
            ("session_id", json_string_opt session_id);
            ("worker_run_id", json_string_opt worker_run_id);
          ]
      in
      Some
        (wrap_event ~ts ~event_type:"context_compacted" ~payload ~agent_name
           ?session_id ?worker_run_id ())
  | Agent_sdk.Event_bus.TaskStateChanged { task_id; from_state; to_state } ->
      let payload =
        `Assoc
          [
            ("task_id", `String task_id);
            ("from_state", `String from_state);
            ("to_state", `String to_state);
          ]
      in
      Some (wrap_event ~ts ~event_type:"task_state_changed" ~payload ~task_id ())
  | Agent_sdk.Event_bus.ElicitationCompleted _ ->
    None  (* Internal; no SSE relay needed *)
  | Agent_sdk.Event_bus.Custom (name, payload) ->
      Some
        (wrap_event ~ts ~event_type:name ~payload
           ?agent_name:(payload_agent_name payload)
           ?session_id:(payload_string_opt "session_id" payload)
           ?worker_run_id:(payload_string_opt "worker_run_id" payload)
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
      (match store with
       | Some store ->
           (try Dated_jsonl.append store j
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
                Log.Misc.warn "oas_sse_bridge: durable append failed: %s"
                  (Printexc.to_string exn))
       | None -> ());
      (try Sse.broadcast_to Coordinators j
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Server.error "oas_sse_bridge: broadcast failed: %s"
             (Printexc.to_string exn))

(** Background fiber: drain events and relay to SSE. *)
let start ~sw ~clock ~(config : Room.config) ~bus =
  let interval_s = drain_interval_s () in
  let store =
    Dated_jsonl.create
      ~base_dir:(Filename.concat (Room.masc_root_dir config) "oas-events")
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
