open Runtime_toml_base

(* --- Layer 1: Providers --- *)

let parse_credential ~home (tbl : Otoml.t) (path : string)
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
       (* A leading "~/" is the operator's home at read time, the same rule
          [Env_config_core.normalize_path_lexically] applies to every other
          path a config names. The seed config ships the Antigravity token
          under "~/.gemini/…" so it is one file for every workspace on a
          machine; expanding here keeps [Runtime_adapter]'s absolute-path
          rule true of the value it sees. *)
       Result.map
         (fun path -> Runtime_schema.File (Env_config_core.expand_home_prefix_under ~home path))
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
    let b key = typed_find_or "a boolean" path tbl key Otoml.get_boolean ~default:false in
    let ( let* ) = Result.bind in
    let* supports_inline_tools = b "supports-inline-tools" in
    let* argv_prompt_preflight = b "argv-prompt-preflight" in
    let* uses_anthropic_caching = b "uses-messages-caching" in
    Ok
      { Runtime_schema.supports_inline_tools
      ; argv_prompt_preflight
      ; uses_anthropic_caching
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
               | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
               | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
               | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _
               | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ -> dirs, errs @ error (path ^ ".add-dirs") "add-dirs entries must be strings")
            ([], [])
            entries
        in
        (match errs with
         | [] -> Ok dirs
         | errs -> Error errs)
      | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
      | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
      | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
      | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _)
      | Some (Otoml.TomlTableArray _) -> Error (error (path ^ ".add-dirs") "add-dirs must be an array of strings")
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
  | Gemini_api
  | Vertex_gemini_api
  | Codex_app_server_runtime
  | Claude_code_runtime
  | Muse_serve_runtime
  | Vibe_cli_runtime ->
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

let usage_read_key = "usage-read"
let usage_read_refresh_key = "refresh-s"
let usage_read_keys = [ "shape"; "url"; usage_read_refresh_key ]
let usage_read_url_scheme = "https"

let usage_read_shape_of_string = function
  | "openrouter-key" -> Some Runtime_schema.Openrouter_key
  | "zai-quota-limit" -> Some Runtime_schema.Zai_quota_limit
  | "kimi-coding-usages" -> Some Runtime_schema.Kimi_coding_usages
  | "ollama-balance" -> Some Runtime_schema.Ollama_balance
  | _ -> None
;;

let usage_read_shape_field ~path tbl =
  match typed_find "a string" path tbl "shape" Otoml.get_string with
  | Error _ as error -> error
  | Ok None -> Error (error (path ^ ".shape") "missing required field 'shape'")
  | Ok (Some raw) ->
    (match usage_read_shape_of_string raw with
     | Some shape -> Ok shape
     | None ->
       Error
         (error
            (path ^ ".shape")
            (Printf.sprintf
               "unknown shape %S — expected one of %s"
               raw
               (String.concat
                  ", "
                  (List.map
                     Runtime_schema.usage_read_shape_to_string
                     Runtime_schema.all_usage_read_shapes)))))
;;

let non_empty_host uri =
  match Uri.host uri with
  | Some host when String.length host > 0 -> Some (String.lowercase_ascii host)
  | Some _ | None -> None
;;

(* The read sends the provider's key, so only an absolute https URL is
   accepted, and only on the host the provider's own [endpoint] names: a typo
   or another host in [url] would otherwise receive the key on every boot. *)
let usage_read_url_field ~path ~(transport : Runtime_schema.transport) tbl =
  match typed_find "a string" path tbl "url" Otoml.get_string with
  | Error _ as error -> error
  | Ok None -> Error (error (path ^ ".url") "missing required field 'url'")
  | Ok (Some url) ->
    let uri = Uri.of_string url in
    (match Uri.scheme uri, non_empty_host uri with
     | Some scheme, Some host when String.equal scheme usage_read_url_scheme ->
       (match transport with
        | Runtime_schema.Cli _ ->
          Error
            (error
               (path ^ ".url")
               "usage-read needs a provider with an HTTP endpoint; this one runs a command")
        | Runtime_schema.Http endpoint ->
          (match non_empty_host (Uri.of_string endpoint) with
           | Some endpoint_host when String.equal endpoint_host host -> Ok url
           | Some endpoint_host ->
             Error
               (error
                  (path ^ ".url")
                  (Printf.sprintf
                     "url host %S must be the provider endpoint host %S; the read \
                      sends the provider's key"
                     host
                     endpoint_host))
           | None ->
             Error
               (error
                  (path ^ ".url")
                  (Printf.sprintf "the provider endpoint %S has no host" endpoint))))
     | Some _, (Some _ | None) | None, (Some _ | None) ->
       Error
         (error
            (path ^ ".url")
            (Printf.sprintf "url must be an absolute https:// URL, got %S" url)))
;;

(* The read sends the API key the runtime's HTTP execution was built with,
   and its windows are recorded under the quota scope of that key.  An
   official-client runtime (Codex, Claude Code, Antigravity, Muse Code, Vibe) logs
   in with the vendor's subscription, and its quota scope names no API key
   (Antigravity's names the OAuth file of that login), so an API-key read
   there would file one account's usage under another.  Codex and
   Antigravity are read through their own client instead
   (Runtime_provider_usage_read). *)
let usage_read_execution_errors ~path (api_format : Runtime_schema.api_format) =
  match api_format with
  | Runtime_schema.Messages_api
  | Runtime_schema.Chat_completions_api
  | Runtime_schema.Ollama_api
  | Runtime_schema.Gemini_api
  | Runtime_schema.Vertex_gemini_api -> []
  | Runtime_schema.Codex_app_server_runtime
  | Runtime_schema.Antigravity_cli_runtime
  | Runtime_schema.Claude_code_runtime
  | Runtime_schema.Muse_serve_runtime
  | Runtime_schema.Vibe_cli_runtime ->
    error
      path
      "usage-read is only for an API-key HTTP provider; this protocol runs an \
       official client"
;;

(** Parse [providers.<id>.usage-read]. Every key must be one of
    {!usage_read_keys}. The read authenticates with the provider's own
    credentials, so a provider that declares none is refused here rather
    than sending an unauthenticated request at start. *)
let parse_usage_read
    ~(path : string)
    ~(api_format : Runtime_schema.api_format)
    ~(credentials : Runtime_schema.credential option)
    ~(transport : Runtime_schema.transport)
    (tbl : Otoml.t)
  : (Runtime_schema.usage_read option, parse_error list) result
  =
  let path = path ^ "." ^ usage_read_key in
  match Otoml.find_opt tbl Fun.id [ usage_read_key ] with
  | None -> Ok None
  | Some ((Otoml.TomlTable entries | Otoml.TomlInlineTable entries) as usage_tbl) ->
    let unknown_key_errors =
      List.concat_map
        (fun (key, _) ->
           if List.mem key usage_read_keys
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown usage-read key %S; expected %s"
                  key
                  (String.concat ", " usage_read_keys)))
        entries
    in
    let credential_errors =
      match credentials with
      | Some _ -> []
      | None ->
        error path "usage-read needs the provider's [credentials]; none are declared"
    in
    let execution_errors = usage_read_execution_errors ~path api_format in
    let refresh_result =
      strict_float_find path usage_tbl usage_read_refresh_key
      |> positive_finite_float_opt_field ~path ~key:usage_read_refresh_key
    in
    (match
       ( unknown_key_errors @ execution_errors @ credential_errors
       , usage_read_shape_field ~path usage_tbl
       , usage_read_url_field ~path ~transport usage_tbl
       , refresh_result )
     with
     | [], Ok shape, Ok url, Ok refresh_s ->
       Ok (Some { Runtime_schema.shape; url; refresh_s })
     | ( ([] | _ :: _) as errors
       , ((Ok _ | Error _) as shape)
       , ((Ok _ | Error _) as url)
       , ((Ok _ | Error _) as refresh) ) ->
       let field_errors = function
         | Ok _ -> []
         | Error errors -> errors
       in
       Error (errors @ field_errors shape @ field_errors url @ field_errors refresh))
  | Some
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) ->
    Error (error path "usage-read must be a TOML table")
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

(* This is the provider table's field contract. Nested tables retain their
   own decoders; arbitrary HTTP header names are not provider keys. Model-set
   is consumed later when bindings are materialized and still belongs here. *)
let provider_keys =
  [ "enabled"; "display-name"; "provider-name"; "protocol"; "endpoint"; "command"
  ; "is-non-interactive"; "credentials"; "capabilities"; "healthcheck"; "headers"
  ; "kind"; "max-context"; "account-home"; "request-path"; "model-set"; usage_read_key
  ; Runtime_schema.connect_timeout_s_key; Runtime_schema.exact_body_timeout_s_key
  ; Runtime_schema.admission_priority_run_limit_key
  ] @ antigravity_cli_option_keys @ antigravity_forbidden_option_keys
;;

let parse_provider ~home (id : string) (tbl : Otoml.t)
  : (Runtime_schema.provider, parse_error list) result
  =
  let path = Ns.(path Providers) id in
  let ( let* ) = Result.bind in
  let* () =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      (match unknown_table_keys ~path ~expected:provider_keys entries with
       | [] -> Ok ()
       | errors -> Error errors)
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> Error (error path "provider must be a TOML table")
  in
  let enabled_result =
    typed_find "a boolean" path tbl "enabled" Otoml.get_boolean
  in
  let display_name_result =
    match
      ( typed_find "a string" path tbl "display-name" Otoml.get_string
      , typed_find "a string" path tbl "provider-name" Otoml.get_string )
    with
    | Error errors, _ | _, Error errors -> Error errors
    | Ok (Some name), Ok _ | Ok None, Ok (Some name) -> Ok name
    | Ok None, Ok None -> Ok id
  in
  let protocol_result =
    match typed_find "a string" path tbl "protocol" Otoml.get_string with
    | Error errors -> Error errors
    | Ok None -> Error (error (path ^ ".protocol") "missing required field 'protocol'")
    | Ok (Some p) ->
      Result.map_error
        (fun detail -> error (path ^ ".protocol") detail)
        (Runtime_protocol.resolve p)
  in
  let transport_result = transport_of_provider ~path tbl id in
  match display_name_result, protocol_result, transport_result with
  | Error errors, _, _ | _, Error errors, _ | _, _, Error errors -> Error errors
  | Ok display_name, Ok (protocol, api_format), Ok transport ->
    let request_path_result =
      match typed_find "a string" path tbl "request-path" Otoml.get_string with
      | Error _ as error -> error
      | Ok None -> Ok None
      | Ok (Some value) ->
        let uri = Uri.of_string value in
        (match transport with
         | Http _ when value <> "" && value.[0] = '/'
             && Uri.scheme uri = None && Uri.host uri = None
             && Uri.query uri = [] && Uri.fragment uri = None
             && not (String.exists (function '\000'..'\032' | '\127' -> true | _ -> false) value) ->
           Ok (Some value)
         | Http _ | Cli _ -> Error (error (path ^ ".request-path")
             "request-path must be an HTTP endpoint-relative absolute path without query or fragment"))
    in
    let account_home_result =
      match typed_find "a string" path tbl "account-home" Otoml.get_string with
      | Error errors -> Error errors
      | Ok None -> Ok None
      | Ok (Some home) ->
        (match api_format with
         | Codex_app_server_runtime | Claude_code_runtime | Muse_serve_runtime
           when Runtime_account_home.is_valid home -> Ok (Some home)
         | Codex_app_server_runtime | Claude_code_runtime | Muse_serve_runtime ->
           Error (error (path ^ ".account-home") "account-home must be a non-empty absolute path without surrounding whitespace")
         | Runtime_schema.Messages_api | Runtime_schema.Chat_completions_api
         | Runtime_schema.Ollama_api | Runtime_schema.Gemini_api | Runtime_schema.Vertex_gemini_api
         | Runtime_schema.Antigravity_cli_runtime
         | Runtime_schema.Vibe_cli_runtime -> Error (error (path ^ ".account-home") "account-home is valid only for Claude Code, Codex and Muse Code official clients"))
    in
    let is_non_interactive_result =
      typed_find_or "a boolean" path tbl "is-non-interactive" Otoml.get_boolean ~default:false
    in
    let credentials_result =
      match Otoml.find_opt tbl Fun.id [ "credentials" ] with
      | Some cred_tbl ->
        Result.map Option.some (parse_credential ~home cred_tbl (path ^ ".credentials"))
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
           (match
              typed_find
                "a string"
                (path ^ ".healthcheck")
                healthcheck_tbl
                "path"
                Otoml.get_string
            with
            | Error _ as error -> error
            | Ok None -> Ok None
            | Ok (Some healthcheck_path) when String.length healthcheck_path > 0
                                           && Char.equal healthcheck_path.[0] '/' ->
              Ok (Some healthcheck_path)
            | Ok (Some healthcheck_path) ->
              Error
                (error
                   (path ^ ".healthcheck.path")
                   (Printf.sprintf
                      "healthcheck.path must be absolute, got %S"
                      healthcheck_path)))
         | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
         | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
         | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _)
         | Some (Otoml.TomlLocalTime _) | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) ->
           Error
             (error (path ^ ".healthcheck") "healthcheck must be a TOML table")
       in
       let usage_read_result = parse_usage_read ~path ~api_format ~credentials ~transport tbl in
       let headers =
         match Otoml.find_opt tbl Fun.id [ "headers" ] with
         | None -> None
         | Some h_tbl -> Some (parse_headers h_tbl (path ^ ".headers"))
       in
       (* Optional per-provider bound on the phase before the response headers
          (agent-core boundary). There is no kind-based default behind it:
          [resolve_explicit_deadline] maps [None] to [Unbounded]
          (http_client.ml). A keeper turn is still bounded by the keeper's
          first-event budget, but an exact-output slot is not, which is why
          plan admission refuses a target carrying neither deadline. *)
       (* The dialect an endpoint speaks, for an endpoint AGENT_CORE has no
          provider row for. Only [protocol] is required: it names the request
          shape, and for a catalogued provider the catalog row names the
          dialect. The two are not the same fact — glm-coding speaks GLM over
          an OpenAI-compatible shape — so an uncatalogued endpoint has to say
          which one it is or nothing can choose its capability base. *)
       let wire_kind_result =
         match typed_find "a string" path tbl "kind" Otoml.get_string with
         | Error errors -> Error errors
         | Ok None -> Ok None
         | Ok (Some raw) ->
           (match Llm_provider.Provider_config.provider_kind_of_string raw with
            | Some kind -> Ok (Some kind)
            | None ->
              Error
                (error
                   (path ^ ".kind")
                   (Printf.sprintf
                      "unknown kind %S — expected one of %s"
                      raw
                      (String.concat
                         ", "
                         (List.map
                            Llm_provider.Provider_config.string_of_provider_kind
                            Llm_provider.Provider_config.all_provider_kinds)))))
       in
       let connect_timeout_key = Runtime_schema.connect_timeout_s_key in
       let connect_timeout_result =
         strict_float_find path tbl connect_timeout_key
         |> positive_finite_float_opt_field ~path ~key:connect_timeout_key
       in
       let exact_body_timeout_key = Runtime_schema.exact_body_timeout_s_key in
       let exact_body_timeout_result =
         strict_float_find path tbl exact_body_timeout_key
         |> positive_finite_float_opt_field ~path ~key:exact_body_timeout_key
       in
       (let ( let* ) = Result.bind in
        let* max_context = positive_int_opt_field ~path ~key:"max-context" tbl in
        let* admission_priority_run_limit =
          positive_int_opt_field ~path ~key:Runtime_schema.admission_priority_run_limit_key tbl
        in
        let* capabilities = capabilities_result in
        let* enabled_opt = enabled_result in
        let* healthcheck_path = healthcheck_result in
        let* connect_timeout_s = connect_timeout_result in
        let* exact_body_timeout_s = exact_body_timeout_result in
        let* is_non_interactive = is_non_interactive_result in
        let* wire_kind = wire_kind_result in
        let* request_path = request_path_result in
        let* account_home = account_home_result in
        let* usage_read = usage_read_result in
          let enabled = match enabled_opt with Some value -> value | None -> true in
          Ok
            { Runtime_schema.id
            ; enabled
            ; display_name
            ; protocol
            ; api_format
            ; wire_kind
            ; request_path
            ; transport
            ; is_non_interactive
            ; credentials
            ; max_context
            ; account_home
            ; capabilities
            ; healthcheck_path
            ; headers
            ; connect_timeout_s
            ; exact_body_timeout_s
            ; admission_priority_run_limit
            ; antigravity_cli
            ; usage_read
            }))
;;

let parse_providers ~home (toml : Otoml.t)
  : (Runtime_schema.provider list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ Ns.(key Providers) ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    partition_results
      (List.map
         (fun (id, tbl) ->
            match
              validate_provider_id ~path:(Ns.(path Providers) id) id
            with
            | Error _ as error -> error
            | Ok () -> parse_provider ~home id tbl)
         entries)
  | Some
      ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ) ->
    Error (error (Ns.(key Providers)) "[providers] must be a TOML table")
;;
