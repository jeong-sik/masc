(* Fixture payloads for the serialization field builder only. No Core linking. *)
open Type_extract
module Util = struct
  let json_of_string_opt = function None -> `Null | Some s -> `String s
  let json_of_float_opt = function None -> `Null | Some n -> `Float n
  let json_of_int_opt = function None -> `Null | Some n -> `Int n
  let json_of_bool_opt = function None -> `Null | Some b -> `Bool b
end
module Context = struct let to_json x = x end
module Mcp_session = struct let info_list_to_json xs = `List xs end
module Agent_input_request = struct let pending_to_json x = x end
module Error = struct
  type serialization = JsonParseError of {detail:string}
  type t = Serialization of serialization
end
let model_to_yojson s = `String s
let usage_to_json x = x
let tool_schema_to_json x = x
let tool_choice_to_json x = x
let response_format_to_json x = x
let reasoning_effort_option_to_json = Util.json_of_string_opt

type checkpoint = {
  version:int; session_id:string; agent_name:string; model:string;
  provider_binding:Reasoning_source.t option; system_prompt:string option;
  messages:Yojson.Safe.t list; usage:Yojson.Safe.t; turn_count:int; created_at:float;
  tools:Yojson.Safe.t list; tool_choice:Yojson.Safe.t option;
  temperature:float option; top_p:float option; top_k:int option; min_p:float option;
  enable_thinking:bool option; preserve_thinking:bool option; response_format:Yojson.Safe.t;
  reasoning_effort:string option; disable_parallel_tool_use:bool; cache_system_prompt:bool;
  context:Yojson.Safe.t; mcp_sessions:Yojson.Safe.t list; pending_input:Yojson.Safe.t option;
  working_context:Yojson.Safe.t option;
}
let fixture provider_binding = {
  version=15;session_id="session";agent_name="agent";model="shared-model";
  provider_binding;system_prompt=None;messages=[];usage=`Assoc [];turn_count=1;created_at=1.;
  tools=[];tool_choice=None;temperature=None;top_p=None;top_k=None;min_p=None;
  enable_thinking=None;preserve_thinking=None;response_format=`String "off";
  reasoning_effort=None;disable_parallel_tool_use=false;cache_system_prompt=false;
  context=`Assoc [];mcp_sessions=[];pending_input=None;working_context=None;
}
