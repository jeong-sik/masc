(** Gardener OAS worker — 1-shot agents with real MASC tools.

    Workers receive [gardener_worker_tool_names] (claim, transition, etc.)
    and terminate after completing their goal. *)

(** [run_for_gap ~config ~topic ~traits_str ~reason] spawns a 1-shot OAS
    worker to address a detected ecosystem gap.  The worker will claim a
    pending task, work on it, and terminate.

    [config] is the room configuration, required so the worker can dispatch
    tool calls through the tag-based registry with proper context. *)
val run_for_gap :
  config:Room.config ->
  topic:string ->
  traits_str:string ->
  reason:string ->
  (Oas_worker.run_result, string) result

(** [run_for_backlog ~config ~backlog] spawns a 1-shot OAS worker for
    backlog triage.  The worker reviews unclaimed tasks, claims high-priority
    ones, and reports via broadcast + board. *)
val run_for_backlog :
  config:Room.config ->
  backlog:Gardener_types.task_backlog_summary ->
  (Oas_worker.run_result, string) result
