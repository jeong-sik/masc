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
    Agent Core tool-routing tables grep them at startup. *)

type operation =
  | Run_init
  | Run_plan
  | Run_get
  | Run_list
[@@deriving enumerate]
(** Closed vocabulary routed by [Tool_run.dispatch], in the surface order
    documented above. *)

val operations : operation list
(** Exhaustive stable-order projection of the run operations. *)

val schema : operation -> Masc_domain.tool_schema
(** Declaration for a run operation. *)

val operation_of_tool_name : string -> operation option
(** Parse a canonical run wire name at the dispatch boundary. *)

val schemas : Masc_domain.tool_schema list
(** The four run-tracking schemas in the surface order documented
    above. List length and [name] strings are pinned at the
    contract seam — a rename of [masc_run_get] to
    [masc_run_read] (or any other rebranding) must touch this
    file as part of an explicit migration so the agent
    Agent Core routing tables stay in sync. *)
