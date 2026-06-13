(** Workspace bootstrap — initialize the default workspace state on
    first boot. *)

open Masc_domain
open Workspace_utils

val default_workspace_state : Workspace_utils_backend_setup.config -> Masc_domain.workspace_state
val ensure_workspace_bootstrap : Workspace_utils_backend_setup.config -> unit
