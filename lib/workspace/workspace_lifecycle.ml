(** Workspace Lifecycle - Agent session binding operations.

    Extracted from Workspace module. Handles agent entry, re-entry, and departure
    including nickname resolution, dedup, metadata, and relation materialization. *)

open Masc_domain
open Workspace_utils
open Workspace_state
open Workspace_identity
open Workspace_broadcast
open Workspace_identity

(* Single-namespace: workspace_id/namespace_id concepts retired (#unify-namespace).
   All workspace scoped by cluster basepath only. *)

(** Bounded snapshot of a corrupt agent JSON file for error diagnostics.
    Reads at most 200 bytes to avoid OOM on large/corrupt files. *)
let agent_parse_error_snapshot ~agent_name ~agent_file =
  let raw_head =
    Safe_ops.protect ~default:"" (fun () ->
      In_channel.with_open_text agent_file (fun ic ->
        let buf = Bytes.create 200 in
        let n = In_channel.input ic buf 0 200 in
        Bytes.sub_string buf 0 n))
  in
  `Assoc [
    ("agent_name", `String agent_name);
    ("agent_file", `String agent_file);
    ("raw_head",
      if raw_head = "" then `Null else `String raw_head);
  ]

(** Bind agent session - with auto-generated nickname and metadata *)
let bind_session config ~agent_name ?(agent_type_override=None) ~capabilities
    ?(pid=None) ?(hostname=None) ?(tty=None)
    ?(parent_task=None) ?(keeper_name=None) ?(keeper_id=None) () =
  ensure_initialized config;

  (* Determine whether [agent_name] is a stable nickname or an agent type. *)
  let agent_type = match agent_type_override with
    | Some t -> t
    | None ->
        (* Check if agent_name looks like a nickname (has dashes) *)
        if Nickname.is_generated_nickname agent_name then
          Option.value (Nickname.extract_agent_type agent_name) ~default:agent_name
        else
          agent_name  (* Legacy: agent_name is the type *)
  in

  (* Reuse existing nickname for same agent_type if already bound,
     otherwise generate a new one. This prevents identity drift when
     the same agent_name binds multiple times within a session. *)
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
               && String.starts_with f ~prefix)
          |> Option.map (fun f -> Filename.chop_suffix f ".json")
        else None
      in
      match existing with
      | Some nick -> nick  (* Reuse existing nickname for this agent_type *)
      | None -> Nickname.generate agent_type
    end
  in

  (* Dedup: if agent already has a session, update last_seen and return early *)
  let agent_file_dedup = Filename.concat (agents_dir config) (safe_filename nickname ^ ".json") in
  let already_bound = Sys.file_exists agent_file_dedup in
  if already_bound then begin
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
         parent_task;
         keeper_name;
         keeper_id;
       } in
       let updated = { existing_agent with
         status = Active;
         last_seen = now_iso ();
         capabilities;
         meta = Some new_meta;
       } in
       write_agent config agent_file_dedup updated;
       if is_inactive then begin
         (* Restore to active_agents on session rebound *)
         let _state = update_state config (fun s ->
           let agents = nickname :: List.filter ((<>) nickname) s.active_agents in
           { s with active_agents = agents }
         ) in
         let _ =
           broadcast config ~from_agent:nickname
             ~msg_type:"session_rebound"
             ~content:(Printf.sprintf "%s rebound the namespace session" nickname)
         in
         log_event config (`Assoc [
           ("type", `String "agent_session_bound");
           ("agent", `String nickname);
           ("agent_type", `String agent_type);
           ("session_id", `String new_session_id);
           ("session_rebound", `Bool true);
           ("ts", `String (now_iso ()));
         ]);
         (Atomic.get Workspace_hooks.observe_agent_lifecycle_fn) config ~agent_id:nickname
           ~event:Workspace_hooks.Session_rebound
           ~details:
             (`Assoc
               [
                 ("agent_type", `String agent_type);
                 ("session_id", `String new_session_id);
                 ("session_rebound", `Bool true);
               ]);
       end
     | Error e ->
         let snapshot =
           agent_parse_error_snapshot ~agent_name:nickname
             ~agent_file:agent_file_dedup
         in
         Log.Workspace.warn
           "agent session rebound: invalid agent JSON for %s: %s | snapshot=%s"
           nickname e (Yojson.Safe.to_string snapshot));
    Printf.sprintf "%s already bound in the namespace (last_seen updated)" nickname
  end else begin
    (* Collect metadata *)
  let session_id = generate_session_id () in
  let meta : agent_meta = {
    session_id;
    agent_type;
    pid;
    hostname = (match hostname with Some h -> Some h | None -> get_hostname ());
    tty = (match tty with Some t -> Some t | None -> get_tty ());
    parent_task;
    keeper_name;
    keeper_id;
  } in

  let agent_file = Filename.concat (agents_dir config) (safe_filename nickname ^ ".json") in
  let agent = {
    id = None;
    name = nickname;
    agent_type;
    status = Active;
    capabilities;
    current_task = None;
    session_bound_at = now_iso ();
    last_seen = now_iso ();
    meta = Some meta;
  } in
  (* Write to filesystem — agent state is short-term workspace data. *)
  write_agent config agent_file agent;

  (* Update state *)
  let _state = update_state config (fun s ->
    let agents = nickname :: (List.filter ((<>) nickname) s.active_agents) in
    { s with active_agents = agents }
  ) in

  (* Broadcast session binding *)
  let _ =
    broadcast config ~from_agent:nickname
      ~msg_type:"session_bound"
      ~content:(Printf.sprintf "%s bound the namespace session" nickname)
  in

  (* Log event with metadata *)
  log_event config (`Assoc [
    ("type", `String "agent_session_bound");
    ("agent", `String nickname);
    ("agent_type", `String agent_type);
    ("session_id", `String session_id);
    ("capabilities", `List (List.map (fun s -> `String s) capabilities));
    ("ts", `String (now_iso ()));
  ]);
  (Atomic.get Workspace_hooks.observe_agent_lifecycle_fn) config ~agent_id:nickname
    ~event:Workspace_hooks.Session_bound
    ~details:
      (`Assoc
        [
          ("agent_type", `String agent_type);
          ("session_id", `String session_id);
          ( "capabilities",
            `List (List.map (fun s -> `String s) capabilities) );
        ]);

  Printf.sprintf "%s session bound\n  Nickname: %s\n  Type: %s\n  Session: %s"
    nickname nickname agent_type session_id
  end

(** End agent session *)
let end_session ?(stop_heartbeats = true) config ~agent_name =
  ensure_initialized config;

  (* Support both exact nickname match and agent_type prefix match *)
  let actual_name = resolve_agent_name config agent_name in

  (* Stop any heartbeats owned by this agent *)
  let _stopped =
    if stop_heartbeats then Heartbeat.stop_by_agent ~agent_name:actual_name else 0
  in

  let agent_file = Filename.concat (agents_dir config) (safe_filename actual_name ^ ".json") in
  let in_fs = Sys.file_exists agent_file in
  if in_fs then begin
    (* Mark agent as Inactive instead of deleting, so a future session can restore
       identity without orphan state. *)
    (match read_agent_with_repair config agent_file with
     | Ok existing_agent ->
       let updated = { existing_agent with status = Inactive; last_seen = now_iso () } in
       write_agent config agent_file updated
     | Error e ->
         let snapshot =
           agent_parse_error_snapshot ~agent_name:actual_name ~agent_file
         in
         Log.Workspace.warn
           "agent session end: invalid agent JSON for %s: %s | snapshot=%s"
           actual_name e (Yojson.Safe.to_string snapshot));

    (* Capture active agents before removal for relationship materialization *)
    let state_snapshot = read_state_snapshot config in
    match state_snapshot.status with
    | State_default_from_read_error ->
      let msg = String.concat "; " state_snapshot.read_errors in
      Log.Workspace.error
        "agent session end skipped state update for %s: %s"
        actual_name
        msg;
      Printf.sprintf "%s session end failed: state read failed: %s" actual_name msg
    | State_authoritative | State_recovered_unpersisted ->
      let peers_before_leave = state_snapshot.state.active_agents in
      let _state = update_state config (fun s ->
        { s with active_agents = List.filter ((<>) actual_name) s.active_agents }
      ) in

      let _ =
        broadcast config ~from_agent:"system"
          ~msg_type:"session_ended"
          ~content:(Printf.sprintf "%s ended the namespace session" actual_name)
      in

      (* Log event *)
      log_event config (`Assoc [
        ("type", `String "agent_session_ended");
        ("agent", `String actual_name);
        ("ts", `String (now_iso ()));
      ]);
      (Atomic.get Workspace_hooks.observe_agent_lifecycle_fn) config ~agent_id:actual_name
        ~event:Workspace_hooks.Session_ended
        ~details:`Null;

      (* Record co-presence relationships via hook (async, non-blocking) *)
      (try (Atomic.get Workspace_hooks.relation_on_leave_fn)
             ~leaving_agent:actual_name ~active_agents:peers_before_leave
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.Workspace.error "relation-materializer session-end hook error: %s"
           (Printexc.to_string exn));

      Printf.sprintf "%s left the namespace" actual_name
  end else
    Printf.sprintf "%s was not in the namespace" actual_name
