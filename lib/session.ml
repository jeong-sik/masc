(** Session Management - Track connected agents and rate limiting *)

open Masc_domain

module AgentMap = Map.Make(String)

(** Session info stored in registry *)
type session = {
  agent_name: string;
  connected_at: float;     (* Unix timestamp *)
  last_activity: float;
  is_listening: bool;
  message_queue: Yojson.Safe.t Eio.Stream.t;  (* Pending messages *)
}

(** Rate limit tracking per category *)
type rate_tracker = {
  general_timestamps: float list;
  broadcast_timestamps: float list;
  task_ops_timestamps: float list;
  burst_used: int;
  last_burst_reset: float;
}

type msg =
  | Register of string * float * session Eio.Promise.u
  | Unregister of string
  | Update_activity of string * bool option * float
  | Check_rate_limit_req of string * rate_limit_category * agent_role * float * (bool * int) Eio.Promise.u
  | Get_rate_limit_status_req of string * agent_role * float * Yojson.Safe.t Eio.Promise.u
  | Push_message of { from_agent: string; content: string; mention: string option; timestamp: string; reply: string list Eio.Promise.u }
  | Push_notification of Yojson.Safe.t * int Eio.Promise.u
  | Get_session of string * session option Eio.Promise.u
  | Get_sessions of session AgentMap.t Eio.Promise.u
  | Restore_from_disk_req of string * float * unit Eio.Promise.u

(** Session registry - manages all connected agents *)
type registry = {
  config: rate_limit_config;
  mailbox: msg Eio.Stream.t;
}

type registry_state = {
  sessions: session AgentMap.t;
  rate_trackers: rate_tracker AgentMap.t;
}

(* Bound: 10x the per-session [max_notification_queue] (1000), sized to
   absorb a keeper-fleet boot burst (16 keepers × ~30 messages each =
   ~500) with 20x headroom. Unbounded ([max_int]) caused #10777-class
   heap exhaustion when the consumer fiber stalled. *)
let max_registry_mailbox = 10_000

let create ?(config = default_rate_limit) () = {
  config;
  mailbox = Eio.Stream.create max_registry_mailbox;
}

let create_tracker now = {
  general_timestamps = [];
  broadcast_timestamps = [];
  task_ops_timestamps = [];
  burst_used = 0;
  last_burst_reset = now;
}

let get_timestamps tracker = function
  | GeneralLimit -> tracker.general_timestamps
  | BroadcastLimit -> tracker.broadcast_timestamps
  | TaskOpsLimit -> tracker.task_ops_timestamps

let set_timestamps tracker category ts =
  match category with
  | GeneralLimit -> { tracker with general_timestamps = ts }
  | BroadcastLimit -> { tracker with broadcast_timestamps = ts }
  | TaskOpsLimit -> { tracker with task_ops_timestamps = ts }

(* Max notification queue size per session. Oldest events are dropped when exceeded. *)
let max_notification_queue = 1000

let process_msg config state msg =
  match msg with
  | Register (agent_name, now, p) ->
      let existing = AgentMap.mem agent_name state.sessions in
      let session = {
        agent_name;
        connected_at = now;
        last_activity = now;
        is_listening = false;
        message_queue = Eio.Stream.create max_notification_queue;
      } in
      let sessions' = AgentMap.add agent_name session state.sessions in
      let total = AgentMap.cardinal sessions' in
      if existing then
        Log.Session.debug "Session refreshed: %s (total: %d)" agent_name total
      else
        Log.Session.info "Session registered: %s (total: %d)" agent_name total;
      Eio.Promise.resolve p session;
      { state with sessions = sessions' }

  | Unregister agent_name ->
      let sessions' = AgentMap.remove agent_name state.sessions in
      Log.Session.info "Session unregistered: %s (total: %d)"
        agent_name (AgentMap.cardinal sessions');
      { state with sessions = sessions' }

  | Update_activity (agent_name, is_listening_opt, now) ->
      (match AgentMap.find_opt agent_name state.sessions with
       | Some session ->
           let is_listen = match is_listening_opt with Some v -> v | None -> session.is_listening in
           let session' = { session with last_activity = now; is_listening = is_listen } in
           { state with sessions = AgentMap.add agent_name session' state.sessions }
       | None -> state)

  | Get_session (agent_name, p) ->
      Eio.Promise.resolve p (AgentMap.find_opt agent_name state.sessions);
      state

  | Get_sessions p ->
      Eio.Promise.resolve p state.sessions;
      state

  | Push_message { from_agent; content; mention; timestamp; reply } ->
      let notification = `Assoc [
        ("type", `String "masc/message");
        ("from", `String from_agent);
        ("content", `String content);
        ("mention", Json_util.string_opt_to_json mention);
        ("timestamp", `String timestamp);
      ] in
      let targets = ref [] in
      AgentMap.iter (fun name session ->
        if name <> from_agent then begin
          let should_send = match mention with
            | None -> true
            | Some m -> m = name
          in
          if should_send then begin
            let rec try_add st ev =
            if Eio.Stream.length st >= max_notification_queue then begin
              ignore (Eio.Stream.take_nonblocking st);
              try_add st ev
            end else
              Eio.Stream.add st ev
          in
          try_add session.message_queue notification;
            targets := name :: !targets
          end
        end
      ) state.sessions;
      if !targets <> [] then
        Log.Session.debug "Pushed to: %s" (String.concat ", " !targets);
      Eio.Promise.resolve reply !targets;
      state

  | Push_notification (event, reply) ->
      let count = ref 0 in
      AgentMap.iter (fun _name session ->
        let rec try_add st ev =
          if Eio.Stream.length st >= max_notification_queue then begin
            ignore (Eio.Stream.take_nonblocking st);
            try_add st ev
          end else
            Eio.Stream.add st ev
        in
        try_add session.message_queue event;
        incr count
      ) state.sessions;
      Eio.Promise.resolve reply !count;
      state

  | Check_rate_limit_req (agent_name, category, role, now, p) ->
      let one_minute_ago = now -. 60.0 in
      let tracker =
        match AgentMap.find_opt agent_name state.rate_trackers with
        | Some t -> t
        | None -> create_tracker now
      in
      let tracker =
        if now -. tracker.last_burst_reset > 60.0 then
          { tracker with burst_used = 0; last_burst_reset = now }
        else tracker
      in
      let timestamps = get_timestamps tracker category in
      let recent = List.filter (fun t -> t > one_minute_ago) timestamps in
      let tracker = set_timestamps tracker category recent in

      let base_limit = effective_limit config ~role ~category in
      let limit =
        if List.mem agent_name config.priority_agents
        then int_of_float (float_of_int base_limit *. 1.5)
        else base_limit
      in

      let current = List.length recent in
      if current >= limit then begin
        if tracker.burst_used < config.burst_allowed then begin
          let tracker' = { tracker with burst_used = tracker.burst_used + 1 } in
          let tracker' = set_timestamps tracker' category (now :: recent) in
          Eio.Promise.resolve p (true, 0);
          { state with rate_trackers = AgentMap.add agent_name tracker' state.rate_trackers }
        end else begin
          let oldest = List.fold_left min now recent in
          let wait = int_of_float (oldest +. 60.0 -. now) in
          Eio.Promise.resolve p (false, max 1 wait);
          { state with rate_trackers = AgentMap.add agent_name tracker state.rate_trackers }
        end
      end else begin
        let tracker' = set_timestamps tracker category (now :: recent) in
        Eio.Promise.resolve p (true, 0);
        { state with rate_trackers = AgentMap.add agent_name tracker' state.rate_trackers }
      end

  | Get_rate_limit_status_req (agent_name, role, now, p) ->
      let one_minute_ago = now -. 60.0 in
      let tracker =
        match AgentMap.find_opt agent_name state.rate_trackers with
        | Some t -> t
        | None -> create_tracker now
      in
      let status_for_category category =
        let timestamps = get_timestamps tracker category in
        let recent = List.filter (fun t -> t > one_minute_ago) timestamps in
        let limit = effective_limit config ~role ~category in
        let current = List.length recent in
        `Assoc [
          ("category", `String (rate_limit_category_to_string category));
          ("current", `Int current);
          ("limit", `Int limit);
          ("remaining", `Int (max 0 (limit - current)));
        ]
      in
      let burst = tracker.burst_used in
      let status = `Assoc [
        ("agent", `String agent_name);
        ("role", `String (agent_role_to_string role));
        ("burst_remaining", `Int (config.burst_allowed - burst));
        ("categories", `List [
          status_for_category GeneralLimit;
          status_for_category BroadcastLimit;
          status_for_category TaskOpsLimit;
        ]);
      ] in
      Eio.Promise.resolve p status;
      state

  | Restore_from_disk_req (agents_path, now, p) ->
      let state' = ref state in
      if Sys.file_exists agents_path && Sys.is_directory agents_path then begin
        let restored = ref 0 in
        Sys.readdir agents_path |> Array.iter (fun name ->
          if Filename.check_suffix name ".json" then begin
            let agent_name = Filename.chop_suffix name ".json" in
            let session = {
              agent_name;
              connected_at = now;
              last_activity = now;
              is_listening = false;
              message_queue = Eio.Stream.create max_notification_queue;
            } in
            state' := { !state' with sessions = AgentMap.add agent_name session !state'.sessions };
            incr restored
          end
        );
        if !restored > 0 then
          Log.Session.info "Restored %d session(s) from disk" !restored
      end;
      Eio.Promise.resolve p ();
      !state'

let start_loop registry ~sw =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop state =
      let msg = Eio.Stream.take registry.mailbox in
      let state' = process_msg registry.config state msg in
      loop state'
    in
    loop { sessions = AgentMap.empty; rate_trackers = AgentMap.empty }
  )

(** Helpers to send messages to the registry *)

let register registry ~agent_name =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Register (agent_name, Time_compat.now (), r));
  Eio.Promise.await p

let unregister registry ~agent_name =
  Eio.Stream.add registry.mailbox (Unregister agent_name)

let update_activity registry ~agent_name ?is_listening () =
  Eio.Stream.add registry.mailbox (Update_activity (agent_name, is_listening, Time_compat.now ()))

let check_rate_limit_ex registry ~agent_name ~category ~role =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Check_rate_limit_req (agent_name, category, role, Time_compat.now (), r));
  Eio.Promise.await p

let check_rate_limit registry ~agent_name =
  check_rate_limit_ex registry ~agent_name ~category:GeneralLimit ~role:Worker

let get_rate_limit_status registry ~agent_name ~role =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Get_rate_limit_status_req (agent_name, role, Time_compat.now (), r));
  Eio.Promise.await p

let push_message registry ~from_agent ~content ~mention =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Push_message { from_agent; content; mention; timestamp = now_iso (); reply = r });
  Eio.Promise.await p

let push_notification_to_active_agents registry ~(event : Yojson.Safe.t) =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Push_notification (event, r));
  Eio.Promise.await p

let get_session registry ~agent_name =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Get_session (agent_name, r));
  Eio.Promise.await p

let get_sessions registry =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Get_sessions r);
  Eio.Promise.await p

let pop_message registry ~agent_name =
  match get_session registry ~agent_name with
  | Some session -> Eio.Stream.take_nonblocking session.message_queue
  | None -> None

let wait_for_message registry ~agent_name ~timeout =
  (* Ensure session exists *)
  let session = match get_session registry ~agent_name with
    | Some s -> s
    | None -> register registry ~agent_name
  in
  update_activity registry ~agent_name ~is_listening:true ();
  
  let result =
    match Process_eio.get_clock () with
    | Ok clk ->
        (match
           Eio.Time.with_timeout clk timeout (fun () ->
             Ok (Eio.Stream.take session.message_queue)
           )
         with
         | Ok msg -> Some msg
         | Error `Timeout -> None
         | exception Eio.Cancel.Cancelled e -> raise (Eio.Cancel.Cancelled e)
         | exception exn ->
             Log.Misc.warn "session listen interrupted: %s" (Printexc.to_string exn);
             None)
    | Error e ->
        Log.Session.debug "clock unavailable in wait_for_message: %s" e;
        None
  in
  update_activity registry ~agent_name ~is_listening:false ();
  result

let get_inactive_agents registry ~threshold =
  let now = Time_compat.now () in
  let sessions = get_sessions registry in
  AgentMap.fold (fun name session acc ->
    if now -. session.last_activity > threshold then name :: acc else acc
  ) sessions []

let get_agent_statuses registry =
  let now = Time_compat.now () in
  let sessions = get_sessions registry in
  AgentMap.fold (fun name session acc ->
    let idle_secs = int_of_float (now -. session.last_activity) in
    let status_icon =
      if session.is_listening then "🎧"
      else if idle_secs > 60 then "💤"
      else "🔨"
    in
    let status = `Assoc [
      ("name", `String name);
      ("listening", `Bool session.is_listening);
      ("idle_seconds", `Int idle_secs);
      ("status", `String status_icon);
    ] in
    status :: acc
  ) sessions []

let status_string registry =
  let statuses = get_agent_statuses registry in
  if statuses = [] then
    "📡 No agents connected."
  else begin
    let buf = Buffer.create 256 in
    Printf.bprintf buf "📡 Connected agents (%d):\n" (List.length statuses);
    Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

    List.iter (fun status ->
      let module U = Yojson.Safe.Util in
      let name = status |> U.member "name" |> U.to_string in
      let icon = status |> U.member "status" |> U.to_string in
      let idle = status |> U.member "idle_seconds" |> U.to_int in
      let listening = status |> U.member "listening" |> U.to_bool in
      let idle_info = if idle > 30 then Printf.sprintf "(idle %ds)" idle else "" in
      let listen_info = if listening then "리스닝중" else "" in
      Printf.bprintf buf "  %s %s %s %s\n" icon name listen_info idle_info
    ) statuses;

    Buffer.add_string buf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
    Buffer.add_string buf "🎧=리스닝 🔨=작업중 💤=졸고있음(60s+)";

    let inactive = get_inactive_agents registry ~threshold:Coord_resilience.default_warning_threshold in
    if inactive <> [] then begin
      Buffer.add_string buf "\n\n**INACTIVE AGENTS**: ";
      Buffer.add_string buf (String.concat ", " inactive);
      Buffer.add_string buf "\n   @mention으로 깨워주세요!"
    end;

    Buffer.contents buf
  end

let connected_agents registry =
  let sessions = get_sessions registry in
  AgentMap.fold (fun name _ acc -> name :: acc) sessions []

let restore_from_disk registry ~agents_path =
  let p, r = Eio.Promise.create () in
  Eio.Stream.add registry.mailbox (Restore_from_disk_req (agents_path, Time_compat.now (), r));
  Eio.Promise.await p

(* ============================================ *)
(* MCP 2025-11-25 Spec: Mcp-Session-Id          *)
(* ============================================ *)

module McpSessionStore = struct
  type mcp_session = {
    id: string;
    created_at: float;
    last_activity: float;
    agent_name: string option;
    metadata: (string * string) list;
    request_count: int;
  }

  type store_msg =
    | Generate_id of string Eio.Promise.u
    | Create of string option * float * mcp_session Eio.Promise.u
    | Get of string * float * mcp_session option Eio.Promise.u
    | Cleanup_stale of float * float * int Eio.Promise.u
    | List_all of mcp_session list Eio.Promise.u
    | Remove of string * bool Eio.Promise.u

  (* Bound: same rationale as [max_registry_mailbox] above. McpSessionStore
     handles 4 message types (Put/Get/Cleanup_stale/List_all/Remove); 10k
     entries is well above any realistic concurrent HTTP request burst and
     prevents heap exhaustion if the consumer fiber stalls. *)
  let max_mcp_session_mailbox = 10_000

  let mailbox = Eio.Stream.create max_mcp_session_mailbox

  let max_age = ref Env_config.Session.max_age_seconds

  let process_msg state msg =
    match msg with
    | Generate_id p ->
        let bytes = Mirage_crypto_rng.generate 16 in
        let buf = Buffer.create 32 in
        for i = 0 to String.length bytes - 1 do
          Printf.bprintf buf "%02x" (Char.code (String.get bytes i))
        done;
        let id = Printf.sprintf "mcp_%s" (Buffer.contents buf) in
        Eio.Promise.resolve p id;
        state

    | Create (agent_name, now, p) ->
        let bytes = Mirage_crypto_rng.generate 16 in
        let buf = Buffer.create 32 in
        for i = 0 to String.length bytes - 1 do
          Printf.bprintf buf "%02x" (Char.code (String.get bytes i))
        done;
        let id = Printf.sprintf "mcp_%s" (Buffer.contents buf) in
        let session = {
          id;
          created_at = now;
          last_activity = now;
          agent_name;
          metadata = [];
          request_count = 0;
        } in
        Eio.Promise.resolve p session;
        AgentMap.add session.id session state

    | Get (session_id, now, p) ->
        (match AgentMap.find_opt session_id state with
         | None ->
             Eio.Promise.resolve p None;
             state
         | Some session ->
             let session' = { session with last_activity = now; request_count = session.request_count + 1 } in
             Eio.Promise.resolve p (Some session');
             AgentMap.add session_id session' state)

    | Cleanup_stale (now, max_age_val, p) ->
        let state', stale_count =
          AgentMap.fold (fun id session (acc_state, acc_count) ->
            if now -. session.last_activity > max_age_val then
              (AgentMap.remove id acc_state, acc_count + 1)
            else
              (acc_state, acc_count)
          ) state (state, 0)
        in
        Eio.Promise.resolve p stale_count;
        state'

    | List_all p ->
        let all = AgentMap.fold (fun _ s acc -> s :: acc) state [] in
        Eio.Promise.resolve p all;
        state

    | Remove (id, p) ->
        let mem = AgentMap.mem id state in
        Eio.Promise.resolve p mem;
        if mem then AgentMap.remove id state else state

  let start_loop ~sw =
    Eio.Fiber.fork ~sw (fun () ->
      let rec loop state =
        let msg = Eio.Stream.take mailbox in
        loop (process_msg state msg)
      in
      loop AgentMap.empty
    )

  let generate_id () =
    let p, r = Eio.Promise.create () in
    Eio.Stream.add mailbox (Generate_id r);
    Eio.Promise.await p

  let create ?agent_name () =
    let p, r = Eio.Promise.create () in
    Eio.Stream.add mailbox (Create (agent_name, Time_compat.now (), r));
    Eio.Promise.await p

  let get session_id =
    let p, r = Eio.Promise.create () in
    Eio.Stream.add mailbox (Get (session_id, Time_compat.now (), r));
    Eio.Promise.await p

  let cleanup_stale () =
    let p, r = Eio.Promise.create () in
    Eio.Stream.add mailbox (Cleanup_stale (Time_compat.now (), !max_age, r));
    Eio.Promise.await p

  let to_json (s : mcp_session) : Yojson.Safe.t =
    `Assoc [
      ("id", `String s.id);
      ("created_at", `Float s.created_at);
      ("last_activity", `Float s.last_activity);
      ("agent_name", Json_util.string_opt_to_json s.agent_name);
      ("request_count", `Int s.request_count);
      ("metadata", `Assoc (List.map (fun (k, v) -> (k, `String v)) s.metadata));
    ]

  let list_all () =
    let p, r = Eio.Promise.create () in
    Eio.Stream.add mailbox (List_all r);
    Eio.Promise.await p

  let remove id =
    let p, r = Eio.Promise.create () in
    Eio.Stream.add mailbox (Remove (id, r));
    Eio.Promise.await p
end

let start_mcp_session_cleanup_loop ~sw ~clock ?(interval=Env_config.Session.max_age_seconds /. 10.0) () =
  (* Also start the store loop since we refactored it to Actor *)
  McpSessionStore.start_loop ~sw;
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock interval;
      (try
        let removed = McpSessionStore.cleanup_stale () in
        if removed > 0 then
          Log.Session.info "Cleaned up %d stale MCP sessions" removed
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Session.warn "mcp session cleanup failed: %s"
           (Printexc.to_string exn));
      loop ()
    in
    loop ()
  )

let extract_mcp_session_id (headers : Cohttp.Header.t) : string option =
  match Cohttp.Header.get headers "Mcp-Session-Id" with
  | Some _ as result -> result
  | None -> Cohttp.Header.get headers "X-MCP-Session-ID"

let get_or_create_mcp_session (headers : Cohttp.Header.t) : McpSessionStore.mcp_session =
  match extract_mcp_session_id headers with
  | Some id ->
    (match McpSessionStore.get id with
     | Some session -> session
     | None -> McpSessionStore.create ())
  | None ->
    McpSessionStore.create ()

let add_mcp_session_header (headers : Cohttp.Header.t) (session : McpSessionStore.mcp_session) : Cohttp.Header.t =
  Cohttp.Header.add headers "Mcp-Session-Id" session.id

let handle_mcp_session_tool (arguments : Yojson.Safe.t) : (bool * string) =
  let get_string key =
    match Yojson.Safe.Util.member key arguments with
    | `String s -> Some s
    | _ -> None
  in
  match get_string "action" with
  | Some "get" ->
    (match get_string "session_id" with
     | Some id ->
       (match McpSessionStore.get id with
        | Some s -> (true, Yojson.Safe.to_string (McpSessionStore.to_json s))
        | None -> (false, Printf.sprintf "MCP session '%s' not found" id))
     | None -> (false, "session_id required"))
  | Some "create" ->
    let agent_name = get_string "agent_name" in
    let s = McpSessionStore.create ?agent_name () in
    (true, Yojson.Safe.to_string (McpSessionStore.to_json s))
  | Some "list" ->
    let sessions = McpSessionStore.list_all () in
    let json = `Assoc [
      ("count", `Int (List.length sessions));
      ("sessions", `List (List.map McpSessionStore.to_json sessions));
    ] in
    (true, Yojson.Safe.to_string json)
  | Some "cleanup" ->
    let removed = McpSessionStore.cleanup_stale () in
    (true, Printf.sprintf "Removed %d stale MCP sessions" removed)
  | Some "remove" ->
    (match get_string "session_id" with
     | Some id ->
       if McpSessionStore.remove id then (true, "Session removed")
       else (false, "Session not found")
     | None -> (false, "session_id required"))
  | Some other -> (false, Printf.sprintf "Unknown action: %s" other)
  | None -> (false, "action required: get, create, list, cleanup, remove")
