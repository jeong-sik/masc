(** Declarative Runtime TOML parser.

    Re-homed from the deleted [Runtime_declarative_parser]. Parses RFC-0058
    layers 1-3 plus [[runtime].default] into a self-standing
    {!Runtime_schema.config}. Reserved top-level namespaces: providers,
    models, runtime, web_search, exec (the [\[exec.ssh.endpoints.*\]] SSH
    endpoint registry, Phase 1 SSH lane spec §4.2). Dropped routing namespaces
    system, routes, and profiles are rejected rather than ignored. A top-level
    table whose name [\[providers\]] declares carries that provider's model
    bindings as sub-tables; every other top-level table belongs to a different
    parser and is left alone.

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

type editor_transport =
  | Endpoint
  | Command

type editor_semantics =
  | Http_provider
  | Official_client

type editor_credential_policy =
  | Credentials_optional
  | Credentials_forbidden
  | Credentials_file_required

type editor_protocol =
  { protocol : string
  ; transport : editor_transport
  ; semantics : editor_semantics
  ; credential_policy : editor_credential_policy
  ; requires_non_interactive : bool
  ; provider_fields : string list
  ; required_provider_fields : string list
  }

type protocol_declaration =
  { protocol : string
  ; api_format : Runtime_schema.api_format
  ; editor : editor_protocol option
  }

let http_editor protocol =
  Some
    { protocol
    ; transport = Endpoint
    ; semantics = Http_provider
    ; credential_policy = Credentials_optional
    ; requires_non_interactive = false
    ; provider_fields = []
    ; required_provider_fields = []
    }
;;

let official_client_editor protocol =
  Some
    { protocol
    ; transport = Command
    ; semantics = Official_client
    ; credential_policy = Credentials_forbidden
    ; requires_non_interactive = true
    ; provider_fields = []
    ; required_provider_fields = []
    }
;;

let antigravity_editor =
  Some
    { protocol = "antigravity-cli"
    ; transport = Command
    ; semantics = Official_client
    ; credential_policy = Credentials_file_required
    ; requires_non_interactive = true
    ; provider_fields = [ "agent"; "effort"; "timeout-s" ]
    ; required_provider_fields = [ "timeout-s" ]
    }
;;

let hidden_protocol protocol api_format =
  { protocol; api_format; editor = None }
;;

let http_protocol protocol api_format =
  { protocol; api_format; editor = http_editor protocol }
;;

let official_client_protocol protocol api_format =
  { protocol; api_format; editor = official_client_editor protocol }
;;

let protocol_declarations =
  [ hidden_protocol "messages-cli" Runtime_schema.Messages_api
  ; http_protocol "messages-http" Runtime_schema.Messages_api
  ; hidden_protocol "openai-compatible-cli" Runtime_schema.Chat_completions_api
  ; http_protocol
      "openai-compatible-http"
      Runtime_schema.Chat_completions_api
  ; http_protocol "ollama-http" Runtime_schema.Ollama_api
  ; official_client_protocol
      "codex-app-server"
      Runtime_schema.Codex_app_server_runtime
  ; official_client_protocol "claude-code" Runtime_schema.Claude_code_runtime
  ; { protocol = "antigravity-cli"
    ; api_format = Runtime_schema.Antigravity_cli_runtime
    ; editor = antigravity_editor
    }
  ]
;;

let protocol_declaration protocol =
  List.find_opt
    (fun declaration -> String.equal declaration.protocol protocol)
    protocol_declarations
;;

let editor_protocols = List.filter_map (fun declaration -> declaration.editor) protocol_declarations

let canonical_protocol_of_protocol protocol =
  Option.map (fun declaration -> declaration.protocol) (protocol_declaration protocol)
;;

let unknown_protocol_error s =
  Printf.sprintf
    "unknown protocol %S: expected one of %s"
    s
    (String.concat ", " (List.map (fun declaration -> declaration.protocol) protocol_declarations))
;;

let api_format_of_protocol (s : string)
  : (Runtime_schema.api_format, string) result
  =
  match protocol_declaration s with
  | Some declaration -> Ok declaration.api_format
  | None -> Error (unknown_protocol_error s)
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

let active_top_level_namespaces =
  [ "providers"
  ; "models"
  ; "runtime"
  ; "web_search"
  ; "exec"
  ; Skill_source_config.top_level_namespace
  ]
;;
let obsolete_top_level_namespaces = [ "system"; "routes"; "profiles" ]
let reserved_namespaces = active_top_level_namespaces @ obsolete_top_level_namespaces
let is_reserved name = List.mem name reserved_namespaces

(* Provider ids stay dot-free: a Runtime id is the literal string
   "<provider>.<model>", so a dot inside the provider id would make that
   compound ambiguous. Model ids admit '.' because they carry upstream API
   model names verbatim (gpt-5.3-codex-spark, mimo-v2.5), written as quoted
   TOML keys that Otoml already parses. *)
let valid_runtime_id_component ~allow_dot value =
  let length = String.length value in
  length > 0
  &&
  let rec loop index =
    if index = length
    then true
    else (
      match value.[index] with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> loop (index + 1)
      | '.' when allow_dot -> loop (index + 1)
      | _ -> false)
  in
  loop 0
;;

let runtime_id_charset ~allow_dot =
  if allow_dot then "[A-Za-z0-9._-]+" else "[A-Za-z0-9_-]+"
;;

let validate_runtime_id_component ~allow_dot ~kind ~path value =
  if not (valid_runtime_id_component ~allow_dot value)
  then
    Error
      (error
         path
         (Printf.sprintf "%s id must match %s" kind (runtime_id_charset ~allow_dot)))
  else if is_reserved value
  then
    Error
      (error
         path
         (Printf.sprintf
            "%s id %S collides with a reserved top-level runtime.toml namespace"
            kind
            value))
  else Ok ()
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

let capability_keys =
  [ "supports-inline-tools"; "argv-prompt-preflight"; "uses-messages-caching" ]
;;

(** Parse a [providers.<id>.capabilities] sub-table. Every key must be one of
    {!capability_keys}; any other key fails the load so a stale or misspelled
    capability is never silently dropped. *)
let parse_capabilities ~(path : string) (tbl : Otoml.t)
  : (Runtime_schema.capabilities, parse_error list) result
  =
  let path = path ^ ".capabilities" in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if List.mem key capability_keys
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown capabilities key %S; expected %s"
                  key
                  (String.concat ", " capability_keys)))
        entries
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTableArray _ -> error path "capabilities must be a TOML table"
  in
  if unknown_key_errors <> []
  then Error unknown_key_errors
  else (
    let b key = Otoml.find_or ~default:false tbl Otoml.get_boolean [ key ] in
    Ok
      { Runtime_schema.supports_inline_tools = b "supports-inline-tools"
      ; argv_prompt_preflight = b "argv-prompt-preflight"
      ; uses_anthropic_caching = b "uses-messages-caching"
      })
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

let antigravity_cli_option_keys = [ "agent"; "effort"; "timeout-s"; "add-dirs" ]

let antigravity_forbidden_option_keys =
  [ "execution-mode"; "sandbox"; "disable-slash-commands" ]
;;

let antigravity_optional_string ~(path : string) (tbl : Otoml.t) key =
  match typed_find "a string" path tbl key Otoml.get_string with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when String.trim value = "" ->
    Error (error (path ^ "." ^ key) (key ^ " must be non-empty when present"))
  | Ok (Some value) when not (String.equal value (String.trim value)) ->
    Error
      (error
         (path ^ "." ^ key)
         (key ^ " must not have leading or trailing whitespace"))
  | Ok (Some value) -> Ok (Some value)
;;

let antigravity_cli_options ~(path : string) (tbl : Otoml.t)
    (api_format : Runtime_schema.api_format)
  : (Runtime_schema.antigravity_cli_options option, parse_error list) result
  =
  match api_format with
  | Antigravity_cli_runtime ->
    let authority_error =
      List.find_opt
        (fun key -> Option.is_some (Otoml.find_opt tbl Fun.id [ key ]))
        antigravity_forbidden_option_keys
      |> Option.map (fun key ->
        error
          (path ^ "." ^ key)
          (Printf.sprintf "unsupported antigravity-cli provider field %S" key))
    in
    (match authority_error with
     | Some error -> Error error
     | None ->
    let agent_result = antigravity_optional_string ~path tbl "agent" in
    let effort_result = antigravity_optional_string ~path tbl "effort" in
    (* [add-dirs] entries must be absolute: the CLI resolves a relative
       [--add-dir] against its own cwd, which is the keeper base path, so a
       relative entry silently names a path inside the base the operator did
       not mean. Reject at load instead. *)
    let add_dirs_result =
      match Otoml.find_opt tbl Fun.id [ "add-dirs" ] with
      | None -> Ok []
      | Some (Otoml.TomlArray entries) ->
        let dirs, errs =
          List.fold_left
            (fun (dirs, errs) entry ->
               match entry with
               | Otoml.TomlString value when String.trim value = "" ->
                 dirs, errs @ error (path ^ ".add-dirs") "add-dirs entries must be non-empty"
               | Otoml.TomlString value when Filename.is_relative value ->
                 ( dirs
                 , errs
                   @ error
                       (path ^ ".add-dirs")
                       (Printf.sprintf
                          "add-dirs entries must be absolute paths, got %S"
                          value) )
               | Otoml.TomlString value -> dirs @ [ value ], errs
               | _ ->
                 dirs, errs @ error (path ^ ".add-dirs") "add-dirs entries must be strings")
            ([], [])
            entries
        in
        (match errs with
         | [] -> Ok dirs
         | errs -> Error errs)
      | Some _ -> Error (error (path ^ ".add-dirs") "add-dirs must be an array of strings")
    in
    let timeout_result =
      match
        strict_float_find path tbl "timeout-s"
        |> positive_finite_float_opt_field ~path ~key:"timeout-s"
      with
      | Error _ as error -> error
      | Ok None ->
        Error
          (error
             (path ^ ".timeout-s")
             "timeout-s is required for protocol antigravity-cli")
      | Ok (Some timeout_s) -> Ok timeout_s
    in
    (match agent_result, effort_result, add_dirs_result, timeout_result with
     | Error errors, _, _, _
     | _, Error errors, _, _
     | _, _, Error errors, _
     | _, _, _, Error errors -> Error errors
     | Ok agent, Ok effort, Ok add_dirs, Ok timeout_s ->
       let effort_result =
         match effort with
         | None -> Ok None
         | Some "low" -> Ok (Some Runtime_schema.Antigravity_low)
         | Some "medium" -> Ok (Some Runtime_schema.Antigravity_medium)
         | Some "high" -> Ok (Some Runtime_schema.Antigravity_high)
         | Some value ->
           Error
             (error
                (path ^ ".effort")
                (Printf.sprintf "effort must be low, medium, or high; got %S" value))
       in
       (match effort_result with
        | Error errors -> Error errors
        | Ok effort ->
          Ok (Some { Runtime_schema.agent; effort; timeout_s; add_dirs }))))
  | Messages_api
  | Chat_completions_api
  | Ollama_api
  | Codex_app_server_runtime
  | Claude_code_runtime ->
    (match
       List.find_opt
         (fun key -> Option.is_some (Otoml.find_opt tbl Fun.id [ key ]))
         (antigravity_cli_option_keys @ antigravity_forbidden_option_keys)
     with
     | None -> Ok None
     | Some key ->
       Error
         (error
            (path ^ "." ^ key)
            (Printf.sprintf "%s is valid only for protocol antigravity-cli" key)))
;;

let parse_provider (id : string) (tbl : Otoml.t)
  : (Runtime_schema.provider, parse_error list) result
  =
  let path = Printf.sprintf "providers.%s" id in
  let enabled_result =
    typed_find "a boolean" path tbl "enabled" Otoml.get_boolean
  in
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
    let antigravity_cli_result = antigravity_cli_options ~path tbl api_format in
    (match credentials_result, antigravity_cli_result with
     | Error errs, _ | _, Error errs -> Error errs
     | Ok credentials, Ok antigravity_cli ->
       let capabilities_result =
         match Otoml.find_opt tbl Fun.id [ "capabilities" ] with
         | None -> Ok None
         | Some capabilities_tbl ->
           Result.map Option.some (parse_capabilities ~path capabilities_tbl)
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
       (* Optional per-provider connect/headers timeout override (agent-core boundary).
          Absent (most providers) leaves the AGENT_CORE kind-based default in force. *)
       let connect_timeout_key = Runtime_schema.connect_timeout_s_key in
       let connect_timeout_result =
         strict_float_find path tbl connect_timeout_key
         |> positive_finite_float_opt_field ~path ~key:connect_timeout_key
       in
       (match
          capabilities_result, enabled_result, healthcheck_result, connect_timeout_result
        with
        | Error errs, _, _, _ | _, Error errs, _, _ | _, _, Error errs, _ | _, _, _, Error errs
          -> Error errs
        | Ok capabilities, Ok enabled_opt, Ok healthcheck_path, Ok connect_timeout_s ->
          let enabled = match enabled_opt with Some value -> value | None -> true in
          Ok
            { Runtime_schema.id
            ; enabled
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
            ; antigravity_cli
            }))
;;

let parse_providers (toml : Otoml.t)
  : (Runtime_schema.provider list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "providers" ] with
  | None -> Ok []
  | Some providers_tbl ->
    let entries = Otoml.get_table providers_tbl in
    partition_results
      (List.map
         (fun (id, tbl) ->
            match
              validate_runtime_id_component
                ~allow_dot:false
                ~kind:"provider"
                ~path:("providers." ^ id)
                id
            with
            | Error _ as error -> error
            | Ok () -> parse_provider id tbl)
         entries)
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

let parse_thinking_control_format ~(path : string) ~(token : string option) (raw : string)
  : (Runtime_schema.thinking_control_format, parse_error list) result
  =
  (* Mirrors the AGENT_CORE catalog contract (agent-core boundary): [Chat_template_token]
     carries its token, so a chat-template-token declaration without a
     [thinking-control-token] key — or a blank/padded token, or a token on a
     non-token format — fails the load instead of detonating per request. *)
  let reject_orphan_token format =
    match token with
    | None -> Ok format
    | Some _ ->
      Error
        (error
           (path ^ "." ^ thinking_control_token_key)
           (Printf.sprintf
              "thinking-control-token is only valid with \
               thinking-control-format = \"chat-template-token\" (got %S)"
              raw))
  in
  match String.lowercase_ascii (String.trim raw) with
  | "" | "none" | "no-thinking-control" | "no_thinking_control" ->
    reject_orphan_token Runtime_schema.No_thinking_control
  | "thinking-object" | "thinking_object" ->
    reject_orphan_token Runtime_schema.Thinking_object
  | "thinking-object-only" | "thinking_object_only" ->
    reject_orphan_token Runtime_schema.Thinking_object_only
  | "chat-template-kwargs" | "chat_template_kwargs" ->
    reject_orphan_token Runtime_schema.Chat_template_kwargs
  | "chat-template-token" | "chat_template_token" ->
    (match token with
     | Some t when String.trim t = t && t <> "" ->
       Ok (Runtime_schema.Chat_template_token t)
     | Some _ ->
       Error
         (error
            (path ^ "." ^ thinking_control_token_key)
            "thinking-control-token must be a non-empty string without \
             leading or trailing whitespace")
     | None ->
       Error
         (error
            (path ^ ".thinking-control-format")
            "chat-template-token requires a thinking-control-token key \
             naming the template token (e.g. \"<|think|>\")"))
  | "ollama-think" | "ollama_think" -> reject_orphan_token Runtime_schema.Ollama_think
  | "reasoning-effort" | "reasoning_effort" ->
    reject_orphan_token Runtime_schema.Reasoning_effort
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
             none|thinking-object|thinking-object-only|chat-template-kwargs|chat-template-token|ollama-think|reasoning-effort"
            other))
;;

let parse_model_capabilities ~(path : string) (tbl : Otoml.t)
  : (Runtime_schema.model_capabilities, parse_error list) result
  =
  let b key = Otoml.find_or ~default:false tbl Otoml.get_boolean [ key ] in
  let b_opt key = Otoml.find_opt tbl Otoml.get_boolean [ key ] in
  let reasoning_streaming_format_result =
    match typed_find "string" path tbl "reasoning-streaming-format" Otoml.get_string with
    | Error errors -> Error errors
    | Ok None -> Ok None
    | Ok (Some raw) ->
      (match Llm_provider.Capability_vocab.reasoning_streaming_format_of_string raw with
       | Some format -> Ok (Some format)
       | None ->
         Error
           (error
              (path ^ ".reasoning-streaming-format")
              (Printf.sprintf
                 "unknown reasoning-streaming-format %S — expected %s"
                 raw
                 Llm_provider.Capability_vocab.reasoning_streaming_format_syntax)))
  in
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
    | Ok None, Ok token ->
      (match token with
       | None -> Ok Runtime_schema.No_thinking_control
       | Some _ ->
         Error
           (error
              (path ^ "." ^ thinking_control_token_key)
              "thinking-control-token requires thinking-control-format = \
               \"chat-template-token\""))
    | Ok (Some raw), Ok token -> parse_thinking_control_format ~path ~token raw
  in
  match thinking_control_format_result, reasoning_streaming_format_result with
  | Error errors, _ | _, Error errors -> Error errors
  | Ok thinking_control_format, Ok reasoning_streaming_format ->
    Ok
      { Runtime_schema.max_output_tokens = positive_int_opt_field "max-output-tokens"
      ; supports_tool_choice = b "supports-tool-choice"
      ; supports_required_tool_choice = b "supports-required-tool-choice"
      ; supports_named_tool_choice = b "supports-named-tool-choice"
      ; supports_parallel_tool_calls = b "supports-parallel-tool-calls"
      ; supports_extended_thinking = b "supports-extended-thinking"
      ; supports_reasoning_budget = b "supports-reasoning-budget"
      ; declared_supports_reasoning_budget = b_opt "supports-reasoning-budget"
      ; thinking_control_format
      ; declared_thinking_control_format =
          (match Otoml.find_opt tbl Fun.id [ "thinking-control-format" ] with
           | None -> None
           | Some _ -> Some thinking_control_format)
      ; reasoning_streaming_format
      ; supports_image_input = b "supports-image-input"
      ; supports_audio_input = b "supports-audio-input"
      ; supports_video_input = b "supports-video-input"
      ; supports_multimodal_inputs = b "supports-multimodal-inputs"
      ; supports_response_format_json = b "supports-response-format-json"
      ; supports_structured_output = b "supports-structured-output"
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
      }
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

(* Read the optional per-model [reasoning-effort]. Parsed into the typed
   effort at load time rather than carried as a string: an unknown value is
   an operator typo, and rejecting it here means no later consumer has to
   decide what an unparseable effort means. *)
let reasoning_effort_opt_field ~(path : string) (tbl : Otoml.t)
  : (Llm_provider.Reasoning_effort.t option, parse_error list) result
  =
  match Otoml.find_opt tbl Otoml.get_string [ "reasoning-effort" ] with
  | None -> Ok None
  | Some raw ->
    (match Llm_provider.Reasoning_effort.of_string raw with
     | Some effort -> Ok (Some effort)
     | None ->
       Error
         [ { path
           ; message =
               Printf.sprintf
                 "reasoning-effort %S is not a known effort; expected one of %s"
                 raw
                 Llm_provider.Reasoning_effort.values_for_log
           }
         ])
;;

(* Read the optional per-model [turn-timeout-s]. Named distinctly from the
   antigravity provider key [timeout-s] because the two sit at different layers
   and the model value wins: an operator reading a config with both should be
   able to tell which one bounds the turn without consulting the resolver. *)
(* Unlike the other float fields, [0] is meaningful here rather than invalid:
   it declares that no deadline is installed, so the spawned client decides
   when its own turn ends. Absent stays distinct from [0] — absent keeps the
   adapter default, [0] removes the bound — so the two cannot be confused
   downstream. Negative and non-finite remain rejected. *)
let turn_timeout_opt_field ~(path : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  match number_opt_field ~path ~key:"turn-timeout-s" tbl with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when value >= 0.0 && Float.is_finite value -> Ok (Some value)
  | Ok (Some value) ->
    Error
      (error
         (path ^ ".turn-timeout-s")
         (Printf.sprintf
            "turn-timeout-s must be a non-negative finite number (0 removes \
             the deadline), got %g"
            value))
;;

(* Read the optional per-model [wall-clock-ceiling-s]. Unlike
   [turn-timeout-s] there is no "0 removes the bound" form: the whole-turn
   ceiling ({!Runtime_wall_clock}) is the fail-safe against a turn that keeps
   emitting forever, so the config may tighten it but never delete it. Absent
   keeps the runtime default ceiling. *)
let wall_clock_ceiling_opt_field ~(path : string) (tbl : Otoml.t)
  : (float option, parse_error list) result
  =
  match number_opt_field ~path ~key:"wall-clock-ceiling-s" tbl with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some value) when value > 0.0 && Float.is_finite value -> Ok (Some value)
  | Ok (Some value) ->
    Error
      (error
         (path ^ ".wall-clock-ceiling-s")
         (Printf.sprintf
            "wall-clock-ceiling-s must be a positive finite number (the \
             ceiling can be tightened but not removed), got %g"
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
  (* [max-context] is an explicit operator override, not a required field: a
     runtime whose model is covered by the AGENT_CORE capability catalog can leave it
     unset and inherit the catalog's max-context (see
     [Runtime.resolve_max_context_of_runtime]). An operator-supplied value
     must still be positive; [materialize_config] fail-closes at load time on
     a runtime that resolves neither source (RFC-0206 §2.1). *)
  let max_context_result = positive_int_opt_field ~path ~key:"max-context" tbl in
  (
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
    let temperature_result = temperature_opt_field ~path tbl in
    let top_p_result = probability_opt_field ~path ~key:"top-p" tbl in
    let top_k_result = positive_int_opt_field ~path ~key:"top-k" tbl in
    let min_p_result = probability_opt_field ~path ~key:"min-p" tbl in
    let reasoning_effort_result = reasoning_effort_opt_field ~path tbl in
    let turn_timeout_result = turn_timeout_opt_field ~path tbl in
    let wall_clock_ceiling_result = wall_clock_ceiling_opt_field ~path tbl in
    let max_prompt_bytes_result =
      positive_int_opt_field ~path ~key:"max-prompt-bytes" tbl
    in
    let ( let* ) = Result.bind in
    let* max_context = max_context_result in
    let* capabilities = capabilities_result in
    let* temperature = temperature_result in
    let* top_p = top_p_result in
    let* top_k = top_k_result in
    let* min_p = min_p_result in
    let* reasoning_effort = reasoning_effort_result in
    let* turn_timeout_s = turn_timeout_result in
    let* wall_clock_ceiling_s = wall_clock_ceiling_result in
    let* max_prompt_bytes = max_prompt_bytes_result in
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
        ; reasoning_effort
        ; turn_timeout_s
        ; wall_clock_ceiling_s
        ; max_prompt_bytes
        ; capabilities        })
;;

let parse_models (toml : Otoml.t)
  : (Runtime_schema.model_spec list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "models" ] with
  | None -> Ok []
  | Some models_tbl ->
    let entries = Otoml.get_table models_tbl in
    partition_results
      (List.map
         (fun (id, tbl) ->
            match
              validate_runtime_id_component
                ~allow_dot:true
                ~kind:"model"
                ~path:("models." ^ id)
                id
            with
            | Error _ as error -> error
            | Ok () -> parse_model id tbl)
         entries)
;;

(* --- [exec.ssh.endpoints] registry (Phase 1 SSH lane, spec §4.2) --- *)

let exec_ssh_endpoint_keys =
  [ "host"
  ; "user"
  ; "port"
  ; "identity_file"
  ; "known_hosts_file"
  ; "remote_root"
  ; "connect_timeout_sec"
  ; "max_concurrent_sessions"
  ; "env_allowlist"
  ; "capabilities"
  ]
;;

(* Required endpoint strings reject surrounding whitespace rather than
   storing padding verbatim — symmetric with [exact_non_empty_string_opt_field]
   on the optional fields of the same record. *)
let exec_ssh_required_string ~(path : string) (tbl : Otoml.t) ~(key : string)
  : (string, parse_error list) result
  =
  match
    required_non_empty_string
      tbl
      ~path
      ~key
      ~message:(Printf.sprintf "endpoint requires non-empty '%s'" key)
  with
  | Error _ as error -> error
  | Ok value when value <> String.trim value ->
    Error
      (error
         (path ^ "." ^ key)
         (key ^ " must not have leading or trailing whitespace"))
  | Ok value -> Ok value
;;

(* The shim maps keeper paths under [remote_root] (spec §4.2 path mapping); a
   relative root would make that translation cwd-dependent, so the value is
   rejected at load — the same fail-closed shape as the [healthcheck.path must
   be absolute] check in [parse_provider]. *)
let exec_ssh_remote_root_field ~(path : string) (tbl : Otoml.t)
  : (string, parse_error list) result
  =
  (* Non-emptiness is proven by [exec_ssh_required_string], so the [0] index
     cannot raise. *)
  match exec_ssh_required_string ~path tbl ~key:"remote_root" with
  | Error _ as error -> error
  | Ok remote_root when Char.equal remote_root.[0] '/' -> Ok remote_root
  | Ok remote_root ->
    Error
      (error
         (path ^ ".remote_root")
         (Printf.sprintf "remote_root must be absolute, got %S" remote_root))
;;

(* ssh accepts ports 1..65535; [positive_int_opt_field] covers the lower
   bound, this adds the upper one so a typo is a load error instead of a
   dispatch-time ssh failure. *)
let exec_ssh_port_field ~(path : string) (tbl : Otoml.t)
  : (int option, parse_error list) result
  =
  match positive_int_opt_field ~path ~key:"port" tbl with
  | Error _ as error -> error
  | Ok (Some port) when port > 65535 ->
    Error
      (error
         (path ^ ".port")
         (Printf.sprintf "port must be in 1..65535; got %d" port))
  | Ok port -> Ok port
;;

(** Parse one [\[exec.ssh.endpoints.<name>\]] table. Every key must be one of
    {!exec_ssh_endpoint_keys}; any other key fails the load so a misspelled
    knob is never silently dropped. [host], [user], and [remote_root] are
    required non-empty strings and reject surrounding whitespace (padding is
    a typo, not a value); [remote_root] must additionally be absolute, since
    the shim's path mapping is defined against it. [port] must be in
    1..65535; every other key carries the spec default. The two file defaults
    resolve here, where the endpoint name is in scope, to base-relative paths
    with the name substituted (see {!Exec_ssh_endpoint}). Unknown
    [capabilities] values warn-and-ignore per the spec table — they are
    Phase 2 reservations, not Phase 1 knobs. *)
let parse_exec_ssh_endpoint ~(name : string) (tbl : Otoml.t)
  : (Exec_ssh_endpoint.t, parse_error list) result
  =
  let path = "exec.ssh.endpoints." ^ name in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if List.mem key exec_ssh_endpoint_keys
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown exec ssh endpoint key %S; expected %s"
                  key
                  (String.concat ", " exec_ssh_endpoint_keys)))
        entries
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
    | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
    | Otoml.TomlTableArray _ -> error path "endpoint must be a TOML table"
  in
  let host_result = exec_ssh_required_string ~path tbl ~key:"host" in
  let user_result = exec_ssh_required_string ~path tbl ~key:"user" in
  let destination_result =
    match host_result, user_result with
    | Ok host, Ok user ->
      Exec_ssh_endpoint.validate_destination ~host ~user
      |> Result.map_error (fun message -> error path message)
    | Error _, _ | _, Error _ -> Ok ()
  in
  let remote_root_result = exec_ssh_remote_root_field ~path tbl in
  let port_result = exec_ssh_port_field ~path tbl in
  let identity_file_result = exact_non_empty_string_opt_field ~path tbl "identity_file" in
  let known_hosts_file_result =
    exact_non_empty_string_opt_field ~path tbl "known_hosts_file"
  in
  let connect_timeout_sec_result =
    positive_int_opt_field ~path ~key:"connect_timeout_sec" tbl
  in
  let max_concurrent_sessions_result =
    positive_int_opt_field ~path ~key:"max_concurrent_sessions" tbl
  in
  let string_array_field key =
    Result.map
      (Option.value ~default:[])
      (typed_find
         "an array of strings"
         path
         tbl
         key
         (Otoml.get_array Otoml.get_string))
  in
  let env_allowlist_result = string_array_field "env_allowlist" in
  let capabilities_result = string_array_field "capabilities" in
  let errs = function Ok _ -> [] | Error errs -> errs in
  let field_errors =
    errs host_result
    @ errs user_result
    @ errs destination_result
    @ errs remote_root_result
    @ errs port_result
    @ errs identity_file_result
    @ errs known_hosts_file_result
    @ errs connect_timeout_sec_result
    @ errs max_concurrent_sessions_result
    @ errs env_allowlist_result
    @ errs capabilities_result
  in
  match unknown_key_errors with
  | _ :: _ -> Error (unknown_key_errors @ field_errors)
  | [] ->
    (match
       ( host_result
       , user_result
       , destination_result
       , remote_root_result
       , port_result
       , identity_file_result
       , known_hosts_file_result
       , connect_timeout_sec_result
       , max_concurrent_sessions_result
       , env_allowlist_result
       , capabilities_result )
     with
     | ( Ok host
       , Ok user
       , Ok ()
       , Ok remote_root
       , Ok port
       , Ok identity_file
       , Ok known_hosts_file
       , Ok connect_timeout_sec
       , Ok max_concurrent_sessions
       , Ok env_allowlist
       , Ok declared_capabilities ) ->
       let capabilities =
         List.filter
           (fun capability ->
              if List.mem capability Exec_ssh_endpoint.known_capabilities
              then true
              else (
                Log.Runtime.warn
                  "runtime_toml: %s.capabilities — unknown capability %S, ignoring"
                  path
                  capability;
                false))
           declared_capabilities
       in
       Ok
         { Exec_ssh_endpoint.name
         ; host
         ; user
         ; port = Option.value ~default:Exec_ssh_endpoint.default_port port
         ; identity_file =
             Option.value
               ~default:(Exec_ssh_endpoint.default_identity_file ~name)
               identity_file
         ; known_hosts_file =
             Option.value
               ~default:(Exec_ssh_endpoint.default_known_hosts_file ~name)
               known_hosts_file
         ; remote_root
         ; connect_timeout_sec =
             Option.value
               ~default:Exec_ssh_endpoint.default_connect_timeout_sec
               connect_timeout_sec
         ; max_concurrent_sessions =
             Option.value
               ~default:Exec_ssh_endpoint.default_max_concurrent_sessions
               max_concurrent_sessions
         ; env_allowlist
         ; capabilities
         }
     (* [field_errors] is non-empty exactly when some field result is [Error],
        so this arm always carries at least one error. *)
     | _ -> Error field_errors)
;;

(* [exec] owns exactly [ssh] and [exec.ssh] owns exactly [endpoints]: the
   namespace is closed, so any sibling key is a typo the load names rather
   than silently dropping — the same fail-closed posture as unknown provider
   capabilities keys. *)
let exec_single_child ~(path : string) ~(child_key : string) (value : Otoml.t)
  : (Otoml.t option, parse_error list) result
  =
  match value with
  | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
    let stray, children =
      List.partition (fun (key, _) -> not (String.equal key child_key)) entries
    in
    let stray_errors =
      List.concat_map
        (fun (key, _) ->
           error
             (path ^ "." ^ key)
             (Printf.sprintf
                "unknown [%s] key %S; expected only [%s.%s]"
                path
                key
                path
                child_key))
        stray
    in
    (match stray_errors, children with
     | _ :: _, _ -> Error stray_errors
     | [], [] -> Ok None
     | [], [ (_, child) ] -> Ok (Some child)
     (* A repeated table key is rejected by the TOML parser itself, so more
        than one [child_key] entry cannot reach here; fail loud rather than
        silently picking one if that invariant ever breaks. *)
     | [], _ :: _ :: _ ->
       Error
         (error
            (path ^ "." ^ child_key)
            (Printf.sprintf "duplicate [%s.%s] table" path child_key)))
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTableArray _ ->
    Error (error path (Printf.sprintf "[%s] must be a TOML table" path))
;;

(** Walk [\[exec.ssh.endpoints.*\]] tables into the endpoint registry. Each
    endpoint name passes {!validate_runtime_id_component} dot-free, matching
    provider ids. Absent [\[exec\]] section yields an empty registry. *)
let parse_exec_endpoints (toml : Otoml.t)
  : (Exec_ssh_endpoint.t list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "exec" ] with
  | None -> Ok []
  | Some exec_value ->
    (match exec_single_child ~path:"exec" ~child_key:"ssh" exec_value with
     | Error _ as error -> error
     | Ok None -> Ok []
     | Ok (Some ssh_value) ->
       (match exec_single_child ~path:"exec.ssh" ~child_key:"endpoints" ssh_value with
        | Error _ as error -> error
        | Ok None -> Ok []
        | Ok (Some endpoints_value) ->
          (match endpoints_value with
           | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
             partition_results
               (List.map
                  (fun (name, tbl) ->
                     match
                       validate_runtime_id_component
                         ~allow_dot:false
                         ~kind:"exec ssh endpoint"
                         ~path:("exec.ssh.endpoints." ^ name)
                         name
                     with
                     | Error _ as error -> error
                     | Ok () -> parse_exec_ssh_endpoint ~name tbl)
                  entries)
           | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
           | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
           | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
           | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ->
             Error
               (error
                  "exec.ssh.endpoints"
                  "[exec.ssh.endpoints] must be a TOML table of endpoint tables"))))
;;

(* --- Reserved namespace detection --- *)

let reject_obsolete_top_level_namespaces (toml : Otoml.t)
  : (unit, parse_error list) result
  =
  let top_entries = Otoml.get_table toml in
  let errors =
    List.filter_map
      (fun namespace ->
         if List.mem_assoc namespace top_entries
         then
           Some
             { path = namespace
             ; message =
                 (Printf.sprintf
                    "obsolete top-level namespace %S is not supported"
                    namespace)
             }
         else None)
      obsolete_top_level_namespaces
  in
  if errors = [] then Ok () else Error errors
;;

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
  let enabled_result = typed_find "a boolean" path tbl "enabled" Otoml.get_boolean in
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
  (* Paired with max-concurrent on purpose: AGENT_CORE validates both in one admission
     declaration and enforces this one before POST by serializing, measuring and
     returning a typed Request_body_too_large. Only max-concurrent was declarable
     here, so the byte ceiling could not be expressed at all and the AGENT_CORE gate
     passed every size. Same shape as its sibling, including the >= 1 rule AGENT_CORE
     already enforces on the declaration. *)
  let max_request_body_bytes_result =
    match typed_find "an integer" path tbl "max-request-body-bytes" Otoml.get_integer with
    | Ok None -> Ok None
    | Ok (Some n) when n > 0 -> Ok (Some n)
    | Ok (Some n) ->
      Error
        (error
           (path ^ ".max-request-body-bytes")
           (Printf.sprintf
              "max-request-body-bytes must be a positive integer or omitted for no \
               declared ceiling; got %d"
              n))
    | Error _ as e -> e
  in
  (* Request-side output budget. AGENT_CORE omits the wire field when this is
     absent, so the provider's own default decides -- 65536 on ollama.com/v1,
     which is where a collapsed generation runs to. Positive-or-omitted mirrors
     max-request-body-bytes: 0 would mean "ask for no output at all", which no
     caller wants and every envelope rejects differently. *)
  let max_tokens_result =
    match typed_find "an integer" path tbl "max-tokens" Otoml.get_integer with
    | Ok None -> Ok None
    | Ok (Some n) when n > 0 -> Ok (Some n)
    | Ok (Some n) ->
      Error
        (error
           (path ^ ".max-tokens")
           (Printf.sprintf
              "max-tokens must be a positive integer, or omitted to let the provider \
               apply its own default; got %d"
              n))
    | Error _ as e -> e
  in
  let price_input_result = typed_find "a float" path tbl "price-input" Otoml.get_float in
  let price_output_result = typed_find "a float" path tbl "price-output" Otoml.get_float in
  let keep_alive_result = typed_find "a string" path tbl "keep-alive" Otoml.get_string in
  let num_ctx_result = typed_find "an integer" path tbl "num-ctx" Otoml.get_integer in
  let repeat_penalty_result =
    match typed_find "a float" path tbl "repeat-penalty" Otoml.get_float with
    | Ok (Some value) when Float.compare value 0.0 <= 0 ->
      Error
        (error
           (path ^ ".repeat-penalty")
           (Printf.sprintf
              "repeat-penalty must be greater than 0 (1.0 disables the penalty); got %g"
              value))
    | other -> other
  in
  let repeat_last_n_result =
    match typed_find "an integer" path tbl "repeat-last-n" Otoml.get_integer with
    | Ok (Some value) when value < -1 ->
      Error
        (error
           (path ^ ".repeat-last-n")
           (Printf.sprintf
              "repeat-last-n must be -1 (whole context), 0 (disabled), or a positive \
               window; got %d"
              value))
    | other -> other
  in
  let return_progress_result =
    typed_find "a boolean" path tbl "return-progress" Otoml.get_boolean
  in
  let ( let* ) = Result.bind in
  let* enabled_opt = enabled_result in
  let enabled = match enabled_opt with Some value -> value | None -> true in
  let* is_default_opt = is_default_result in
  let is_default = Option.value is_default_opt ~default:false (* DET-OK: fallback to false if omitted *) in
  let* wizard_default_opt = wizard_default_result in
  let wizard_default =
    Option.value wizard_default_opt ~default:false
    (* DET-OK: omitted means not selected for install wizard. *)
  in
  let* max_concurrent = max_concurrent_result in
  let* max_request_body_bytes = max_request_body_bytes_result in
  let* max_tokens = max_tokens_result in
  let* price_input = price_input_result in
  let* price_output = price_output_result in
  let* keep_alive = keep_alive_result in
  let* num_ctx = num_ctx_result in
  let* repeat_penalty = repeat_penalty_result in
  let* repeat_last_n = repeat_last_n_result in
  let* return_progress = return_progress_result in
  Ok
    { Runtime_schema.provider_id
    ; model_id
    ; enabled
    ; is_default
    ; wizard_default
    ; max_concurrent
    ; max_request_body_bytes
    ; max_tokens
    ; price_input
    ; price_output
    ; keep_alive
    ; num_ctx
    ; repeat_penalty
    ; repeat_last_n
    ; return_progress
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

(* Top-level table names that own a binding group, taken from the [\[providers\]]
   keys as written rather than from successfully parsed providers: a malformed
   provider row must be reported as a provider error, not silently reclassify its
   bindings as some other namespace. *)
let declared_provider_ids (toml : Otoml.t) : string list =
  match Otoml.find_opt toml Fun.id [ "providers" ] with
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) -> List.map fst entries
  | Some _ | None -> []
;;

let parse_bindings (toml : Otoml.t)
  : (Runtime_schema.binding list, parse_error list) result
  =
  let top_entries = Otoml.get_table toml in
  let declared = declared_provider_ids toml in
  (* A top-level table describes a provider's bindings only when [\[providers\]]
     declares that provider. The namespace used to be defined by exclusion —
     anything not on the reserved list — which made every unrelated config
     section a phantom binding group: [\[voice.tts\]] and [\[fusion.presets\]]
     each parsed as a binding whose provider did not exist, and the loader had to
     drop unresolved bindings quietly for boot to survive them. That silence is
     what hid a real dangling reference (masc#28403). Naming the namespace
     positively lets {!Runtime.load_list} treat an unresolved binding as the typo
     it is. Scalar / array entries are still excluded because
     [parse_provider_table] would crash on them. *)
  let provider_tables =
    List.filter
      (fun (name, value) ->
        (not (is_reserved name)) && is_toml_table value && List.mem name declared)
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
   sole SSOT for keeper-to-runtime assignment. Each
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

type runtime_section =
  { default_runtime_id : string option
  ; media_failover : string list
  }

let empty_runtime_section =
  { default_runtime_id = None
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
     {!Runtime.validate_runtime_references}, which now judges every [runtime]
     field that names a routing target. *)
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
           | "exact_output_lanes" ->
             (* Parsed separately as raw AGENT_CORE target references. *)
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
                      "unknown [runtime] key %S; expected default, \
                       media_failover, [runtime.lanes], \
                       [runtime.exact_output_lanes], [runtime.assignments], or a \
                       table-valued [runtime.<profile>]"
                      key) )
        )
        (empty_runtime_section, [])
        entries
    in
    if errs <> [] then Error errs else Ok section
  | Some _ -> Error (error "runtime" "[runtime] must be a TOML table")
;;

(* [\[runtime.lanes.<id>\]] — ordered failover candidate lists. Each lane is a
   table with [candidates] (array of runtime ids). Candidate ids are resolved
   against materialized runtimes at load time, not here, so the parser returns
   declarations only.

   [candidates] is the whole vocabulary. The RFC-0206 routing rebirth dropped
   the strategy ADT (a lane is ordered by construction), and until this check
   a leftover [strategy = "ordered"] line was accepted and ignored — a key an
   operator could edit with no effect. Unknown keys fail the load instead,
   the same shape as [parse_exact_output_lane] below. *)
let parse_lane ~(id : string) (tbl : Otoml.t)
  : (Runtime_schema.lane_decl, parse_error list) result
  =
  let path = Printf.sprintf "runtime.lanes.%s" id in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if String.equal key "candidates"
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown lane key %S; expected candidates (lanes are ordered \
                   by construction; there is no strategy key)"
                  key))
        entries
    | _ -> []
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
  match candidate_ids_result with
  | Error e -> Error (unknown_key_errors @ e)
  | Ok _ when unknown_key_errors <> [] -> Error unknown_key_errors
  | Ok candidate_ids ->
    if candidate_ids = []
    then Error (error path "lane must have at least one candidate")
    else Ok { Runtime_schema.id; candidate_ids }
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

let parse_exact_output_lane ~(id : string) (tbl : Otoml.t)
  : (Runtime_schema.exact_output_lane_decl, parse_error list) result
  =
  let path = Printf.sprintf "runtime.exact_output_lanes.%s" id in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if String.equal key "slots" || String.equal key "cli_slots"
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown exact-output lane key %S; expected slots or cli_slots"
                  key))
        entries
    | _ -> []
  in
  let slots_result =
    match Otoml.find_opt tbl Fun.id [ "slots" ] with
    | None -> Error (error (path ^ ".slots") "exact-output lane slots is required")
    | Some value ->
      (try Ok (Otoml.get_array Otoml.get_string value) with
       | Otoml.Type_error msg ->
         Error
           (error
              (path ^ ".slots")
              (Printf.sprintf
                 "exact-output lane slots must be an array of opaque strings; got %s"
                 msg)))
  in
  let cli_slots_result =
    match Otoml.find_opt tbl Fun.id [ "cli_slots" ] with
    | None -> Ok []
    | Some value ->
      (try Ok (Otoml.get_array Otoml.get_string value) with
       | Otoml.Type_error msg ->
         Error
           (error
              (path ^ ".cli_slots")
              (Printf.sprintf
                 "exact-output lane cli_slots must be an array of runtime ids; got %s"
                 msg)))
  in
  let slots_result =
    match slots_result, cli_slots_result with
    | Error slot_errors, Error cli_errors -> Error (slot_errors @ cli_errors)
    | Error slot_errors, Ok _ -> Error slot_errors
    | Ok _, Error cli_errors -> Error cli_errors
    | Ok slots, Ok cli_slots -> Ok (slots, cli_slots)
  in
  match unknown_key_errors, slots_result with
  | _ :: _, Error slot_errors -> Error (slot_errors @ unknown_key_errors)
  | _ :: _, Ok _ -> Error unknown_key_errors
  | [], (Error _ as error) -> error
  | [], Ok ([], _) ->
    Error (error path "exact-output lane must have at least one slot")
  | [], Ok (slot_ids, cli_slot_ids) ->
    let rec validate_cli position seen = function
      | [] -> Ok ()
      | cli_id :: rest ->
        if String.equal (String.trim cli_id) ""
        then
          Error
            (error
               (path ^ ".cli_slots")
               (Printf.sprintf "cli slot %d must not be blank" position))
        else if List.exists (String.equal cli_id) seen
        then
          Error
            (error
               (path ^ ".cli_slots")
               (Printf.sprintf "cli slot %d duplicates %S" position cli_id))
        else validate_cli (position + 1) (cli_id :: seen) rest
    in
    let rec validate position seen = function
      | [] ->
        (match validate_cli 1 [] cli_slot_ids with
         | Error _ as error -> error
         | Ok () -> Ok { Runtime_schema.id; slot_ids; cli_slot_ids })
      | slot_id :: rest ->
        if String.equal (String.trim slot_id) ""
        then
          Error
            (error
               (path ^ ".slots")
               (Printf.sprintf "exact-output slot %d must not be blank" position))
        else if List.exists (String.equal slot_id) seen
        then
          Error
            (error
               (path ^ ".slots")
               (Printf.sprintf
                  "exact-output slot %d duplicates %S"
                  position
                  slot_id))
        else validate (position + 1) (slot_id :: seen) rest
    in
    validate 1 [] slot_ids
;;

let parse_exact_output_lanes (toml : Otoml.t)
  : (Runtime_schema.exact_output_lane_decl list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "runtime"; "exact_output_lanes" ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    partition_results
      (List.map
         (fun (id, value) ->
            match value with
            | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
              parse_exact_output_lane ~id value
            | _ ->
              Error
                (error
                   (Printf.sprintf "runtime.exact_output_lanes.%s" id)
                   "exact-output lane must be a table"))
         entries)
  | Some _ ->
    Error
      (error
         "runtime.exact_output_lanes"
         "[runtime.exact_output_lanes] must be a table of lane tables")
;;

(* [repeat-penalty] and [repeat-last-n] are fields of Ollama's own
   [/api/chat] [options] object. No other request builder has a field to put
   them in, so on any other wire the declaration was accepted, dropped without
   a word, and the operator was left believing the knob was live -- while the
   repetition loop it exists to stop kept running.

   Probed 2026-08-25 against ollama.com/v1/chat/completions with
   deepseek-v4-flash:0731 at seed 7: repeat_penalty=1.15 returned 65 completion
   tokens against a 63-token baseline, so the OpenAI-compatible endpoint ignores
   the name rather than honouring it under a different one. That endpoint's own
   repetition controls are [frequency_penalty] / [presence_penalty], which are
   different functions of the token history and not this value under another
   spelling -- so there is nothing to translate to, and the declaration is
   refused rather than silently reinterpreted.

   A binding whose provider is not declared is not judged here: those are
   dropped downstream by design, and naming them at this Gate would report the
   wrong defect. *)
let validate_ollama_only_binding_fields
      (providers : Runtime_schema.provider list)
      (bindings : Runtime_schema.binding list)
  : parse_error list
  =
  let api_format_of_provider provider_id =
    List.find_map
      (fun (provider : Runtime_schema.provider) ->
         if String.equal provider.id provider_id
         then Some provider.api_format
         else None)
      providers
  in
  List.concat_map
    (fun (binding : Runtime_schema.binding) ->
       match api_format_of_provider binding.provider_id with
       | None | Some Runtime_schema.Ollama_api -> []
       | Some
           (( Runtime_schema.Messages_api
            | Runtime_schema.Chat_completions_api
            | Runtime_schema.Codex_app_server_runtime
            | Runtime_schema.Antigravity_cli_runtime
            | Runtime_schema.Claude_code_runtime ) as api_format) ->
         let path = binding.provider_id ^ "." ^ binding.model_id in
         let refuse key =
           error
             (path ^ "." ^ key)
             (Printf.sprintf
                "%s is an Ollama /api/chat option and provider %S speaks %s, whose \
                 request has no field for it -- the value would be dropped without a \
                 trace. Remove it, or bind this model to a provider declared with \
                 protocol = \"ollama-http\"."
                key
                binding.provider_id
                (Runtime_schema.show_api_format api_format))
         in
         (match binding.repeat_penalty with
          | Some _ -> refuse "repeat-penalty"
          | None -> [])
         @ (match binding.repeat_last_n with
            | Some _ -> refuse "repeat-last-n"
            | None -> []))
    bindings
;;

let parse_toml (toml : Otoml.t) : (Runtime_schema.config, parse_error list) result =
  let obsolete_namespaces_result = reject_obsolete_top_level_namespaces toml in
  let providers_result = parse_providers toml in
  let models_result = parse_models toml in
  let runtime_section_result = parse_runtime_section toml in
  let assignments_result = parse_keeper_assignments toml in
  let bindings_result = parse_bindings toml in
  let lanes_result = parse_lanes toml in
  let exact_output_lanes_result = parse_exact_output_lanes toml in
  let exec_ssh_endpoints_result = parse_exec_endpoints toml in
  let errs = function Ok _ -> [] | Error errs -> errs in
  let all_errors =
    errs obsolete_namespaces_result
    @ errs providers_result
    @ errs models_result
    @ errs runtime_section_result
    @ errs assignments_result
    @ errs bindings_result
    @ errs lanes_result
    @ errs exact_output_lanes_result
    @ errs exec_ssh_endpoints_result
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
    let exact_output_lane_decls =
      extract_after_all_errors_guard
        ~label:"exact_output_lanes"
        exact_output_lanes_result
    in
    let exec_ssh_endpoints =
      extract_after_all_errors_guard
        ~label:"exec_ssh_endpoints"
        exec_ssh_endpoints_result
    in
    (* Cross-table Gate: a binding field only reaches the wire through its
       provider's request builder, so whether it is carriable is a fact about
       the provider, not about the binding table it was written in. *)
    match validate_ollama_only_binding_fields providers bindings with
    | _ :: _ as errors -> Error errors
    | [] ->
      Ok
        { Runtime_schema.providers
        ; models
        ; bindings
        ; default_runtime_id = runtime_section.default_runtime_id
        ; keeper_assignments
        ; media_failover = runtime_section.media_failover
        ; lane_decls
        ; exact_output_lane_decls
        ; exec_ssh_endpoints
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
