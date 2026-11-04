(** One Keeper's skill activation records and its usage of the catalog's
    surfaces, read from that Keeper's ledger alone (RFC-0483 L2).

    [GET /api/v1/keepers/skill-activations?keeper=<name>] answers with
    {!json}. A reader that heard [keeper_skill_activations_changed] for the
    Keeper reads this instead of every Keeper's ledger. *)

val usage_rows :
  Keeper_skill_catalog.skill list -> Keeper_skill_activation_ledger.t -> Yojson.Safe.t list
(** For each catalog surface the ledger used, its reference and how many
    times it was invoked, delivered and acted on, and when it was last used.
    A surface the ledger never used has no row. *)

val json : config:Workspace.config -> keeper_name:string -> Yojson.Safe.t
(** The answer for [keeper_name]: the activation projection, as
    [/api/v1/dashboard/tools?keeper=] carries it, and [usage] whose [state]
    is [ready] (with [rows]), [no_ledger] when the Keeper has no readable
    ledger, or [no_catalog] when the workspace has no ready skill catalog. *)
