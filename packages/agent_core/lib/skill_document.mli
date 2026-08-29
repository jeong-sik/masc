(** Agent Skills [SKILL.md] document decoding.

    This module owns the portable file contract only. Discovery roots,
    precedence, activation lifetime, permissions, and execution are client
    concerns and deliberately live outside this module. *)

type standard_field =
  | Name
  | Description
  | License
  | Compatibility
  | Metadata
  | Allowed_tools_syntax_only
  (** Parser/diagnostic tag for the official experimental field. The decoded
      value is deliberately discarded and grants no MASC runtime authority. *)

type field =
  | Standard of standard_field
  | Extension of string

type expected_shape =
  | String_value
  | String_mapping

type name_violation =
  | Empty_name
  | Name_too_long of
      { length : int
      ; maximum : int
      }
  | Name_not_lowercase
  | Name_starts_with_hyphen
  | Name_ends_with_hyphen
  | Name_has_consecutive_hyphens
  | Name_has_invalid_character

type diagnostic =
  | Missing_frontmatter
  | Byte_order_mark
      (** A UTF-8 byte-order mark preceded the frontmatter. Official Agent
          Skills documents must start with the frontmatter delimiter. *)
  | Unterminated_frontmatter
  | Malformed_yaml of string
  | Frontmatter_not_mapping
  | Duplicate_field of field
  | Duplicate_metadata_key of string
  | Unexpected_frontmatter_field of string
  | Missing_name
  | Missing_description
  | Invalid_field_type of
      { field : field
      ; expected : expected_shape
      }
  | Invalid_name of
      { name : string
      ; violations : name_violation list
      }
  | Name_mismatch of
      { declared : string
      ; directory : string
      }
  | Description_too_long of { length : int }
  | Compatibility_empty
  | Compatibility_too_long of { length : int }
  | Invalid_metadata_value of { key : string }

type extension_value =
  | Null
  | Boolean of bool
  | Number of float
  | Text of string
  | Sequence of extension_value list
  | Mapping of (string * extension_value) list

type t = private
  { name : string
  ; declared_name : string option
  ; description : string
  ; license : string option
  ; compatibility : string option
  ; metadata : (string * string) list
        (** Unique, specification-conforming string metadata. Ambiguous
            duplicate keys and non-string values are excluded here. *)
  ; metadata_values : (string * extension_value) list
        (** Valid string metadata values in source order. The richer value type
            keeps registry projection independent from the YAML library while
            the decoder rejects non-string and duplicate metadata entries. *)
  ; body : string
  }

type load_outcome =
  | Loaded of t
  | Unloadable of diagnostic list

val canonical_name : string -> (string, name_violation list) result
(** Parse one Agent Skills name with the same normalization and grammar used by
    {!decode}. The returned value is the canonical NFKC spelling. *)

val decode : directory_name:string -> string -> load_outcome
(** Decode one complete [SKILL.md] using the Agent Skills specification as its
    admission contract. Both required fields, the name-directory equality,
    length limits, metadata shape, and the closed top-level field set must be
    valid. Any diagnostic makes the document [Unloadable]. Client-specific
    data belongs under the specification's [metadata] field. *)

val diagnostics : load_outcome -> diagnostic list
val diagnostic_to_string : diagnostic -> string
val diagnostic_to_yojson : diagnostic -> Yojson.Safe.t
(** Closed operator projection with a stable [code], the constructor's typed
    payload, and a human-readable [message]. Consumers classify and automate
    from [code] plus payload, never by parsing [message]. *)
