(** Keeper_turn_setup — keeper setup helpers.

    Extracted from keeper_turn.ml. *)

(** Resolve a keeper by name and return its effective meta record.
    Returns [Error] if the keeper does not exist, the meta is unreadable,
    or TOML/profile overlay cannot be applied. *)
val ensure_keeper_exists :
  ctx:_ Keeper_types_profile.context ->
  name:string ->
  (Keeper_meta_contract.keeper_meta, string) result

(** The most keeper names {!absent_roster_clause} lists. *)
val absent_roster_name_limit : int

(** [absent_roster_clause names] is the text a refusal for an unknown keeper
    appends: ["; registered keepers: a, b, c"] with [names] sorted and without
    repeats. Past {!absent_roster_name_limit} names it lists the first ones and
    says how many were left out. It is [""] when [names] is empty, so a refusal
    without a roster reads as it did before. *)
val absent_roster_clause : string list -> string

(** [keeper_absent_detail ~config name] is the refusal for a [name] that
    resolved to no keeper. A [name] that an active agent holds is called an
    agent, because no amount of looking for it as a keeper will help; any other
    [name] is ["keeper not found: <name>"] followed by
    {!absent_roster_clause} of the keepers registered in this server process,
    the ones a delegate or a message accepts. *)
val keeper_absent_detail : config:Workspace.config -> string -> string
