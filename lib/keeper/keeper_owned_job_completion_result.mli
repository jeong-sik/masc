(** Integrity-read the complete original owner without backend effects. *)
type t
val read : base_path:string -> keeper_name:string ->
  Keeper_event_queue.owned_job_completion -> t
val check : t -> (unit, Keeper_owned_job_store.error) result
val to_json : t -> Yojson.Safe.t
