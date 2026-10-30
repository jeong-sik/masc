(** What one builtin Skill package's state on disk calls for, as a table with
    no filesystem access. The caller reads the receipt and the installed tree.
    [authority] decides only whether a change to an installed tree runs now or
    is reported as pending. {!Builtin_skill_package} documents each verdict. *)

type ownership = Recorded | Untracked | Modified

type bundled_verdict =
  | Install_missing
  | Up_to_date
  | Adopt_identical
  | Adopt_with_release_permissions
  | Permissions_pending of { revision : string }
  | Replace_recorded of { backup : string }
  | Replace_pending of { revision : string }
  | Keep_modified of { revision : string }
  | Keep_untracked_different of { revision : string }
  | Keep_uninspectable of { reason : string }

type retired_verdict =
  | Retire_recorded of { backup : string option }
  | Retire_pending of { revision : string option }
  | Keep_retired_modified of { revision : string }
  | Keep_retired_uninspectable of { reason : string }

type authority =
  | Startup
      (** Server start and probes: publish missing packages and record trees
          that already equal the release, nothing else. *)
  | Installer  (** [masc init]. *)

type bundled_step =
  | Settled of bundled_verdict  (** Nothing to change. *)
  | Publish
  | Record of { revision : string }
  | Record_with_release_permissions of
      { revision : string; entries : Builtin_skill_revision.entry list }
  | Exchange of { revision : string }

type retired_step =
  | Settled_retired of retired_verdict  (** Nothing to change. *)
  | Remove_receipt
  | Move_aside of { revision : string }

val ownership : receipt:string option -> revision:string -> ownership
(** [receipt] is the receipt file's content, [None] when there is none. *)

val bundled_step :
  authority ->
  receipt:string option ->
  installed:Builtin_skill_revision.entry list option ->
  bundled_revision:string ->
  bundled_step
(** A package this release ships. [installed] is the installed tree, [None]
    when its directory is missing. *)

val retired_step :
  authority -> receipt:string -> installed:Builtin_skill_revision.entry list option -> retired_step
(** A receipt whose package this release no longer ships. *)
