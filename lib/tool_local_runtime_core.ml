(** Tool_local_runtime core — types, helpers, process discovery, model fetching. *)

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

type llama_process = {
  pid : int option;
  command : string;
  port : int option;
  host : string option;
  alias : string option;
  model_path : string option;
  ctx_size : int option;
  batch_size : int option;
  ubatch_size : int option;
  slots_enabled : bool;
}

type bench_sample = {
  success : bool;
  latency_ms : int;
  error : string option;
}

let parse_int_opt value =
  Stdlib.int_of_string_opt ((String.trim value))


let split_ws text =
  match Exec_policy.parse_string_to_ir ~mode:Strict text with
  | Error _ ->
      let trimmed = String.trim text in
      if String.equal trimmed "" then [] else [ trimmed ]
  | Ok ir -> Exec_policy.flat_stage_words ir






