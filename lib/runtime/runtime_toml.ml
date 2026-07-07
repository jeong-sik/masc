(** Declarative Runtime TOML parser.

    Re-homed from the deleted [Runtime_declarative_parser]. Parses RFC-0058
    layers 1-3 plus [[runtime].default] into a self-standing
    {!Runtime_schema.config}. Reserved top-level namespaces: providers,
    models, runtime, web_search (plus the dropped routing namespaces system,
    routes, profiles, which are still reserved so they are never mistaken for a
    provider table). Any other top-level table is a provider table, with
    sub-tables as model bindings.

    Routing layers are intentionally NOT parsed (see {!Runtime_toml} mli):
    Layer 4 aliases, Layer 5 routes/system/profiles, and the
    strategy/cycle-policy/scoring tables are dropped from
    {!Runtime_schema}, so this parser neither reads nor populates them. *)

type parse_error =
  { path : string
  ; message : string
  }
[@@deriving show]

(* --- Error accumulation --- *)

let error path message = [ { path; message } ]

(** [typed_find kind path tbl key getter] wraps [Otoml.find_opt] so that a
    type mismatch produces a structured [parse_error] instead of raising
    [Otoml.Type_error] past the parser boundary. *)
let typed_find (kind : string) (path : string) (tbl : Otoml.t) (key : string) getter
  : ('a option, parse_error list) result
  =
  try Ok (Otoml.find_opt tbl getter [ key ]) with
  | Otoml.Type_error msg ->
    Error
      (error
         (path ^ "." ^ key)
         (Printf.sprintf "%s must be %s; got %s" key kind msg))
;;

let strict_float_find (path : string) (tbl : Otoml.t) (key : string)
  : (float option, parse_error list) result
  =
  match Otoml.find_opt tbl Fun.id [ key ] with
  | None -> Ok None
  | Some (Otoml.TomlFloat value) -> Ok (Some value)
  | Some _ -> Error (error (path ^ "." ^ key) (key ^ " must be a float"))
;;

let positive_finite_float_opt_field
      ~(path : string)
      ~(key : string)
      (value_result : (float option, parse_error list) result)
  : (float option, parse_error list) result
  =
  match value_result with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when value > 0.0 && Float.is_finite value -> Ok (Some value)
  | Ok (Some value) ->
    Error
      (error
         (path ^ "." ^ key)
         (Printf.sprintf
            "%s must be a positive finite float; got %g"
            key
            value))
;;

let required_non_empty_string
      ?(trim_result = false)
      (tbl : Otoml.t)
      ~(path : string)
      ~(key : string)
      ~(message : string)
  : (string, parse_error list) result
  =
  match Otoml.find_opt tbl Otoml.get_string [ key ] with
  | Some value when String.trim value <> "" ->
    Ok (if trim_result then String.trim value else value)
  | Some _ | None -> Error (error (path ^ "." ^ key) message)
;;

(* Partition a list of per-entry parse results into a single
   collected result. Either every entry parsed (return [Ok all]),
   or at least one entry failed (return [Error] with every error
   concatenated). Removes the historical two-pass pattern where the
   success branch carried a dead [Error _ -> None] arm guarded by a
   prior [if errs <> []]: with this helper the dead arm cannot be
   written, so a future caller cannot accidentally re-introduce a
   silent drop. *)
let partition_results
  (results : ('a, parse_error list) result list)
  : ('a list, parse_error list) result
  =
  let oks, errs =
    List.partition_map
      (function
        | Ok x -> Either.Left x
        | Error e -> Either.Right e)
      results
  in
  if errs <> [] then Error (List.concat errs) else Ok oks
;;

(* --- Protocol string -> Runtime_schema.api_format --- *)

let canonical_protocol_of_protocol = function
  | "messages-cli" | "messages-http" | "openai-compatible-cli"
  | "openai-compatible-http" | "ollama-http" as protocol -> Some protocol
  | _ -> None
;;

let unknown_protocol_error s =
  Printf.sprintf
    "unknown protocol %S: expected one of messages-cli, messages-http, \
     openai-compatible-cli, openai-compatible-http, ollama-http"
    s
;;

let api_format_of_protocol (s : string)
  : (Runtime_schema.api_format, string) result
  =
  match s with
  | "messages-cli" | "messages-http" -> Ok Runtime_schema.Messages_api
  | "openai-compatible-cli" | "openai-compatible-http" ->
    Ok Runtime_schema.Chat_completions_api
  | "ollama-http" -> Ok Runtime_schema.Ollama_api
  | _ -> Error (unknown_protocol_error s)
;;

(* --- Transport extraction --- *)

let transport_of_provider (tbl : Otoml.t) (id : string)
  : (Runtime_schema.transport, string) result
  =
  let endpoint = Otoml.find_opt tbl Otoml.get_string [ "endpoint" ] in
  let command = Otoml.find_opt tbl Otoml.get_string [ "command" ] in
  match endpoint, command with
  | Some url, None -> Ok (Runtime_schema.Http url)
  | None, Some cmd -> Ok (Runtime_schema.Cli cmd)
  | Some _, Some _ ->
    Error (Printf.sprintf "provider %s: cannot specify both 'endpoint' and 'command'" id)
  | None, None ->
    Error (Printf.sprintf "provider %s: must specify either 'endpoint' or 'command'" id)
;;

(* --- Layer 1: Providers --- *)

let parse_credential (tbl : Otoml.t) (path : string)
  : (Runtime_schema.credential, parse_error list) result
  =
  match
    required_non_empty_string
      ~trim_result:true
      tbl
      ~path
      ~key:"type"
      ~message:"credential requires non-empty 'type'"
  with
  | Error errs -> Error errs
  | Ok cred_type ->
    (match cred_type with
     | "env" ->
       Result.map
         (fun key -> Runtime_schema.Env key)
         (required_non_empty_string
            ~trim_result:true
            tbl
            ~path
            ~key:"key"
            ~message:"credential type 'env' requires non-empty 'key'")
     | "file" ->
       Result.map
         (fun path -> Runtime_schema.File path)
         (required_non_empty_string
            ~trim_result:true
            tbl
            ~path
            ~key:"path"
            ~message:"credential type 'file' requires non-empty 'path'")
     | "inline" ->
       Result.map
         (fun value -> Runtime_schema.Inline value)
         (required_non_empty_string
            tbl
            ~path
            ~key:"value"
            ~message:"credential type 'inline' requires non-empty 'value'")
     | t -> Error (error (path ^ ".type") (Printf.sprintf "unknown credential type %S" t)))
;;

(* Deprecation notices fire once per process per [path.capabilities.key], not
   once per parse. runtime.toml is re-parsed on every keeper boot, so a per-parse
   warning flooded the WARN log — one observed day carried ~315 of these (25% of
   the live WARN volume) from a handful of deprecated capability keys across
   providers, drowning genuine warnings. The notice still surfaces once so an
   operator can remove the ignored field; only the per-parse repetition is
   dropped, so no signal is lost. *)
let deprecation_notice_seen : (string, unit) Hashtbl.t = Hashtbl.create 16
let deprecation_notice_seen_mu = Stdlib.Mutex.create ()

let parse_capabilities ~(path : string) (tbl : Otoml.t) : Runtime_schema.capabilities =
  let b key = Otoml.find_or ~default:false tbl Otoml.get_boolean [ key ] in
  let warn_deprecated key =
    match Otoml.find_opt tbl Fun.id [ key ] with
    | None -> ()
    | Some _ ->
      let notice_key = path ^ ".capabilities." ^ key in
      let should_warn =
        Stdlib.Mutex.protect deprecation_notice_seen_mu (fun () ->
          if Hashtbl.mem deprecation_notice_seen notice_key
          then false
          else (
            Hashtbl.replace deprecation_notice_seen notice_key ();
            true))
      in
      if should_warn
      then
        Log.Runtime.warn
          "runtime_toml: %s.capabilities.%s is deprecated and ignored; runtime-MCP capability is resolved from OAS provider bindings"
          path
          key
  in
  let string_list_field key =
    match Otoml.find_opt tbl Fun.id [ key ] with
    | None -> []
    | Some v ->
      (* RFC-0145 — narrow to the only exception [Otoml.get_array]
         raises on a wrong-typed value.  Unrelated runtime exceptions
         propagate. *)
      (try Otoml.get_array Otoml.get_string v with
       | Otoml.Type_error _ ->
         Log.Runtime.warn "runtime_toml: %s.capabilities.%s — expected string array, ignoring"
             path
             key;
         [])
  in
  let positive_int_opt_field key =
    (* Reject non-positive values at parse time: a cap of 0 or -N would
       clamp every attempt to a meaningless budget downstream. *)
    match Otoml.find_opt tbl Otoml.get_integer [ key ] with
    | None -> None
    | Some n when n > 0 -> Some n
    | Some n ->
      Log.Runtime.warn "runtime_toml: %s.capabilities.%s = %d — expected positive integer, ignoring"
          path
          key
          n;
      None
  in
  List.iter
    warn_deprecated
    [ "supports-runtime-mcp-tools"
    ; "supports-runtime-tool-events"
    ; "supports-runtime-mcp-http-headers"
    ];
  { Runtime_schema.supports_inline_tools = b "supports-inline-tools"
  ; requires_per_keeper_bridging_for_bound_actor_tools =
      b "requires-per-keeper-bridging-for-bound-actor-tools"
  ; identity_runtime_mcp_header_keys =
      string_list_field "identity-runtime-mcp-header-keys"
  ; argv_prompt_preflight = b "argv-prompt-preflight"
  ; uses_anthropic_caching = b "uses-messages-caching"
  ; max_turns_per_attempt = positive_int_opt_field "max-turns-per-attempt"
  ; tolerates_bound_actor_fallback = b "tolerates-bound-actor-fallback"
  }
;;

(** Parse a [providers.<id>.headers] sub-table into a sorted association
    list. Caller invokes only when the sub-table key exists, so the
    returned list distinguishes "declared but empty / all entries rejected"
    (empty list) from "no sub-table" (caller passes [None]).

    Non-table values at the sub-table position emit a WARN and yield an
    empty list. Non-string header values emit a per-entry WARN and are
    dropped. The result is sorted by key for deterministic show/eq. *)
let parse_headers (tbl : Otoml.t) (path : string) : (string * string) list =
  match Otoml.get_table tbl with
  (* RFC-0145 — narrow to the only exception [Otoml.get_table] raises
     on a non-table value.  Unrelated runtime exceptions propagate. *)
  | exception Otoml.Type_error _ ->
    Log.Runtime.warn "runtime_toml: %s — expected TOML table, got non-table value; treating as empty"
        path;
    []
  | entries ->
    let pairs =
      List.filter_map
        (fun (k, v) ->
           match Otoml.get_string v with
           | s -> Some (k, s)
           (* RFC-0145 — narrow to the only exception [Otoml.get_string]
              raises on a non-string value. *)
           | exception Otoml.Type_error _ ->
             Log.Runtime.warn "runtime_toml: %s.%s — non-string header value, ignoring" path k;
             None)
        entries
    in
    List.sort (fun (a, _) (b, _) -> String.compare a b) pairs
;;

let parse_provider (id : string) (tbl : Otoml.t)
  : (Runtime_schema.provider, parse_error list) result
  =
  let path = Printf.sprintf "providers.%s" id in
  let display_name =
    match Otoml.find_opt tbl Otoml.get_string [ "display-name" ] with
    | Some n -> n
    | None ->
      (match Otoml.find_opt tbl Otoml.get_string [ "provider-name" ] with
       | Some n -> n
       | None -> id)
  in
  let protocol_result =
    match Otoml.find_opt tbl Otoml.get_string [ "protocol" ] with
    | Some p ->
      (match api_format_of_protocol p with
       | Ok fmt ->
         (match canonical_protocol_of_protocol p with
          | Some protocol -> Ok (protocol, fmt)
          | None -> Error (unknown_protocol_error p))
       | Error e -> Error e)
    | None -> Error "missing required field 'protocol'"
  in
  let transport_result = transport_of_provider tbl id in
  match protocol_result, transport_result with
  | Error e, _ -> Error (error (path ^ ".protocol") e)
  | _, Error e -> Error (error path e)
  | Ok (protocol, api_format), Ok transport ->
    let is_non_interactive =
      Otoml.find_or ~default:false tbl Otoml.get_boolean [ "is-non-interactive" ]
    in
    let credentials_result =
      match Otoml.find_opt tbl Fun.id [ "credentials" ] with
      | Some cred_tbl ->
        Result.map Option.some (parse_credential cred_tbl (path ^ ".credentials"))
      | None -> Ok None
    in
    (match credentials_result with
     | Error errs -> Error errs
     | Ok credentials ->
       let capabilities =
         Otoml.find_opt tbl Fun.id [ "capabilities" ]
         |> Option.map (parse_capabilities ~path)
       in
       let healthcheck_result =
         match Otoml.find_opt tbl Fun.id [ "healthcheck" ] with
         | None -> Ok None
         | Some (Otoml.TomlTable _ | Otoml.TomlInlineTable _ as healthcheck_tbl) ->
           (match Otoml.find_opt healthcheck_tbl Otoml.get_string [ "path" ] with
            | None -> Ok None
            | Some healthcheck_path when String.length healthcheck_path > 0
                                      && Char.equal healthcheck_path.[0] '/' ->
              Ok (Some healthcheck_path)
            | Some healthcheck_path ->
              Error
                (error
                   (path ^ ".healthcheck.path")
                   (Printf.sprintf
                      "healthcheck.path must be absolute, got %S"
                      healthcheck_path)))
         | Some _ ->
           Error
             (error (path ^ ".healthcheck") "healthcheck must be a TOML table")
       in
       let headers =
         match Otoml.find_opt tbl Fun.id [ "headers" ] with
         | None -> None
         | Some h_tbl -> Some (parse_headers h_tbl (path ^ ".headers"))
       in
       (* Optional per-provider connect/headers timeout override (oas#2163).
          Absent (most providers) leaves the OAS kind-based default in force. *)
       let connect_timeout_key = Runtime_schema.connect_timeout_s_key in
       let connect_timeout_result =
         strict_float_find path tbl connect_timeout_key
         |> positive_finite_float_opt_field ~path ~key:connect_timeout_key
       in
       (match healthcheck_result, connect_timeout_result with
        | Error errs, _ | _, Error errs -> Error errs
        | Ok healthcheck_path, Ok connect_timeout_s ->
          Ok
            { Runtime_schema.id
            ; display_name
            ; protocol
            ; api_format
            ; transport
            ; is_non_interactive
            ; credentials
            ; capabilities
            ; healthcheck_path
            ; headers
            ; connect_timeout_s
            }))
;;

let parse_providers (toml : Otoml.t)
  : (Runtime_schema.provider list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "providers" ] with
  | None -> Ok []
  | Some providers_tbl ->
    let entries = Otoml.get_table providers_tbl in
    partition_results (List.map (fun (id, tbl) -> parse_provider id tbl) entries)
;;

(* --- Layer 2: Models --- *)

let thinking_control_token_key = "thinking-control-token"

let exact_non_empty_string_opt_field ~(path : string) (tbl : Otoml.t) (key : string)
  : (string option, parse_error list) result
  =
  match typed_find "string" path tbl key Otoml.get_string with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when String.trim value = "" ->
    Error (error (path ^ "." ^ key) (key ^ " must be non-empty"))
  | Ok (Some value) when value <> String.trim value ->
    Error (error (path ^ "." ^ key) (key ^ " must not have leading or trailing whitespace"))
  | Ok (Some value) -> Ok (Some value)
;;

let require_no_thinking_control_token
      ~(path : string)
      ~(thinking_control_format : string)
      (thinking_control_token : string option)
      (format : Runtime_schema.thinking_control_format)
  : (Runtime_schema.thinking_control_format, parse_error list) result
  =
  match thinking_control_token with
  | None -> Ok format
  | Some _ ->
    Error
      (error
         (path ^ "." ^ thinking_control_token_key)
         (Printf.sprintf
            "thinking-control-token is only valid when thinking-control-format \
             is \"chat_template_token\"; got %S"
            thinking_control_format))
;;

let parse_thinking_control_format
      ~(path : string)
      ~(thinking_control_token : string option)
      (raw : string)
  : (Runtime_schema.thinking_control_format, parse_error list) result
  =
  match String.lowercase_ascii (String.trim raw) with
  | "" | "none" | "no-thinking-control" | "no_thinking_control" ->
    require_no_thinking_control_token
      ~path
      ~thinking_control_format:"none"
      thinking_control_token
      Runtime_schema.No_thinking_control
  | "thinking-object" | "thinking_object" ->
    require_no_thinking_control_token
      ~path
      ~thinking_control_format:"thinking_object"
      thinking_control_token
      Runtime_schema.Thinking_object
  | "thinking-object-only" | "thinking_object_only" ->
    require_no_thinking_control_token
      ~path
      ~thinking_control_format:"thinking_object_only"
      thinking_control_token
      Runtime_schema.Thinking_object_only
  | "chat-template-kwargs" | "chat_template_kwargs" ->
    require_no_thinking_control_token
      ~path
      ~thinking_control_format:"chat_template_kwargs"
      thinking_control_token
      Runtime_schema.Chat_template_kwargs
  | "chat-template-token" | "chat_template_token" ->
    (match thinking_control_token with
     | Some token -> Ok (Runtime_schema.Chat_template_token token)
     | None ->
       Error
         (error
            (path ^ "." ^ thinking_control_token_key)
            "thinking-control-token is required when thinking-control-format is \
             \"chat_template_token\""))
  | "ollama-think" | "ollama_think" ->
    require_no_thinking_control_token
      ~path
      ~thinking_control_format:"ollama_think"
      thinking_control_token
      Runtime_schema.Ollama_think
  | "reasoning-effort" | "reasoning_effort" ->
    require_no_thinking_control_token
      ~path
      ~thinking_control_format:"reasoning_effort"
      thinking_control_token
      Runtime_schema.Reasoning_effort
  | "enable-thinking" | "enable_thinking" ->
    require_no_thinking_control_token
      ~path
      ~thinking_control_format:"enable_thinking"
      thinking_control_token
      Runtime_schema.Enable_thinking
  | other ->
    (* Unknown enum members fail the load, mirroring how this parser already
       rejects unknown protocols / credential types. A silent downgrade to
       No_thinking_control hid config typos that disable thinking control for a
       model that needs it. *)
    Error
      (error
         (path ^ ".thinking-control-format")
         (Printf.sprintf
            "unknown thinking-control-format %S — expected one of \
             none|thinking-object|thinking-object-only|chat-template-kwargs|chat-template-token|ollama-think|reasoning-effort|enable-thinking"
            other))
;;

let parse_model_capabilities ~(path : string) (tbl : Otoml.t)
  : (Runtime_schema.model_capabilities, parse_error list) result
  =
  let b key = Otoml.find_or ~default:false tbl Otoml.get_boolean [ key ] in
  let b_default_true key = Otoml.find_or ~default:true tbl Otoml.get_boolean [ key ] in
  let positive_int_opt_field key =
    match Otoml.find_opt tbl Otoml.get_integer [ key ] with
    | None -> None
    | Some n when n > 0 -> Some n
    | Some n ->
      Log.Runtime.warn "runtime_toml: %s.capabilities.%s = %d — expected positive integer, ignoring"
          path
          key
          n;
      None
  in
  let thinking_control_format_result =
    match
      ( typed_find "string" path tbl "thinking-control-format" Otoml.get_string
      , exact_non_empty_string_opt_field ~path tbl thinking_control_token_key )
    with
    | Error errs, _ | _, Error errs -> Error errs
    | Ok None, Ok None -> Ok Runtime_schema.No_thinking_control
    | Ok None, Ok (Some token) ->
      require_no_thinking_control_token
        ~path
        ~thinking_control_format:"none"
        (Some token)
        Runtime_schema.No_thinking_control
    | Ok (Some raw), Ok thinking_control_token ->
      parse_thinking_control_format ~path ~thinking_control_token raw
  in
  Result.map
    (fun thinking_control_format ->
      { Runtime_schema.max_output_tokens = positive_int_opt_field "max-output-tokens"
      ; supports_tool_choice = b "supports-tool-choice"
      ; supports_required_tool_choice = b "supports-required-tool-choice"
      ; supports_named_tool_choice = b "supports-named-tool-choice"
      ; supports_parallel_tool_calls = b "supports-parallel-tool-calls"
      ; supports_extended_thinking = b "supports-extended-thinking"
      ; supports_reasoning_budget = b "supports-reasoning-budget"
      ; thinking_control_format
      ; supports_image_input = b "supports-image-input"
      ; supports_audio_input = b "supports-audio-input"
      ; supports_video_input = b "supports-video-input"
      ; supports_multimodal_inputs = b "supports-multimodal-inputs"
      ; supports_response_format_json = b "supports-response-format-json"
      ; supports_structured_output = b "supports-structured-output"
      ; supports_native_streaming = b "supports-native-streaming"
      ; supports_system_prompt = b "supports-system-prompt"
      ; supports_caching = b "supports-caching"
      ; supports_prompt_caching = b "supports-prompt-caching"
      ; prompt_cache_alignment = positive_int_opt_field "prompt-cache-alignment"
      ; supports_top_k = b "supports-top-k"
      ; supports_min_p = b "supports-min-p"
      ; supports_seed = b "supports-seed"
      ; supports_seed_with_images = b "supports-seed-with-images"
      ; emits_usage_tokens = b_default_true "emits-usage-tokens"
      ; supports_computer_use = b "supports-computer-use"
      ; supports_code_execution = b "supports-code-execution"
      })
    thinking_control_format_result
;;

(* LLM sampling temperature bounds. OpenAI/Kimi/DeepSeek accept [0.0, 2.0]; a
   value outside this range is a config error, not something to silently clamp.
   0.0 (greedy) is valid, so temperature is NOT parsed through the
   positive-float path. *)
let temperature_min = 0.0
let temperature_max = 2.0
let probability_min = 0.0
let probability_max = 1.0

let number_opt_field ~(path : string) ~(key : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  match Otoml.find_opt tbl Fun.id [ key ] with
  | None -> Ok None
  | Some value ->
    let as_float =
      match value with
      | Otoml.TomlFloat v -> Some v
      | Otoml.TomlInteger v -> Some (float_of_int v)
      | _ -> None
    in
    (match as_float with
     | None -> Error (error (path ^ "." ^ key) (key ^ " must be a number"))
     | Some value -> Ok (Some value))
;;

let bounded_number_opt_field
      ~(path : string)
      ~(key : string)
      ~(lower : float)
      ~(upper : float)
      (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  match number_opt_field ~path ~key tbl with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when Float.is_finite value && value >= lower && value <= upper ->
    Ok (Some value)
  | Ok (Some value) ->
    Error
      (error
         (path ^ "." ^ key)
         (Printf.sprintf
            "%s must be a finite number in [%g, %g]; got %g"
            key
            lower
            upper
            value))
;;

(* Read the optional per-model [temperature]. A TOML integer (1) or float (1.0)
   both read as a float so an operator is not tripped by "1 vs 1.0". Absent →
   [Ok None] (caller keeps its fallback). Wrong type or out of
   [temperature_min, temperature_max] → parse error: reject at load rather than
   send an out-of-range value the provider would reject at request time. *)
let temperature_opt_field ~(path : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  bounded_number_opt_field
    ~path
    ~key:"temperature"
    ~lower:temperature_min
    ~upper:temperature_max
    tbl
;;

let probability_opt_field ~(path : string) ~(key : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  bounded_number_opt_field
    ~path
    ~key
    ~lower:probability_min
    ~upper:probability_max
    tbl
;;

let positive_int_opt_field ~(path : string) ~(key : string) (tbl : Otoml.t)
  : (int option, parse_error list) result
  =
  match typed_find "an integer" path tbl key Otoml.get_integer with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when value > 0 -> Ok (Some value)
  | Ok (Some value) ->
       Error
         (error
            (path ^ "." ^ key)
            (Printf.sprintf
               "%s must be a positive integer; got %d"
               key
               value))
;;

let sampling_capability_errors
      ~(path : string)
      ~(capabilities : Runtime_schema.model_capabilities option)
      ~(top_k : int option)
      ~(min_p : float option)
  : parse_error list
  =
  match capabilities with
  | None -> []
  | Some capabilities ->
    let top_k_errors =
      match top_k with
      | Some _ when not capabilities.supports_top_k ->
        error
          (path ^ ".top-k")
          (Printf.sprintf
             "top-k is set but %s.capabilities.supports-top-k is false"
             path)
      | Some _ | None -> []
    in
    let min_p_errors =
      match min_p with
      | Some _ when not capabilities.supports_min_p ->
        error
          (path ^ ".min-p")
          (Printf.sprintf
             "min-p is set but %s.capabilities.supports-min-p is false"
             path)
      | Some _ | None -> []
    in
    top_k_errors @ min_p_errors
;;

let parse_model (id : string) (tbl : Otoml.t)
  : (Runtime_schema.model_spec, parse_error list) result
  =
  let path = Printf.sprintf "models.%s" id in
  let api_name =
    match Otoml.find_opt tbl Otoml.get_string [ "api-name" ] with
    | Some n -> n
    | None ->
      (match Otoml.find_opt tbl Otoml.get_string [ "model-name" ] with
       | Some n -> n
       | None -> id)
  in
  let max_context = Otoml.find_or ~default:(-1) tbl Otoml.get_integer [ "max-context" ] in
  if max_context <= 0
  then Error (error (path ^ ".max-context") "missing or invalid max-context")
  else (
    let tools_support =
      Otoml.find_or ~default:false tbl Otoml.get_boolean [ "tools-support" ]
    in
    let thinking_support =
      Otoml.find_or ~default:false tbl Otoml.get_boolean [ "thinking-support" ]
    in
    let preserve_thinking =
      Otoml.find_opt tbl Otoml.get_boolean [ "preserve-thinking" ]
    in
    let max_thinking_budget =
      Otoml.find_opt tbl Otoml.get_integer [ "max-thinking-budget" ]
    in
    let streaming = Otoml.find_or ~default:true tbl Otoml.get_boolean [ "streaming" ] in
    let capabilities_result =
      match Otoml.find_opt tbl Fun.id [ "capabilities" ] with
      | None -> Ok None
      | Some t ->
        Result.map Option.some (parse_model_capabilities ~path:(path ^ ".capabilities") t)
    in
    let match_prefixes =
      match Otoml.find_opt tbl Fun.id [ "match-prefixes" ] with
      | None -> []
      | Some v ->
        (* RFC-0145 — narrow to the only exception [Otoml.get_array]
           raises on a wrong-typed value.  Unrelated runtime exceptions
           propagate. *)
        (try
           Otoml.get_array Otoml.get_string v
           |> List.filter_map (fun s ->
             let trimmed = String.trim s in
             if String.length trimmed = 0
             then (
               Log.Runtime.warn "runtime_toml: %s.match-prefixes contains empty entry, ignoring" path;
               None)
             else Some trimmed)
         with
         | Otoml.Type_error _ ->
           Log.Runtime.warn "runtime_toml: %s.match-prefixes — expected string array, ignoring" path;
           [])
    in
    let temperature_result = temperature_opt_field ~path tbl in
    let top_p_result = probability_opt_field ~path ~key:"top-p" tbl in
    let top_k_result = positive_int_opt_field ~path ~key:"top-k" tbl in
    let min_p_result = probability_opt_field ~path ~key:"min-p" tbl in
    let ( let* ) = Result.bind in
    let* capabilities = capabilities_result in
    let* temperature = temperature_result in
    let* top_p = top_p_result in
    let* top_k = top_k_result in
    let* min_p = min_p_result in
    match sampling_capability_errors ~path ~capabilities ~top_k ~min_p with
    | _ :: _ as errors -> Error errors
    | [] ->
      Ok
        { Runtime_schema.id
        ; api_name
        ; tools_support
        ; max_context
        ; thinking_support
        ; preserve_thinking
        ; max_thinking_budget
        ; streaming
        ; temperature
        ; top_p
        ; top_k
        ; min_p
        ; capabilities
        ; match_prefixes
        })
;;

let parse_models (toml : Otoml.t)
  : (Runtime_schema.model_spec list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "models" ] with
  | None -> Ok []
  | Some models_tbl ->
    let entries = Otoml.get_table models_tbl in
    partition_results (List.map (fun (id, tbl) -> parse_model id tbl) entries)
;;

(* --- Reserved namespace detection --- *)

(* The dropped routing namespaces (system, routes, profiles) remain
   reserved: keeping them out of the provider-table scan ensures a stale
   [[routes]]/[[profiles]] table in an existing runtime.toml is silently
   ignored rather than misread as a provider with bogus model bindings. *)
let reserved_namespaces =
  [ "providers"; "models"; "system"; "routes"; "profiles"; "runtime"; "web_search" ]
;;

let is_reserved (name : string) : bool = List.mem name reserved_namespaces

(* --- Layer 3: Bindings from provider tables --- *)

(* [Otoml.t] is a 3rd-party closed variant with 12 value constructors;
   this parser only ever distinguishes "table-shaped" (TomlTable /
   TomlInlineTable) from everything else. Enumerating the other 10 once
   here satisfies warning 4 and means an [otoml] version bump that adds a
   value constructor breaks exactly this site rather than a dozen call
   sites. *)
let is_toml_table : Otoml.t -> bool = function
  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> true
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ -> false

let parse_binding_fields (provider_id : string) (model_id : string) (tbl : Otoml.t)
  : (Runtime_schema.binding, parse_error list) result
  =
  let path = Printf.sprintf "%s.%s" provider_id model_id in
  (* [max-concurrent] is an explicit operator override, not a required binding
     property. Absence means "no static client-side cap"; provider pressure is
     handled by the global provider HTTP gate, live health/backoff, and any
     provider-reported throttling.

     An explicit non-positive value is a configuration error: 0 was historically
     used as an omission sentinel, and negative values are meaningless. Reject
     them at load time rather than silently downgrading to "no cap". *)
  let is_default_result = typed_find "a boolean" path tbl "is-default" Otoml.get_boolean in
  let wizard_default_result =
    typed_find "a boolean" path tbl "wizard-default" Otoml.get_boolean
  in
  let max_concurrent_result =
    match typed_find "an integer" path tbl "max-concurrent" Otoml.get_integer with
    | Ok None -> Ok None
    | Ok (Some n) when n > 0 -> Ok (Some n)
    | Ok (Some n) ->
      Error
        (error
           (path ^ ".max-concurrent")
           (Printf.sprintf
              "max-concurrent must be a positive integer or omitted for no static cap; got %d"
              n))
    | Error _ as e -> e
  in
  let price_input_result = typed_find "a float" path tbl "price-input" Otoml.get_float in
  let price_output_result = typed_find "a float" path tbl "price-output" Otoml.get_float in
  let keep_alive_result = typed_find "a string" path tbl "keep-alive" Otoml.get_string in
  let num_ctx_result = typed_find "an integer" path tbl "num-ctx" Otoml.get_integer in
  let ( let* ) = Result.bind in
  let* is_default_opt = is_default_result in
  let is_default = Option.value is_default_opt ~default:false (* DET-OK: fallback to false if omitted *) in
  let* wizard_default_opt = wizard_default_result in
  let wizard_default =
    Option.value wizard_default_opt ~default:false
    (* DET-OK: omitted means not selected for install wizard. *)
  in
  let* max_concurrent = max_concurrent_result in
  let* price_input = price_input_result in
  let* price_output = price_output_result in
  let* keep_alive = keep_alive_result in
  let* num_ctx = num_ctx_result in
  Ok
    { Runtime_schema.provider_id
    ; model_id
    ; is_default
    ; wizard_default
    ; max_concurrent
    ; price_input
    ; price_output
    ; keep_alive
    ; num_ctx
    }
;;

(* Parse one provider table ([<provider>.*]) into its Layer-3 bindings.
   Each direct sub-key is a model binding. Layer-4 aliases ([<p>.<m>.<a>])
   are dropped: when a model entry contains nested sub-tables (the former
   alias declarations), only the model's own leaf fields are used to build
   the binding; the nested sub-tables are ignored. *)
let parse_provider_table (provider_id : string) (tbl : Otoml.t)
  : (Runtime_schema.binding list, parse_error list) result
  =
  let entries = Otoml.get_table tbl in
  partition_results
    (List.map
       (fun (model_id, sub) ->
          if is_toml_table sub
          then (
            (* [sub] is TomlTable/TomlInlineTable (per [is_toml_table]); both
               unwrap to a (key, value) list via [Otoml.get_table]. The
               nested sub-tables (Layer-4 aliases) are filtered out so the
               binding is built from this model's own leaf fields only. *)
            let fields = Otoml.get_table sub in
            let leaf_fields = List.filter (fun (_, v) -> not (is_toml_table v)) fields in
            let synthetic_tbl = Otoml.TomlTable leaf_fields in
            parse_binding_fields provider_id model_id synthetic_tbl)
          else parse_binding_fields provider_id model_id sub)
       entries)
;;

let parse_bindings (toml : Otoml.t)
  : (Runtime_schema.binding list, parse_error list) result
  =
  let top_entries = Otoml.get_table toml in
  (* Only top-level tables can describe a provider; scalar / array entries
     (e.g. an operator-authored ["comment = ..."]) would crash
     [Otoml.get_table] in [parse_provider_table]. *)
  let provider_tables =
    List.filter
      (fun (name, value) -> (not (is_reserved name)) && is_toml_table value)
      top_entries
  in
  Result.map
    List.concat
    (partition_results
       (List.map
          (fun (provider_id, tbl) -> parse_provider_table provider_id tbl)
          provider_tables))
;;

(* --- Top-level parse --- *)

(* Extract the [Ok] payload from a parse result that the caller has
   just proven via the [all_errors = []] guard. The [Error _] branch
   is statically unreachable; reaching it indicates a refactor has
   desynchronized the collect site from the extraction site. Crash with
   [invalid_arg] rather than silently substituting an empty list,
   which would mask a corrupt config. *)
let extract_after_all_errors_guard ~label = function
  | Ok x -> x
  | Error _ ->
    invalid_arg
      (Printf.sprintf
         "runtime_toml.parse_toml: %s — guarded extraction reached Error branch; \
          collect/extract desync"
         label)
;;

(* [[runtime.assignments]] — keeper name → runtime id ["provider.model"]. The
   sole SSOT for keeper→runtime assignment (persona⊥{model,runtime}). Each
   value must be a TOML string (an opaque runtime id resolved later against the
   binding list at {!Runtime.load_list}). A non-string value is a parse error,
   not a silent drop — an operator typo (e.g. an inline table) must fail loud
   rather than route the keeper to the default. *)
let parse_keeper_assignments (toml : Otoml.t)
  : ((string * string) list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "runtime"; "assignments" ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    let oks, errs =
      List.partition_map
        (fun (keeper_name, value) ->
          match value with
          | Otoml.TomlString runtime_id -> Left (keeper_name, runtime_id)
          | _ ->
            Right
              { path = Printf.sprintf "runtime.assignments.%s" keeper_name
              ; message = "keeper runtime assignment must be a string runtime id"
              })
        entries
    in
    if errs <> [] then Error errs else Ok oks
  | Some _ ->
    Error
      [ { path = "runtime.assignments"
        ; message = "[runtime.assignments] must be a table of keeper = runtime-id"
        }
      ]
;;

(* [\[pause\]] section → typed [Runtime_schema.pause_threshold].

   Fails soft: a malformed value (e.g. wrong type) is logged + ignored rather
   than aborting config load, mirroring the existing [runtime].media_failover
   pattern above. Missing section / missing keys → [pause_threshold_default],
   which mirrors the legacy fallback values in [Keeper_behavioral_regime.ml].
   Operational pause paths consume this through [Runtime.pause_threshold]. *)
let parse_pause_threshold (toml : Otoml.t) : Runtime_schema.pause_threshold =
  let read_field ~path ~key ~getter =
    try
      Ok (Otoml.find_opt toml getter [ path; key ])
    with
    | Otoml.Type_error msg ->
      Error (Printf.sprintf "[%s].%s: %s" path key msg)
  in
  let pick_int ~path ~key ~default =
    match read_field ~path ~key ~getter:Otoml.get_integer with
    | Ok (Some v) -> v
    | Ok None -> default
    | Error msg ->
      Log.Runtime.warn
        "runtime_toml: %s — using default %d" msg default;
      default
  in
  let pick_float ~path ~key ~default =
    match read_field ~path ~key ~getter:Otoml.get_float with
    | Ok (Some v) -> v
    | Ok None -> default
    | Error msg ->
      Log.Runtime.warn
        "runtime_toml: %s — using default %g" msg default;
      default
  in
  let d = Runtime_schema.pause_threshold_default in
  { turn_fail_streak_threshold =
      pick_int
        ~path:"pause" ~key:"turn_fail_streak_threshold"
        ~default:d.turn_fail_streak_threshold
  ; recent_restart_window_sec =
      pick_float
        ~path:"pause" ~key:"recent_restart_window_sec"
        ~default:d.recent_restart_window_sec
  ; recent_restart_count_threshold =
      pick_int
        ~path:"pause" ~key:"recent_restart_count_threshold"
        ~default:d.recent_restart_count_threshold
  ; tool_failure_count_threshold =
      pick_int
        ~path:"pause" ~key:"tool_failure_count_threshold"
        ~default:d.tool_failure_count_threshold
  ; tool_failure_ratio_threshold =
      pick_float
        ~path:"pause" ~key:"tool_failure_ratio_threshold"
        ~default:d.tool_failure_ratio_threshold
  }
;;

type runtime_section =
  { default_runtime_id : string option
  ; librarian_runtime_id : string option
  ; structured_judge_runtime_id : string option
  ; cross_verifier_runtime_id : string option
  ; media_failover : string list
  }

let empty_runtime_section =
  { default_runtime_id = None
  ; librarian_runtime_id = None
  ; structured_judge_runtime_id = None
  ; cross_verifier_runtime_id = None
  ; media_failover = []
  }
;;

let parse_runtime_string_leaf ~path ~key value =
  match value with
  | Otoml.TomlString value -> Ok value
  | _ -> Error (error path (key ^ " must be a string runtime id"))
;;

let parse_runtime_media_failover ~path value =
  (* RFC-0265 — ordered runtime ids for modality-gated reroute. A genuine type
     mismatch (a scalar where an ordered array is required — a bare string cannot
     mean a list) is surfaced as a load [Error], consistent with the sibling
     string leaves ({!parse_runtime_string_leaf}), instead of silently degrading
     to [] (the repo's Unknown→Permissive anti-pattern). An explicit empty array
     [] is preserved as the intentional derive-from-declared-caps signal; id typos
     in a well-typed array are still caught loudly by
     {!Runtime.validate_media_failover}. *)
  try Ok (Otoml.get_array Otoml.get_string value) with
  | Otoml.Type_error msg ->
    Error
      (error
         path
         (Printf.sprintf "media_failover must be an array of string runtime ids; got %s" msg))
;;

let parse_runtime_section (toml : Otoml.t) : (runtime_section, parse_error list) result =
  match Otoml.find_opt toml Fun.id [ "runtime" ] with
  | None -> Ok empty_runtime_section
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    let section, errs =
      List.fold_left
        (fun (section, errs) (key, value) ->
           match key with
           | "default" ->
             (match parse_runtime_string_leaf ~path:"runtime.default" ~key value with
              | Ok default_runtime_id ->
                { section with default_runtime_id = Some default_runtime_id }, errs
              | Error e -> section, errs @ e)
           | "librarian" ->
             (match parse_runtime_string_leaf ~path:"runtime.librarian" ~key value with
              | Ok librarian_runtime_id ->
                { section with librarian_runtime_id = Some librarian_runtime_id }, errs
              | Error e -> section, errs @ e)
           | "structured_judge" ->
             (match
                parse_runtime_string_leaf ~path:"runtime.structured_judge" ~key value
              with
              | Ok structured_judge_runtime_id ->
                ( { section with
                    structured_judge_runtime_id = Some structured_judge_runtime_id
                  }
                , errs )
              | Error e -> section, errs @ e)
           | "cross_verifier" ->
             (match
                parse_runtime_string_leaf ~path:"runtime.cross_verifier" ~key value
              with
              | Ok cross_verifier_runtime_id ->
                { section with cross_verifier_runtime_id = Some cross_verifier_runtime_id },
                errs
              | Error e -> section, errs @ e)
           | "media_failover" ->
             (match parse_runtime_media_failover ~path:"runtime.media_failover" value with
              | Ok media_failover -> { section with media_failover }, errs
              | Error e -> section, errs @ e)
           | "assignments" ->
             (* Parsed by [parse_keeper_assignments], including table-shape
                validation. It is still recognized here so a malformed scalar
                does not get reported as an unknown key first. *)
             section, errs
           | "lanes" ->
             (* Parsed by [parse_lanes] after the runtime section is shaped. *)
             section, errs
           | _ when is_toml_table value ->
             (* [runtime.<profile>] tables are reserved for runtime profiles and
                intentionally ignored by this parser layer. *)
             section, errs
           | _ ->
             ( section
             , errs
               @ error
                   ("runtime." ^ key)
                   (Printf.sprintf
                      "unknown [runtime] key %S; expected default, librarian, \
                       cross_verifier, media_failover, [runtime.lanes], \
                       [runtime.assignments], or a table-valued [runtime.<profile>]"
                      key) )
        )
        (empty_runtime_section, [])
        entries
    in
    if errs <> [] then Error errs else Ok section
  | Some _ -> Error (error "runtime" "[runtime] must be a TOML table")
;;

(* [\[runtime.lanes.<id>\]] — ordered failover candidate lists. Each lane is a
   table with [strategy] (only "ordered" supported) and [candidates] (array of
   runtime ids). Candidate ids are resolved against materialized runtimes at
   load time, not here, so the parser returns declarations only. *)
let parse_lane ~(id : string) (tbl : Otoml.t)
  : (Runtime_schema.lane_decl, parse_error list) result
  =
  let path = Printf.sprintf "runtime.lanes.%s" id in
  let strategy_result =
    match Otoml.find_opt tbl Otoml.get_string [ "strategy" ] with
    | None | Some "ordered" -> Ok Runtime_schema.Ordered
    | Some other ->
      Error
        (error
           (path ^ ".strategy")
           (Printf.sprintf "unsupported lane strategy %S" other))
  in
  let candidate_ids_result =
    match Otoml.find_opt tbl Fun.id [ "candidates" ] with
    | None -> Error (error (path ^ ".candidates") "lane candidates is required")
    | Some value ->
      (try Ok (Otoml.get_array Otoml.get_string value) with
       | Otoml.Type_error msg ->
         Error
           (error
              (path ^ ".candidates")
              (Printf.sprintf
                 "lane candidates must be an array of string runtime ids; got %s"
                 msg)))
  in
  match strategy_result, candidate_ids_result with
  | Error e, _ | _, Error e -> Error e
  | Ok strategy, Ok candidate_ids ->
    if candidate_ids = []
    then Error (error path "lane must have at least one candidate")
    else Ok { Runtime_schema.id; strategy; candidate_ids }
;;

let parse_lanes (toml : Otoml.t) : (Runtime_schema.lane_decl list, parse_error list) result =
  match Otoml.find_opt toml Fun.id [ "runtime"; "lanes" ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    partition_results
      (List.map
         (fun (id, value) ->
            match value with
            | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> parse_lane ~id value
            | _ ->
              Error
                (error
                   (Printf.sprintf "runtime.lanes.%s" id)
                   "lane must be a table"))
         entries)
  | Some _ ->
    Error (error "runtime.lanes" "[runtime.lanes] must be a table of lane tables")
;;

let parse_toml (toml : Otoml.t) : (Runtime_schema.config, parse_error list) result =
  let providers_result = parse_providers toml in
  let models_result = parse_models toml in
  let runtime_section_result = parse_runtime_section toml in
  let assignments_result = parse_keeper_assignments toml in
  let bindings_result = parse_bindings toml in
  let lanes_result = parse_lanes toml in
  let errs = function Ok _ -> [] | Error errs -> errs in
  let all_errors =
    errs providers_result
    @ errs models_result
    @ errs runtime_section_result
    @ errs assignments_result
    @ errs bindings_result
    @ errs lanes_result
  in
  if all_errors <> []
  then Error all_errors
  else (
    let providers =
      extract_after_all_errors_guard ~label:"providers" providers_result
    in
    let models = extract_after_all_errors_guard ~label:"models" models_result in
    let keeper_assignments =
      extract_after_all_errors_guard ~label:"assignments" assignments_result
    in
    let bindings =
      extract_after_all_errors_guard ~label:"bindings" bindings_result
    in
    let runtime_section =
      extract_after_all_errors_guard ~label:"runtime" runtime_section_result
    in
    let lane_decls =
      extract_after_all_errors_guard ~label:"lanes" lanes_result
    in
    let pause_threshold = parse_pause_threshold toml in
    Ok
      { Runtime_schema.providers
      ; models
      ; bindings
      ; default_runtime_id = runtime_section.default_runtime_id
      ; librarian_runtime_id = runtime_section.librarian_runtime_id
      ; structured_judge_runtime_id = runtime_section.structured_judge_runtime_id
      ; cross_verifier_runtime_id = runtime_section.cross_verifier_runtime_id
      ; keeper_assignments
      ; media_failover = runtime_section.media_failover
      ; pause_threshold
      ; lane_decls
      })
;;

let parse_string (content : string) : (Runtime_schema.config, parse_error list) result =
  match Otoml.Parser.from_string_result content with
  | Ok toml -> parse_toml toml
  | Error msg -> Error [ { path = "<parse>"; message = msg } ]
;;

let parse_file (path : string) : (Runtime_schema.config, parse_error list) result =
  try
    let toml = Otoml.Parser.from_file path in
    parse_toml toml
  with
  | Otoml.Parse_error (_, msg) -> Error [ { path; message = msg } ]
  | Sys_error msg -> Error [ { path; message = msg } ]
;;
