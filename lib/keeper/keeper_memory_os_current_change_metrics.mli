(** What one Memory commit changed, counted by memory ID, and the metrics
    those counts move (RFC-0517 §2.2).

    [Keeper_memory_os_current_update] records a commit that rewrote the
    snapshot once both store locks are released. A commit that kept the stored
    snapshot ([Unchanged]) is not recorded: its snapshot still carries the
    change of the commit before it. *)

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
(** An ordered program, summed stage by stage from its proof. *)

(** How a commit is counted: under the pass that called it, from the committed
    snapshot and the commit's own output. [replace] seeds a whole snapshot and
    no pass calls it, so it is [Not_counted]. *)
type 'a change_count =
  | Counted of
      { pass : Keeper_memory_commit_pass.t
      ; count : Keeper_memory_os_current_types.t -> 'a -> counts
      }
  | Not_counted

val record :
  keeper_id:string ->
  'a change_count ->
  Keeper_memory_os_current_types.t ->
  'a ->
  unit
(** Move [masc_keeper_memory_changes_total] by each count under the keeper,
    the pass and the change, and set [masc_keeper_memory_facts] and
    [masc_keeper_memory_snapshot_bytes] from the committed snapshot. The bytes
    are its rendered facts, the same count the Memory health row shows. *)
