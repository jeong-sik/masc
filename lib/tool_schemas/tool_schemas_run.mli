(** Tool_schemas_run — SSOT for the four run-tracking tool
    schemas.

    Surface order:
    - [masc_run_init]        — initialise [.masc/runs/<task_id>/]
      and start tracking; required [task_id], [agent_name].
    - [masc_run_plan]        — set / update execution plan;
      required [task_id], [plan].
    - [masc_run_get]         — retrieve the run record + plan for
      one run, creating an empty scaffold when missing; required
      [task_id].
    - [masc_run_list]        — list all runs with status; no
      required params.

    Concatenated by {!Keeper_tool_surfaces} into the
    process-wide tool surface; list length and per-tool [name]
    strings are part of the public contract because the agent
    SDK's tool-routing tables grep them at startup. *)

val schemas : Masc_domain.tool_schema list
(** The four run-tracking schemas in the surface order documented
    above. List length and [name] strings are pinned at the
    contract seam — a rename of [masc_run_get] to
    [masc_run_read] (or any other rebranding) must touch this
    file as part of an explicit migration so the agent
    SDK's routing tables stay in sync. *)
