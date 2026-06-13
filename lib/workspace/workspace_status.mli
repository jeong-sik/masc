(** Workspace status snapshot — render the workspace/agent state as a
    human-readable string for the [masc_status] tool. *)

open Masc_domain
open Workspace_utils
open Workspace_state

val status : Workspace_utils_backend_setup.config -> string
