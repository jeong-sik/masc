(** What one Memory commit changed, counted by memory ID, and the metrics
    those counts move (RFC-0517 §2.2).

    [Keeper_memory_os_current_update] sets the gauges of a commit that
    rewrote the snapshot while it still holds the store locks, so they follow
    commit order, and moves the counter once both locks are released. A commit
    that kept the stored snapshot ([Unchanged]) moves neither: its snapshot
    still carries the change of the commit before it. *)

type counts =
  { added : int  (** IDs the result holds that the basis did not *)
  ; absorbed : int  (** IDs that left through an applied absorption *)
  ; superseded : int  (** IDs that left through an applied revision *)
  ; dropped : int  (** every other ID that left, support invalidations included *)
  }

val of_change :
  absorbed:Keeper_memory_os_types.absorbed_statement list ->
  revisions:Keeper_memory_os_types.revision list ->
  Keeper_memory_os_current_types.change ->
  counts
(** One snapshot transition. An ID on both sides of the change kept its
    identity and changed only its payload, so it is counted nowhere. *)

val of_publication : Keeper_memory_os_program_types.publication -> counts
(** An ordered program, once, from its initial to its final facts. Only an ID
    of the initial facts can be absorbed, superseded or dropped. One that left
    through an absorption or a revision is followed through each later
    stage's absorption or revision of the ID carrying it. It counts by the
    kind of its first exit when that chain ends in the final facts, and as
    dropped otherwise. *)

(** How a commit is counted: under the pass that called it, from the committed
    snapshot and the commit's own output. [replace] seeds a whole snapshot and
    no pass calls it, so it is [Not_counted]. *)
type 'a change_count =
  | Counted of
      { pass : Keeper_memory_commit_pass.t
      ; count : Keeper_memory_os_current_types.t -> 'a -> counts
      }
  | Not_counted

val set_gauges :
  keeper_id:string -> 'a change_count -> Keeper_memory_os_current_types.t -> unit
(** Set [masc_keeper_memory_facts] and [masc_keeper_memory_snapshot_bytes] from
    the committed snapshot. The bytes are its rendered facts, the same count
    the Memory health row shows. In-memory only, so the store calls it under
    its locks. *)

val count_changes :
  keeper_id:string ->
  'a change_count ->
  Keeper_memory_os_current_types.t ->
  'a ->
  unit
(** Move [masc_keeper_memory_changes_total] by each count under the keeper,
    the pass and the change. *)
