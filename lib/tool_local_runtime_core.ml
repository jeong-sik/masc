(** Tool_local_runtime core — shared types and a parse helper. *)

type tool_result = Tool_result.result

type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  continue:(unit -> tool_result) ->
  tool_result

type context = {
  config : Workspace.config;
  agent_name : string;
  authorize_external_effect : external_effect_authorizer option;
}

let parse_int_opt value =
  Stdlib.int_of_string_opt ((String.trim value))
