(** Production completed-history Addon adapter. Call only inside the Keeper's
    serialized Memory lane and purge fence. Resume immutable retained work before
    invoking a fresh selector; never re-create or redispatch an unknown request. *)
val consume_one : config:Workspace.config -> keeper_name:string ->
  wake:(unit -> unit) ->
  (Keeper_librarian_durable_consumer.outcome,
   Keeper_librarian_durable_consumer.error) result
(** An unavailable attachment leaves the original source unread. Original
    completed local publication may still recover while the Addon is Off.
    [wake] schedules the same Memory lane after a newly observed Finished fact;
    scheduling acceptance does not prove a Memory effect or a drained queue. *)
