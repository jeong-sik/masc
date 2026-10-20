(** The MSX machine's tools, named once for the host that routes a call and
    the worker that runs it. The library has no dependencies, so the tool
    schema, catalog and route layers can name a tool without linking the
    machine. *)

type t =
  | Load
  | Eject
  | Save
  | Restore
  | Export_disk
  | Change_disk
  | Screen
  | Meta
  | Checkpoint_info
  | Press
  | Step
  | Step_until_change
  | Peek
  | Ram_diff

val all : t list
(** Every tool in declaration order, which is the order the worker advertises
    them in. *)

val name : t -> string
(** The [masc_msx_*] wire name, the one place it is written. *)

val of_name : string -> t option
(** [None] for a name that is not an MSX tool. *)

val reads_only : t -> bool
(** [true] when the tool only reads: it changes neither the machine nor a
    file. The read-only flag a misc tool reports and the permission its
    catalog entry requires are both this value. *)

val default_checkpoint_slot : string
(** The slot a save or a checkpoint report names when the caller names none.
    A restore has no default: one that names no slot lists the saved slots. *)
