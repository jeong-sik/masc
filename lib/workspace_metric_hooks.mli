(** Otel_metric_store adapter for neutral Workspace metric hooks. *)

val is_admin_agent : base_path:string -> agent_name:string -> bool
(** [is_admin_agent ~base_path ~agent_name] is true for the bootstrap
    initial admin or a non-expired persisted credential with [Admin] role. *)

val install : unit -> unit
