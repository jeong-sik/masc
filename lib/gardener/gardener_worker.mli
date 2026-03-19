(** Gardener OAS worker — 1-shot agents with real MASC tools.

    Replaces the zombie-producing [Spawn_eio.spawn] path (which only gave
    workers heartbeat/session tools) and the [Observe_only] team-session
    path (which could not mutate state).

    Workers receive [gardener_worker_tool_names] (claim, transition, etc.)
    and terminate after completing their goal. *)

(** [run_for_gap ~topic ~traits_str ~reason] spawns a 1-shot OAS worker
    to address a detected ecosystem gap.  The worker will claim a pending
    task, work on it, and terminate. *)
val run_for_gap :
  topic:string ->
  traits_str:string ->
  reason:string ->
  (Oas_worker.run_result, string) result

(** [run_for_backlog ~backlog] spawns a 1-shot OAS worker for backlog
    triage.  The worker reviews unclaimed tasks, claims high-priority
    ones, and reports via broadcast + board. *)
val run_for_backlog :
  backlog:Gardener_types.task_backlog_summary ->
  (Oas_worker.run_result, string) result
