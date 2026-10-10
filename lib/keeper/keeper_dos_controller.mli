(** Host lifecycle policy; controller state belongs to the attached worker. *)
val release_retired : config:Workspace.config -> keeper_name:string -> by:string -> (unit, string) result
(** Conditionally release [keeper_name] when its Keeper is removed permanently.
    Worker Board events are published after the call completes. No shared DOS
    installation or an unheld controller is a successful no-op; unreadable or
    unconfirmed worker state returns an error. *)
