(** Workspace state — backlog, workspace state, and recovery helpers. *)

open Masc_domain
open Workspace_utils

val normalized_string_list : string list -> string list

(** Project a JSON entry of the [active_agents] array to the agent
    name it identifies. Current state accepts only bare [`String name]
    entries; object-shaped historical entries are ignored during repair. *)
val recover_active_agent_name : Yojson.Safe.t -> string option

val recover_workspace_state :
  Workspace_utils_backend_setup.config ->
  Yojson.Safe.t -> Masc_domain.workspace_state

val write_state :
  Workspace_utils_backend_setup.config -> Masc_domain.workspace_state -> unit

val write_state_result :
  Workspace_utils_backend_setup.config ->
  Masc_domain.workspace_state ->
  (unit, string) result

type read_state_error =
  | State_read_failed of string
  | State_repair_write_failed of
      { decode_error : string
      ; write_error : string
      ; recovered_state : Masc_domain.workspace_state
      }

val read_state_error_to_string : read_state_error -> string

type read_state_status =
  | State_authoritative
  | State_recovered_unpersisted
  | State_default_from_read_error

val read_state_status_to_string : read_state_status -> string

type read_state_snapshot =
  { state : Masc_domain.workspace_state
  ; status : read_state_status
  ; read_errors : string list
  }

val read_state_result :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state, read_state_error) result

val read_state_snapshot :
  Workspace_utils_backend_setup.config -> read_state_snapshot

val read_state : Workspace_utils_backend_setup.config -> Masc_domain.workspace_state

val update_state_result :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state -> Masc_domain.workspace_state) ->
  (Masc_domain.workspace_state, string) result

val update_state :
  Workspace_utils_backend_setup.config ->
  (Masc_domain.workspace_state -> Masc_domain.workspace_state) ->
  Masc_domain.workspace_state

val next_seq : Workspace_utils_backend_setup.config -> int
val is_paused_result : Workspace_utils_backend_setup.config -> (bool, string) result
val is_paused : Workspace_utils_backend_setup.config -> bool

val pause_info_result :
  Workspace_utils_backend_setup.config ->
  ((string option * string option * string option) option, string) result

val pause_info :
  Workspace_utils_backend_setup.config ->
  (string option * string option * string option) option

val heartbeat_timeout_seconds : float
val parse_iso_time_opt : string -> float option
val parse_iso_time : string -> float
val is_zombie_agent :
  ?agent_type:string -> ?agent_meta:Masc_domain.agent_meta -> agent_name:string -> string -> bool
val take : int -> 'a list -> 'a list
