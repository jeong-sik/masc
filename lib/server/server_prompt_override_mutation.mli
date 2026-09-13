(** Persist an admitted HTTP override before notifying an existing curator.
    The notification only queues work; it does not run a provider. *)
type error = Validation of string | Persistence of string
type applied =
  { message : string
  ; curator_refresh : Server_workspace_memory_curator.refresh option
  }
val apply : base_path:string -> Server_prompt_override_request.t -> (applied, error) result
val refresh_json : Server_workspace_memory_curator.refresh option -> Yojson.Safe.t
