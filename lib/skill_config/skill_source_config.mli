(** Typed [runtime.toml] contract for ordered Skill discovery sources. *)

type source_id = private string

type anchor =
  | Base_path
  | User_home
  | Absolute

type access =
  | Read_only
  | Read_write

type resource_read_max_bytes = private int
(** Strictly positive configured bound for one deferred Skill resource read. *)

type source = private
  { id : source_id
  ; anchor : anchor
  ; configured_path : string
  ; access : access
  }

type t = private
  { resource_read_max_bytes : resource_read_max_bytes option
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
  | Missing_resource_read_max_bytes
  | Invalid_resource_read_max_bytes_type of value_kind
  | Non_positive_resource_read_max_bytes of int
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
val source_id_of_string : string -> (source_id, string) result
val resource_read_max_bytes_to_int : resource_read_max_bytes -> int
val top_level_namespace : string
val anchor_to_string : anchor -> string
val access_to_string : access -> string
val path_rejection_to_string : path_rejection -> string
val anchor_rejection_to_string : anchor_rejection -> string
val diagnostic_to_string : diagnostic -> string
