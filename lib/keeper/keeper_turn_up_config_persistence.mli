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

type conflict =
  { expected : revision
  ; observed : revision
  }

type warning =
  | Manifest_parent_sync_unconfirmed of string
  | Lock_release_unconfirmed of string

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

type error =
  | Io_error of string
  | Revision_conflict of conflict
  | Reconciliation_required of reconciliation

type 'a publication =
  | Commit of 'a
  | Rollback of 'a

val revision_to_yojson : revision -> Yojson.Safe.t

val revision_of_yojson : Yojson.Safe.t -> (revision, string) result

val error_to_string : error -> string

val warning_to_yojson : warning -> Yojson.Safe.t

val current_revision :
  config:Workspace.config -> keeper_name:string -> (revision, string) result

val with_current_revision :
  config:Workspace.config ->
  keeper_name:string ->
  (revision -> 'a) ->
  ('a receipt, string) result

val persist_with_publication :
  expected_revision:revision ->
  config:Workspace.config ->
  parsed:Keeper_turn_up_args.parsed_args ->
  meta:Keeper_meta_contract.keeper_meta ->
  publish:(outcome -> 'a publication) ->
  unit ->
  ('a receipt, error) result

val persist :
  expected_revision:revision ->
  config:Workspace.config ->
  parsed:Keeper_turn_up_args.parsed_args ->
  meta:Keeper_meta_contract.keeper_meta ->
  unit ->
  (outcome receipt, error) result

module For_testing : sig
  val persist_with_release_failure :
    release_failure:File_lock_eio.durable_lock_error ->
    expected_revision:revision ->
    config:Workspace.config ->
    parsed:Keeper_turn_up_args.parsed_args ->
    meta:Keeper_meta_contract.keeper_meta ->
    unit ->
    (outcome receipt, error) result

  val persist_with_rollback_parent_sync_failure :
    expected_revision:revision ->
    config:Workspace.config ->
    parsed:Keeper_turn_up_args.parsed_args ->
    meta:Keeper_meta_contract.keeper_meta ->
    unit ->
    (unit receipt, error) result
end
