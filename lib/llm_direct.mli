(** Llm_direct — Direct LLM API calls without llm-mcp dependency.

    @deprecated Use {!Llm_client.run_prompt_cascade} with
    {!Lodge_cascade.get_cascade} instead. This module will be removed
    in a future release. *)

val env_set : string array -> string -> string -> string array
[@@deprecated "Use Llm_client.run_prompt_cascade instead"]

val strip_extra : string -> string
[@@deprecated "Llm_client handles response cleanup internally"]

val call_glm :
  ?api_key:string ->
  model:string ->
  prompt:string ->
  timeout_sec:int ->
  max_chars:int ->
  unit ->
  string
[@@deprecated "Use Llm_client.run_prompt_cascade with Lodge_cascade.get_cascade"]

val call_claude_cli :
  ?api_key:string ->
  model:string ->
  prompt:string ->
  timeout_sec:int ->
  max_chars:int ->
  unit ->
  string
[@@deprecated "Use Llm_client.run_prompt_cascade with Lodge_cascade.get_cascade"]

val call_ollama :
  model:string ->
  prompt:string ->
  timeout_sec:int ->
  max_chars:int ->
  unit ->
  string
[@@deprecated "Use Llm_client.run_prompt_cascade with Lodge_cascade.get_cascade"]

val call_llama :
  model:string ->
  prompt:string ->
  timeout_sec:int ->
  max_chars:int ->
  unit ->
  string
[@@deprecated "Use Llm_client.run_prompt_cascade with Lodge_cascade.get_cascade"]

val dispatch :
  tool_name:string ->
  ?api_key:string ->
  model:string ->
  prompt:string ->
  timeout_sec:int ->
  max_chars:int ->
  unit ->
  string
[@@deprecated "Use Llm_client.run_prompt_cascade with Lodge_cascade.get_cascade"]
