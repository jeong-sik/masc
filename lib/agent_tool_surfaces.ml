(** Agent_tool_surfaces — lightweight internal tool surface definitions.

    This module stays dependency-light so spawned agents, local workers, and
    strict worker flows can share allowlists without pulling in the full public
    capability registry.
*)

open Types

let unique_preserve_order items =
  let rec loop seen rev_items = function
    | [] -> List.rev rev_items
    | x :: xs ->
        if List.mem x seen then
          loop seen rev_items xs
        else
          loop (x :: seen) (x :: rev_items) xs
  in
  loop [] [] items

let dedupe_schemas (schemas : Types.tool_schema list) =
  let seen = Hashtbl.create (List.length schemas) in
  List.filter
    (fun (schema : Types.tool_schema) ->
      if Hashtbl.mem seen schema.name then
        false
      else (
        Hashtbl.add seen schema.name ();
        true))
    schemas

let prefixed_tool_names names =
  names |> List.map (fun name -> "mcp__masc__" ^ name)

let spawned_agent_public_tool_names : string list =
  [
    "masc_status";
    "masc_tasks";
    "masc_claim_next";
    "masc_transition";
    "masc_task_history";
    "masc_broadcast";
    "masc_join";
    "masc_leave";
    "masc_who";
    "masc_agent_update";
    "masc_add_task";
    "masc_heartbeat";
    "masc_messages";
    "masc_worktree_create";
    "masc_worktree_remove";
    "masc_worktree_list";
    "masc_handover_create";
    "masc_handover_list";
    "masc_handover_claim";
    "masc_handover_get";
    "masc_memento_mori";
    "masc_relay_status";
    "masc_relay_checkpoint";
    "masc_board_list";
    "masc_board_post";
    "masc_board_comment";
    "masc_board_vote";
    "masc_board_get";
    "masc_tool_stats";
    "masc_tool_help";
    "masc_tool_admin_snapshot";
    "masc_keeper_tool_catalog";
    (* masc_tool_list, masc_tool_grant, masc_tool_revoke removed:
       no matching schema found (dead entries) *)
    "masc_portal_open";
    "masc_portal_send";
    "masc_portal_status";
    "masc_team_session_start";
    "masc_team_session_step";
    "masc_team_session_status";
    "masc_team_session_events";
    "masc_team_session_finalize";
    "masc_team_session_stop";
    "masc_team_session_report";
    "masc_team_session_prove";
    "masc_team_session_list";
    "masc_team_session_compare";
    "masc_operator_snapshot";
    "masc_operator_action";
    "masc_operator_confirm";
    "masc_a2a_delegate";
    "masc_a2a_subscribe";
    "masc_poll_events";
    (* masc_vote_create, masc_vote_cast, masc_vote_status removed:
       hidden in Tool_catalog (prefer decision/governance V2 tools) *)
    "masc_run_init";
    "masc_run_log";
    "masc_run_deliverable";
    "masc_run_get";
    "masc_spawn";
    "masc_heartbeat_list";
    (* masc_trpg_dice_roll, masc_trpg_turn_advance, masc_trpg_stream,
       masc_trpg_round_run removed: legacy aliases deprecated in
       Tool_protocol_game_view; use canonical trpg.* names instead *)
  ]

let spawned_agent_prefixed_tools : string list =
  prefixed_tool_names spawned_agent_public_tool_names

let llama_worker_tool_names : string list =
  [
    "masc_heartbeat";
    "masc_team_session_status";
    "masc_team_session_step";
    "masc_memento_mori";
  ]

let llama_worker_prefixed_tools : string list =
  prefixed_tool_names llama_worker_tool_names

let mdal_auditable_tool_names : string list =
  [
    "masc_code_search";
    "masc_code_symbols";
    "masc_code_read";
    "masc_worktree_create";
    "masc_worktree_list";
    "masc_worktree_remove";
    "masc_run_init";
    "masc_run_plan";
    "masc_run_log";
    "masc_run_deliverable";
    "masc_run_get";
    "masc_run_list";
    "masc_spawn";
  ]

let lodge_worker_base_tool_names ?(allow_post = false) ?(extra = []) () =
  let base =
    [
      "masc_board_get";
      "masc_board_list";
      "masc_board_search";
      "masc_board_comment";
      "masc_board_vote";
      "lodge_search";
      "lodge_profile";
      "lodge_research";
    ]
  in
  let names = if allow_post then "masc_board_post" :: base else base in
  unique_preserve_order (names @ extra)

let local_worker_public_tool_names : string list =
  unique_preserve_order
    ([
       "masc_board_get";
       "masc_board_list";
       "masc_board_search";
       "masc_board_comment";
       "masc_board_vote";
       "masc_board_post";
     ]
    @ mdal_auditable_tool_names)

let local_worker_internal_schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_heartbeat";
      description =
        "Update the worker heartbeat timestamp so long-running local tasks are not reaped as zombies.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
    {
      Types.name = "masc_team_session_status";
      description =
        "Get the current status and progress summary for a team session.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("session_id", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      Types.name = "masc_team_session_step";
      description =
        "Record a team orchestration turn and optionally execute broadcast or checkpoint action.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("turn_kind", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                  ("task_title", `Assoc [ ("type", `String "string") ]);
                  ("task_description", `Assoc [ ("type", `String "string") ]);
                  ("task_priority", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id"; `String "turn_kind" ]);
          ];
    };
    {
      Types.name = "masc_memento_mori";
      description =
        "Check context pressure and auto-handle prepare or handoff when thresholds are crossed.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("context_ratio", `Assoc [ ("type", `String "number") ]);
                  ("full_context", `Assoc [ ("type", `String "string") ]);
                  ("summary", `Assoc [ ("type", `String "string") ]);
                  ("current_task", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "context_ratio" ]);
          ];
    };
    {
      Types.name = "lodge_research";
      description = "Research a topic using LLM and share findings with the lodge.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("topic", `Assoc [ ("type", `String "string") ]);
                  ("agent_name", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "topic" ]);
          ];
    };
    {
      Types.name = "lodge_profile";
      description = "Get an agent profile with recent lodge activity and stats.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("agent_name", `Assoc [ ("type", `String "string") ]) ] );
            ("required", `List [ `String "agent_name" ]);
          ];
    };
    {
      Types.name = "lodge_search";
      description = "Search lodge content and agents by keyword.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("query", `Assoc [ ("type", `String "string") ]);
                  ("limit", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "query" ]);
          ];
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
        "Read file with offset/limit pagination.";
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
      description = "Create an isolated Git worktree for your work.";
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
      description = "Remove a worktree after your work is merged.";
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
      description = "List all active worktrees in the project.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
  ]

let local_worker_run_schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_run_init";
      description = "Initialize execution memory for a task.";
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
      description = "Add a timestamped note to task execution log.";
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
      description = "Get full execution history for a task.";
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
      description = "List all task runs with status.";
      input_schema =
        `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
    };
  ]

let local_worker_spawn_schemas : Types.tool_schema list =
  [
    {
      Types.name = "masc_spawn";
      description = "Spawn an agent to execute a task.";
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
                ] );
            ("required", `List [ `String "agent_name"; `String "prompt" ]);
          ];
    };
  ]

let select_public_local_worker_schemas () =
  let wanted = local_worker_public_tool_names in
  dedupe_schemas
    (Tool_board.tools
    @ local_worker_code_schemas
    @ local_worker_worktree_schemas
    @ local_worker_run_schemas
    @ local_worker_spawn_schemas)
  |> List.filter (fun (schema : Types.tool_schema) ->
         List.mem schema.name wanted)

let local_worker_tool_schemas ?names () :
    (Types.tool_schema list, string) result =
  let all_schemas =
    dedupe_schemas (local_worker_internal_schemas @ select_public_local_worker_schemas ())
  in
  match names with
  | None -> Ok all_schemas
  | Some values ->
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

(** Admin tool names that should be excluded from autonomous agents. *)
let admin_tool_names : string list =
  [
    "masc_tool_admin_snapshot";
    "masc_operator_snapshot";
    "masc_operator_action";
    "masc_operator_confirm";
    "masc_team_session_stop";
    "masc_team_session_finalize";
    "masc_gardener_execute_spawn";
    "masc_gardener_execute_retire";
    "masc_gardener_reset_circuit";
  ]

(** Coordination tool names for coordinators and fleet leaders. *)
let coordination_tool_names : string list =
  [
    "masc_status";
    "masc_tasks";
    "masc_add_task";
    "masc_broadcast";
    "masc_join";
    "masc_leave";
    "masc_who";
    "masc_heartbeat";
    "masc_messages";
    "masc_board_list";
    "masc_board_post";
    "masc_board_comment";
    "masc_board_vote";
    "masc_board_get";
    "masc_claim_next";
    "masc_transition";
    "masc_team_session_start";
    "masc_team_session_status";
    "masc_team_session_events";
    "masc_team_session_report";
    "masc_team_session_list";
    "masc_spawn";
    "masc_portal_open";
    "masc_portal_send";
    "masc_portal_status";
  ]

(** Execution tool names for worker agents. *)
let execution_tool_names : string list =
  [
    "masc_heartbeat";
    "masc_memento_mori";
    "masc_team_session_step";
    "masc_team_session_status";
    "masc_claim_next";
    "masc_transition";
    "masc_broadcast";
    "masc_code_search";
    "masc_code_symbols";
    "masc_code_read";
    "masc_run_init";
    "masc_run_log";
    "masc_run_deliverable";
    "masc_run_get";
    "masc_tool_help";
  ]

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
    | "worker" -> execution_tool_names
    | "coordinator" | "fleet_leader" -> coordination_tool_names
    | _ ->
        (* autonomous: all except admin *)
        List.filter
          (fun name -> not (List.mem name admin_tool_names))
          all_names
  in
  unique_preserve_order filtered
