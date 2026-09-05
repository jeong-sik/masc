(** Feature Flag Registry — single source of truth for all MASC boolean
    feature flags.

    Each flag has a canonical default, description, category, and
    lifecycle state. The registry does not replace [env_config] modules
    (they still read env vars). Instead it provides:

    + Runtime enumeration for operators
    + Consistency verification (CI lint: [check-feature-flag-consistency.sh])
    + Current lifecycle classification: Active or Experimental
    + Machine-readable flag catalog *)

(** {1 Types} *)

(** Flag lifecycle state machine. *)
type lifecycle =
  | Active
  | Experimental          (** not yet stable, may change without notice *)

type flag = {
  env_name : string;      (** MASC_* environment variable name *)
  description : string;
  default : bool;
  category : string;      (** Grouping: transport/tool/keeper/dashboard/inference/runtime *)
  lifecycle : lifecycle;
}

(** {1 Registry} *)

(** The canonical registry. Alphabetically ordered within each
    category. CI verifies that every [get_bool ... "MASC_*"] call in
    [lib/config/] has a matching entry here with the same default. *)
val all_flags : flag list

(** Lookup a flag by env var name. O(n) — acceptable for ~30 flags. *)
val find_opt : string -> flag option

(** {1 Runtime value} *)

(** Read runtime value using the flag's canonical default. *)
val runtime_value : flag -> bool

(** Source of the active value: ["env"], ["boot_override"], or
    ["default"]. *)
val runtime_source : flag -> string

(** [get_bool env_name] reads the registered flag using its canonical
    default. Raises {!Env_config_core.Config_error} when [env_name] is not
    registered. *)
val get_bool : string -> bool

(** Like {!get_bool}, but raises {!Env_config_core.Config_error} when the
    selected env or boot-override value is present, non-empty, and malformed. *)
val get_bool_strict : string -> bool

(** {1 Serialisation} *)

val lifecycle_to_string : lifecycle -> string

(** JSON shape: [{env_name, description, canonical_default, runtime_value,
    source, category, lifecycle}]. *)
val flag_to_json : flag -> Yojson.Safe.t

(** All flags grouped by category:
    [{total_flags, categories:{transport:[...], tool:[...], ...}}]. *)
val to_json : unit -> Yojson.Safe.t

(** {1 Queries} *)

(** Flags whose runtime value differs from the canonical default. *)
val overridden_flags : unit -> flag list
