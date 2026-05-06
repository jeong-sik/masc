(** Best-effort playground repository state cache. *)

val is_shallow_repo : string -> bool
(** Return true when [repo_path] is a shallow git repository.

    Probe failures return false. {!Eio.Cancel.Cancelled} is re-raised. *)

val update :
  playground_dir:string ->
  repo_name:string ->
  repo_path:string ->
  action:string ->
  shallow:bool ->
  unit
(** Upsert [repo_name] into [<playground_dir>/.playground_state.json]
    using live git metadata from [repo_path].

    Failures are logged at warn and otherwise ignored. {!Eio.Cancel.Cancelled}
    is re-raised. *)
