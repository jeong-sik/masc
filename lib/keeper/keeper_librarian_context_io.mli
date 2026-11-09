val capture : base_path:string -> keepers_dir:string -> keeper_name:string -> Keeper_librarian_context.input
(** Read-only event and outstanding-chat snapshots, without Owner mailbox
    calls or growing pagination. Invoke on an IO worker. Nothing is claimed
    or consumed. Source read failures are recorded in [input.unavailable].
    Queue sources and retained pockets are filtered through the server-bound
    Keeper's current Board readership before any raw payload reaches a model. *)
