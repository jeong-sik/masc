(** Declarative Runtime TOML parser.

    Re-homed from the deleted [Runtime_declarative_parser]. Parses RFC-0058
    layers 1-3 plus [[runtime].default] into a self-standing
    {!Runtime_schema.config}. Reserved top-level namespaces: providers,
    models, runtime (plus the dropped routing namespaces system, routes,
    profiles, which are still reserved so they are never mistaken for a
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
         })
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
  : Runtime_schema.thinking_control_format
  =
  match String.lowercase_ascii (String.trim raw) with
  | "" | "none" | "no-thinking-control" | "no_thinking_control" ->
    Runtime_schema.No_thinking_control
  | "thinking-object" | "thinking_object" -> Runtime_schema.Thinking_object
  | "chat-template-kwargs" | "chat_template_kwargs" -> Runtime_schema.Chat_template_kwargs
  | "chat-template-token" | "chat_template_token" -> Runtime_schema.Chat_template_token
  | "reasoning-effort" | "reasoning_effort" -> Runtime_schema.Reasoning_effort
  | other ->
    Log.Runtime.warn "runtime_toml: %s.capabilities.thinking-control-format = %S — expected one of \
         none|thinking-object|chat-template-kwargs|chat-template-token|reasoning-effort, defaulting to none"
        path
        other;
    Runtime_schema.No_thinking_control
;;

let parse_model_capabilities ~(path : string) (tbl : Otoml.t)
  : Runtime_schema.model_capabilities
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
  let thinking_control_format =
    match Otoml.find_opt tbl Otoml.get_string [ "thinking-control-format" ] with
    | None -> Runtime_schema.No_thinking_control
    | Some raw -> parse_thinking_control_format ~path raw
  in
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
  }
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
      Otoml.find_or ~default:false tbl Otoml.get_boolean [ "preserve-thinking" ]
    in
    let max_thinking_budget =
      Otoml.find_opt tbl Otoml.get_integer [ "max-thinking-budget" ]
    in
    let streaming = Otoml.find_or ~default:true tbl Otoml.get_boolean [ "streaming" ] in
    let capabilities =
      Otoml.find_opt tbl Fun.id [ "capabilities" ]
      |> Option.map (parse_model_capabilities ~path:(path ^ ".capabilities"))
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
    Ok
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
  [ "providers"; "models"; "system"; "routes"; "profiles"; "runtime" ]
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
  : Runtime_schema.binding
  =
  let is_default = Otoml.find_or ~default:false tbl Otoml.get_boolean [ "is-default" ] in
  (* RFC-0058 §3.4: max-concurrent is REQUIRED. The marker value 0
     here makes the omission visible to the validator instead of
     silently throttling every binding to 1. *)
  let max_concurrent =
    match Otoml.find_opt tbl Otoml.get_integer [ "max-concurrent" ] with
    | Some n -> n
    | None -> 0
  in
  let price_input = Otoml.find_opt tbl Otoml.get_float [ "price-input" ] in
  let price_output = Otoml.find_opt tbl Otoml.get_float [ "price-output" ] in
  let keep_alive = Otoml.find_opt tbl Otoml.get_string [ "keep-alive" ] in
  let num_ctx = Otoml.find_opt tbl Otoml.get_integer [ "num-ctx" ] in
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
  : Runtime_schema.binding list
  =
  let entries = Otoml.get_table tbl in
  List.map
    (fun (model_id, sub) ->
       if is_toml_table sub
       then (
         (* [sub] is TomlTable/TomlInlineTable (per [is_toml_table]); both
            unwrap to a (key, value) list via [Otoml.get_table]. The
            nested sub-tables (Layer-4 aliases) are filtered out so the
            binding is built from this model's leaf fields only. *)
         let fields = Otoml.get_table sub in
         let leaf_fields = List.filter (fun (_, v) -> not (is_toml_table v)) fields in
         let synthetic_tbl = Otoml.TomlTable leaf_fields in
         parse_binding_fields provider_id model_id synthetic_tbl)
       else parse_binding_fields provider_id model_id sub)
    entries
;;

let parse_bindings (toml : Otoml.t) : Runtime_schema.binding list =
  let top_entries = Otoml.get_table toml in
  (* Only top-level tables can describe a provider; scalar / array entries
     (e.g. an operator-authored ["comment = ..."]) would crash
     [Otoml.get_table] in [parse_provider_table]. *)
  let provider_tables =
    List.filter
      (fun (name, value) -> (not (is_reserved name)) && is_toml_table value)
      top_entries
  in
  List.concat_map
    (fun (provider_id, tbl) -> parse_provider_table provider_id tbl)
    provider_tables
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

let parse_toml (toml : Otoml.t) : (Runtime_schema.config, parse_error list) result =
  let providers_result = parse_providers toml in
  let models_result = parse_models toml in
  let assignments_result = parse_keeper_assignments toml in
  let errs = function Ok _ -> [] | Error errs -> errs in
  let all_errors =
    errs providers_result @ errs models_result @ errs assignments_result
  in
  let bindings = parse_bindings toml in
  let default_runtime_id =
    Otoml.find_opt toml Otoml.get_string [ "runtime"; "default" ]
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
    Ok
      { Runtime_schema.providers
      ; models
      ; bindings
      ; default_runtime_id
      ; keeper_assignments
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
