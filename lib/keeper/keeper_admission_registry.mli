(** Loads per-persona admission policies from [cascade.toml] sub-tables
    and exposes them as a [Keeper_admission_glue.policy_lookup].

    Reads [\[admission.<keeper>\]] sub-tables produced by
    [cascade_toml_materializer] (TOML -> JSON via Otoml).  Each parses
    through [Keeper_admission_policy.parse_admission_json].  A single
    failed parse does NOT abort the load — the registry surfaces it as
    a [Load_error] entry the operator can inspect, but other personas
    keep working.  This is the same fail-loud-but-keep-going pattern
    used by [cascade_config_loader] for individual cascade entries.

    Cache: the registry holds a snapshot.  Hot reload is the caller's
    responsibility (rebuild via [load_from_json]).  No mtime polling
    here — the existing [cascade_config_loader] already refreshes on
    mtime change and a thin wrapper at the heartbeat layer can rebuild
    the registry whenever the loader returns a fresh JSON. *)

type t

type load_error = {
  keeper_id : string;
  reason : Keeper_admission_policy.validation_error;
}

(** {1 Construction} *)

val empty : t
(** Empty registry — every [lookup] returns [None].  Useful as a
    placeholder while wiring [Keeper_admission_glue.decide] before the
    JSON loader is connected. *)

val load_from_json :
  Yojson.Safe.t -> t * load_error list
(** Walk the [admission] sub-object of the cascade JSON.  For each
    [<keeper>] key, parse the value as a per-persona policy.  Returns
    the assembled registry plus the list of personas whose blocks
    failed validation.

    Expected shape:
    {v
    {
      "admission": {
        "analyst":      {weight, min_tier, candidates},
        "executor":     {weight, min_tier, candidates},
        ...
      }
    }
    v}

    Pure: no file I/O.  The caller passes a pre-loaded JSON value. *)

(** {1 Query} *)

val lookup : t -> string -> Keeper_admission_policy.t option
(** Returns the policy for [keeper_id], or [None] if no entry exists.
    Plug this into [Keeper_admission_glue.decide]'s [policies]
    parameter. *)

val keeper_ids : t -> string list
(** All registered keeper IDs in insertion order.  For diagnostic
    output and dashboards. *)

val size : t -> int
