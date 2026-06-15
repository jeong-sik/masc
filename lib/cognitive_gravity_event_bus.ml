(* Event Bus sourcing for Cognitive Gravity's Memory OS decay.

   Phase4: Bridges workspace activity (Board posts, Task transitions,
   Git events) to Cognitive_gravity.decay_trigger values for use in
   Memory OS stale-fact reconciliation via apply_decay. *)

(** [source_board ~limit ()] converts recent Board posts into
    [BoardPost] triggers. *)
let source_board ?(limit = 10) () =
  (* Stub: In production this calls into the Board runtime to fetch
     recent post IDs. The exact integration mechanism depends on the
     Board storage layer (tool_shard vs. MCP runtime). *)
  let _ = limit in
  []

(** [source_tasks ~since_ids ()] converts task status transitions into
    [TaskTransition] triggers. *)
let source_tasks ?(since_ids = []) () =
  let _ = since_ids in
  []

(** [source_git ~since_ref ()] converts recent git events into
    [GitEvent] triggers. *)
let source_git ?(since_ref = "HEAD~5") () =
  let _ = since_ref in
  []

(** [poll_all ()] collects triggers from all three sources. *)
let poll_all () =
  List.concat [ source_board (); source_tasks (); source_git () ]