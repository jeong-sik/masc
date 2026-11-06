(** The checks and the Gate approval of a write in
    [Keeper_tool_filesystem_runtime].

    [check_invariant_sandbox_isolation] checks that the target of a confined
    path lies in the host root of the turn sandbox, and
    [confined_write_is_keeper_playground] says whether the root of a confined
    path is the playground of the keeper.
    [gate_operation] is the Gate operation of every local write.
    [file_write_gate_input] builds the Gate input of a write,
    [write_call_summary] states in one line what the approval is about, and
    [decide_file_write] asks the Gate for the decision.
    [path_effect_operation_of_write_mode] names the effect of a write mode,
    [declared_root_write_gate_input] builds the Gate input of a write under
    the declared roots of an endpoint, and [declared_root_writes] authorizes
    such writes through the Gate.
    [approved_write_of_gate_input] decodes a recorded Gate input into the
    [approved_write] it approved, [fs_write_mode_of_gate_effect_operation]
    reads the write mode back from the operation of the recorded effect, and
    [replay_args_of_gate_input] rebuilds the arguments of the write handler.
    [Keeper_tool_filesystem_runtime] includes this module. *)
open Keeper_meta_contract
open Keeper_tool_filesystem_runtime_shared

val check_invariant_sandbox_isolation :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  confined:Keeper_alerting_path.confined_path -> (unit, string) result

type approved_write =
  { target : string
  ; mode : fs_write_mode
  ; carried : (string * Yojson.Safe.t) list
  }

val approved_write_of_gate_input : Yojson.Safe.t -> (approved_write, string) result

val replay_args_of_gate_input : Yojson.Safe.t -> (Yojson.Safe.t, string) result

val write_call_summary : requested_target:string -> string option

val gate_operation : string

val file_write_gate_input :
  effect_json:Yojson.Safe.t ->
  requested_target:string ->
  content:string ->
  ?content_source:Keeper_write_content.t ->
  ?old_string:string ->
  ?new_string:string ->
  ?replace_all:bool ->
  ?insert_before_line:int ->
  ?insert_text:string -> unit -> Yojson.Safe.t

val decide_file_write :
  config:Workspace_utils_backend_setup.config ->
  meta:keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate_types.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  requested_target:string ->
  input:Yojson.Safe.t -> unit -> Keeper_gate_types.decision

val declared_root_write_gate_input :
  endpoint:Exec_ssh_endpoint.t ->
  requested_target:string ->
  mode:Keeper_tool_write_mode.t ->
  content_source:Keeper_write_content.t ->
  content:string ->
  patch:Keeper_tool_filesystem_remote_write.patch_request option ->
  Yojson.Safe.t

val declared_root_writes :
  config:Workspace_utils_backend_setup.config ->
  meta:keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate_types.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  unit -> Keeper_tool_filesystem_remote_write.declared_root_writes

val confined_write_is_keeper_playground :
  config:Workspace_utils_backend_setup.config ->
  meta:keeper_meta ->
  Keeper_alerting_path.confined_path -> bool
