(** Owner-scoped resume authority, published only by the running bootstrap. *)
type error = Owner_not_ready | Workspace_mismatch | Configuration_unavailable
val install : sw:Eio.Switch.t -> base_path:string -> resume:(unit -> (bool, error) result) -> unit
val request : base_path:string -> (bool, error) result
(** [Ok authority_available] means conversational runtime is active; exact-output
    feature availability is reported separately. Caller must require CanAdmin. *)
val error_message : error -> string
