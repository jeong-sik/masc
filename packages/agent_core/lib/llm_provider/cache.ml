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

(* Conservative caller and endpoint identity. Provider projection and catalog
   defaults are bound by [http_request_fingerprint] below; this component
   alone does not identify a completed HTTP request. The exhaustive config
   pattern keeps additions explicit. *)
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
                     ; credential_source
                     ; auth_scheme
                     ; api_key
                     ; headers
                     ; request_path
                     ; max_tokens
                     ; max_context
                     ; temperature
                     ; top_p
                     ; top_k
                     ; min_p
                     ; system_prompt
                     ; enable_thinking
                     ; preserve_thinking
                     ; reasoning_effort
                     ; reasoning_uncontrolled
                     ; clear_thinking
                     ; tool_stream
                     ; tool_choice
                     ; disable_parallel_tool_use
                     ; response_format
                     ; cache_system_prompt
                     ; cache_extended_ttl
                     ; model_capabilities_override
                     ; model_anthropic_thinking_control_override
                     ; request_policy_snapshot
                     ; keep_alive
                     ; return_progress
                     ; internal_model_rotation_count
                     ; num_ctx
                     ; seed
                     ; previous_response_id
                     ; connect_timeout_s
                     ; max_concurrent_requests
                     ; admission_priority_run_limit
                     ; admission_class
                     ; repeat_penalty
                     ; repeat_last_n
                     }
    =
    config
  in
  (* Excluded, and why. These do not change what the provider is asked:
     [connect_timeout_s], [max_concurrent_requests],
     [admission_priority_run_limit] and [admission_class] are transport
     limits and queueing enforced on this side;
     [return_progress] and [tool_stream] select how the answer is delivered,
     not what is asked; [internal_model_rotation_count] is a local attempt
     counter; capability overrides (including the Anthropic
     thinking-control override) and the request policy snapshot are
     reflected in the exact body bound by [http_request_fingerprint];
     [credential_source] is where the credential came from
     rather than what it is, and a refreshable one has no stable account
     identity in this snapshot -- Complete disables response caching for those
     before calling this function. [reasoning_uncontrolled] only says whether a
     request with no reasoning effort may be sent on a wire that reasons by
     itself; the request it admits is byte-for-byte the one with no effort,
     [reasoning_effort] is already in the key, and Complete runs that admission
     before the cache lookup, so a refused request never reaches the key. *)
  (* See the exclusion note above for why this one is not in the key. *)
  ignore credential_source;
  ignore connect_timeout_s;
  ignore max_concurrent_requests;
  ignore admission_priority_run_limit;
  ignore admission_class;
  ignore return_progress;
  ignore tool_stream;
  ignore internal_model_rotation_count;
  ignore model_capabilities_override;
  ignore model_anthropic_thinking_control_override;
  ignore request_policy_snapshot;
  ignore reasoning_uncontrolled;
  let json =
    `Assoc
      [ "kind", `String (Provider_config.string_of_provider_kind kind)
      ; "provider_id", opt_json (fun s -> `String s) provider_id
      ; "model_id", `String model_id
      ; "base_url", `String base_url
        (* Which header carries the credential. The identity below says whose
           credential it is, not how it is presented, and a provider that
           accepts one presentation and refuses the other would otherwise be
           answered from a response the other one earned. Over-separating costs
           a cache hit; this is the side the comment above puts that on. *)
      ; ( "auth_scheme"
        , `String
            (match auth_scheme with
             | Provider_config.Provider_default -> "provider_default"
             | Provider_config.Bearer_token -> "bearer_token") )
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

let http_request_fingerprint ~config ~messages ?(tools = []) ~http_codec ~body () =
  let canonical =
    `Assoc
      [ "request", `String (request_fingerprint ~config ~messages ~tools ())
      ; "http_codec", `String (Provider_http_codec.fingerprint_tag http_codec)
      ; "body", `String body
      ]
    |> Yojson.Safe.to_string
  in
  Digest.string canonical |> Digest.to_hex
;;

(* ── Serialization ──────────────────────────────────── *)

let schema_version = "3"

(* A cached response retains its original inference telemetry, including the
   source needed to persist signed reasoning. Incompatible payloads are misses;
   a cache hit must never manufacture provenance from the current config. *)

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
    ; "telemetry", opt_json Types.inference_telemetry_to_yojson resp.telemetry
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
        |> List.fold_left (fun result block ->
          Result.bind result (fun blocks ->
            Api_common.content_block_of_json_result block
            |> Result.map (fun decoded -> decoded :: blocks))) (Ok [])
        |> Result.map List.rev
        |> Result.to_option
      in
      let telemetry =
        match List.assoc "telemetry" (to_assoc json) with
        | `Null -> Some None
        | value ->
          Types.inference_telemetry_of_yojson value
          |> Result.to_option
          |> Option.map Option.some
      in
      match content, telemetry with
      | Some content, Some telemetry ->
        let response =
          { Types.id = json |> member "id" |> to_string
          ; model = json |> member "model" |> to_string
          ; stop_reason =
              json |> member "stop_reason" |> to_string |> Types.stop_reason_of_string
          ; content
          ; usage
          ; telemetry
          } in
        (match Types.assistant_message_of_response response with
         | Ok _ -> Some response
         | Error _ -> None)
      | None, _ | _, None -> None)
  with
  | Yojson.Safe.Util.Type_error _ | Not_found | Yojson.Json_error _ -> None
;;
