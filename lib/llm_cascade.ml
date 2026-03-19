(** LLM Cascade — compatibility wrapper over {!Oas_cascade}.

    New or migrated operational code should call [Oas_cascade] directly.
    This module remains for compatibility with out-of-scope paths and
    dashboard/archive code that still depends on the historic name. *)

type cascade_result = Oas_cascade.text_result = {
  response : string;
  llm_used : string;
  duration_ms : int;
}

let max_concurrent_llm = Oas_cascade.max_concurrent_llm
let llm_semaphore_available = Oas_cascade.llm_semaphore_available
let llm_permits_in_use = Oas_cascade.llm_permits_in_use
let default_config_path = Oas_cascade.default_config_path
let default_model_strings = Oas_cascade.default_model_strings
let get_cascade = Oas_cascade.get_cascade
let call_state = Oas_cascade.call_state
let call = Oas_cascade.call
let call_raw = Oas_cascade.call_raw
let call_with_tools = Oas_cascade.call_with_tools
