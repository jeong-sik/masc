(** A2A MCP Tools - Agent-to-Agent communication protocol.
    Types and JSON conversion are in A2a_types. *)

open Types
include A2a_types

(** Subscription *)
type subscription = {
  id: string;
  agent_filter: string option;  (* None = all agents *)
  event_types: event_type list;
  created_at: string;
} [@@deriving show]

(* Global subscription store *)
let subscriptions : (string, subscription) Hashtbl.t = Hashtbl.create 16
let subscriptions_mutex = Eio.Mutex.create ()

(* Persistence file path - set by init *)
let subscriptions_file = ref ""

(** Convert event_type to string for JSON *)
let event_type_to_string = function
  | TaskUpdate -> "task_update"
  | Broadcast -> "broadcast"
  | Completion -> "completion"
  | Error -> "error"
  | HeartbeatTask -> "heartbeat_task"

(** Subscription to JSON *)
let subscription_to_json (sub : subscription) : Yojson.Safe.t =
  `Assoc [
    ("id", `String sub.id);
    ("agent_filter", match sub.agent_filter with
      | None -> `Null
      | Some a -> `String a);
    ("event_types", `List (List.map (fun e -> `String (event_type_to_string e)) sub.event_types));
    ("created_at", `String sub.created_at);
  ]

(** Subscription from JSON *)
let subscription_of_json (json : Yojson.Safe.t) : subscription option =
  try
    let module U = Yojson.Safe.Util in
    let id = json |> U.member "id" |> U.to_string in
    let agent_filter = match json |> U.member "agent_filter" with
      | `Null -> None
      | `String s -> Some s
      | _ -> None
    in
    let event_types = json |> U.member "event_types" |> U.to_list |> List.filter_map (function
      | `String s -> (match event_type_of_string s with Ok e -> Some e | Error _ -> None)
      | _ -> None)
    in
    let created_at = json |> U.member "created_at" |> U.to_string in
    Some { id; agent_filter; event_types; created_at }
  with Yojson.Safe.Util.Type_error (msg, _) ->
    Log.Misc.warn "subscription_of_json: %s" msg;
    None

(** Save subscriptions to file *)
let save_subscriptions () =
  if !subscriptions_file = "" then ()
  else
    let subs = Eio.Mutex.use_ro subscriptions_mutex (fun () ->
      Hashtbl.fold (fun _k v acc -> subscription_to_json v :: acc) subscriptions []) in
    let json = `Assoc [("subscriptions", `List subs)] in
    let content = Yojson.Safe.pretty_to_string json in
    try
      Fs_compat.save_file !subscriptions_file content
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.Misc.error "save_subscriptions failed: %s" (Printexc.to_string e)

(** Load subscriptions from file *)
let load_subscriptions () =
  if !subscriptions_file = "" || not (Sys.file_exists !subscriptions_file) then ()
  else
    match Safe_ops.read_json_file_safe !subscriptions_file with
    | Error msg -> Log.Misc.warn "load_subscriptions: %s" msg
    | Ok json ->
      let module U = Yojson.Safe.Util in
      let subs = try json |> U.member "subscriptions" |> U.to_list
                 with U.Type_error _ -> [] in
      Eio.Mutex.use_rw ~protect:true subscriptions_mutex (fun () ->
        List.iter (fun j ->
          match subscription_of_json j with
          | Some sub -> Hashtbl.replace subscriptions sub.id sub
          | None -> ()
        ) subs)

(** Initialize A2A tools with MASC directory *)
let init ~masc_dir =
  subscriptions_file := Filename.concat masc_dir "subscriptions.json";
  load_subscriptions ()

(** Event record for buffering *)
type buffered_event = {
  event_type: event_type;
  agent: string;
  data: Yojson.Safe.t;
  timestamp: float;
} [@@deriving show]

(* Event buffer per subscription - key: subscription_id, value: event list *)
let event_buffers : (string, buffered_event list) Hashtbl.t = Hashtbl.create 16
let event_buffers_mutex = Eio.Mutex.create ()

(* Max events per subscription to prevent memory bloat *)
let max_buffered_events = Env_config_governance.Timeouts.event_buffer_size

(** Generate UUID-like ID using Hashtbl.hash of timestamp (no Mirage_crypto dependency).
    For A2A subscriptions, cryptographic randomness is not required.
*)
let generate_uuid () =
  let t = Unix.gettimeofday () in
  let h1 = Hashtbl.hash t in
  let h2 = Hashtbl.hash (t *. 1000.0) in
  let h3 = Hashtbl.hash (t *. 1_000_000.0) in
  let h4 = Hashtbl.hash (h1 lxor h2) in
  Printf.sprintf "%08x-%04x-%04x-%04x-%04x%08x"
    (h1 land 0xFFFFFFFF)
    (h2 land 0xFFFF)
    (h3 land 0xFFFF)
    (h4 land 0xFFFF)
    ((h1 lxor h3) land 0xFFFF)
    (h2 lxor h4)

(** Get current ISO8601 timestamp *)
let now_iso8601 () : string =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

type heartbeat_task_snapshot = {
  seq: int;
  goal: string;
  context: string;
  worker_mode: string;
  allowed_tools: string list;
  decision_reason: string option;
  created_at: string;
}

type heartbeat_result_snapshot = {
  seq: int;
  status: string;
  summary: string;
  worker_name: string;
  tool_call_count: int;
  tool_names: string list;
  decision_reason: string;
  decision_confidence: float;
  failure_reason: string option;
  updated_at: string;
}

let latest_heartbeat_tasks : (string, heartbeat_task_snapshot) Hashtbl.t =
  Hashtbl.create 32

let latest_heartbeat_results : (string, heartbeat_result_snapshot) Hashtbl.t =
  Hashtbl.create 32

let heartbeat_mutex = Eio.Mutex.create ()

let heartbeat_snapshot_seq = ref 0

let next_heartbeat_snapshot_seq () =
  heartbeat_snapshot_seq := !heartbeat_snapshot_seq + 1;
  !heartbeat_snapshot_seq

let latest_heartbeat_task agent =
  Eio.Mutex.use_ro heartbeat_mutex (fun () ->
    Hashtbl.find_opt latest_heartbeat_tasks agent)

let latest_heartbeat_result agent =
  Eio.Mutex.use_ro heartbeat_mutex (fun () ->
    Hashtbl.find_opt latest_heartbeat_results agent)

let remote_agent_card_paths =
  [ "/.well-known/agent.json"; "/.well-known/agent-card.json" ]

let fetch_remote_agent_card url :
    (Yojson.Safe.t * string, string) result =
  let rec loop = function
    | [] ->
        Stdlib.Error
          (Printf.sprintf "No agent discovery endpoint succeeded for %s" url)
    | path :: rest ->
        let well_known = url ^ path in
        let argv =
          [
            "curl";
            "-s";
            "--max-time";
            "10";
            "--proto";
            "=https,http";
            "-H";
            "Accept: application/json";
            well_known;
          ]
        in
        try
          let (status, body) =
            Process_eio.run_argv_with_status ~timeout_sec:Env_config_runtime.Timeout.gcloud_auth_sec argv
          in
          match status with
          | Unix.WEXITED 0 when String.length body > 0 -> (
              try
                let card_json = Yojson.Safe.from_string body in
                Stdlib.Ok (card_json, well_known)
              with Yojson.Json_error msg ->
                Stdlib.Error
                  (Printf.sprintf "Invalid JSON from %s: %s" well_known msg))
          | Unix.WEXITED 0 ->
              loop rest
          | Unix.WEXITED 7 | Unix.WEXITED 22 | Unix.WEXITED 28 ->
              loop rest
          | Unix.WEXITED code ->
              Stdlib.Error
                (Printf.sprintf "HTTP fetch failed (exit %d): %s" code well_known)
          | Unix.WSIGNALED sig_num ->
              Stdlib.Error
                (Printf.sprintf "Fetch killed by signal %d: %s" sig_num well_known)
          | Unix.WSTOPPED _ ->
              Stdlib.Error (Printf.sprintf "Fetch stopped: %s" well_known)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Stdlib.Error
            (Printf.sprintf "Remote discovery error (%s): %s" well_known
               (Printexc.to_string exn))
  in
  loop remote_agent_card_paths

(** Discover available agents

    Combines local room agents with remote agent card fetching.

    @param endpoint Optional remote endpoint URL
    @param capability Optional filter by capability
    @return List of agent cards
*)
let discover config ?(endpoint : string option) ?(capability : string option) ?(schemas : Types.tool_schema list = []) ()
    : (Yojson.Safe.t, string) result =
  match endpoint with
  | Some url ->
      (match fetch_remote_agent_card url with
      | Stdlib.Ok (card_json, discovered_url) ->
          Stdlib.Ok
            (`Assoc
              [
                ("type", `String "remote_discovery");
                ("endpoint", `String url);
                ("discovered_url", `String discovered_url);
                ("agent_card", card_json);
              ])
      | Stdlib.Error err -> Stdlib.Error err)
  | None ->
    (* Local discovery - list agents in room *)
    let agents = Room.get_agents_raw config in
    (* Filter by capability if specified *)
    let filtered = match capability with
      | None -> agents
      | Some cap ->
        List.filter (fun (a : agent) ->
          List.mem cap a.capabilities
        ) agents
    in
    (* Include local agent card *)
    let local_card = Agent_card.generate_default ~schemas () in
    let agents_json = List.map (fun (a : agent) ->
      `Assoc [
        ("name", `String a.name);
        ("status", `String (agent_status_to_string a.status));
        ("capabilities", `List (List.map (fun s -> `String s) a.capabilities));
        ("current_task", match a.current_task with
          | None -> `Null
          | Some t -> `String t);
        ("joined_at", `String a.joined_at);
        ("last_seen", `String a.last_seen);
      ]
    ) filtered in
    Ok (`Assoc [
      ("type", `String "local_discovery");
      ("agent_count", `Int (List.length filtered));
      ("agents", `List agents_json);
      ("local_card", Agent_card.to_json local_card);
      ("capability_filter", match capability with
        | None -> `Null
        | Some c -> `String c);
    ])

(** Query skill details from an agent

    @param agent_name Target agent name
    @param skill_id Skill ID to query
    @return Skill details
*)
let query_skill config ~schemas ~agent_name ~skill_id : (Yojson.Safe.t, string) result =
  (* First, find the agent *)
  let agents = Room.get_agents_raw config in
  let agent_opt = List.find_opt (fun (a : agent) -> a.name = agent_name) agents in
  match agent_opt with
  | None -> Error (Printf.sprintf "Agent '%s' not found" agent_name)
  | Some _agent ->
    (* Look up skill from dynamic MCP tool schemas *)
    let skills = Agent_card.skills_from_tools schemas in
    let skill_opt = List.find_opt (fun (s : Agent_card.skill) -> s.id = skill_id) skills in
    match skill_opt with
    | None -> Error (Printf.sprintf "Skill '%s' not found" skill_id)
    | Some skill ->
      Ok (`Assoc [
        ("agent", `String agent_name);
        ("skill", `Assoc [
          ("id", `String skill.id);
          ("name", `String skill.name);
          ("description", match skill.description with
            | None -> `Null
            | Some d -> `String d);
          ("input_modes", `List (List.map (fun s -> `String s) skill.input_modes));
          ("output_modes", `List (List.map (fun s -> `String s) skill.output_modes));
        ]);
        ("examples", `List [
          `Assoc [
            ("input", `String "Example input for skill");
            ("output", `String "Example output");
          ]
        ]);
      ])

(** Delegate a task to another agent

    Uses Portal for communication. Opens portal, sends task, optionally waits.

    @param target Target agent name
    @param message Task description/prompt
    @param task_type sync/async/stream
    @param artifacts Optional input files/data
    @param timeout Timeout in seconds
    @return Delegate result
*)
let delegate config ~agent_name ~target ~message
    ?(task_type_str = "async")
    ?(artifacts : artifact list = [])
    ?(timeout = 300)
    () : (Yojson.Safe.t, string) result =
  (* BUG: Prevent self-delegation — creates blocking self-portal *)
  if String.equal agent_name target then
    Error (Printf.sprintf "Self-delegation not allowed: agent '%s' cannot delegate to itself" agent_name)
  else
  (* Timeout is stored and returned in response for client-side enforcement *)
  let timeout_ms = timeout * 1000 in
  let deadline = Time_compat.now () +. (float_of_int timeout) in
  let task_type_result = task_type_of_string task_type_str in
  match task_type_result with
  | Error e -> Error e
  | Ok task_type ->
    (* Open portal to target agent *)
    let artifacts_json =
      if artifacts = [] then ""
      else Printf.sprintf "\n\nArtifacts: %s"
        (Yojson.Safe.to_string (`List (List.map artifact_to_yojson artifacts)))
    in
    let full_message = message ^ artifacts_json in
    let portal_result = Room.portal_open_r config
      ~agent_name
      ~target_agent:target
      ~initial_message:(Some full_message)
    in
    match portal_result with
    | Error e -> Error (masc_error_to_string e)
    | Ok msg ->
      let task_id = generate_uuid () in
      match task_type with
      | Sync ->
        (* For sync, we'd need to wait for response. For now, return task ID *)
        Ok (`Assoc [
          ("task_id", `String task_id);
          ("status", `String "delegated");
          ("type", `String "sync");
          ("target", `String target);
          ("portal_message", `String msg);
          ("timeout_ms", `Int timeout_ms);
          ("deadline", `Float deadline);
          ("note", `String "Use masc_portal_status to check for response");
        ])
      | Async ->
        Ok (`Assoc [
          ("task_id", `String task_id);
          ("status", `String "delegated");
          ("type", `String "async");
          ("target", `String target);
          ("portal_message", `String msg);
          ("timeout_ms", `Int timeout_ms);
          ("deadline", `Float deadline);
        ])
      | Stream ->
        Ok (`Assoc [
          ("task_id", `String task_id);
          ("status", `String "delegated");
          ("type", `String "stream");
          ("target", `String target);
          ("portal_message", `String msg);
          ("timeout_ms", `Int timeout_ms);
          ("deadline", `Float deadline);
          ("stream_endpoint", `String "/sse/portal");
        ])

(** Subscribe to agent events

    @param agent_filter Optional agent name filter (asterisk for all)
    @param events List of event types to subscribe to
    @return Subscription info
*)
let subscribe ?(agent_filter : string option) ~(events : string list) ()
    : (Yojson.Safe.t, string) result =
  (* Parse event types *)
  let event_types_result : (event_type list, string) result =
    List.fold_left (fun (acc : (event_type list, string) result) e ->
      match acc with
      | Error _ -> acc
      | Ok types ->
        match event_type_of_string e with
        | Error err -> Error err
        | Ok et -> Ok (et :: types)
    ) (Ok []) events
  in
  match event_types_result with
  | Error e -> Error e
  | Ok event_types ->
    let sub_id = generate_uuid () in
    let sub = {
      id = sub_id;
      agent_filter;
      event_types = List.rev event_types;
      created_at = now_iso8601 ();
    } in
    Eio.Mutex.use_rw ~protect:true subscriptions_mutex (fun () ->
      Hashtbl.add subscriptions sub_id sub);
    save_subscriptions ();
    Ok (`Assoc [
      ("subscription_id", `String sub_id);
      ("agent_filter", match agent_filter with
        | None -> `String "*"
        | Some a -> `String a);
      ("events", `List (List.map (fun e -> `String (show_event_type e)) event_types));
      ("created_at", `String sub.created_at);
      ("sse_endpoint", `String "/sse/subscriptions");
      ("note", `String "Connect to SSE endpoint to receive events");
    ])

(** Unsubscribe from events

    @param subscription_id Subscription ID to remove
*)
let unsubscribe ~subscription_id : (Yojson.Safe.t, string) result =
  let exists = Eio.Mutex.use_ro subscriptions_mutex (fun () ->
    Hashtbl.mem subscriptions subscription_id) in
  if exists then begin
    Eio.Mutex.use_rw ~protect:true subscriptions_mutex (fun () ->
      Hashtbl.remove subscriptions subscription_id);
    Eio.Mutex.use_rw ~protect:true event_buffers_mutex (fun () ->
      Hashtbl.remove event_buffers subscription_id);
    save_subscriptions ();
    Ok (`Assoc [
      ("unsubscribed", `Bool true);
      ("subscription_id", `String subscription_id);
    ])
  end else
    Error (Printf.sprintf "Subscription '%s' not found" subscription_id)

(** List active subscriptions *)
let list_subscriptions () : Yojson.Safe.t =
  let subs = Eio.Mutex.use_ro subscriptions_mutex (fun () ->
    Hashtbl.fold (fun _k v acc ->
      let sub_json = `Assoc [
        ("id", `String v.id);
        ("agent_filter", match v.agent_filter with
          | None -> `String "*"
          | Some a -> `String a);
        ("events", `List (List.map (fun e -> `String (show_event_type e)) v.event_types));
        ("created_at", `String v.created_at);
        ("buffered_count", `Int (
          match Hashtbl.find_opt event_buffers v.id with
          | None -> 0
          | Some events -> List.length events
        ));
      ] in
      sub_json :: acc
    ) subscriptions []) in
  `Assoc [
    ("count", `Int (List.length subs));
    ("subscriptions", `List subs);
  ]

(** Poll buffered events for a subscription

    Retrieves all buffered events and clears the buffer.
    Use this for background subscription workflow:
    1. subscribe (returns immediately)
    2. do work (claim, broadcast, etc.)
    3. poll_events periodically to check for updates

    @param subscription_id Subscription ID
    @param clear Whether to clear buffer after reading (default: true)
    @return List of buffered events
*)
let poll_events ~subscription_id ?(clear = true) ()
    : (Yojson.Safe.t, string) result =
  let mem = Eio.Mutex.use_ro subscriptions_mutex (fun () ->
    Hashtbl.mem subscriptions subscription_id) in
  if not mem then
    Error (Printf.sprintf "Subscription '%s' not found" subscription_id)
  else
    let events = Eio.Mutex.use_ro event_buffers_mutex (fun () ->
      match Hashtbl.find_opt event_buffers subscription_id with
      | None -> []
      | Some events -> events) in
    (* Optionally clear buffer *)
    if clear then Eio.Mutex.use_rw ~protect:true event_buffers_mutex (fun () ->
      Hashtbl.replace event_buffers subscription_id []);
    (* Convert to JSON *)
    let events_json = List.map (fun e ->
      `Assoc [
        ("type", `String (show_event_type e.event_type));
        ("agent", `String e.agent);
        ("data", e.data);
        ("timestamp", `Float e.timestamp);
      ]
    ) events in
    Ok (`Assoc [
      ("subscription_id", `String subscription_id);
      ("event_count", `Int (List.length events));
      ("events", `List events_json);
      ("cleared", `Bool clear);
    ])

(** Buffer an event for a subscription (with max limit enforcement) *)
let buffer_event sub_id event =
  Eio.Mutex.use_rw ~protect:true event_buffers_mutex (fun () ->
    let current = match Hashtbl.find_opt event_buffers sub_id with
      | None -> []
      | Some events -> events
    in
    (* Keep only last (max - 1) events + new one *)
    let trimmed =
      if List.length current >= max_buffered_events then
        match current with
        | _ :: rest -> rest
        | [] -> []
      else current
    in
    Hashtbl.replace event_buffers sub_id (trimmed @ [event]))

(** Notify subscribers of an event (internal use)
    Now also buffers events for polling in addition to SSE broadcast *)
let notify_event ~(event_type : event_type) ~(agent : string) ~(data : Yojson.Safe.t) : unit =
  let timestamp = Time_compat.now () in
  Eio.Mutex.use_ro subscriptions_mutex (fun () ->
  Hashtbl.iter (fun _id sub ->
    (* Check agent filter *)
    let agent_match = match sub.agent_filter with
      | None -> true
      | Some filter -> filter = "*" || filter = agent
          || event_type = HeartbeatTask (* System event: bypass agent filter *)
    in
    (* Check event type *)
    let event_match = List.mem event_type sub.event_types in
    if agent_match && event_match then begin
      (* Buffer event for polling *)
      let event = { event_type; agent; data; timestamp } in
      buffer_event sub.id event;

      (* Push event as MCP JSON-RPC Notification (no id = notification) *)
      let event_params = `Assoc [
        ("type", `String (show_event_type event_type));
        ("agent", `String agent);
        ("data", data);
        ("timestamp", `Float timestamp);
        ("subscription_id", `String sub.id);
      ] in
      let mcp_notification = `Assoc [
        ("jsonrpc", `String "2.0");
        ("method", `String "masc/event");
        ("params", event_params);
      ] in
      Sse.broadcast_to Coordinators mcp_notification;
      Log.debug ~ctx:"a2a" "Event %s from %s buffered+SSE (sub: %s)"
        (show_event_type event_type) agent sub.id
    end
  ) subscriptions)

(** {1 Heartbeat Task Events — Soul + Tool Loop Pattern}

    MASC emits heartbeat_task events when an external worker should act as a Lodge
    agent through the MCP tool loop. The payload carries the goal, context, and
    allowed tools. The worker performs tools directly, then reports completion
    evidence back to MASC.
*)

(** Emit a heartbeat_task event for Worker to process.
    @param agent Agent name (soul to embody)
    @param goal Concrete goal for the worker
    @param context Board state, recent posts, etc.
    @param allowed_tools Curated MCP tool allowlist for the worker
    @param board_id Optional target board ID *)
let emit_heartbeat_task
    ~agent
    ~goal
    ~context
    ~allowed_tools
    ?(board_id : string option)
    ?(worker_mode = "mcp_tool_loop")
    ?(mcp_base_url : string option)
    ?(session_id : string option)
    ?(decision_reason : string option)
    ?(decision_confidence : float option)
    ?(auth_token : string option)
    () : unit =
  Eio.Mutex.use_rw ~protect:true heartbeat_mutex (fun () ->
    Hashtbl.replace latest_heartbeat_tasks agent
      {
        seq = next_heartbeat_snapshot_seq ();
      goal;
      context;
      worker_mode;
      allowed_tools;
      decision_reason;
        created_at = now_iso8601 ();
      });
  let data = `Assoc ([
    ("agent", `String agent);
    ("goal", `String goal);
    ("context", `String context);
    ("worker_mode", `String worker_mode);
    ("allowed_tools", `List (List.map (fun name -> `String name) allowed_tools));
  ] @ (match board_id with
    | Some bid -> [("board_id", `String bid)]
    | None -> [])
  @ (match mcp_base_url with
    | Some url -> [("mcp_base_url", `String url)]
    | None -> [])
  @ (match session_id with
    | Some id -> [("session_id", `String id)]
    | None -> [])
  @ (match decision_reason with
    | Some reason -> [("decision_reason", `String reason)]
    | None -> [])
  @ (match decision_confidence with
    | Some confidence -> [("decision_confidence", `Float confidence)]
    | None -> [])
  @ (match auth_token with
    | Some token -> [("auth_token", `String token)]
    | None -> []))
  in
  notify_event ~event_type:HeartbeatTask ~agent ~data;
  Log.info ~ctx:"heartbeat"
    "💓 HeartbeatTask emitted for %s (goal: %d chars, tools: %d, worker_mode: %s)"
    agent (String.length goal) (List.length allowed_tools) worker_mode

(** {1 A2A Worker Response — Completion Evidence}

    Worker processes heartbeat_task, performs MCP tools directly, and submits a
    completion/evidence record. MASC no longer proxies the board write.
*)

(** Submit heartbeat task result from A2A Worker.
    @param worker_name Worker agent name (e.g., "model-worker-local")
    @param agent Original agent name (soul owner)
    @param status "acted" | "skipped" | "failed"
    @param summary Short completion summary
    @param tool_call_count Number of MCP tool calls the worker made
    @param tool_names Executed MCP tool names
    @param decision_reason Why the worker chose this outcome
    @param decision_confidence Confidence score (0.0-1.0)
    @param failure_reason Optional explicit error reason
    @return Success/error *)
let submit_heartbeat_result
    ~worker_name
    ~agent
    ~status
    ~summary
    ~tool_call_count
    ~tool_names
    ~decision_reason
    ~decision_confidence
    ?failure_reason
    () : (Yojson.Safe.t, string) result =
  let normalized_status = String.lowercase_ascii (String.trim status) in
  let result =
    match normalized_status with
    | "acted" | "skipped" | "failed" ->
        Ok (`Assoc [
          ("success", `Bool true);
          ("status", `String normalized_status);
          ("agent", `String agent);
          ("worker", `String worker_name);
          ("summary", `String summary);
          ("tool_call_count", `Int tool_call_count);
          ("tool_names", `List (List.map (fun name -> `String name) tool_names));
          ("decision_reason", `String decision_reason);
          ("decision_confidence", `Float decision_confidence);
          ("failure_reason",
            match failure_reason with
            | Some reason -> `String reason
            | None -> `Null);
        ])
    | other ->
        Error (Printf.sprintf "Unknown worker status: %s" other)
  in

  (* Broadcast completion event *)
  (match result with
   | Ok _ ->
       Eio.Mutex.use_rw ~protect:true heartbeat_mutex (fun () ->
         Hashtbl.replace latest_heartbeat_results agent
           {
             seq = next_heartbeat_snapshot_seq ();
           status = normalized_status;
           summary;
           worker_name;
           tool_call_count;
           tool_names;
           decision_reason;
           decision_confidence;
           failure_reason;
             updated_at = now_iso8601 ();
           });
       notify_event ~event_type:Completion ~agent
         ~data:(`Assoc [
           ("worker", `String worker_name);
           ("status", `String normalized_status);
           ("summary", `String summary);
           ("tool_call_count", `Int tool_call_count);
           ("tool_names", `List (List.map (fun name -> `String name) tool_names));
           ("decision_reason", `String decision_reason);
           ("decision_confidence", `Float decision_confidence);
           ("failure_reason",
           match failure_reason with
            | Some reason -> `String reason
            | None -> `Null);
         ])
   | Error msg ->
       Log.Misc.info "heartbeat result rejected: %s" msg);

  result
