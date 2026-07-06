(** Workspace init / pause / resume / reset.

    Boot-time workspace state initialisation, pause/resume gating for
    agent claims, and a destructive [reset] hook used by the
    [masc_reset] tool. *)

open Masc_domain
open Workspace_utils

(** Initialise workspace state; session-binds [agent_name] when given. *)
val init :
  Workspace_utils_backend_setup.config -> agent_name:'a option -> string

(** Mark workspace automation as paused with metadata for [pause_info]. *)
val pause :
  Workspace_utils_backend_setup.config ->
  by:string -> reason:string -> unit

(** Clear an active pause. [`Already_running] when no pause was
    set, [`Resumed] otherwise. *)
val resume_result :
  Workspace_utils_backend_setup.config ->
  by:string -> ([ `Already_running | `Resumed ], string) result

val resume :
  Workspace_utils_backend_setup.config ->
  by:string -> [> `Already_running | `Resumed ]

(** Destructive reset of workspace state — primarily for the
    [masc_reset] tool. *)
val reset : Workspace_utils_backend_setup.config -> string
