(** Tool_schemas_run — SSOT for the six run-tracking tool
    schemas.

    Surface order:
    - [masc_run_init]        — initialise [.masc/runs/<task_id>/]
      and start tracking; required [task_id], [agent_name].
    - [masc_run_plan]        — set / update execution plan;
      required [task_id], [plan].
    - [masc_run_log]         — append a timestamped note to the
      run's audit log; required [task_id], [note].
    - [masc_run_deliverable] — record the final output;
      required [task_id], [deliverable].
    - [masc_run_get]         — retrieve plan + logs +
      deliverables for one run; required [task_id].
    - [masc_run_list]        — list all runs with status; no
      required params.

    Concatenated by {!Agent_tool_surfaces} into the
    process-wide tool surface; list length and per-tool [name]
    strings are part of the public contract because the agent
    SDK's tool-routing tables grep them at startup. *)

val schemas : Masc_domain.tool_schema list
(** The six run-tracking schemas in the surface order documented
    above. List length and [name] strings are pinned at the
    contract seam — a rename of [masc_run_log] to
    [masc_run_note] (or any other rebranding) must touch this
    file as part of an explicit migration so the agent
    SDK's routing tables stay in sync. *)
