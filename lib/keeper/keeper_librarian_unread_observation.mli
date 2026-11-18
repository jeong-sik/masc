(** A scalar atom count bound to the exact inputs used by the unread-count
    selector. Boundary keys keep only row numbers, trace, restart/start and
    endpoint variants. They never keep task context, message bodies, parse
    error text, a checkpoint or a closure over those values.

    Every caller still reads metadata, boundaries and both cursors afresh.
    This is observation evidence only, never selection or commit authority. *)

type key
type t

val key :
  keeper_dir:string -> session_dir:string ->
  keeper_id:Keeper_identity.Keeper_id.t -> keeper_uid:Keeper_id.Uid.t option ->
  created_at:string -> trace_id:string ->
  lines:(int * (Keeper_turn_boundaries.record, Keeper_turn_boundaries.read_error) result) list ->
  progress:Keeper_librarian_progress.t option ->
  official_cursor:Keeper_librarian_official_progress.t option -> key

val remember :
  key -> atoms:int -> witness:Keeper_checkpoint_store.Read_observation.t -> t

val reuse : key -> t -> (int * t) option
(** [Some (atoms, observation)] only for equal typed count inputs and a
    revalidated complete checkpoint witness. The returned observation keeps
    any refreshed witness and replaces the prior observation. A mismatch or
    any revalidation failure returns
    [None]; the caller must load and count the current source. *)

module For_testing : sig
  val revalidate_after_object_read :
    after_object_read:(Agent_core.Checkpoint_objects.digest -> unit) ->
    t -> Keeper_checkpoint_store.Read_observation.revalidation
  (** Revalidate the observation's actual retained witness, observing its
      header-object reads without substituting a reader or validation result. *)
end
