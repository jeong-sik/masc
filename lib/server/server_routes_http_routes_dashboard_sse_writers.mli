(** Worktree-status SSE writer helpers. *)

val observe_worktree_status_sse_write :
  Httpun.Body.Writer.t -> string -> (unit, string) result

val observe_worktree_status_sse_write_all :
  Httpun.Body.Writer.t -> string list -> (unit, string) result

val observe_worktree_status_sse_close : Httpun.Body.Writer.t -> unit
