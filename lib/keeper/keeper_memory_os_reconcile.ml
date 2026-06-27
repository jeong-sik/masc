(** Keeper_memory_os_reconcile — placeholder degrade path.

    The full reconcile pass is not implemented in this worktree. The
    server bootstrap maintenance fiber references this module through
    the public [reconcile_keeper] function; when the module is only a
    stub it logs a warning and returns so the fiber can proceed without
    breaking the build or crashing the maintenance loop. *)

let reconcile_keeper ~keeper_id () =
  Log.Server.warn "memory_os_reconcile: module not available; skipping keeper=%s" keeper_id
;;