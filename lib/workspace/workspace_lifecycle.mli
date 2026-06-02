(** Workspace lifecycle — agent session binding and registry parse-error
    diagnostics. *)

open Masc_domain
open Workspace_utils
open Workspace_state
open Workspace_broadcast

val bind_session :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  ?agent_type_override:string option ->
  capabilities:string list ->
  ?pid:int option ->
  ?hostname:string option ->
  ?tty:string option ->
  ?parent_task:string option ->
  ?keeper_name:string option ->
  ?keeper_id:string option ->
  unit ->
  string

val end_session :
  ?stop_heartbeats:bool ->
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  string
