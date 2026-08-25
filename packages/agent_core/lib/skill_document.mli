(** Agent Skills [SKILL.md] document decoding.

    This module owns the portable file contract only. Discovery roots,
    precedence, activation lifetime, permissions, and execution are client
    concerns and deliberately live outside this module. *)

type diagnostic =
  | Missing_frontmatter
  | Unterminated_frontmatter
  | Malformed_yaml of string
  | Frontmatter_not_mapping
  | Duplicate_field of string
  | Missing_name
  | Missing_description
  | Invalid_field_type of
      { field : string
      ; expected : string
      }
  | Invalid_name of string
  | Name_mismatch of
      { declared : string
      ; directory : string
      }
  | Description_too_long of { length : int }
  | Compatibility_too_long of { length : int }
  | Invalid_metadata_value of { key : string }

type conformance =
  | Conformant
  | Runtime_compatible of diagnostic list

type t = private
  { name : string
  ; declared_name : string option
  ; description : string
  ; license : string option
  ; compatibility : string option
  ; metadata : (string * string) list
  ; allowed_tools : string option
  ; extensions : (string * Yaml.value) list
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
    [Unloadable], because the document cannot participate in discovery. *)

val diagnostics : load_outcome -> diagnostic list
val diagnostic_to_string : diagnostic -> string
val conformance_to_string : conformance -> string
