[@@@warning "-32-33-69"]

open Server_auth

include Server_trpg_rest_views

let trpg_keeper_call_with_runtime
    ~(config : Room.config)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~name:keeper_name
    ~message
    ~timeout_sec
  : Tool_trpg.keeper_call_result =
  let keeper_ctx : _ Tool_keeper.context =
    { config; agent_name = "trpg-rest"; sw; clock; proc_mgr = None }
  in
  let forced_models = trpg_keeper_models_for_round () in
  let forced_models_field =
    if forced_models = [] then []
    else [ ("models", `List (List.map (fun m -> `String m) forced_models)) ]
  in
  let inline_goal =
    Printf.sprintf
      "TRPG runtime keeper for %s. You are an in-world keeper of this setting; avoid out-of-world meta narration, stay in character, keep continuity, answer concisely, and never output SKILL/STATE tags, prompt recalls, or raw visible_state_json."
      keeper_name
  in
  let turn_instructions =
    Tool_trpg.trpg_structured_action_system_instructions
  in
  let keeper_args =
    `Assoc
      (forced_models_field
      @ [
          ("name", `String keeper_name);
          ("message", `String message);
          ("goal", `String inline_goal);
          ("require_existing", `Bool true);
          ("timeout_sec", `Float timeout_sec);
          ("turn_instructions", `String turn_instructions);
        ])
  in
  try
    Eio.Time.with_timeout_exn clock timeout_sec (fun () ->
      match
        Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_msg" ~args:keeper_args
      with
      | None -> `Error "masc_keeper_msg dispatch unavailable"
      | Some (true, body) -> (
          try `Ok (Yojson.Safe.from_string body)
          with Yojson.Json_error e ->
            `Error (Printf.sprintf "keeper returned invalid json: %s" e))
      | Some (false, msg) -> `Error msg)
  with
  | Eio.Time.Timeout -> `Timeout
  | exn -> `Error (Printexc.to_string exn)

type trpg_round_run_guard_state = {
  mutex : Mutex.t;
  inflight_rooms : (string, unit) Hashtbl.t;
  idempotency_cache : (string, Yojson.Safe.t) Hashtbl.t;
  mutable cache_writes : int;
}

let trpg_round_run_guard : trpg_round_run_guard_state =
  {
    mutex = Mutex.create ();
    inflight_rooms = Hashtbl.create 64;
    idempotency_cache = Hashtbl.create 512;
    cache_writes = 0;
  }
let trpg_keeper_probe_with_runtime
    ~(config : Room.config)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~name:keeper_name
  : Tool_trpg.keeper_probe_result =
  let keeper_ctx : _ Tool_keeper.context =
    { config; agent_name = "trpg-rest"; sw; clock; proc_mgr = None }
  in
  let keeper_args =
    `Assoc [ ("name", `String keeper_name); ("fast", `Bool true) ]
  in
  try
    Eio.Time.with_timeout_exn clock 5.0 (fun () ->
      match
        Tool_keeper.dispatch keeper_ctx ~name:"masc_keeper_status"
          ~args:keeper_args
      with
      | None -> `Error "masc_keeper_status dispatch unavailable"
      | Some (true, _body) -> `Ok
      | Some (false, msg) -> `Error msg)
  with
  | Eio.Time.Timeout -> `Error "timeout"
  | exn -> `Error (Printexc.to_string exn)
let trpg_round_run_json
    ~(state : Mcp_server.server_state)
    ~(agent_name : string)
    ~(sw : Eio.Switch.t)
    ~(clock : float Eio.Time.clock_ty Eio.Resource.t)
    ~(idempotency_key : string option)
    ~body_str
  : trpg_api_result =
  let with_round_run_guard_lock f =
    Mutex.lock trpg_round_run_guard.mutex;
    Fun.protect ~finally:(fun () -> Mutex.unlock trpg_round_run_guard.mutex) f
  in
  let trpg_round_run_extract_room_id (args : Yojson.Safe.t) : string =
    let pick key =
      match Yojson.Safe.Util.member key args with
      | `String raw ->
          let trimmed = String.trim raw in
          if trimmed = "" then None else Some trimmed
      | _ -> None
    in
    match pick "room_id" with
    | Some room_id -> room_id
    | None -> (
        match pick "room" with
        | Some room_id -> room_id
        | None -> "default")
  in
  let trpg_round_run_extract_idempotency_key
      ~(header_key : string option)
      (args : Yojson.Safe.t) : string option =
    let normalize = function
      | None -> None
      | Some raw ->
          let trimmed = String.trim raw in
          if trimmed = "" then None else Some trimmed
    in
    match normalize header_key with
    | Some _ as key -> key
    | None -> (
        match Yojson.Safe.Util.member "idempotency_key" args with
        | `String raw -> normalize (Some raw)
        | _ -> None)
  in
  let trpg_round_run_cache_key ~room_id ~idempotency_key =
    room_id ^ "\x1f" ^ idempotency_key
  in
  let trpg_round_run_cache_lookup ~room_id ~idempotency_key =
    let key = trpg_round_run_cache_key ~room_id ~idempotency_key in
    with_round_run_guard_lock (fun () ->
      Hashtbl.find_opt trpg_round_run_guard.idempotency_cache key)
  in
  let trpg_round_run_cache_store ~room_id ~idempotency_key ~result_json =
    let key = trpg_round_run_cache_key ~room_id ~idempotency_key in
    with_round_run_guard_lock (fun () ->
      Hashtbl.replace trpg_round_run_guard.idempotency_cache key result_json;
      trpg_round_run_guard.cache_writes <- trpg_round_run_guard.cache_writes + 1;
      if trpg_round_run_guard.cache_writes >= 1024
         && Hashtbl.length trpg_round_run_guard.idempotency_cache > 4096
      then (
        Hashtbl.reset trpg_round_run_guard.idempotency_cache;
        trpg_round_run_guard.cache_writes <- 0))
  in
  let trpg_round_run_try_acquire ~room_id =
    with_round_run_guard_lock (fun () ->
      if Hashtbl.mem trpg_round_run_guard.inflight_rooms room_id then false
      else (
        Hashtbl.replace trpg_round_run_guard.inflight_rooms room_id ();
        true))
  in
  let trpg_round_run_release ~room_id =
    with_round_run_guard_lock (fun () ->
      Hashtbl.remove trpg_round_run_guard.inflight_rooms room_id)
  in
  try
    let args = Yojson.Safe.from_string body_str in
    let room_id = trpg_round_run_extract_room_id args in
    let idempotency_key =
      trpg_round_run_extract_idempotency_key ~header_key:idempotency_key args
    in
    let run_once () =
      let keeper_call =
        trpg_keeper_call_with_runtime
          ~config:state.Mcp_server.room_config
          ~sw
          ~clock
      in
      let keeper_probe =
        trpg_keeper_probe_with_runtime
          ~config:state.Mcp_server.room_config
          ~sw
          ~clock
      in
      let trpg_ctx : Tool_trpg.context =
        {
          store = Trpg_store.make_sqlite ~base_dir:state.Mcp_server.room_config.base_path;
          agent_name;
          keeper_call = Some keeper_call;
          keeper_probe = Some keeper_probe;
          dm_voice_emit = None;
        }
      in
      match Tool_trpg.dispatch trpg_ctx ~name:"masc_trpg_round_run" ~args with
      | None ->
          Error (`Internal_server_error, "masc_trpg_round_run dispatch unavailable")
      | Some (false, msg) -> Error (`Bad_request, msg)
      | Some (true, body) -> (
          try Ok (Yojson.Safe.from_string body)
          with Yojson.Json_error e ->
            Error (`Internal_server_error, Printf.sprintf "invalid tool json: %s" e))
    in
    let run_with_single_flight () =
      if not (trpg_round_run_try_acquire ~room_id) then
        Error
          ( `Bad_request,
            Printf.sprintf
              "round run already in progress for room_id=%s (single-flight)"
              room_id )
      else
        Fun.protect
          ~finally:(fun () -> trpg_round_run_release ~room_id)
          (fun () ->
            let result = run_once () in
            (match (result, idempotency_key) with
            | Ok json, Some idem_key ->
                trpg_round_run_cache_store
                  ~room_id
                  ~idempotency_key:idem_key
                  ~result_json:json
            | _ -> ());
            result)
    in
    match idempotency_key with
    | Some idem_key -> (
        match trpg_round_run_cache_lookup ~room_id ~idempotency_key:idem_key with
        | Some json -> Ok json
        | None -> run_with_single_flight ())
    | None -> run_with_single_flight ()
  with
  | Yojson.Json_error e -> Error (`Bad_request, Printf.sprintf "invalid json: %s" e)
  | exn -> Error (`Internal_server_error, Printexc.to_string exn)


(* ============================================ *)
(* TRPG SSE Streaming                           *)
(* ============================================ *)

let trpg_sse_poll_interval_s = 2.0

(** TRPG SSE keepalive interval in seconds *)
let trpg_sse_keepalive_s = 30.0

(** Format a single TRPG event as an SSE frame.
    Uses the event's seq as the SSE id, and the event_type string as the SSE event field. *)
let trpg_event_to_sse (ev : Trpg_engine_event.t) : string =
  let data = Yojson.Safe.to_string (Trpg_engine_event.to_yojson ev) in
  let event_type_str = Trpg_engine_event.string_of_event_type ev.event_type in
  Printf.sprintf "id: %d\nevent: %s\ndata: %s\n\n" ev.seq event_type_str data

(** Handle TRPG SSE streaming endpoint (HTTP/1.1).
    Opens a long-lived text/event-stream connection, replays events after Last-Event-ID,
    then polls SQLite every 2s for new events. Sends keepalive comments every 30s. *)
let handle_trpg_sse ~base_dir ~room_id ~event_type_filter request reqd =
  let room_id = String.trim room_id in
  if room_id = "" then begin
    let origin = get_origin request in
    Http_server_eio.Response.json ~status:`Bad_request
      ~extra_headers:(cors_headers origin)
      (Yojson.Safe.to_string (trpg_error_json "room_id is required")) reqd
  end else
    let origin = get_origin request in
    match trpg_parse_event_type_filter event_type_filter with
    | Error (`Bad_request, msg) ->
        Http_server_eio.Response.json ~status:`Bad_request
          ~extra_headers:(cors_headers origin)
          (Yojson.Safe.to_string (trpg_error_json msg)) reqd
    | Ok event_type_opt ->
        let last_event_id =
          match Httpun.Headers.get request.Httpun.Request.headers "last-event-id" with
          | Some id -> (try int_of_string id with Failure _ -> 0)
          | None -> 0
        in
        let headers = Httpun.Headers.of_list ([
          ("content-type", "text/event-stream");
          ("cache-control", "no-cache");
          ("connection", "keep-alive");
        ] @ cors_headers origin) in
        let response = Httpun.Response.create ~headers `OK in
        let writer = Httpun.Reqd.respond_with_streaming reqd response in
        let mutex = Eio.Mutex.create () in
        let closed = ref false in
        let last_seq = ref last_event_id in

        let send_raw_data data =
          if !closed || Httpun.Body.Writer.is_closed writer then begin
            closed := true; false
          end else
            try
              Eio.Mutex.use_rw ~protect:true mutex (fun () ->
                Httpun.Body.Writer.write_string writer data;
                Httpun.Body.Writer.flush writer (fun _ -> ()));
              true
            with _exn ->
              closed := true; false
        in

        (* Send initial comment to confirm connection *)
        ignore (send_raw_data
          (Printf.sprintf ": TRPG SSE stream for room %s (after_seq=%d)\nretry: 3000\n\n"
             room_id !last_seq));

        (* Replay existing events newer than last_seq *)
        (match
           (if !last_seq > 0 then
              Trpg_engine_store_sqlite.read_events_after
                ~base_dir ~room_id ~after_seq:!last_seq
            else
              Trpg_engine_store_sqlite.read_events ~base_dir ~room_id)
         with
         | Ok events ->
             let events = match event_type_opt with
               | None -> events
               | Some et ->
                   List.filter
                     (fun (ev : Trpg_engine_event.t) -> ev.event_type = et)
                     events
             in
             List.iter (fun ev ->
               if not !closed then begin
                 ignore (send_raw_data (trpg_event_to_sse ev));
                 last_seq := max !last_seq ev.Trpg_engine_event.seq
               end) events
         | Error _ -> ());

        (* Start polling fiber for new events + keepalive *)
        (match Eio_context.get_switch_opt (), Eio_context.get_clock_opt () with
         | Some sw, Some clock ->
             Eio.Fiber.fork ~sw (fun () ->
               let is_cancelled = function
                 | Eio.Cancel.Cancelled _ -> true | _ -> false
               in
               let keepalive_counter = ref 0 in
               let polls_per_keepalive =
                 max 1 (int_of_float (trpg_sse_keepalive_s /. trpg_sse_poll_interval_s))
               in
               let rec loop () =
                 if not !closed then begin
                   (try Eio.Time.sleep clock trpg_sse_poll_interval_s
                    with exn -> if is_cancelled exn then raise exn);
                   if not !closed then begin
                     (match
                        Trpg_engine_store_sqlite.read_events_after
                          ~base_dir ~room_id ~after_seq:!last_seq
                      with
                      | Ok events ->
                          let events = match event_type_opt with
                            | None -> events
                            | Some et ->
                                List.filter
                                  (fun (ev : Trpg_engine_event.t) ->
                                    ev.event_type = et)
                                  events
                          in
                          List.iter (fun ev ->
                            if not !closed then begin
                              if not (send_raw_data (trpg_event_to_sse ev)) then
                                closed := true
                              else
                                last_seq := max !last_seq
                                  ev.Trpg_engine_event.seq
                            end) events
                      | Error _ -> ());
                     incr keepalive_counter;
                     if !keepalive_counter >= polls_per_keepalive then begin
                       keepalive_counter := 0;
                       if not !closed then
                         ignore (send_raw_data ": keepalive\n\n")
                     end
                   end;
                   loop ()
                 end
               in
               try loop () with exn ->
                 if is_cancelled exn then raise exn
                 else
                   Log.Trpg.error "poll loop error for room %s: %s"
                     room_id (Printexc.to_string exn))
         | _ ->
             ignore (send_raw_data
               "event: error\ndata: {\"error\":\"server not ready\"}\n\n"))
