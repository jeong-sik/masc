(** Late-bound full-tool research adapter for the HITL Auto Judge.

    [Hitl_summary_worker] is upstream of the Keeper runtime and therefore owns
    only the neutral runner contract. This adapter lives beside the complete
    tool bundle and closes over the runtime capabilities required by that
    contract. *)

val make_runner :
  config:Workspace.config ->
  publication_recovery_provider:
    Keeper_publication_recovery_availability.provider ->
  Hitl_summary_worker.research_runner
