(** Test-only scripted provider responses. Production OAS exposes no mock
    provider or mock transport. *)

open Agent_sdk
open Types

type response_fn = message list -> api_response

type t =
  { responses : response_fn list
  ; mutable index : int
  }

let create ~responses () = { responses; index = 0 }

let next_response mock messages =
  match mock.responses with
  | [] -> Error (Error.Internal "test provider has no scripted responses")
  | responses ->
    let fn = List.nth responses (mock.index mod List.length responses) in
    mock.index <- mock.index + 1;
    Ok (fn messages)
;;

let reset mock = mock.index <- 0
let call_count mock = mock.index

let usage ~input_tokens ~output_tokens =
  Some
    { input_tokens
    ; output_tokens
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = None
    }
;;

let text_response
      ?(id = "test-id")
      ?(model = "test-model")
      ?(input_tokens = 0)
      ?(output_tokens = 0)
      text
  =
  fun (_ : message list) ->
  { id
  ; model
  ; stop_reason = EndTurn
  ; content = [ Text text ]
  ; usage = usage ~input_tokens ~output_tokens
  ; telemetry = None
  }
;;

let tool_use_response
      ?(id = "test-id")
      ?(model = "test-model")
      ?(input_tokens = 0)
      ?(output_tokens = 0)
      ~tool_name
      ~tool_input
      ()
  =
  fun (_ : message list) ->
  { id
  ; model
  ; stop_reason = StopToolUse
  ; content = [ ToolUse { id = id ^ ":tool"; name = tool_name; input = tool_input } ]
  ; usage = usage ~input_tokens ~output_tokens
  ; telemetry = None
  }
;;

let tool_then_text ~tool_name ~tool_input ~final_text () =
  [ tool_use_response ~tool_name ~tool_input (); text_response final_text ]
;;

let thinking_response
      ?(id = "test-id")
      ?(model = "test-model")
      ?(input_tokens = 0)
      ?(output_tokens = 0)
      ~thinking
      ~text
      ()
  =
  fun (_ : message list) ->
  { id
  ; model
  ; stop_reason = EndTurn
  ; content = [ Thinking { signature = None; content = thinking }; Text text ]
  ; usage = usage ~input_tokens ~output_tokens
  ; telemetry = None
  }
;;

let local_provider_config ?(provider_id = "test") ~base_url ~model_id ~request_path () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id
    ~model_id
    ~base_url
    ~api_key:""
    ~headers:[ "Content-Type", "application/json" ]
    ~request_path
    ()
;;

let to_provider_config () =
  local_provider_config
    ~base_url:"http://test.invalid"
    ~model_id:"test-model"
    ~request_path:"/v1/chat/completions"
    ()
;;
