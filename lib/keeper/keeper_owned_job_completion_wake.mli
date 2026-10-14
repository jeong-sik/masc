(** Recover the original job's complete result, then durably enqueue one typed
    notification before acknowledging its canonical owner. *)
type report =
  { inspected : int; waiting : int; delivered : int; retired : int
  ; failures : (string * Keeper_owned_job_store.error) list }

val reconcile : config:Workspace.config -> (report, Keeper_owned_job_store.error) result
(** Startup/maintenance entrypoint. Only pending discovery markers are read.
    No current task/channel, TTL, process registry or replacement job is used. *)
