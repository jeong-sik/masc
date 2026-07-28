(** Workspace state — backlog, workspace state, and recovery helpers. *)

open Masc_domain
open Workspace_utils

val normalized_string_list : string list -> string list

(** Project a JSON entry of the [active_agents] array to the agent
    name it identifies. Current state accepts only bare [`String name]
    entries; object-shaped historical entries are ignored during repair. *)


val write_state :
  Workspace_utils_backend_setup.config -> Masc_domain.workspace_state -> unit

val read_state : Workspace_utils_backend_setup.config -> Masc_domain.workspace_state

val update_state :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state -> Masc_domain.workspace_state) ->
  Masc_domain.workspace_state

val next_seq : Workspace_utils_backend_setup.config -> int
val is_paused : Workspace_utils_backend_setup.config -> bool

val pause_info :
  Workspace_utils_backend_setup.config ->
  (string option * string option * string option) option

val take : int -> 'a list -> 'a list
