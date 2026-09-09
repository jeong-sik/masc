(** Rejection delivery obligations committed with the Task verdict. *)
val pending :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.pending_completion_rejection list, string) result

(** Acknowledges only the exact verification identity. A stale acknowledgement
    cannot retire a newer rejection for the same task. *)
val acknowledge :
  Workspace_utils_backend_setup.config ->
  task_id:string -> verification_id:string -> (unit, string) result
