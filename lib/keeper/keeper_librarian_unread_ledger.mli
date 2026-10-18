(** Cumulative verified unread evidence, owned by the Memory aggregate lock.
    Callers must already hold that lock. This store grants no cursor advance. *)
val path : keepers_dir:string -> keeper_id:string -> string
val read : keepers_dir:string -> keeper_id:string -> (Keeper_librarian_unread.t list, string) result
(** Absence is an initial empty ledger. Existing malformed/unreadable bytes fail. *)
val archive : keepers_dir:string -> keeper_id:string -> Keeper_librarian_unread.t list ->
  (Keeper_librarian_unread.t list, string) result
(** Atomic, fsynced cumulative union. A merge conflict preserves the old file. *)
