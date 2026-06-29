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

let parse_capabilities ~(path : string) (tbl : Otoml.t) : Runtime_schema.capabilities =
  let b key = Otoml.find_or ~default:false tbl Otoml.get_boolean [ key ] in
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
  { Runtime_schema.supports_inline_tools = b "supports-inline-tools"
  ; supports_runtime_mcp_tools = b "supports-runtime-mcp-tools"
  ; supports_runtime_tool_events = b "supports-runtime-tool-events"
  ; supports_runtime_mcp_http_headers = b "supports-runtime-mcp-http-headers"
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
       (* [providers.<id>.log] and [providers.<id>.healthcheck] sub-tables are
          parse-and-ignore: their fields were dropped from
          {!Runtime_schema.provider}, so they are neither read nor populated.
          Leaving them in a TOML file is not an error. *)
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
       (match connect_timeout_result with
        | Error errs -> Error errs
        | Ok connect_timeout_s ->
          Ok
            { Runtime_schema.id
            ; display_name
            ; protocol
            ; api_format
            ; transport
            ; is_non_interactive
            ; credentials
            ; capabilities
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

let parse_thinking_control_format ~(path : string) (raw : string)
  : (Runtime_schema.thinking_control_format, parse_error list) result
  =
  match String.lowercase_ascii (String.trim raw) with
  | "" | "none" | "no-thinking-control" | "no_thinking_control" ->
    Ok Runtime_schema.No_thinking_control
  | "thinking-object" | "thinking_object" -> Ok Runtime_schema.Thinking_object
  | "chat-template-kwargs" | "chat_template_kwargs" -> Ok Runtime_schema.Chat_template_kwargs
  | "chat-template-token" | "chat_template_token" -> Ok Runtime_schema.Chat_template_token
  | "reasoning-effort" | "reasoning_effort" -> Ok Runtime_schema.Reasoning_effort
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
             none|thinking-object|chat-template-kwargs|chat-template-token|reasoning-effort"
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
    match Otoml.find_opt tbl Otoml.get_string [ "thinking-control-format" ] with
    | None -> Ok Runtime_schema.No_thinking_control
    | Some raw -> parse_thinking_control_format ~path raw
  in
  Result.map
    (fun thinking_control_format ->
      { Runtime_schema.max_output_tokens = positive_int_opt_field "max-output-tokens"
      ; supports_tool_choice = b "supports-tool-choice"
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
      ; supports_caching = b "supports-caching"
      ; supports_prompt_caching = b "supports-prompt-caching"
      ; prompt_cache_alignment = positive_int_opt_field "prompt-cache-alignment"
      ; supports_top_k = b "supports-top-k"
      ; supports_min_p = b "supports-min-p"
      ; supports_seed = b "supports-seed"
      ; emits_usage_tokens = b_default_true "emits-usage-tokens"
      ; supports_computer_use = b "supports-computer-use"
      })
    thinking_control_format_result
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
    (* Default preserve-thinking to thinking-support: a model that can think
       should preserve its thinking trace for the dashboard interleaving unless
       it explicitly opts out. Previously this defaulted to false, so 28/30
       thinking-capable models in the catalog left it unset and the dashboard
       thinking-interleaving wiring stayed dormant (oas requests the provider
       without preserve/clear_thinking=false, so the provider clears or omits
       thinking and no ThinkingDelta reaches the SSE stream). Explicit
       preserve-thinking=false still opts out (e.g. Gemma4's own <|think|>
       chat-template path). *)
    let preserve_thinking =
      Otoml.find_or ~default:thinking_support tbl Otoml.get_boolean [ "preserve-thinking" ]
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
    Result.map
      (fun capabilities ->
        { Runtime_schema.id
        ; api_name
        ; tools_support
        ; max_context
        ; thinking_support
        ; preserve_thinking
        ; max_thinking_budget
        ; streaming
        ; capabilities
        ; match_prefixes
        })
      capabilities_result)
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
  let* max_concurrent = max_concurrent_result in
  let* price_input = price_input_result in
  let* price_output = price_output_result in
  let* keep_alive = keep_alive_result in
  let* num_ctx = num_ctx_result in
  Ok
    { Runtime_schema.provider_id
    ; model_id
    ; is_default
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
  ; cross_verifier_runtime_id : string option
  ; media_failover : string list
  }

let empty_runtime_section =
  { default_runtime_id = None
  ; librarian_runtime_id = None
  ; cross_verifier_runtime_id = None
  ; media_failover = []
  }
;;

let parse_runtime_string_leaf ~path ~key value =
  match value with
  | Otoml.TomlString value -> Ok value
  | _ -> Error (error path (key ^ " must be a string runtime id"))
;;

let parse_runtime_media_failover value =
  (* RFC-0265 — ordered runtime ids for modality-gated reroute. RFC-0145:
     narrow to the [Otoml.get_array] wrong-type exception; a malformed value
     degrades to [] (→ derive-from-declared-caps), and any id typo is caught
     loudly at load by {!Runtime.validate_media_failover}. *)
  try Otoml.get_array Otoml.get_string value with
  | Otoml.Type_error _ ->
    Log.Runtime.warn
      "runtime_toml: [runtime].media_failover — expected string array, ignoring";
    []
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
           | "cross_verifier" ->
             (match
                parse_runtime_string_leaf ~path:"runtime.cross_verifier" ~key value
              with
              | Ok cross_verifier_runtime_id ->
                { section with cross_verifier_runtime_id = Some cross_verifier_runtime_id },
                errs
              | Error e -> section, errs @ e)
           | "media_failover" ->
             { section with media_failover = parse_runtime_media_failover value }, errs
           | "assignments" ->
             (* Parsed by [parse_keeper_assignments], including table-shape
                validation. It is still recognized here so a malformed scalar
                does not get reported as an unknown key first. *)
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
                       cross_verifier, media_failover, [runtime.assignments], or \
                       a table-valued [runtime.<profile>]"
                      key) )
        )
        (empty_runtime_section, [])
        entries
    in
    if errs <> [] then Error errs else Ok section
  | Some _ -> Error (error "runtime" "[runtime] must be a TOML table")
;;

let parse_toml (toml : Otoml.t) : (Runtime_schema.config, parse_error list) result =
  let providers_result = parse_providers toml in
  let models_result = parse_models toml in
  let runtime_section_result = parse_runtime_section toml in
  let assignments_result = parse_keeper_assignments toml in
  let bindings_result = parse_bindings toml in
  let errs = function Ok _ -> [] | Error errs -> errs in
  let all_errors =
    errs providers_result
    @ errs models_result
    @ errs runtime_section_result
    @ errs assignments_result
    @ errs bindings_result
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
    let pause_threshold = parse_pause_threshold toml in
    Ok
      { Runtime_schema.providers
      ; models
      ; bindings
      ; default_runtime_id = runtime_section.default_runtime_id
      ; librarian_runtime_id = runtime_section.librarian_runtime_id
      ; cross_verifier_runtime_id = runtime_section.cross_verifier_runtime_id
      ; keeper_assignments
      ; media_failover = runtime_section.media_failover
      ; pause_threshold
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
