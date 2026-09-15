(** Whole-package distribution updates. Operator resources, deletions and
    permissions participate in the revision, not just SKILL.md. *)
type package

val make : name:string -> files:(string * string) list -> (package, string) result
val name : package -> string
val bundled_revision : package -> string
(** Complete revision of this immutable binary-embedded package value. *)

type ownership = Recorded | Untracked | Modified
type inspection =
  | Missing
  | Present of { revision : string; bundled_revision : string; ownership : ownership }

(** What reconciliation did with a package this binary ships.

    Server startup and every probe that boots a config root run
    {!reconcile_at_startup}. Several binaries with different packages can share
    one base path, so startup only adds: it publishes missing packages and
    writes receipts for trees that already equal this release. Everything that
    changes or moves an installed tree is left to {!install}, which a person
    runs ([masc init]), and startup reports it as pending. *)
type bundled_verdict =
  | Install_missing
      (** No package directory existed; the bundled package and its receipt were published. *)
  | Up_to_date
      (** The receipt matches the installed tree and the tree equals this release. *)
  | Adopt_identical
      (** The installed tree already equals this release byte for byte, but its
          receipt was absent or described another tree. Only the receipt was written. *)
  | Adopt_with_release_permissions
      (** {!install} only. No receipt, and the files, directories and bytes
          equal this release while some permissions differ. The permissions
          were set to the release's and the receipt was written. *)
  | Permissions_pending of { revision : string }
      (** {!reconcile_at_startup} only. The same tree as
          [Adopt_with_release_permissions]; startup does not change an
          installed tree, so {!install} sets the permissions. *)
  | Replace_recorded of { backup : string }
      (** {!install} only. The receipt matches the installed tree and this
          release differs. The tree that was installed is kept at [backup],
          the package's one backup entry, replacing the tree an earlier
          replacement or retirement of the same package kept there. The backup
          entry is not touched until the installed tree has left the Skill
          source. *)
  | Replace_pending of { revision : string }
      (** {!reconcile_at_startup} only. The receipt matches the installed tree
          and this release differs; {!install} replaces it. *)
  | Keep_modified of { revision : string }
      (** The tree changed since its receipt was written and differs from this release. *)
  | Keep_untracked_different of { revision : string }
      (** No receipt, and the files or their bytes differ from this release. It
          may be the operator's own version, so it is not replaced. *)
  | Keep_uninspectable of { reason : string }
      (** The tree or receipt is not an owned regular tree (links, special
          files, unreadable directories). Nothing was changed. *)

(** What reconciliation did with a receipt whose package this binary no longer ships. *)
type retired_verdict =
  | Retire_recorded of { backup : string option }
      (** {!install} only. The receipt matched the installed tree: the tree was
          moved to [backup] and the receipt removed. [None]: the package
          directory was already gone, so only the receipt was removed. *)
  | Retire_pending of { revision : string option }
      (** {!reconcile_at_startup} only. What [Retire_recorded] would do;
          [None]: only the receipt is left. *)
  | Keep_retired_modified of { revision : string }
      (** The tree changed since installation. Tree and receipt are kept. *)
  | Keep_retired_uninspectable of { reason : string }

type error =
  | Invalid_path of string
  | Revision_conflict of inspection
  | Bundled_revision_conflict of { actual_revision : string }
  | Io_error of string
  | Published_but_unrecorded of { backup : string option; reason : string }
  | Exported_but_unsynced of { destination : string; reason : string }
  | Retired_but_unrecorded of { backup : string; reason : string }
  | Backup_move_pending of { note : string }
      (** A move note for this package already exists: an earlier replacement
          or retirement did not finish. The package is not replaced or retired
          until {!install} finishes that move. *)
  | Backup_move_unresolved of { note : string }
      (** {!install} found no tree with the revision in [note] in the Skill
          source, the backup entry or staging. Staging is kept. *)

(** How {!install} finished a replacement or retirement that stopped after
    writing its move note. *)
type backup_move =
  | Move_never_started  (** The Skill source still holds the tree. *)
  | Move_completed  (** The backup entry already holds the tree. *)
  | Move_finished of { backup : string }
      (** The tree was in a staging holder and now is at [backup]. *)

type report =
  | Interrupted of { name : string; result : (backup_move, error) result }
      (** {!install} only. One per move note found when it starts. *)
  | Bundled of { name : string; result : (bundled_verdict, error) result }
  | Retired of { name : string; result : (retired_verdict, error) result }
  | Unfinished of { path : string; result : (unit, error) result }
      (** {!install} only. An interrupted installation left [path] in the
          staging directory; [Ok] means it was removed. *)

val inspect : base_path:string -> package -> (inspection, error) result
val export : destination:string -> package -> (unit, error) result
(** Write the complete bundled package to a new directory for a normal diff.
    Never replace an existing destination. *)

type startup_reconciliation =
  | Reconciled of report list
  | Busy of { lock : string }
      (** Something had to be published or recorded, and another installation
          held [lock]. Nothing was changed; the next start tries again. *)

val reconcile_at_startup :
  base_path:string -> package list -> (startup_reconciliation, error) result
(** Bring [.masc/skills] in line with [packages] without changing any installed
    tree. One [Bundled] report per package, in order, then one [Retired] report
    per installation receipt whose name is not in [packages].

    Reading is done without the installer lock. The lock is taken only when a
    package has to be published or recorded, and never waited for. [Error]
    means no package was examined (unusable deployment root or receipt
    directory). *)

val install :
  on_wait:(string -> unit) -> base_path:string -> package list -> (report list, error) result
(** Everything {!reconcile_at_startup} does, plus replacing and retiring
    recorded trees and setting release permissions on untracked trees whose
    files equal this release. First one [Interrupted] report per move note an
    interrupted replacement or retirement left, then, when every one of them
    was finished, one [Unfinished] report per staging holder it removed, then
    the reports of {!reconcile_at_startup}.

    A replacement or retirement writes a move note naming the installed
    tree's revision before that tree leaves the Skill source, and removes it
    once the backup entry is verified to hold that tree. Staging, where the
    tree waits in between, is emptied only when no note is left unfinished.

    A tree is replaced or retired only when its receipt matches it. A tree
    without a receipt is never removed: MASC cannot tell a former builtin from
    the operator's own Skill. A package failure is reported in its own report
    and does not stop the others. The receipt names are read before anything is
    changed, so [Error] means no package was examined (unusable deployment
    root, lock, receipt or staging directory).

    When another installation holds the lock, [on_wait] receives the lock path
    once and the call waits for it. This is a synchronous operation. Callers
    must serialize operator file editing with installation: the lock serializes
    installers, not arbitrary external editors. Refresh a running Skill catalog
    after installation before starting a new instruction invocation. *)

type replacement = Replaced of { backup : string } | Already_current

val replace_reviewed :
  on_wait:(string -> unit) ->
  base_path:string ->
  installed_revision:string ->
  bundled_revision:string ->
  package ->
  (replacement, error) result
(** Replace an installed package after the operator reviewed both complete
    revisions, whatever its receipt says. Either revision having changed since
    review rejects the replacement. The old package is kept in the package's
    backup directory, as for [Replace_recorded]. Publication exchanges directories atomically; unsupported
    filesystems return an error with the original package intact. [on_wait]
    is {!install}'s. It does not finish earlier moves; while a move note for
    this package exists it returns [Backup_move_pending]. The next replacement
    or retirement of the package, including a routine {!install}, replaces the
    backup, so operator changes kept only there are deleted then. *)

val error_message : error -> string
val report_to_string : report -> string
(** One line naming the package, what happened, and the next step when the
    operator has one. *)

module For_testing : sig
  type interruption = After_move_note | After_leaving_skill_source | After_backup_placed
  val install :
    interrupt:(interruption -> unit) ->
    on_wait:(string -> unit) -> base_path:string -> package list -> (report list, error) result
  (** {!install}, calling [interrupt] between the steps of each replacement
      and retirement so a test can stop the process there. *)

  val ensure_directory : sync_parent:(string -> unit) -> string -> (unit, error) result
  (** Observe or fail parent sync after actual directory creation. *)
  val export : sync_parent:(string -> unit) -> destination:string -> package -> (unit, error) result
  (** Inject a parent sync failure after real no-replace publication. *)
end
