(** Whole-package distribution updates. Operator resources, deletions and
    permissions participate in the revision, not just SKILL.md. *)
type package

val make : name:string -> files:(string * string) list -> (package, string) result
val name : package -> string

type ownership = Recorded | Untracked | Modified
type inspection =
  | Missing
  | Present of { revision : string; bundled_revision : string; ownership : ownership }

type request = Seed_missing | Automatic | Replace_if_revision of string
type outcome =
  | Installed
  | Already_present
  | Current
  | Preserved of inspection
  | Preserved_invalid_path of string
  | Updated of { backup : string }

type error =
  | Invalid_path of string
  | Revision_conflict of inspection
  | Io_error of string
  | Published_but_unrecorded of { backup : string option; reason : string }

val inspect : base_path:string -> package -> (inspection, error) result
val export : destination:string -> package -> (unit, error) result
(** Write the complete bundled package to a new directory for a normal diff.
    Never replace an existing destination. *)
val install : base_path:string -> request:request -> package -> (outcome, error) result
(** [Automatic] replaces only a tree whose complete revision matches its
    installation receipt. Untracked/modified trees remain untouched, even
    when their SKILL.md happens to equal the new builtin. Explicit replacement
    requires the current complete revision and retains the old package outside
    the Skill source. Publication exchanges directories atomically; unsupported
    filesystems return an error with the original package intact.

    This is a synchronous installer operation. Callers must serialize operator
    file editing with installation. The advisory lock serializes installers;
    it is not a lock on arbitrary external editors. Refresh a running Skill
    catalog after installation before starting a new instruction invocation. *)

val error_message : error -> string
