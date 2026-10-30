val capture : base_path:string -> keepers_dir:string -> keeper_name:string -> Keeper_librarian_context.input
(** Read-only event and outstanding-chat snapshots, without Owner mailbox
    calls or growing pagination. Invoke on an IO worker. Nothing is claimed
    or consumed; failures remain explicit in the model input. *)
val render : base_path:string -> keepers_dir:string -> keeper_name:string -> string option
(** Validate event and chat identities without awaiting Librarian or Owner. *)
