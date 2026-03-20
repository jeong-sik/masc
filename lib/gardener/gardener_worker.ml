(** Gardener OAS worker — 1-shot agents with real MASC tools.
    See {!gardener_worker.mli} for rationale. *)

(** Build [Types.tool_schema list] from [gardener_worker_tool_names].
    Returns an empty list on schema-lookup failure so the caller can
    still attempt an LLM call (the model will simply have no tools). *)
let worker_tools () : Types.tool_schema list =
  match
    Agent_tool_surfaces.local_worker_tool_schemas
      ~names:Agent_tool_surfaces.gardener_worker_tool_names ()
  with
  | Ok schemas -> schemas
  | Error msg ->
      Eio.traceln "[Gardener_worker] tool schema lookup failed: %s" msg;
      []

(** Dispatch closure that routes tool calls through the tag-based registry.

    The old [Tool_dispatch.dispatch] path uses a handler Hashtbl that is never
    populated — all real handlers live behind [Tool_dispatch.lookup_tag] and
    module-specific dispatch functions.  This closure mirrors the lightweight
    subset of [execute_tool_eio]'s tag dispatch for the tools a Gardener
    worker actually needs. *)
let make_dispatch ~(config : Room.config) ~(agent_name : string) () ~name ~args =
  match Tool_dispatch.lookup_tag name with
  | Some Tool_dispatch.Mod_task ->
      (match Tool_task.dispatch { Tool_task.config; agent_name } ~name ~args with
       | Some result -> result
       | None -> (false, Printf.sprintf "Unknown task tool: %s" name))
  | Some Tool_dispatch.Mod_room ->
      (match Tool_room.dispatch { Tool_room.config; agent_name } ~name ~args with
       | Some result -> result
       | None -> (false, Printf.sprintf "Unknown room tool: %s" name))
  | Some Tool_dispatch.Mod_heartbeat ->
      (* Heartbeat requires sw/clock — skip in worker context, return success *)
      (true, Printf.sprintf "Heartbeat skipped (in-process worker): %s" agent_name)
  | Some _ ->
      (* Tool exists in tag registry but not in the worker's supported set *)
      (false, Printf.sprintf "Tool %s is not available in worker context" name)
  | None ->
      (false, Printf.sprintf "Unknown tool: %s" name)

(* Exception handling moved to Oas_worker.run internally — no run_safe needed. *)

let run_for_gap ~(config : Room.config) ~topic ~traits_str ~reason =
  let agent_name = Printf.sprintf "gardener-worker-%s" topic in
  let institution_context = Institution_eio.load_and_format_for_welcome ~fs:() config in
  let memory = Memory_oas_bridge.create_memory ~agent_name in
  ignore (Memory_oas_bridge.seed_institution ~memory ~config);
  Oas_worker.run_named_with_masc_tools
    ~cascade_name:"gardener_spawn"
    ~system_prompt:
      (Printf.sprintf
         "You are a MASC Gardener worker. Your agent_name is '%s'.\n\
          Topic: %s\n\
          Traits: %s\n\
          Always include agent_name='%s' in every tool call arguments.\n\
          1. masc_status -> room state\n\
          2. masc_tasks -> find unclaimed work\n\
          3. masc_claim_next -> claim a task\n\
          4. Work on the claimed task\n\
          5. masc_transition(task_id=..., action='done') -> mark done\n\
          6. masc_broadcast -> report results\n\
          Terminate after completion. Do not loop.\n\
          %s"
         agent_name topic traits_str agent_name institution_context)
    ~goal:(Printf.sprintf "Address gap '%s': %s" topic reason)
    ~masc_tools:(worker_tools ())
    ~dispatch:(make_dispatch ~config ~agent_name ())
    ~memory
    ~max_turns:10 ~temperature:0.3 ()

let run_for_backlog ~(config : Room.config) ~(backlog : Gardener_types.task_backlog_summary) =
  let agent_name = "gardener-triage-worker" in
  let institution_context = Institution_eio.load_and_format_for_welcome ~fs:() config in
  let memory = Memory_oas_bridge.create_memory ~agent_name in
  ignore (Memory_oas_bridge.seed_institution ~memory ~config);
  Oas_worker.run_named_with_masc_tools
    ~cascade_name:"gardener_spawn"
    ~system_prompt:
      (Printf.sprintf
         "You are a MASC triage worker. Your agent_name is '%s'.\n\
          Always include agent_name='%s' in every tool call arguments.\n\
          1. masc_tasks -> review backlog\n\
          2. masc_claim_next -> claim high-priority task\n\
          3. Process or delegate\n\
          4. masc_transition -> update status\n\
          5. masc_broadcast -> report results\n\
          Terminate after completion.\n\
          %s"
         agent_name agent_name institution_context)
    ~goal:
      (Printf.sprintf
         "Triage backlog: %d unclaimed (%d high-pri, %d orphan)."
         backlog.todo_count backlog.high_priority_todo backlog.orphan_count)
    ~masc_tools:(worker_tools ())
    ~dispatch:(make_dispatch ~config ~agent_name ())
    ~memory
    ~max_turns:15 ~temperature:0.3 ()
