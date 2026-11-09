(** The application of a program or a disposition to a snapshot: the types of
    a disposition, its basis and its error and of a program source and
    commit, the message digest, the preparation of a program source, the
    application of a program with its I/O, the guarded application of a
    disposition and the text of a disposition error.

    [Keeper_memory_os_current] includes this module. *)

open Keeper_memory_os_types
open Keeper_memory_os_current_types
open Keeper_memory_os_current_read_anchor

(* Apply a librarian's disposition to whatever the snapshot holds when the
   lock is taken.

   The librarian says what changes: retire that one for this reason, add these
   new claims. A fact the disposition never mentions is left alone.

   A fact the librarian retires is retired even if the keeper re-observed it
   during the pass: the judgment was about the claim, and a re-observation does
   not answer it. The keeper can state it again on its next turn. *)
type disposition =
  { snapshot : t
  ; commit : commit_effect
  ; absorbed_applied : absorbed_statement list
  ; absorbed_not_applied : absorbed_statement list
  ; claims_not_applied : fact list
  ; revisions_applied : revision list
  }

type disposition_basis =
  { expected_revision : int option
  ; expected_facts : fact list option
  }

type disposition_error =
  | Basis_superseded of t option
  | Destination_absent of { memory_id : string; current : t option }
  | Disposition_store_failed of string

type program_source =
  | Atom_program_source of
      { range : durable_range_id
      ; checkpoint : Agent_core.Types.message list
      }
  | Official_program_source of
      { range : official_range_id
      ; selected_turns : (int * Ids.Turn_ref.t * Agent_core.Types.message list) list
      }

type program_commit =
  { snapshot : t
  ; proof : Keeper_memory_os_program_types.publication
  }

val apply_program_with_io :
  ?write_snapshot:(string ->
                   string ->
                   (unit, Fs_compat.atomic_replace_failure) result) ->
  ?sync_snapshot:(string -> (unit, string) result) ->
  ?finalize_journal:(keepers_dir:string ->
                     keeper_id:string ->
                     Keeper_memory_os_current_publication.publication_receipt ->
                     (Keeper_memory_os_current_publication.publication_receipt,
                      string)
                     result) ->
  ?on_committed:(program_commit -> unit) ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  anchor:program_anchor ->
  source:program_source ->
  validate_source:(unit -> (unit, string) result) ->
  Keeper_memory_os_program_types.t -> (program_commit, string) result

val apply_program :
  ?on_committed:(program_commit -> unit) ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  keepers_dir:string -> keeper_id:string -> now:float ->
  anchor:program_anchor -> source:program_source ->
  validate_source:(unit -> (unit, string) result) ->
  Keeper_memory_os_program.t -> (program_commit, string) result

val apply_disposition_guarded :
  ?expected_basis:disposition_basis ->
  ?on_committed:(disposition -> unit) ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  ?dropped_statements:dropped_statement list ->
  ?durable_range_id:durable_range_id ->
  ?official_range_id:official_range_id ->
  ?explicit_candidate_ids:explicit_candidate_id
                          list ->
  ?admission_recall:admission_recall ->
  ?required_memory_ids:string list ->
  absorbed:absorbed_statement list ->
  revisions:revision list ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  source:source ->
  new_claims:fact list ->
  unit -> (disposition, disposition_error) result

val disposition_error_to_string : disposition_error -> string

val apply_disposition :
  ?expected_basis:disposition_basis ->
  ?on_committed:(disposition -> unit) ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  ?dropped_statements:dropped_statement list ->
  ?durable_range_id:durable_range_id ->
  ?official_range_id:official_range_id ->
  ?explicit_candidate_ids:explicit_candidate_id
                          list ->
  ?admission_recall:admission_recall ->
  ?required_memory_ids:string list ->
  absorbed:absorbed_statement list ->
  revisions:revision list ->
  keepers_dir:string ->
  keeper_id:string ->
  now:float ->
  source:source ->
  new_claims:fact list ->
  unit -> (disposition, string) result
