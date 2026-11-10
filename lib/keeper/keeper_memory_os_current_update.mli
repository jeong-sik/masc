(** The locked update of a Keeper's current snapshot: the retraction plan and
    equal-facts types, the quarantine of an undecodable snapshot together with
    its removal receipt, and the update functions
    [update_locked_with_output] and [update_locked_with_error].

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types
open Keeper_memory_os_current_publication

(* An exact retraction batch: its plan id and the error that reports pending
   journal evidence for the snapshot it wrote. *)
type 'error retraction_plan =
  string
  * (plan_id:string -> snapshot_revision:int -> snapshot_sha256:string -> detail:string -> 'error)

(* What a commit does when its facts equal the stored ones. A Librarian pass
   keeps the stored snapshot. An explicit write still writes a revision: its
   caller reads the returned [change] as what that write did, and the keeper
   stamps [last_seen] with the write time, so an equal set does not arise
   from it in practice. A retraction plan is an explicit write, so a kept
   pass never carries one. *)
type 'error equal_facts =
  | Keep_stored
  | Write_revision of 'error retraction_plan option

val quarantine_snapshot_and_receipt :
  keepers_dir:string ->
  keeper_id:string ->
  snapshot_path:string ->
  now:float -> rejection:string -> (string, string) result

val update_locked_with_output :
  ?write_snapshot:(string ->
                   string -> (unit, Fs_compat.atomic_replace_failure) result) ->
  ?sync_snapshot:(string -> (unit, string) result) ->
  ?finalize_journal:(keepers_dir:string ->
                     keeper_id:string ->
                     publication_receipt ->
                     (publication_receipt,
                      string)
                     result) ->
  ?on_committed:(t ->
                 commit_effect -> unit) ->
  ?program_of_output:('a -> Keeper_memory_os_program_types.publication) ->
  ?observe_output:(t ->
                   commit_effect -> 'a -> unit) ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  ?dropped_statements:dropped_statement list ->
  ?before_replace:(previous:t option ->
                   next:t -> (unit, 'b) result) ->
  ?declared_revisions:revision list ->
  ?durable_range_id:durable_range_id ->
  ?official_range_id:official_range_id ->
  ?explicit_candidate_ids:explicit_candidate_id
                          list ->
  ?admission_recall:admission_recall ->
  change_count:'a Keeper_memory_os_current_change_metrics.change_count ->
  equal_facts:'b equal_facts ->
  store_error:(string -> 'b) ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  (snapshot_content:string option ->
   t option ->
   (t * 'a, 'b) result) ->
  (t *
   commit_effect * 'a, 'b)
  result
(** For a commit that rewrote the snapshot, [change_count] sets the Memory
    gauges under both locks, in commit order, and moves the change counter
    after both locks are released. That includes a commit that returns an
    error after its snapshot rename, because its journal evidence is still
    pending or the directory sync failed. A kept snapshot is not counted. *)

val update_locked_with_error :
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  ?dropped_statements:dropped_statement list ->
  ?retraction_plan:'a retraction_plan ->
  change_count:unit Keeper_memory_os_current_change_metrics.change_count ->
  store_error:(string -> 'a) ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  (snapshot_content:string option ->
   t option ->
   (t, 'a) result) ->
  (t, 'a) result
