(** Shared commit lock for the ordinary and source-bound current Memory OS
    snapshots.

    The snapshots remain separate current-only stores. Writers take this lock
    before their store-specific lock so each can observe the other store's
    exact rendered payload inside one aggregate budget transaction. Readers do
    not take it. Source revalidation is also exempt: it can only replace a fact
    with a strictly shorter invalidation rendering, so it never consumes a
    writer's reserved bytes. *)

val with_lock :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> (unit -> 'a)
  -> 'a
