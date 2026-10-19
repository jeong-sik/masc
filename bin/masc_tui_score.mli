(** Terminal ownership transfer to the official alphaTab score viewer.
    No score text becomes a shell command, and the snapshot is private. *)
val available : unit -> bool

val launch_music :
  restore:(unit -> unit) -> reenter:(unit -> unit) ->
  project_root:string -> session_root:string ->
  soundfont:string option -> (unit, string) result
(** Opens the ANSI music workbench with explicit workspace-owned project and
    take directories. No score snapshot or graphics capability is needed. *)

val launch :
  restore:(unit -> unit) -> reenter:(unit -> unit) ->
  sources:string list -> index:int -> cell_pixels:int * int ->
  soundfont:string option -> (unit, string) result
(** The helper receives a frozen snapshot of the current conversation's
    closed fences. [index] is one-based, newest first. Every return path
    after [restore] calls [reenter]; the snapshot is removed on return. *)
