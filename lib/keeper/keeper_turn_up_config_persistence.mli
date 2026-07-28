(** Declarative TOML persistence for [masc_keeper_up].

    Runtime metadata deliberately scrubs TOML-owned policy fields. This module
    makes the tool contract durable by creating a complete manifest for a new
    Keeper, or patching only explicitly supplied fields on an existing one. *)

type outcome =
  { path : string
  ; created : bool
  }

val persist :
  config:Workspace.config ->
  parsed:Keeper_turn_up_args.parsed_args ->
  meta:Keeper_meta_contract.keeper_meta ->
  (outcome, string) result
