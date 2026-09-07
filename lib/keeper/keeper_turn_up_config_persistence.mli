(** Declarative TOML persistence for [masc_keeper_up].

    Runtime metadata deliberately scrubs TOML-owned policy fields. This module
    makes the tool contract durable by creating a complete manifest for a new
    Keeper, or patching only explicitly supplied fields on an existing one. *)

type outcome =
  { path : string
  ; created : bool
  ; revision : revision
  }

and revision =
  | Missing
  | Sha256 of string

type config_revision =
  { manifest : revision
  ; runtime_assignment : Runtime.keeper_assignment_revision
  }

type conflict =
  { expected : config_revision
  ; observed : config_revision
  }

type warning =
  | Manifest_parent_sync_unconfirmed of string
  | Runtime_config_parent_sync_unconfirmed of string
  | Lock_release_unconfirmed of string
  | Runtime_config_lock_release_unconfirmed of string

type 'a receipt =
  { value : 'a
  ; warnings : warning list
  }

type reconciliation_observation =
  | Observed_revision of revision
  | Unreadable_manifest of string

type reconciliation =
  { path : string
  ; detail : string
  ; observed : reconciliation_observation
  }

type runtime_reconciliation =
  { path : string option
  ; detail : string
  }

type composite_reconciliation =
  { manifest : reconciliation option
  ; runtime_assignment : runtime_reconciliation option
  }

type error =
  | Io_error of string
  | Revision_conflict of conflict
  | Reconciliation_required of reconciliation
  | Composite_reconciliation_required of composite_reconciliation
  | Publication_exception of
      { path : string
      ; detail : string
      }

type 'a publication =
  | Commit of 'a
  | Commit_with_warnings of 'a * warning list
  | Rollback of 'a

val revision_to_yojson : revision -> Yojson.Safe.t

val config_revision_to_yojson : config_revision -> Yojson.Safe.t

val config_revision_of_yojson : Yojson.Safe.t -> (config_revision, string) result

val error_to_string : error -> string

val warning_to_yojson : warning -> Yojson.Safe.t

val warnings_of_runtime_assignment_write :
  Runtime.keeper_assignment_write -> warning list

val current_config_revision :
  config:Workspace.config -> keeper_name:string -> (config_revision, string) result

val with_current_config_revision :
  config:Workspace.config ->
  keeper_name:string ->
  (config_revision -> 'a) ->
  ('a receipt, string) result

val persist_with_publication :
  expected_revision:config_revision ->
  config:Workspace.config ->
  parsed:Keeper_turn_up_args.parsed_args ->
  meta:Keeper_meta_contract.keeper_meta ->
  publish:(Runtime.keeper_assignment_transaction -> outcome -> 'a publication) ->
  unit ->
  ('a receipt, error) result

val persist :
  expected_revision:config_revision ->
  config:Workspace.config ->
  parsed:Keeper_turn_up_args.parsed_args ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (outcome receipt, error) result

module For_testing : sig
  val persist_with_release_failure :
    release_failure:File_lock_eio.durable_lock_error ->
    expected_revision:config_revision ->
    config:Workspace.config ->
    parsed:Keeper_turn_up_args.parsed_args ->
    meta:Keeper_meta_contract.keeper_meta ->
    unit ->
    (outcome receipt, error) result

  val persist_with_rollback_parent_sync_failure :
    expected_revision:config_revision ->
    config:Workspace.config ->
    parsed:Keeper_turn_up_args.parsed_args ->
    meta:Keeper_meta_contract.keeper_meta ->
    unit ->
    (unit receipt, error) result


  val persist_with_post_write_revision_failure :
    expected_revision:config_revision ->
    config:Workspace.config ->
    parsed:Keeper_turn_up_args.parsed_args ->
    meta:Keeper_meta_contract.keeper_meta ->
    unit ->
    (outcome receipt, error) result

  val persist_with_runtime_restore_replace_file :
    replace_file:
      (string ->
       string ->
       (unit, Fs_compat.atomic_replace_failure) result) ->
    expected_revision:config_revision ->
    config:Workspace.config ->
    parsed:Keeper_turn_up_args.parsed_args ->
    meta:Keeper_meta_contract.keeper_meta ->
    publish:
      (Runtime.keeper_assignment_transaction -> outcome -> 'a publication) ->
    unit ->
    ('a receipt, error) result
end
