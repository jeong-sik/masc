(** Response cache interface for LLM completions. *)

type t =
  { get : key:string -> Yojson.Safe.t option
  ; set : key:string -> ttl_sec:int -> Yojson.Safe.t -> unit
  }

(* ── Fingerprint ────────────────────────────────────── *)

let message_fingerprint (m : Types.message) : Yojson.Safe.t =
  `Assoc
    [ "role", `String (Types.role_to_string m.role)
    ; "content", `List (List.map Api_common.content_block_to_json m.content)
    ]
;;

let opt_json f = function
  | None -> `Null
  | Some v -> f v
;;

(* The key decides whether a stored response may answer a later request, so
   every field that changes what the provider is asked must reach it. The
   record is destructured field by field with warning 9 on: a field added to
   [Provider_config.t] stops the build here until someone decides which side
   it is on. Over-separating only costs a cache hit; under-separating returns
   a response produced under a different request (#27906). *)
let request_fingerprint
      ~(config : Provider_config.t)
      ~(messages : Types.message list)
      ?(tools = [])
      ()
  =
  let[@warning "+9"] { Provider_config.kind
                     ; provider_id
                     ; model_id
                     ; base_url
                     ; api_key
                     ; headers
                     ; request_path
                     ; max_tokens
                     ; max_context
                     ; max_request_body_bytes
                     ; temperature
                     ; top_p
                     ; top_k
                     ; min_p
                     ; system_prompt
                     ; enable_thinking
                     ; preserve_thinking
                     ; thinking_budget
                     ; reasoning_effort
                     ; clear_thinking
                     ; tool_stream
                     ; tool_choice
                     ; disable_parallel_tool_use
                     ; response_format
                     ; cache_system_prompt
                     ; cache_extended_ttl
                     ; supports_tool_choice_override
                     ; supports_structured_output_override
                     ; model_capabilities_override
                     ; keep_alive
                     ; return_progress
                     ; internal_model_rotation_count
                     ; num_ctx
                     ; seed
                     ; previous_response_id
                     ; connect_timeout_s
                     ; max_concurrent_requests
                     }
    =
    config
  in
  (* Excluded, and why. These do not change what the provider is asked:
     [max_request_body_bytes], [connect_timeout_s] and
     [max_concurrent_requests] are transport limits enforced on this side;
     [return_progress] and [tool_stream] select how the answer is delivered,
     not what is asked; [internal_model_rotation_count] is a local attempt
     counter; [supports_*_override] and [model_capabilities_override] gate
     which of the fields below may be sent at all, and those fields are
     already in the key. *)
  ignore max_request_body_bytes;
  ignore connect_timeout_s;
  ignore max_concurrent_requests;
  ignore return_progress;
  ignore tool_stream;
  ignore internal_model_rotation_count;
  ignore supports_tool_choice_override;
  ignore supports_structured_output_override;
  ignore model_capabilities_override;
  let json =
    `Assoc
      [ "kind", `String (Provider_config.string_of_provider_kind kind)
      ; "provider_id", opt_json (fun s -> `String s) provider_id
      ; "model_id", `String model_id
      ; "base_url", `String base_url
      ; ( "api_key_identity"
        , opt_json (fun id -> `Int (Secret.hash_identity id)) (Secret.identity api_key) )
      ; ( "headers"
        , `List
            (headers
             |> List.map (fun (k, v) -> `List [ `String k; `String v ])) )
      ; "request_path", `String request_path
      ; "max_tokens", opt_json (fun n -> `Int n) max_tokens
      ; "max_context", opt_json (fun n -> `Int n) max_context
      ; "temperature", opt_json (fun f -> `Float f) temperature
      ; "top_p", opt_json (fun f -> `Float f) top_p
      ; "top_k", opt_json (fun n -> `Int n) top_k
      ; "min_p", opt_json (fun f -> `Float f) min_p
      ; "system_prompt", opt_json (fun s -> `String s) system_prompt
      ; "enable_thinking", opt_json (fun b -> `Bool b) enable_thinking
      ; "preserve_thinking", opt_json (fun b -> `Bool b) preserve_thinking
      ; "thinking_budget", opt_json (fun n -> `Int n) thinking_budget
      ; ( "reasoning_effort"
        , opt_json (fun e -> `String (Reasoning_effort.to_string e)) reasoning_effort )
      ; "clear_thinking", opt_json (fun b -> `Bool b) clear_thinking
      ; "tool_choice", opt_json Types.tool_choice_to_json tool_choice
      ; "disable_parallel_tool_use", `Bool disable_parallel_tool_use
      ; "response_format", Types.response_format_to_json response_format
      ; "cache_system_prompt", `Bool cache_system_prompt
      ; "cache_extended_ttl", `Bool cache_extended_ttl
      ; "keep_alive", opt_json (fun s -> `String s) keep_alive
      ; "num_ctx", opt_json (fun n -> `Int n) num_ctx
      ; "seed", opt_json (fun n -> `Int n) seed
      ; "previous_response_id", opt_json (fun s -> `String s) previous_response_id
      ; "messages", `List (List.map message_fingerprint messages)
      ; "tools", `List tools
      ]
  in
  let canonical = Yojson.Safe.to_string json in
  Digest.string canonical |> Digest.to_hex
;;

(* ── Serialization ──────────────────────────────────── *)

let schema_version = "2"

(* stop_reason wire serialization is the SSOT [Types.stop_reason_to_string]
   (this module's former local copy was byte-identical). schema_version "2":
   [api_usage.input_tokens] became the inclusive prompt total (Anthropic wire
   normalization) — entries written under "1" hold exclusive input for
   Anthropic responses, so the version guard retires them instead of
   replaying mixed semantics. *)

(* Cache replay routes through [Types.stop_reason_of_string] so that a cached
   response parses identically to a live one. A local copy here previously
   diverged from the canonical parser (it never learned pause_turn/refusal/
   compaction/model_context_window_exceeded), so a cached PauseTurn replayed as
   [Unknown "pause_turn"]. *)
let response_to_json (resp : Types.api_response) : Yojson.Safe.t =
  let usage_json =
    match resp.usage with
    | Some u ->
      `Assoc
        [ "input_tokens", `Int u.input_tokens
        ; "output_tokens", `Int u.output_tokens
        ; "cache_creation_input_tokens", `Int u.cache_creation_input_tokens
        ; "cache_read_input_tokens", `Int u.cache_read_input_tokens
        ; ( "cost_usd"
          , match u.cost_usd with
            | Some cost -> `Float cost
            | None -> `Null )
        ]
    | None -> `Null
  in
  `Assoc
    [ "v", `String schema_version
    ; "id", `String resp.id
    ; "model", `String resp.model
    ; "stop_reason", `String (Types.stop_reason_to_string resp.stop_reason)
    ; "content", `List (List.map Api_common.content_block_to_json resp.content)
    ; "usage", usage_json
    ]
;;

let response_of_json (json : Yojson.Safe.t) : Types.api_response option =
  let open Yojson.Safe.Util in
  try
    let v = json |> member "v" |> to_string in
    if v <> schema_version
    then None
    else (
      let usage =
        match json |> member "usage" with
        | `Null -> None
        | u ->
          Some
            { Types.input_tokens = u |> member "input_tokens" |> to_int
            ; output_tokens = u |> member "output_tokens" |> to_int
            ; cache_creation_input_tokens =
                u |> member "cache_creation_input_tokens" |> to_int
            ; cache_read_input_tokens = u |> member "cache_read_input_tokens" |> to_int
            ; cost_usd = u |> member "cost_usd" |> to_float_option
            }
      in
      let content =
        json
        |> member "content"
        |> to_list
        |> List.filter_map Api_common.content_block_of_json
      in
      Some
        { Types.id = json |> member "id" |> to_string
        ; model = json |> member "model" |> to_string
        ; stop_reason =
            json |> member "stop_reason" |> to_string |> Types.stop_reason_of_string
        ; content
        ; usage
        ; telemetry = None
        })
  with
  | Yojson.Safe.Util.Type_error _ | Not_found | Yojson.Json_error _ -> None
;;
