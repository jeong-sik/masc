(** Coord Lifecycle - Agent join/leave operations.

    Extracted from Coord module. Handles agent entry, re-entry, and departure
    including nickname resolution, dedup, metadata, and relation materialization. *)

open Types
open Coord_utils
open Coord_state
open Coord_broadcast

(* Single-namespace: room_id/namespace_id concepts retired (#unify-namespace).
   All coordination scoped by cluster basepath only. *)

(** Bounded snapshot of a corrupt agent JSON file for error diagnostics.
    Reads at most 200 bytes to avoid OOM on large/corrupt files. *)
let agent_parse_error_snapshot ~agent_name ~agent_file =
  let raw_head =
    try
      In_channel.with_open_text agent_file (fun ic ->
        let buf = Bytes.create 200 in
        let n = In_channel.input ic buf 0 200 in
        Bytes.sub_string buf 0 n)
    with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ""
  in
  `Assoc [
    ("agent_name", `String agent_name);
    ("agent_file", `String agent_file);
    ("raw_head",
      if raw_head = "" then `Null else `String raw_head);
  ]

(** Join room - with auto-generated nickname and metadata *)
let join config ~agent_name ?(agent_type_override=None) ~capabilities
    ?(pid=None) ?(hostname=None) ?(tty=None) ?(worktree=None) ?(parent_task=None) () =
  ensure_initialized config;

  (* Determine if this is a legacy call (agent_name = type) or new style *)
  let agent_type = match agent_type_override with
    | Some t -> t
    | None ->
        (* Check if agent_name looks like a nickname (has dashes) *)
        if Nickname.is_generated_nickname agent_name then
          Option.value (Nickname.extract_agent_type agent_name) ~default:agent_name
        else
          agent_name  (* Legacy: agent_name is the type *)
  in

  (* Reuse existing nickname for same agent_type if already joined,
     otherwise generate a new one. This prevents identity drift when
     the same agent_name joins multiple times within a session. *)
  let nickname =
    if Nickname.is_generated_nickname agent_name then
      agent_name  (* Already a nickname, use as-is *)
    else begin
      let dir = agents_dir config in
      let prefix = safe_filename agent_type ^ "-" in
      let existing =
        if Sys.file_exists dir && Sys.is_directory dir then
          Array.to_list (Sys.readdir dir)
          |> List.find_opt (fun f ->
               Filename.check_suffix f ".json"
               && String.length f > String.length prefix
               && String.sub f 0 (String.length prefix) = prefix)
          |> Option.map (fun f -> Filename.chop_suffix f ".json")
        else None
      in
      match existing with
      | Some nick -> nick  (* Reuse existing nickname for this agent_type *)
      | None -> Nickname.generate agent_type
    end
  in

  (* Dedup: if agent already joined, update last_seen and return early *)
  let agent_file_dedup = Filename.concat (agents_dir config) (safe_filename nickname ^ ".json") in
  let already_joined = Sys.file_exists agent_file_dedup in
  if already_joined then begin
    (match read_agent_with_repair config agent_file_dedup with
     | Ok existing_agent ->
       let is_inactive = existing_agent.status = Inactive in
       let new_session_id = if is_inactive then generate_session_id () else
         match existing_agent.meta with Some m -> m.session_id | None -> generate_session_id ()
       in
       let new_meta : agent_meta = {
         session_id = new_session_id;
         agent_type;
         pid;
         hostname = (match hostname with Some h -> Some h | None -> get_hostname ());
         tty = (match tty with Some t -> Some t | None -> get_tty ());
         worktree;
         parent_task;
       } in
       let updated = { existing_agent with
         status = Active;
         last_seen = now_iso ();
         capabilities;
         meta = Some new_meta;
       } in
       write_json config agent_file_dedup (agent_to_yojson updated);
       if is_inactive then begin
         (* Restore to active_agents on rejoin *)
         let _ = update_state config (fun s ->
           let agents = nickname :: List.filter ((<>) nickname) s.active_agents in
           { s with active_agents = agents }
         ) in
         let _ = broadcast config ~from_agent:nickname
                   ~content:(Printf.sprintf "👋 %s rejoined the namespace" nickname) in
         log_event config (Printf.sprintf
           "{\"type\":\"agent_join\",\"agent\":\"%s\",\"agent_type\":\"%s\",\"session_id\":\"%s\",\"rejoin\":true,\"ts\":\"%s\"}"
           nickname agent_type new_session_id (now_iso ()));
         (Atomic.get Coord_hooks.observe_agent_lifecycle_fn) config ~agent_id:nickname
           ~event_kind:"rejoin"
           ~details:
             (`Assoc
               [
                 ("agent_type", `String agent_type);
                 ("session_id", `String new_session_id);
                 ("rejoin", `Bool true);
               ]);
       end
     | Error e ->
         let snapshot =
           agent_parse_error_snapshot ~agent_name:nickname
             ~agent_file:agent_file_dedup
         in
         Log.Coord.warn
           "agent rejoin: invalid agent JSON for %s: %s | snapshot=%s"
           nickname e (Yojson.Safe.to_string snapshot));
    Printf.sprintf "✅ %s already in the namespace (last_seen updated)" nickname
  end else begin
    (* Collect metadata *)
  let session_id = generate_session_id () in
  let meta : agent_meta = {
    session_id;
    agent_type;
    pid;
    hostname = (match hostname with Some h -> Some h | None -> get_hostname ());
    tty = (match tty with Some t -> Some t | None -> get_tty ());
    worktree;
    parent_task;
  } in

  let agent_file = Filename.concat (agents_dir config) (safe_filename nickname ^ ".json") in
  let agent = {
    name = nickname;
    agent_type;
    status = Active;
    capabilities;
    current_task = None;
    joined_at = now_iso ();
    last_seen = now_iso ();
    meta = Some meta;
  } in
  let agent_json = agent_to_yojson agent in
  (* Write to filesystem — agent state is short-term coordination data. *)
  write_json config agent_file agent_json;

  (* Update state *)
  let _ = update_state config (fun s ->
    let agents = nickname :: (List.filter ((<>) nickname) s.active_agents) in
    { s with active_agents = agents }
  ) in

  (* Broadcast join *)
  let _ = broadcast config ~from_agent:nickname ~content:(Printf.sprintf "👋 %s joined the namespace" nickname) in

  (* Log event with metadata *)
  log_event config (Printf.sprintf
    "{\"type\":\"agent_join\",\"agent\":\"%s\",\"agent_type\":\"%s\",\"session_id\":\"%s\",\"capabilities\":%s,\"ts\":\"%s\"}"
    nickname
    agent_type
    session_id
    (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) capabilities)))
    (now_iso ()));
  (Atomic.get Coord_hooks.observe_agent_lifecycle_fn) config ~agent_id:nickname
    ~event_kind:"join"
    ~details:
      (`Assoc
        [
          ("agent_type", `String agent_type);
          ("session_id", `String session_id);
          ( "capabilities",
            `List (List.map (fun s -> `String s) capabilities) );
        ]);

  Printf.sprintf "✅ %s joined\n  Nickname: %s\n  Type: %s\n  Session: %s"
    nickname nickname agent_type session_id
  end

(* join_in_room removed — namespace concept retired (#unify-namespace).
   Use [join] directly. *)

(** Leave room *)
let leave config ~agent_name =
  ensure_initialized config;

  (* Support both exact nickname match and agent_type prefix match *)
  let actual_name = resolve_agent_name config agent_name in

  (* Stop any heartbeats owned by this agent *)
  let _stopped = Heartbeat.stop_by_agent ~agent_name:actual_name in

  let agent_file = Filename.concat (agents_dir config) (safe_filename actual_name ^ ".json") in
  let in_fs = Sys.file_exists agent_file in
  if in_fs then begin
    (* Mark agent as Inactive instead of deleting, so re-join can restore identity.
       This prevents orphan state when the same agent_type re-joins later. *)
    (match read_agent_with_repair config agent_file with
     | Ok existing_agent ->
       let updated = { existing_agent with status = Inactive; last_seen = now_iso () } in
       write_json config agent_file (agent_to_yojson updated)
     | Error e ->
         let snapshot =
           agent_parse_error_snapshot ~agent_name:actual_name ~agent_file
         in
         Log.Coord.warn
           "agent leave: invalid agent JSON for %s: %s | snapshot=%s"
           actual_name e (Yojson.Safe.to_string snapshot));

    (* Capture active agents before removal for relationship materialization *)
    let peers_before_leave = (read_state config).active_agents in

    let _ = update_state config (fun s ->
      { s with active_agents = List.filter ((<>) actual_name) s.active_agents }
    ) in

    let _ = broadcast config ~from_agent:"system" ~content:(Printf.sprintf "👋 %s left the namespace" actual_name) in

    (* Log event *)
    log_event config (Printf.sprintf
      "{\"type\":\"agent_leave\",\"agent\":\"%s\",\"ts\":\"%s\"}"
      actual_name (now_iso ()));
    (Atomic.get Coord_hooks.observe_agent_lifecycle_fn) config ~agent_id:actual_name
      ~event_kind:"leave"
      ~details:`Null;

    (* Record co-presence relationships via hook (async, non-blocking) *)
    (try (Atomic.get Coord_hooks.relation_on_leave_fn)
           ~leaving_agent:actual_name ~active_agents:peers_before_leave
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.Coord.error "relation-materializer leave hook error: %s"
         (Printexc.to_string exn));

    Printf.sprintf "✅ %s left the namespace" actual_name
  end else
    Printf.sprintf "⚠ %s was not in the namespace" actual_name
