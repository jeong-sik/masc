(** Agent_tool_surfaces — lightweight internal tool surface definitions.

    This module stays dependency-light so spawned agents, local workers, and
    strict worker flows can share allowlists without pulling in the full public
    capability registry.
*)

open Types

module SS = Set.Make (String)

let unique_preserve_order = Json_util.dedupe_keep_order

let dedupe_schemas (schemas : Types.tool_schema list) =
  let seen = ref SS.empty in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if SS.mem schema.name !seen then
        false
      else (
        seen := SS.add schema.name !seen;
        true))
    schemas

let prefixed_tool_names names =
  names |> List.map (fun name -> "mcp__masc__" ^ name)

let lookup_schemas_by_name_exn ~label all_schemas values =
  let requested =
    values
    |> List.map String.trim
    |> List.filter (fun value -> value <> "")
    |> unique_preserve_order
  in
  let by_name = Hashtbl.create (List.length all_schemas) in
  List.iter
    (fun (schema : Types.tool_schema) ->
      if not (Hashtbl.mem by_name schema.name) then
        Hashtbl.add by_name schema.name schema)
    all_schemas;
  let missing =
    requested
    |> List.filter (fun tool_name -> not (Hashtbl.mem by_name tool_name))
  in
  if missing <> [] then
    invalid_arg
      (Printf.sprintf "%s: unknown tool schema(s): %s" label
         (String.concat ", " missing));
  (* Guard above ensures all names exist — use List.map to preserve _exn contract *)
  requested |> List.map (Hashtbl.find by_name)

let spawned_agent_public_tool_names : string list =
  Tool_catalog.tools_for_surface Tool_catalog.Spawned_agent

let spawned_agent_prefixed_tools : string list =
  prefixed_tool_names spawned_agent_public_tool_names

let local_worker_public_tool_names : string list =
  Tool_catalog.tools_for_surface Tool_catalog.Local_worker

let local_worker_contract_schemas : Types.tool_schema list =
  Sdk_tool_contract.sdk_tool_schemas

let local_worker_compat_passthrough_tool_names =
  [
    "masc_status";
    "masc_tasks";
    "masc_claim_next";
    "masc_transition";
    "masc_add_task";
    "masc_broadcast";
  ]

let local_worker_compat_passthrough_schemas : Types.tool_schema list =
  lookup_schemas_by_name_exn
    ~label:"agent_tool_surfaces.local_worker_compat_passthrough_schemas"
    (Tool_schemas_coord_core.schemas
     @ Tool_task_schemas.schemas
     @ Tool_schemas_inline_coord.schemas)
    local_worker_compat_passthrough_tool_names

let local_worker_internal_schemas : Types.tool_schema list =
  [
    { Types.name = "masc_heartbeat";
      description =
        "Update the worker heartbeat timestamp so long-running local tasks are not reaped as zombies.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
  ]

let local_worker_code_schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_code_search";
      description =
        "Search code using ripgrep with regex support. Returns structured results with file path, line number, and matched content.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("query", `Assoc [ ("type", `String "string") ]);
                  ("path", `Assoc [ ("type", `String "string") ]);
                  ("file_pattern", `Assoc [ ("type", `String "string") ]);
                  ("case_insensitive", `Assoc [ ("type", `String "boolean") ]);
                  ("max_results", `Assoc [ ("type", `String "number") ]);
                ] );
            ("required", `List [ `String "query" ]);
          ];
    };
    {
      Types.name = "masc_code_symbols";
      description =
        "Extract symbols (functions, types, classes) from a file using heuristics.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("path", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "path" ]);
          ];
    };
    {
      Types.name = "masc_code_read";
      description =
        "Read a file with offset/limit pagination for large files. Use when inspecting source code during task execution without loading the entire file into context.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("path", `Assoc [ ("type", `String "string") ]);
                  ("offset", `Assoc [ ("type", `String "number") ]);
                  ("limit", `Assoc [ ("type", `String "number") ]);
                ] );
            ("required", `List [ `String "path" ]);
          ];
    };
  ]

let local_worker_worktree_schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_worktree_create";
      description = "Create an isolated Git worktree under .worktrees/{agent}-{task}/ with a new branch. Use when starting a task that modifies files, so other agents' work is not affected.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("agent_name", `Assoc [ ("type", `String "string") ]);
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("base_branch", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "agent_name"; `String "task_id" ]);
          ];
    };
    {
      Types.name = "masc_worktree_remove";
      description = "Remove a worktree and its local branch after your work is merged. Use when your PR has been merged and the isolated worktree is no longer needed.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("agent_name", `Assoc [ ("type", `String "string") ]);
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "agent_name"; `String "task_id" ]);
          ];
    };
    {
      Types.name = "masc_worktree_list";
      description = "List all active worktrees in the project with agent and task mappings. Use when checking for stale worktrees or seeing who is working in parallel.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
  ]

let local_worker_run_schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_run_init";
      description = "Initialize execution memory (.masc/runs/{task_id}/) to track plan, logs, and deliverables. Use after claiming a task to enable structured progress tracking.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("agent_name", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "agent_name" ]);
          ];
    };
    {
      Types.name = "masc_run_plan";
      description = "Set or update the execution plan for a task run.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("plan", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "plan" ]);
          ];
    };
    {
      Types.name = "masc_run_log";
      description = "Append a timestamped note to a task's execution log for audit and handoff continuity. Use when reaching milestones, finding blockers, or making key decisions during execution.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("note", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "note" ]);
          ];
    };
    {
      Types.name = "masc_run_deliverable";
      description = "Record the final deliverable/output of a task run.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("task_id", `Assoc [ ("type", `String "string") ]);
                  ("deliverable", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "task_id"; `String "deliverable" ]);
          ];
    };
    {
      Types.name = "masc_run_get";
      description = "Retrieve the full execution history for a task including plan revisions, log notes, and deliverables. Use when reviewing progress before handoff or for post-mortem analysis.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("task_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "task_id" ]);
          ];
    };
    {
      Types.name = "masc_run_list";
      description = "List all task runs with their current status (init, active, completed). Use when surveying execution state across tasks or finding abandoned runs to resume.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
  ]

let local_worker_spawn_schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_spawn";
      description = "Spawn a new agent to execute a specific task with configurable model, prompt, and execution scope. Use when work decomposition requires parallel execution by a dedicated worker.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("agent_name", `Assoc [ ("type", `String "string") ]);
                  ("model", `Assoc [ ("type", `String "string") ]);
                  ("prompt", `Assoc [ ("type", `String "string") ]);
                  ("timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                  ("working_dir", `Assoc [ ("type", `String "string") ]);
                  ( "execution_scope",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "observe_only";
                              `String "limited_code_change";
                              `String "autonomous";
                            ] );
                        ( "description",
                          `String
                            "Execution scope for the spawned agent. \
                             Determines tool surface and prompt composition." );
                      ] );
                ] );
            ("required", `List [ `String "agent_name"; `String "prompt" ]);
          ];
    };
  ]

let select_public_local_worker_schemas () =
  let wanted = local_worker_public_tool_names in
  dedupe_schemas
    (Tool_board.tools
    @ Tool_schemas_coord_extra.schemas
    @ local_worker_code_schemas
    @ local_worker_worktree_schemas
    @ local_worker_run_schemas
    @ local_worker_spawn_schemas)
  |> List.filter (fun (schema : Types.tool_schema) ->
         List.mem schema.name wanted)

let resolve_named_schemas all_schemas values :
    (Types.tool_schema list, string) result =
  let requested =
    values
    |> List.map String.trim
    |> List.filter (fun value -> value <> "")
    |> unique_preserve_order
  in
  let schemas =
    all_schemas
    |> List.filter (fun (schema : Types.tool_schema) ->
           List.mem schema.name requested)
  in
  let missing =
    requested
    |> List.filter (fun tool_name ->
           not
             (List.exists
                (fun (schema : Types.tool_schema) ->
                  String.equal schema.name tool_name)
                schemas))
  in
  if missing <> [] then
    Error
      (Printf.sprintf "unknown tool schema(s): %s"
         (String.concat ", " missing))
  else
    Ok schemas

let local_worker_tool_schemas ?names () :
    (Types.tool_schema list, string) result =
  let all_schemas =
    dedupe_schemas
      ( local_worker_internal_schemas
      @ local_worker_compat_passthrough_schemas
      @ local_worker_contract_schemas
      @ select_public_local_worker_schemas () )
  in
  match names with
  | None -> Ok all_schemas
  | Some values -> resolve_named_schemas all_schemas values

(** Admin tool names that should be excluded from autonomous agents.
    SSOT: Tool_catalog.Admin surface. *)
let admin_tool_names : string list =
  Tool_catalog.tools_for_surface Tool_catalog.Admin

(** Role-catalog candidates for coordinators and fleet leaders.
    SSOT: Tool_catalog_surfaces.coordination_role_tools.
    [build_tool_catalog] filters against surfaced tool names so stale
    entries cannot escape into prompts. *)
let coordination_tool_names : string list =
  Tool_catalog_surfaces.coordination_role_tools

(** Role-catalog candidates for worker agents.
    SSOT: Tool_catalog_surfaces.execution_role_tools. *)
let execution_tool_names : string list =
  Tool_catalog_surfaces.execution_role_tools

let filter_catalog_to_available ~available names =
  let available = SS.of_list available in
  names
  |> List.filter (fun name -> SS.mem name available)
  |> unique_preserve_order

(** Build a role-based tool catalog from the full registered tool set.
    [role] determines which subset of tools the agent sees:
    - ["worker"]: execution-focused tools
    - ["coordinator"]: coordination and orchestration tools
    - [_]: all non-admin tools (autonomous default)
    Returns tool names (unprefixed). *)
let build_tool_catalog ~(role : string) () : string list =
  let all_names =
    spawned_agent_public_tool_names @ local_worker_public_tool_names
    |> unique_preserve_order
  in
  let filtered =
    match role with
    | "worker" ->
        filter_catalog_to_available ~available:all_names execution_tool_names
    | "coordinator" | "fleet_leader" ->
        filter_catalog_to_available ~available:all_names coordination_tool_names
    | _ ->
        (* autonomous: all except admin *)
        List.filter
          (fun name -> not (List.mem name admin_tool_names))
          all_names
  in
  unique_preserve_order filtered

(** [local_worker_resolvable_tool_names ()] returns only the tool names
    that [local_worker_tool_schemas] can actually resolve.  Use this to
    intersect with [build_tool_catalog] output before passing to
    [run_worker], so that the autonomous catalog does not include names
    unknown to the local worker schema registry. *)
let local_worker_resolvable_tool_names () : string list =
  match local_worker_tool_schemas () with
  | Ok schemas ->
      List.map (fun (s : Types.tool_schema) -> s.name) schemas
  | Error msg ->
      Eio.traceln
        "[AgentToolSurfaces] local_worker_tool_schemas failed: %s"
        msg;
      []
