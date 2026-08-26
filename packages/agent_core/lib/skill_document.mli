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

type conformance =
  | Conformant
  | Runtime_compatible of diagnostic list

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
        (** All metadata values in source order, including client-specific
            structures and duplicate keys, for diagnostics and projection. *)
  ; extensions : (string * extension_value) list
        (** Non-standard top-level fields. Their presence makes the document
            runtime-compatible rather than strictly conformant. *)
  ; body : string
  }

type load_outcome =
  | Loaded of
      { document : t
      ; conformance : conformance
      }
  | Unloadable of diagnostic list

val decode : directory_name:string -> string -> load_outcome
(** Decode one complete [SKILL.md]. Strictly conforming documents have both
    required fields and satisfy the Agent Skills naming and length rules.

    The runtime-compatible path may use [directory_name] when [name] is
    absent, or retain a usable non-conforming document with diagnostics. A
    missing description or structurally unreadable frontmatter is
    [Unloadable], because the document cannot participate in discovery.

    Unknown top-level fields are retained as extensions and diagnosed as
    runtime-compatible rather than silently assigned client semantics. *)

val diagnostics : load_outcome -> diagnostic list
val conformance_diagnostics : conformance -> diagnostic list
val diagnostic_to_string : diagnostic -> string
val conformance_to_string : conformance -> string
