val prune :
  cutoff_month:string -> cutoff_day:string -> Fs_compat.Retention_directory.t -> int
(** Remove regular day files strictly before the writer's canonical UTC
    calendar cutoff. Names use Dated_jsonl_layout, including completed
    rotation segments. Only held descriptor-relative operations are used. *)
