(** Runtime-owned confirmation deadline observation for one workspace. *)
type t =
  | Not_managed
  | Initializing
  | Observed
  | Source_unavailable
  | Deadline_unavailable
  | Workspace_unobserved
  | Scope_unavailable

type sample
type reading
type provider = Workspace.config -> sample

val unmanaged : sample
val managed : epoch:string -> generation:int -> t -> sample
val status : reading -> t
val same_revision : reading -> reading -> bool
(** A revision binds the runtime owner, workspace epoch, and source generation.
    A state transition alone does not change the source revision. *)

val get : Workspace.config -> t
(** Standalone reads without a runtime observer return [Not_managed]. *)

val read : Workspace.config -> reading
(** Take a source revision before and after a store read to reject a snapshot
    that crossed a publication or workspace replacement. *)

val install : provider -> provider
(** Install a switch-owned observer and return the previous provider. *)

val restore_if_current : current:provider -> previous:provider -> bool
(** Restore only if the installed provider has not been replaced. *)
