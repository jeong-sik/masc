(** Typed [runtime.toml] contract for ordered Skill discovery sources. *)

type source_id = private string

type anchor =
  | Base_path
  | User_home
  | Absolute

type access =
  | Read_only
  | Read_write

type activation_lifetime = Session

type precedence = Earlier_source_wins
(** The first configured source containing a usable Skill name is the default
    winner. Later same-name entries remain addressable by exact identity and
    are reported as shadowed by the catalog snapshot. *)

type source = private
  { id : source_id
  ; anchor : anchor
  ; configured_path : string
  ; access : access
  }

type t = private
  { activation_lifetime : activation_lifetime option
  ; precedence : precedence option
  ; sources : source list
  }

type source_field =
  | Id
  | Anchor
  | Path
  | Access
  | Unexpected of string

type value_kind =
  | String
  | Integer
  | Float
  | Boolean
  | Array
  | Table
  | Table_array
  | Date_time

type path_rejection =
  | Contains_nul
  | Expected_relative
  | Expected_absolute
  | Empty_component
  | Current_directory_component
  | Parent_directory_component

type anchor_rejection =
  | Empty_anchor
  | Relative_anchor
  | Anchor_contains_nul

type diagnostic =
  | Toml_syntax of string
  | Missing_activation_lifetime
  | Invalid_activation_lifetime_type of value_kind
  | Unsupported_activation_lifetime of string
  | Missing_precedence
  | Invalid_precedence_type of value_kind
  | Unsupported_precedence of string
  | Unexpected_skill_field of string
  | Invalid_sources_type of value_kind
  | Invalid_source_entry_type of
      { index : int
      ; actual : value_kind
      }
  | Missing_source_field of
      { index : int
      ; field : source_field
      }
  | Invalid_source_field_type of
      { index : int
      ; field : source_field
      ; actual : value_kind
      }
  | Unexpected_source_field of
      { index : int
      ; field : string
      }
  | Invalid_source_id of
      { index : int
      ; value : string
      }
  | Unsupported_anchor of
      { index : int
      ; value : string
      }
  | Unsupported_access of
      { index : int
      ; value : string
      }
  | Invalid_source_path of
      { index : int
      ; rejection : path_rejection
      }
  | Duplicate_source_id of
      { first_index : int
      ; duplicate_index : int
      ; id : source_id
      }

type resolution =
  | Resolved of string
  | Anchor_unavailable of anchor
  | Anchor_invalid of
      { anchor : anchor
      ; rejection : anchor_rejection
      }
  | Path_rejected of path_rejection

type resolved_source =
  { source : source
  ; resolution : resolution
  }

val parse_doc : Keeper_toml_loader.toml_doc -> (t, diagnostic list) result
val parse_text : string -> (t, diagnostic list) result
val validate_text : string -> (unit, diagnostic list) result
val to_yojson : t -> Yojson.Safe.t
(** Canonical Skill-only projection used for configuration revisions and
    observation. Source order is preserved. *)

val resolve :
  base_path:string -> user_home:string option -> source -> resolved_source
(** Resolve one source without filesystem access. Relative paths never escape
    their selected anchor; absolute paths are normalized lexically. *)

val source_id_to_string : source_id -> string
val top_level_namespace : string
val anchor_to_string : anchor -> string
val access_to_string : access -> string
val activation_lifetime_to_string : activation_lifetime -> string
val precedence_to_string : precedence -> string
val value_kind_to_string : value_kind -> string
val path_rejection_to_string : path_rejection -> string
val anchor_rejection_to_string : anchor_rejection -> string
val diagnostic_to_string : diagnostic -> string
