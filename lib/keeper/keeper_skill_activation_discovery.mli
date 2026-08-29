(** Read-only discovery over retained Skill activation ledgers.

    The activation ledger remains the only authority. Discovery reads every
    immediate, typed trace directory below the workspace-owned trace store;
    it creates no index and does not change Keeper behavior. *)

type filesystem_operation =
  | Open_directory
  | Read_directory
  | Close_directory
  | Stat_entry

type filesystem_error =
  { operation : filesystem_operation
  ; path : string
  ; cause : Unix.error
  }

type gap =
  | Trace_root_unavailable of filesystem_error
  | Trace_root_not_directory of Unix.file_kind
  | Trace_entry_unreadable of filesystem_error
  | Invalid_trace_directory of string
  | Symlink_trace_entry of string
  | Trace_entry_not_directory of
      { trace_id : Keeper_id.Trace_id.t
      ; kind : Unix.file_kind
      }
  | Trace_inventory_changed_during_discovery
  | Trace_root_changed_during_discovery
  | Ledger_changed_during_discovery of Keeper_id.Trace_id.t
  | Ledger_unreadable of
      { trace_id : Keeper_id.Trace_id.t
      ; cause : Keeper_skill_activation_ledger.store_error
      }

type scope =
  | Complete_retained_trace_snapshot
  | Incomplete_retained_trace_snapshot
  | Trace_store_unavailable

type evidence =
  { trace_id : Keeper_id.Trace_id.t
  ; activation : Keeper_skill_activation_ledger.activation
  }

type latest =
  | Not_observed
  | Most_recent_observed of evidence
  | Most_recent_observed_timestamp_tie of evidence list

type t =
  { latest : latest
  ; scope : scope
  ; sessions_inspected : int
  ; ledgers_loaded : int
  ; gaps : gap list
  }

val discover : Workspace.config -> Skill_reference.t -> t

module For_testing : sig
  val discover :
    after_first_pass:(unit -> unit) ->
    Workspace.config ->
    Skill_reference.t ->
    t
end
