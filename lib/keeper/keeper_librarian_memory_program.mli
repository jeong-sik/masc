(** Bind a private, gated Runtime decision to exact processed source messages.
    This adapter has no storage effects and does not establish exhaustion or
    prove that the host's source manifest covers the whole original boundary. *)
val decision
  : sources:Keeper_librarian_unread.source list
  -> Keeper_librarian_runtime.memory_step
  -> (Keeper_memory_os_program.decision, string) result
(** Require exactly one matching source hash per actual input message, in
    input order. Reject malformed coordinates, missing messages, reordering or
    changed bytes. Preserve the original gated decision, working state and
    original rendered base prompt/variables (including host context);
    opaque evidence is data and grants no publication authority. An empty
    message/source list requires actual tool or counterpart observations in
    the original Runtime input; it accounts for no conversation message. *)

val create
  : transaction_id:string
  -> keeper_id:Keeper_identity.Keeper_id.t
  -> turn_ref:Ids.Turn_ref.t
  -> sources:Keeper_librarian_unread.source list
  -> unread:Keeper_librarian_unread.t list
  -> initial_current:Keeper_memory_os_types.fact list option
  -> steps:(Keeper_librarian_unread.source list * Keeper_librarian_runtime.memory_step) list
  -> (Keeper_memory_os_program.t, string) result
(** Bind every step to its actual messages, then validate the ordered program
    and its processed/unread partition against the frozen host manifest. *)
