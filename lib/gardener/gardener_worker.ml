(** Gardener OAS worker — 1-shot agents with real MASC tools.
    See {!gardener_worker.mli} for rationale. *)

(** Build [Types.tool_schema list] from [gardener_worker_tool_names].
    Fail fast if the worker contract cannot be materialized. *)
let worker_tools () : (Types.tool_schema list, string) result =
  Agent_tool_surfaces.gardener_worker_tool_schemas ()
  |> Result.map_error (fun msg ->
         Printf.sprintf "Gardener worker tool schema lookup failed: %s" msg)

(** Dispatch closure that routes tool calls through the tag-based registry.

    The old [Tool_dispatch.dispatch] path uses a handler Hashtbl that is never
    populated — all real handlers live behind [Tool_dispatch.lookup_tag] and
    module-specific dispatch functions.  This closure mirrors the lightweight
    subset of [execute_tool_eio]'s tag dispatch for the tools a Gardener
    worker actually needs. *)
let make_dispatch ~(config : Room.config) ~(agent_name : string) () ~name ~args =
  match
    Agent_swarm_contract.resolve_requested_tool_call
      ~agent_name ~requested_name:name ~arguments:args
  with
  | Error msg -> (false, msg)
  | Ok (resolved_name, resolved_args) -> (
      match resolved_name with
      | "masc_broadcast" ->
          let message = Tool_args.get_string resolved_args "message" "" in
          let trimmed = String.trim message in
          if trimmed = "" then
            (false, "Broadcast message cannot be empty")
          else
            (true, Room.broadcast config ~from_agent:agent_name ~content:message)
      | _ -> (
          match Tool_dispatch.lookup_tag resolved_name with
          | Some Tool_dispatch.Mod_task ->
              (match
                 Tool_task.dispatch { Tool_task.config; agent_name }
                   ~name:resolved_name ~args:resolved_args
               with
               | Some result -> result
               | None ->
                   (false, Printf.sprintf "Unknown task tool: %s" resolved_name))
          | Some Tool_dispatch.Mod_room ->
              (match
                 Tool_room.dispatch { Tool_room.config; agent_name }
                   ~name:resolved_name ~args:resolved_args
               with
               | Some result -> result
               | None ->
                   (false, Printf.sprintf "Unknown room tool: %s" resolved_name))
          | Some Tool_dispatch.Mod_plan ->
              (match
                 Tool_plan.dispatch { Tool_plan.config }
                   ~name:resolved_name ~args:resolved_args
               with
               | Some result -> result
               | None ->
                   (false, Printf.sprintf "Unknown plan tool: %s" resolved_name))
          | Some Tool_dispatch.Mod_heartbeat ->
              (* Heartbeat requires sw/clock — skip in worker context, return success *)
              (true, Printf.sprintf "Heartbeat skipped (in-process worker): %s" agent_name)
          | Some _ ->
              (* Tool exists in tag registry but not in the worker's supported set *)
              (false, Printf.sprintf "Tool %s is not available in worker context" resolved_name)
          | None -> (false, Printf.sprintf "Unknown tool: %s" resolved_name)))

(* Exception handling moved to Oas_worker.run internally — no run_safe needed. *)

let run_for_gap ~(config : Room.config) ~topic ~traits_str ~reason =
  let agent_name = Printf.sprintf "gardener-worker-%s" topic in
  let institution_context = Institution_eio.load_and_format_for_welcome ~fs:() config in
  let memory = Memory_oas_bridge.create_memory ~agent_name in
  ignore (Memory_oas_bridge.seed_institution ~memory ~config);
  ignore (Memory_oas_bridge.seed_procedures ~memory ~agent_name:"_global" ~limit:5);
  match worker_tools () with
  | Error _ as error -> error
  | Ok masc_tools ->
      Oas_worker.run_named_with_masc_tools
        ~cascade_name:"gardener_spawn"
        ~system_prompt:
          (Printf.sprintf
             "You are a MASC Gardener worker. Your agent_name is '%s'.\n\
              Topic: %s\n\
              Traits: %s\n\
              Follow each tool schema exactly. SDK tools inject agent_name automatically.\n\
              1. masc_room_status -> room state\n\
              2. masc_list_tasks -> find unclaimed work\n\
              3. masc_claim_next -> claim a task\n\
              4. masc_set_current_task(task_id=...) -> bind current task\n\
              5. Work on the claimed task\n\
              6. masc_complete_task(task_id=...) -> mark done\n\
              7. masc_broadcast(message=...) -> report results\n\
              Terminate after completion. Do not loop.\n\
              %s"
             agent_name topic traits_str institution_context)
        ~goal:(Printf.sprintf "Address gap '%s': %s" topic reason)
        ~masc_tools
        ~dispatch:(make_dispatch ~config ~agent_name ())
        ~memory
        ~max_turns:10 ~temperature:0.3 ()

let run_for_backlog ~(config : Room.config) ~(backlog : Gardener_types.task_backlog_summary) =
  let agent_name = "gardener-triage-worker" in
  let institution_context = Institution_eio.load_and_format_for_welcome ~fs:() config in
  let memory = Memory_oas_bridge.create_memory ~agent_name in
  ignore (Memory_oas_bridge.seed_institution ~memory ~config);
  ignore (Memory_oas_bridge.seed_procedures ~memory ~agent_name:"_global" ~limit:5);
  match worker_tools () with
  | Error _ as error -> error
  | Ok masc_tools ->
      Oas_worker.run_named_with_masc_tools
        ~cascade_name:"gardener_spawn"
        ~system_prompt:
          (Printf.sprintf
             "You are a MASC triage worker. Your agent_name is '%s'.\n\
              Follow each tool schema exactly. SDK tools inject agent_name automatically.\n\
              1. masc_list_tasks -> review backlog\n\
              2. masc_claim_next -> claim high-priority task\n\
              3. masc_set_current_task(task_id=...) -> bind current task\n\
              4. Process or delegate\n\
              5. masc_complete_task(task_id=...) -> update status when work is done\n\
              6. masc_broadcast(message=...) -> report results\n\
              Terminate after completion.\n\
              %s"
             agent_name institution_context)
        ~goal:
          (Printf.sprintf
             "Triage backlog: %d unclaimed (%d high-pri, %d orphan)."
             backlog.todo_count backlog.high_priority_todo backlog.orphan_count)
        ~masc_tools
        ~dispatch:(make_dispatch ~config ~agent_name ())
        ~memory
        ~max_turns:15 ~temperature:0.3 ()
