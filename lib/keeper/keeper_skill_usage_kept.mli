(** The Skill usage counts [GET /api/v1/skills] answers, kept per Keeper
    (RFC-0480 §3.4).

    A Keeper's counts for a Skill reference are computed from its activation
    ledger once and kept while the ledger's revision stays the same. A
    committed row moves that Keeper's revision, so only its counts are
    computed again; the other Keepers' are reused. The ledger itself is read
    from where the last read stopped ({!Keeper_skill_activation_ledger.load}). *)

val usage :
  base_path:string ->
  keeper_name:string ->
  Keeper_skill_activation_ledger.t ->
  Skill_reference.t ->
  Keeper_skill_activation_ledger.catalog_usage option
(** {!Keeper_skill_activation_ledger.usage_for_reference} for this ledger,
    from the kept counts when the Keeper's ledger has not moved since they
    were computed. *)
