(** Gardener OAS worker — 1-shot agents with real MASC tools.
    See {!gardener_worker.mli} for rationale. *)

(** Build [Llm_types.tool_def list] from [gardener_worker_tool_names].
    Returns an empty list on schema-lookup failure so the caller can
    still attempt an LLM call (the model will simply have no tools). *)
let worker_tools () : Llm_types.tool_def list =
  match
    Agent_tool_surfaces.local_worker_tool_schemas
      ~names:Agent_tool_surfaces.gardener_worker_tool_names ()
  with
  | Ok schemas ->
      List.map
        (fun (s : Types.tool_schema) ->
          {
            Llm_types.tool_name = s.name;
            tool_description = s.description;
            parameters = s.input_schema;
          })
        schemas
  | Error msg ->
      Eio.traceln "[Gardener_worker] tool schema lookup failed: %s" msg;
      []

(** Dispatch closure that routes tool calls through the global registry. *)
let make_dispatch () ~name ~args =
  match Tool_dispatch.dispatch ~name ~args with
  | Some result -> result
  | None -> (false, Printf.sprintf "Unknown tool: %s" name)

(** Wrap OAS worker calls so Eio exceptions (Mutex.Poisoned from LLM
    connection failure, etc.) become [Error] results instead of crashing. *)
let run_safe f =
  try f ()
  with exn ->
    Error (Printf.sprintf "OAS worker exception: %s" (Printexc.to_string exn))

let run_for_gap ~topic ~traits_str ~reason =
  run_safe (fun () ->
    Oas_worker.run_named_with_masc_tools
      ~cascade_name:"gardener_spawn"
      ~system_prompt:
        (Printf.sprintf
           "You are a MASC Gardener worker. Address: %s\n\
            Traits: %s\n\
            1. masc_status -> room state\n\
            2. masc_tasks -> find unclaimed work\n\
            3. masc_claim_next -> claim a task\n\
            4. Work on the claimed task\n\
            5. masc_transition -> mark done\n\
            6. masc_broadcast -> report results\n\
            Terminate after completion. Do not loop."
           topic traits_str)
      ~goal:(Printf.sprintf "Address gap '%s': %s" topic reason)
      ~masc_tools:(worker_tools ())
      ~dispatch:(make_dispatch ())
      ~max_turns:10 ~temperature:0.3 ())

let run_for_backlog ~(backlog : Gardener_types.task_backlog_summary) =
  run_safe (fun () ->
    Oas_worker.run_named_with_masc_tools
      ~cascade_name:"gardener_spawn"
      ~system_prompt:
        "You are a MASC triage worker.\n\
         1. masc_tasks -> review backlog\n\
         2. masc_claim_next -> claim high-priority task\n\
         3. Process or delegate\n\
         4. masc_transition -> update status\n\
         5. masc_broadcast -> report results\n\
         Terminate after completion."
      ~goal:
        (Printf.sprintf
           "Triage backlog: %d unclaimed (%d high-pri, %d orphan)."
           backlog.todo_count backlog.high_priority_todo backlog.orphan_count)
      ~masc_tools:(worker_tools ())
      ~dispatch:(make_dispatch ())
      ~max_turns:15 ~temperature:0.3 ())
