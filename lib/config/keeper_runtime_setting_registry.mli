(** Typed authority for Keeper-owned runtime settings.

    A setting is public only when this registry names its environment variable,
    optional [runtime.toml] key, value contract, default, effect boundary, and
    concrete runtime consumers.  Runtime loaders, operator JSON, documentation,
    and census tests project this data instead of maintaining parallel lists. *)

type value_kind =
  | Boolean
  | Integer
  | Float
  | String

type value_range =
  | Unbounded
  | Integer_range of
      { min_inclusive : int option
      ; max_inclusive : int option
      }
  | Float_range of
      { min_inclusive : float option
      ; min_exclusive : float option
      ; max_inclusive : float option
      }

type reload_class =
  | Hot
  | Next_turn
  | Next_cycle
  | Fiber_restart
  | Process_restart

type exposure =
  | Toml_and_env of string
  | Env_only

type setting =
  { env_name : string
  ; exposure : exposure
  ; value_kind : value_kind
  ; value_range : value_range
  ; default_display : string
  ; reload_class : reload_class
  ; consumers : string list
  ; category : string
  ; description : string
  }

val all : setting list
(** Complete registry, including explicitly environment-only rows. *)

val toml_settings : setting list
(** The rows that own a TOML key. *)

val toml_env_mappings : (string * string) list
(** TOML key to environment name, one pair per row of [toml_settings]. *)

val toml_key_opt : setting -> string option
val find_by_toml_key : string -> setting option

val value_kind_label : value_kind -> string
val value_range_label : value_range -> string
val reload_class_label : reload_class -> string

val requires_restart : setting -> bool
(** [true] for settings whose next effect boundary requires a fiber or process
    restart. *)

val validate_registry : unit -> (unit, string list) result
(** Rejects duplicate environment/TOML identities, malformed exposure, and
    TOML settings without a concrete consumer. *)

val schema_to_yojson : unit -> Yojson.Safe.t
(** Machine-readable catalog used by operator surfaces and generated docs. *)
