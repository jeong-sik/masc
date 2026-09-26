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
(** Bound for one deferred Skill resource read. Always
    {!Common.max_tool_result_wire_bytes}: it is derived, not configured. *)

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
  | Missing_resource_read_policy
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

type notice = Ignored_resource_read_max_bytes
(** [[skills] resource-read-max-bytes] is present. It is ignored for one
    version and refused after that (#39284). *)

val parse_text : string -> (t, diagnostic list) result
val parse_text_with_notices : string -> (t * notice list, diagnostic list) result
(** [parse_text] plus the keys that were accepted but ignored. *)
val validate_text : string -> (unit, diagnostic list) result
val read_only_absolute_source :
  id:source_id -> path:string -> (source, path_rejection) result
(** Typed source for an explicitly declared package export. *)
val append_sources : t -> source list -> (t, diagnostic list) result
(** Preserve source order and the configured read policy. Package sources
    require a [skills] policy; absent policies and duplicate IDs are errors. *)
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

val rejection_message : config_path:string -> diagnostic list -> string
(** One line naming every diagnostic and then the runtime.toml that carries
    them. The save path (HTTP 400) and the boot WARN both print this line, so
    an operator reads the same key and file in either place. *)

val notice_to_string : notice -> string
val notice_message : config_path:string -> notice list -> string
(** Same shape as {!rejection_message}, for keys that are ignored. *)

module For_testing : sig
  val with_resource_read_max_bytes : int -> t -> t
  (** A smaller bound than the derived one, to exercise the oversize path. *)
end
