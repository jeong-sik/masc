(** Coord init / pause / resume / reset.

    Boot-time coord state initialisation, pause/resume gating for
    agent claims, and a destructive [reset] hook used by the
    [masc_reset] tool. *)

open Masc_domain
open Coord_utils
open Coord_state
open Coord_broadcast

(** Initialise coord state; session-binds [agent_name] when given. *)
val init :
  Coord_utils_backend_setup.config -> agent_name:'a option -> string

(** Mark the coord as paused with metadata for [pause_info]. *)
val pause :
  Coord_utils_backend_setup.config ->
  by:string -> reason:string -> unit

(** Clear an active pause. [`Already_running] when no pause was
    set, [`Resumed] otherwise. *)
val resume :
  Coord_utils_backend_setup.config ->
  by:string -> [> `Already_running | `Resumed ]

(** Destructive reset of the coord state — primarily for the
    [masc_reset] tool. *)
val reset : Coord_utils_backend_setup.config -> string
