(** Exact, path-free identity of one immutable Agent Skill document. *)

type package_id = private string

type package_id_error =
  | Empty_package_id
  | Current_directory_package_id
  | Parent_directory_package_id
  | Package_id_contains_separator
  | Package_id_contains_nul

type content_revision = private string

type revision_error =
  | Invalid_revision_length of { actual : int }
  | Invalid_revision_character of
      { index : int
      ; found : char
      }

type identity = private
  { source_id : Skill_source_config.source_id
  ; package_id : package_id
  ; name : string
  }

type t = private
  { identity : identity
  ; content_revision : content_revision
  }

type decode_error =
  | Expected_object of { field : string }
  | Expected_list of { field : string }
  | Missing_field of
      { object_name : string
      ; field : string
      }
  | Expected_string of
      { object_name : string
      ; field : string
      }
  | Duplicate_field of
      { object_name : string
      ; field : string
      }
  | Unexpected_field of
      { object_name : string
      ; field : string
      }
  | Invalid_source_id of string
  | Invalid_package_id of package_id_error
  | Invalid_content_revision of revision_error
  | Duplicate_reference of t

val package_id_of_directory : string -> (package_id, package_id_error) result
val package_id_to_string : package_id -> string

val validate_revision_string : string -> (unit, revision_error) result
val content_revision_of_string : string -> (content_revision, revision_error) result
val content_revision_of_source_text : string -> content_revision
val content_revision_to_string : content_revision -> string
val equal_content_revision : content_revision -> content_revision -> bool

val make_identity :
  source_id:Skill_source_config.source_id ->
  package_id:package_id ->
  name:string ->
  identity

val make : identity:identity -> content_revision:content_revision -> t
val equal_identity : identity -> identity -> bool
val equal : t -> t -> bool

val identity_key : identity -> string
val key : t -> string
(** The identity as one [source/package/name] string.

    Three parts because two are not unique: one source publishes many packages
    and one package holds many Skills. The content revision is absent — the
    turn's frozen snapshot already fixes which revision an identity resolves
    to, so a caller that has the snapshot does not need the model to echo the
    hash back to it.

    One-to-one with the three parts, because none of them can contain the
    separator where it is built: [source_id] is a portable name, [package_id]
    rejects separators, and a Skill name takes only letters, digits and
    hyphens. Nothing parses this back and nothing may — it is offered as a
    closed choice and matched by equality against a list that was already
    projected — but it stays legible, because a chat row names a Skill call
    by it.

    In-process only. It is a Hashtbl key and an equality, never written to a
    file or a wire field — an encoding change has to stay a recompile, not a
    migration. *)

val identity_to_yojson : identity -> Yojson.Safe.t
val to_yojson : t -> Yojson.Safe.t
val pp : Format.formatter -> t -> unit
(** Canonical exact JSON printer used by enclosing derived domain printers. *)
val list_to_yojson : t list -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, decode_error) result
val list_of_yojson : Yojson.Safe.t -> (t list, decode_error) result
(** Decoders are strict: objects reject unknown and duplicate fields, lists
    reject duplicate exact references, and the former string-only Task shape is
    not accepted. Skill-name conformance remains the catalog document parser's
    authority; an externally decoded identity becomes usable only after exact
    snapshot resolution. *)
