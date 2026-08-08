(** Gemini URL construction.

    Extracted from {!Complete} to keep the main completion module
    focused on request/response lifecycle.  Sampling values are caller-owned;
    this module does not inject provider-wide defaults.

    @since 0.205.9 *)

(** Construct the URL for a Gemini API call.
    Sync: [base_url/models/model_id:generateContent]
    Stream: [base_url/models/model_id:streamGenerateContent?alt=sse]

    The API key is never included in the URL.  Callers must add it to the
    [x-goog-api-key] header via {!Provider_config.auth_headers_for_config}. *)
let gemini_url ~(config : Provider_config.t) ~stream =
  let method_name = if stream then "streamGenerateContent" else "generateContent" in
  let base =
    Printf.sprintf "%s/models/%s:%s" config.base_url config.model_id method_name
  in
  if stream then base ^ "?alt=sse" else base
;;

(* --- gemini_url tests --- *)

let%test "gemini_url sync no api_key" =
  let config : Provider_config.t =
    { kind = Provider_config.Gemini
    ; provider_id = None
    ; model_id = "gemini-2.5-flash"
    ; base_url = "https://gen.googleapis.com/v1beta"
    ; api_key = Secret.empty
    ; request_path = ""
    ; headers = []
    ; system_prompt = None
    ; temperature = None
    ; max_tokens = Some 1024
    ; max_context = None
    ; max_request_body_bytes = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; clear_thinking = None
    ; tool_stream = false
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; response_format = Types.Off
    ; cache_system_prompt = false
    ; supports_tool_choice_override = None
    ; supports_structured_output_override = None
    ; model_capabilities_override = None
    ; keep_alive = None
    ; internal_model_rotation_count = None
    ; num_ctx = None
    ; seed = None
    ; previous_response_id = None
    ; connect_timeout_s = None
    ; max_concurrent_requests = None
    }
  in
  let url = gemini_url ~config ~stream:false in
  url = "https://gen.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
;;

let%test "gemini_url sync with api_key" =
  let config : Provider_config.t =
    { kind = Gemini
    ; provider_id = None
    ; model_id = "gemini-2.5-flash"
    ; base_url = "https://gen.googleapis.com/v1beta"
    ; api_key = Secret.of_string "mykey"
    ; request_path = ""
    ; headers = []
    ; system_prompt = None
    ; temperature = None
    ; max_tokens = Some 1024
    ; max_context = None
    ; max_request_body_bytes = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; clear_thinking = None
    ; tool_stream = false
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; response_format = Types.Off
    ; cache_system_prompt = false
    ; supports_tool_choice_override = None
    ; supports_structured_output_override = None
    ; model_capabilities_override = None
    ; keep_alive = None
    ; internal_model_rotation_count = None
    ; num_ctx = None
    ; seed = None
    ; previous_response_id = None
    ; connect_timeout_s = None
    ; max_concurrent_requests = None
    }
  in
  let url = gemini_url ~config ~stream:false in
  url = "https://gen.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
;;

let%test "gemini_url stream with api_key" =
  let config : Provider_config.t =
    { kind = Gemini
    ; provider_id = None
    ; model_id = "gemini-2.5-flash"
    ; base_url = "https://gen.googleapis.com/v1beta"
    ; api_key = Secret.of_string "mykey"
    ; request_path = ""
    ; headers = []
    ; system_prompt = None
    ; temperature = None
    ; max_tokens = Some 1024
    ; max_context = None
    ; max_request_body_bytes = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; clear_thinking = None
    ; tool_stream = false
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; response_format = Types.Off
    ; cache_system_prompt = false
    ; supports_tool_choice_override = None
    ; supports_structured_output_override = None
    ; model_capabilities_override = None
    ; keep_alive = None
    ; internal_model_rotation_count = None
    ; num_ctx = None
    ; seed = None
    ; previous_response_id = None
    ; connect_timeout_s = None
    ; max_concurrent_requests = None
    }
  in
  let url = gemini_url ~config ~stream:true in
  url
  = "https://gen.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
;;

let%test "gemini_url stream no api_key" =
  let config : Provider_config.t =
    { kind = Gemini
    ; provider_id = None
    ; model_id = "gemini-2.5-flash"
    ; base_url = "https://gen.googleapis.com/v1beta"
    ; api_key = Secret.empty
    ; request_path = ""
    ; headers = []
    ; system_prompt = None
    ; temperature = None
    ; max_tokens = Some 1024
    ; max_context = None
    ; max_request_body_bytes = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; clear_thinking = None
    ; tool_stream = false
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; response_format = Types.Off
    ; cache_system_prompt = false
    ; supports_tool_choice_override = None
    ; supports_structured_output_override = None
    ; model_capabilities_override = None
    ; keep_alive = None
    ; internal_model_rotation_count = None
    ; num_ctx = None
    ; seed = None
    ; previous_response_id = None
    ; connect_timeout_s = None
    ; max_concurrent_requests = None
    }
  in
  let url = gemini_url ~config ~stream:true in
  url
  = "https://gen.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
;;

let%test "gemini_url never leaks api_key even when set" =
  let config : Provider_config.t =
    { kind = Gemini
    ; provider_id = None
    ; model_id = "gemini-2.5-flash"
    ; base_url = "https://gen.googleapis.com/v1beta"
    ; api_key = Secret.of_string "mykey"
    ; request_path = ""
    ; headers = []
    ; system_prompt = None
    ; temperature = None
    ; max_tokens = Some 1024
    ; max_context = None
    ; max_request_body_bytes = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; clear_thinking = None
    ; tool_stream = false
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; response_format = Types.Off
    ; cache_system_prompt = false
    ; supports_tool_choice_override = None
    ; supports_structured_output_override = None
    ; model_capabilities_override = None
    ; keep_alive = None
    ; internal_model_rotation_count = None
    ; num_ctx = None
    ; seed = None
    ; previous_response_id = None
    ; connect_timeout_s = None
    ; max_concurrent_requests = None
    }
  in
  let contains_substring haystack needle =
    let hlen = String.length haystack in
    let nlen = String.length needle in
    let rec scan i =
      if i + nlen > hlen
      then false
      else if String.sub haystack i nlen = needle
      then true
      else scan (i + 1)
    in
    scan 0
  in
  let url_sync = gemini_url ~config ~stream:false in
  let url_stream = gemini_url ~config ~stream:true in
  (not (contains_substring url_sync "mykey"))
  && not (contains_substring url_stream "mykey")
;;

let%test "gemini_url empty base_url no trailing slash" =
  let config : Provider_config.t =
    { kind = Gemini
    ; provider_id = None
    ; model_id = "gemini-2.5-flash"
    ; base_url = ""
    ; api_key = Secret.empty
    ; request_path = ""
    ; headers = []
    ; system_prompt = None
    ; temperature = None
    ; max_tokens = Some 1024
    ; max_context = None
    ; max_request_body_bytes = None
    ; top_p = None
    ; top_k = None
    ; min_p = None
    ; enable_thinking = None
    ; preserve_thinking = None
    ; thinking_budget = None
    ; reasoning_effort = None
    ; clear_thinking = None
    ; tool_stream = false
    ; tool_choice = None
    ; disable_parallel_tool_use = false
    ; response_format = Types.Off
    ; cache_system_prompt = false
    ; supports_tool_choice_override = None
    ; supports_structured_output_override = None
    ; model_capabilities_override = None
    ; keep_alive = None
    ; internal_model_rotation_count = None
    ; num_ctx = None
    ; seed = None
    ; previous_response_id = None
    ; connect_timeout_s = None
    ; max_concurrent_requests = None
    }
  in
  let url = gemini_url ~config ~stream:false in
  url = "/models/gemini-2.5-flash:generateContent"
;;
