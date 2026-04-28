(** Coord_agent -- Agent status, capability registration, and discovery.

    Read/write operations on agent state: status listing, capability
    broadcasting, agent metadata updates, and capability-based search. *)

open Types
include Coord_utils
include Coord_state

let get_agents_status config =
  ensure_initialized config;

  let agents_path = agents_dir config in
  if not (Sys.file_exists agents_path) then
    `Assoc [("agents", `List []); ("count", `Int 0)]
  else begin
    let agents = ref [] in
    Sys.readdir agents_path |> Array.iter (fun name ->
        Coord_query.safe_yield ();
      if Filename.check_suffix name ".json" then begin
        let path = Filename.concat agents_path name in
        match read_agent_with_repair config path with
        | Ok agent ->
            let is_zombie = is_zombie_agent ~agent_name:agent.name agent.last_seen in
            let status = if is_zombie then "zombie" else agent_status_to_string agent.status in
            agents := `Assoc [
              ("name", `String agent.name);
              ("status", `String status);
              ("is_zombie", `Bool is_zombie);
              ("current_task", Json_util.string_opt_to_json agent.current_task);
              ("last_seen", `String agent.last_seen);
              ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
            ] :: !agents
        | Error msg ->
            Log.Misc.error "agent state read failed: %s" msg
      end
    );
    `Assoc [
      ("agents", `List (List.rev !agents));
      ("count", `Int (List.length !agents));
    ]
  end

(* ============================================ *)
(* Agent Discovery - Capability Broadcasting   *)
(* ============================================ *)

(** Register agent capabilities *)
let register_capabilities config ~agent_name ~capabilities =
  ensure_initialized config;

  (* Support both exact nickname and agent_type prefix match *)
  let actual_name = resolve_agent_name config agent_name in
  let agent_file = Filename.concat (agents_dir config) (safe_filename actual_name ^ ".json") in
  if Sys.file_exists agent_file then begin
    with_file_lock config agent_file (fun () ->
      match read_agent_with_repair config agent_file with
      | Ok agent ->
          let updated = { agent with capabilities; last_seen = now_iso () } in
          write_json config agent_file (agent_to_yojson updated);

          (* Log event *)
          log_event config (Yojson.Safe.from_string (Printf.sprintf
            "{\"type\":\"capabilities_registered\",\"agent\":\"%s\",\"capabilities\":%s,\"ts\":\"%s\"}"
            actual_name
            (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) capabilities)))
            (now_iso ())));

          Printf.sprintf "📡 %s capabilities: %s" actual_name (String.concat ", " capabilities)
      | Error _ ->
          Printf.sprintf "⚠ Invalid agent file for %s" actual_name
    )
  end else
    Printf.sprintf "⚠ Agent %s not found. Join first!" agent_name

(** Update agent metadata (status/capabilities).
    Since #4638 agent metadata always lives under the root agents_dir. *)
let update_agent_r config ~agent_name ?status ?capabilities () : string Types.masc_result =
  if not (is_initialized config) then Error Types.NotInitialized
  else match validate_agent_name_r agent_name with
    | Error e -> Error e
    | Ok _ ->
        let actual_name = resolve_agent_name config agent_name in
        let filename = safe_filename actual_name ^ ".json" in
        (* Since #4638 rooms are flattened; agents always in root agents_dir *)
        let agent_file = Filename.concat (agents_dir config) filename in
        if not (Sys.file_exists agent_file) then
          Error (Types.AgentNotFound actual_name)
        else
          let locked =
            with_file_lock_r config agent_file (fun () ->
              match read_agent_with_repair config agent_file with
              | Error _ -> Error (Types.InvalidJson "Invalid agent file")
              | Ok agent ->
                  let status_opt =
                    match status with
                    | None -> Ok None
                    | Some s ->
                        (match Types.agent_status_of_string_opt (String.lowercase_ascii s) with
                         | Some st -> Ok (Some st)
                         | None -> Error (Types.InvalidJson ("Unknown status: " ^ s)))
                  in
                  (match status_opt with
                   | Error e -> Error e
                   | Ok maybe_status ->
                       let invalid =
                         match agent.current_task, maybe_status with
                         | Some _, Some Types.Inactive ->
                             Some "Cannot set inactive while a task is assigned"
                         | None, Some Types.Busy ->
                             Some "Cannot set busy without an active task"
                         | _ -> None
                       in
                       (match invalid with
                        | Some msg -> Error (Types.TaskInvalidState msg)
                        | None ->
                            let updated_caps =
                              match capabilities with
                              | None -> agent.capabilities
                              | Some caps -> caps
                            in
                            let updated_status =
                              match maybe_status with
                              | None -> agent.status
                              | Some st -> st
                            in
                            let updated = {
                              agent with
                              status = updated_status;
                              capabilities = updated_caps;
                              last_seen = now_iso ();
                            } in
                            write_json config agent_file (agent_to_yojson updated);
                            log_event config (Yojson.Safe.from_string (Printf.sprintf
                              "{\"type\":\"agent_update\",\"agent\":\"%s\",\"status\":\"%s\",\"capabilities\":%s,\"ts\":\"%s\"}"
                              actual_name
                              (Types.agent_status_to_string updated_status)
                              (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) updated_caps)))
                              (now_iso ())));
                            Ok (Printf.sprintf "✅ %s updated" actual_name)
                       ))
            )
          in
          (match locked with
           | Ok (Ok msg) -> Ok msg
           | Ok (Error e) -> Error e
           | Error e -> Error e)

(** Find agents by capability *)
let find_agents_by_capability config ~capability =
  ensure_initialized config;

  let agents_path = agents_dir config in
  if not (Sys.file_exists agents_path) then
    `Assoc [("agents", `List []); ("count", `Int 0)]
  else begin
    let matching = ref [] in
    Sys.readdir agents_path |> Array.iter (fun name ->
        Coord_query.safe_yield ();
      if Filename.check_suffix name ".json" then begin
        let path = Filename.concat agents_path name in
        match read_agent_with_repair config path with
        | Ok agent when List.mem capability agent.capabilities && not (is_zombie_agent ~agent_name:agent.name agent.last_seen) ->
            matching := `Assoc [
              ("name", `String agent.name);
              ("status", `String (agent_status_to_string agent.status));
              ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
            ] :: !matching
        | Ok _ | Error _ -> ()
      end
    );
    `Assoc [
      ("capability", `String capability);
      ("agents", `List (List.rev !matching));
      ("count", `Int (List.length !matching));
    ]
  end
