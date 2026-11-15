(** The fact operations on a Keeper's snapshot and the rest of the module: the
    replace and the upsert of a fact, the retraction of the current facts, of
    one fact and of a batch, the supersession of a fact, the identity and the
    tail read of the journal projection, the move-aside of a Keeper's
    snapshot files, and the [For_testing] module.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types
open Keeper_memory_os_current_read_anchor
open Keeper_memory_os_current_program_apply

val replace :
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  ?dropped_statements:dropped_statement list ->
  keepers_dir:string ->
  keeper_id:string ->
  expected_revision:int option ->
  now:float ->
  source:source ->
  facts:fact list ->
  unit -> (t, string) result

val upsert_fact :
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  pass:Keeper_memory_commit_pass.t ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  source:source ->
  fact ->
  (t,
   upsert_error)
  result

val retract_fact :
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  pass:Keeper_memory_commit_pass.t ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  source:source ->
  memory_id:string ->
  reason:string ->
  unit ->
  (t,
   retract_error)
  result

val supersede_fact :
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  pass:Keeper_memory_commit_pass.t ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  source:source ->
  superseded_memory_id:string ->
  fact ->
  (t *
   supersession,
   supersede_error)
  result

val retract_facts :
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  pass:Keeper_memory_commit_pass.t ->
  keepers_dir:string ->
  keeper_id:string ->
  expected_revision:int ->
  expected_snapshot_sha256:string ->
  now:float ->
  source:source ->
  retraction list ->
  (t,
   retract_batch_error)
  result

val read_journal_tail_projection :
  keepers_dir:string ->
  keeper_id:string ->
  limit:int ->
  (Yojson.Safe.t list, string) result

val move_aside_for_keepers_dir :
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  rejection:string ->
  expected_snapshot_sha256:string -> unit -> (string, string) result

module For_testing :
  sig
    val decode_snapshot :
      string -> (t, string) result
    val recover_publication_with_sync :
      sync_parent:(Unix.file_descr -> 'a) ->
      keepers_dir:string -> keeper_id:string -> (unit, string) result
    val apply_program_with_publication_io :
      write_snapshot:(string ->
                      string ->
                      (unit, Fs_compat.atomic_replace_failure) result) ->
      sync_snapshot:(string -> (unit, string) result) ->
      before_journal:(unit -> 'a) ->
      on_committed:(program_commit ->
                    unit) ->
      pass:Keeper_memory_commit_pass.t ->
      keepers_dir:string ->
      keeper_id:string ->
      now:float ->
      anchor:program_anchor ->
      source:program_source ->
      validate_source:(unit -> (unit, string) result) ->
      Keeper_memory_os_program_types.t ->
      (program_commit, string)
      result
    val replace_with_publication_io :
      write_snapshot:(string ->
                      string ->
                      (unit, Fs_compat.atomic_replace_failure) result) ->
      sync_snapshot:(string -> (unit, string) result) ->
      on_committed:(t ->
                    commit_effect -> unit) ->
      before_journal:(unit -> 'a) ->
      keepers_dir:string ->
      keeper_id:string ->
      now:float ->
      source:source ->
      facts:fact list ->
      (t, string) result
    val durable_range_receipt_decodes : unit -> int
  end
