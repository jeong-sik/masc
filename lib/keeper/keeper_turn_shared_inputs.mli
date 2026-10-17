(** Independent discovery inputs shared by direct and autonomous turns.
    Results retain each source's existing absence and unavailable states. *)
type t =
  { lane_updates : (Yojson.Safe.t, string) result
  ; workspace_memory : Workspace_memory_ledger.observation
  ; wiki_contents : Keeper_wiki_contents.t
  }

val observe :
  ?preview:Keeper_turn_preview.writer ->
  config:Workspace.config -> keeper_name:string -> unit -> t
(** Read each source once, concurrently on Eio fibers and sequentially outside
    Eio. Each read retains {!Domain_pool_ref.submit_io_or_inline}'s worker,
    non-Eio and absent-pool handling. Typed source failures remain data; an
    exception or cancellation propagates without retrying a read.

    A supplied writer observes the enclosing world-input preparation using
    its producer-supplied original turn reference. Logging and workspace
    gauges run once after the reads join, on the caller's fiber. This is not
    an atomic cross-store snapshot or permission cache. Pool submissions
    relay cancellation to their own invocation and join entered worker
    cleanup before returning cancellation; blocking IO or protected cleanup
    can therefore delay settlement. *)
