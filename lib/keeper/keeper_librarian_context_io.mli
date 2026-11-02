val capture : base_path:string -> keepers_dir:string -> keeper_name:string -> Keeper_librarian_context.input
(** Read-only event and outstanding-chat snapshots, without Owner mailbox
    calls or growing pagination. Invoke on an IO worker. Nothing is claimed
    or consumed. Source read failures are recorded in [input.unavailable]. *)
val render : base_path:string -> keepers_dir:string -> keeper_name:string -> (string option, string) result
(** Validate event and chat identities without awaiting Librarian or Owner.
    Source read failures in [input.unavailable] are logged and can still return
    [Ok] context. Managed-guidance failures and unexpected capture/render
    exceptions return [Error]; cancellation is re-raised. *)
