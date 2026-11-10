(** The status and cancel controls of an asynchronous composition request.

    [status_result] polls a request of the calling Keeper and [cancel_result]
    asks to cancel one; [status_result_for_invocation] also tells the result
    delivery that the status was read for an invocation, and
    [discard_status_binding] drops that binding. [make_request_control_tool]
    builds a control tool that validates its input and hands the request id to
    its handler. [result_from_json] makes a tool result out of JSON data, and
    [async_submission_error] is either the tool result of a refused submission
    or an error of the broker.
    [Keeper_tool_composition_surface] includes this module. *)

val result_from_json :
  tool_name:string ->
  start_time:Tool_timing.started ->
  class_:Tool_result.tool_failure_class ->
  ok:bool -> Yojson.Safe.t -> Tool_result.result

type async_submission_error =
  | Submission_result of Tool_result.result
  | Broker_error of Keeper_msg_async.submit_error

val discard_status_binding :
  delivery_registry:Keeper_composition_result_delivery.t option ->
  invocation:Agent_core_base.Tool_contract.Invocation.t option -> unit

val status_result_for_invocation :
  ?delivery_registry:Keeper_composition_result_delivery.t ->
  ?invocation:Agent_core_base.Tool_contract.Invocation.t ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  request_id:string -> unit -> Tool_result.result

val status_result :
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  request_id:string -> Tool_result.result

val cancel_result :
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  request_id:string -> Tool_result.result

val make_request_control_tool :
  config:Workspace_utils_backend_setup.config ->
  name:string ->
  description:string ->
  input_schema:Yojson.Safe.t ->
  descriptor:Agent_core_base.Tool.descriptor ->
  on_rejected:(Agent_core_base.Tool.Execution_env.t -> 'a) ->
  handle:(Agent_core_base.Tool.Execution_env.t ->
          string -> Tool_result.result) ->
  (Agent_core_base.Tool.t, Tool_bridge.schema_error) result
