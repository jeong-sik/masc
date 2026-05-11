(** Declarative cascade TOML parser (RFC-0058 v2).

    Parses the 5-layer TOML schema into typed [cascade_config].
    Reserved top-level namespaces: providers, models, system, tier,
    tier-group, routes, profiles. Any other top-level table is a
    provider alias, with sub-tables as model bindings or aliases. *)

open Cascade_declarative_types

type parse_error =
  { path : string
  ; message : string
  }
[@@deriving show]

(* --- Error accumulation --- *)

let error path message = [ { path; message } ]
let add_errors acc more = acc @ more

(* --- Protocol string -> cascade_api_format --- *)

let api_format_of_protocol (s : string) : (cascade_api_format, string) result =
  match s with
  | "anthropic-cli" | "anthropic-http" -> Ok Messages_api
  | "openai-http" | "google-cli" | "kimi-cli" -> Ok Chat_completions_api
  | "ollama-http" -> Ok Ollama_api
  | _ ->
    Error
      (Printf.sprintf
         "unknown protocol %S: expected one of anthropic-cli, anthropic-http, \
          openai-http, google-cli, kimi-cli, ollama-http"
         s)
;;

(* --- Transport extraction --- *)

let transport_of_provider (tbl : Otoml.t) (id : string)
  : (cascade_transport, string) result
  =
  let endpoint = Otoml.find_opt tbl Otoml.get_string [ "endpoint" ] in
  let command = Otoml.find_opt tbl Otoml.get_string [ "command" ] in
  match endpoint, command with
  | Some url, None -> Ok (Http url)
  | None, Some cmd -> Ok (Cli cmd)
  | Some _, Some _ ->
    Error (Printf.sprintf "provider %s: cannot specify both 'endpoint' and 'command'" id)
  | None, None ->
    Error (Printf.sprintf "provider %s: must specify either 'endpoint' or 'command'" id)
;;

(* --- Layer 1: Providers --- *)

let parse_credential (tbl : Otoml.t) (path : string)
  : (cascade_credential, parse_error list) result
  =
  let cred_type = Otoml.find tbl Otoml.get_string [ "type" ] in
  match cred_type with
  | "env" ->
    (match Otoml.find_opt tbl Otoml.get_string [ "key" ] with
     | Some key -> Ok (Env key)
     | None -> Error (error (path ^ ".key") "credential type 'env' requires 'key'"))
  | "file" ->
    (match Otoml.find_opt tbl Otoml.get_string [ "path" ] with
     | Some p -> Ok (File p)
     | None -> Error (error (path ^ ".path") "credential type 'file' requires 'path'"))
  | "inline" ->
    (match Otoml.find_opt tbl Otoml.get_string [ "value" ] with
     | Some v -> Ok (Inline v)
     | None -> Error (error (path ^ ".value") "credential type 'inline' requires 'value'"))
  | t -> Error (error (path ^ ".type") (Printf.sprintf "unknown credential type %S" t))
;;

let parse_capabilities ~(path : string) (tbl : Otoml.t) : cascade_capabilities =
  let b key = Otoml.find_or ~default:false tbl Otoml.get_boolean [ key ] in
  let string_list_field key =
    match Otoml.find_opt tbl Fun.id [ key ] with
    | None -> []
    | Some v ->
      (try Otoml.get_array Otoml.get_string v
       with _ ->
         Logs.warn (fun m ->
           m
             "cascade_declarative_parser: %s.capabilities.%s — \
              expected string array, ignoring"
             path
             key);
         [])
  in
  let positive_int_opt_field key =
    (* Reject non-positive values at parse time: a cap of 0 or -N would
       clamp every cascade attempt to a meaningless budget downstream. *)
    match Otoml.find_opt tbl Otoml.get_integer [ key ] with
    | None -> None
    | Some n when n > 0 -> Some n
    | Some n ->
      Logs.warn (fun m ->
        m
          "cascade_declarative_parser: %s.capabilities.%s = %d — \
           expected positive integer, ignoring"
          path
          key
          n);
      None
  in
  {
    supports_inline_tools = b "supports-inline-tools";
    supports_runtime_mcp_tools = b "supports-runtime-mcp-tools";
    supports_runtime_tool_events = b "supports-runtime-tool-events";
    supports_runtime_mcp_http_headers = b "supports-runtime-mcp-http-headers";
    requires_per_keeper_bridging_for_bound_actor_tools =
      b "requires-per-keeper-bridging-for-bound-actor-tools";
    identity_runtime_mcp_header_keys =
      string_list_field "identity-runtime-mcp-header-keys";
    argv_prompt_preflight = b "argv-prompt-preflight";
    uses_anthropic_caching = b "uses-anthropic-caching";
    max_turns_per_attempt = positive_int_opt_field "max-turns-per-attempt";
    tolerates_bound_actor_fallback = b "tolerates-bound-actor-fallback";
  }
;;

(** Parse a [providers.<id>.headers] sub-table into a sorted association
    list. Caller invokes only when the sub-table key exists, so the
    returned list distinguishes "declared but empty / all entries rejected"
    (empty list) from "no sub-table" (caller passes [None]).

    Non-table values at the sub-table position emit a WARN and yield an
    empty list. Non-string header values emit a per-entry WARN and are
    dropped. The result is sorted by key for deterministic show/eq. *)
let parse_headers (tbl : Otoml.t) (path : string)
  : (string * string) list
  =
  match Otoml.get_table tbl with
  | exception _ ->
    Logs.warn (fun m ->
      m
        "cascade_declarative_parser: %s — expected TOML table, got non-table \
         value; treating as empty"
        path);
    []
  | entries ->
    let pairs =
      List.filter_map
        (fun (k, v) ->
          match Otoml.get_string v with
          | s -> Some (k, s)
          | exception _ ->
            Logs.warn (fun m ->
              m
                "cascade_declarative_parser: %s.%s — non-string header value, \
                 ignoring"
                path
                k);
            None)
        entries
    in
    List.sort (fun (a, _) (b, _) -> String.compare a b) pairs
;;

let parse_provider (id : string) (tbl : Otoml.t)
  : (cascade_provider, parse_error list) result
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
    | Some p -> api_format_of_protocol p
    | None -> Error "missing required field 'protocol'"
  in
  let transport_result = transport_of_provider tbl id in
  match protocol_result, transport_result with
  | Error e, _ -> Error (error (path ^ ".protocol") e)
  | _, Error e -> Error (error path e)
  | Ok api_format, Ok transport ->
    let is_non_interactive =
      Otoml.find_or ~default:false tbl Otoml.get_boolean [ "is-non-interactive" ]
    in
    let credentials =
      match Otoml.find_opt tbl Fun.id [ "credentials" ] with
      | Some cred_tbl ->
        (match parse_credential cred_tbl (path ^ ".credentials") with
         | Ok c -> Some c
         | Error errs ->
           Logs.warn (fun m ->
             m
               "cascade_declarative_parser: %s"
               (let e = List.hd errs in
                Printf.sprintf "%s: %s" e.path e.message));
           None)
      | None -> None
    in
    let liveness_class =
      match Otoml.find_opt tbl Fun.id [ "liveness" ] with
      | None -> None
      | Some live_tbl ->
        (match Otoml.find_opt live_tbl Otoml.get_string [ "class" ] with
         | None -> None
         | Some raw ->
           (match String.lowercase_ascii (String.trim raw) with
            | "cloud_fast" -> Some Cloud_fast
            | "cloud_thinking" -> Some Cloud_thinking
            | "local_27b" -> Some Local_27b
            | "local_70b_plus" -> Some Local_70b_plus
            | other ->
              Logs.warn (fun m ->
                m "cascade_declarative_parser: %s.liveness.class \
                   unknown value %S — ignoring (expected one of \
                   cloud_fast, cloud_thinking, local_27b, \
                   local_70b_plus)"
                  path other);
              None))
    in
    let capabilities =
      Otoml.find_opt tbl Fun.id [ "capabilities" ]
      |> Option.map (parse_capabilities ~path)
    in
    let headers =
      match Otoml.find_opt tbl Fun.id [ "headers" ] with
      | None -> None
      | Some h_tbl -> Some (parse_headers h_tbl (path ^ ".headers"))
    in
    Ok { id; display_name; api_format; transport; is_non_interactive;
         credentials; liveness_class; capabilities; headers }
;;

let parse_providers (toml : Otoml.t) : (cascade_provider list, parse_error list) result =
  match Otoml.find_opt toml Fun.id [ "providers" ] with
  | None -> Ok []
  | Some providers_tbl ->
    let entries = Otoml.get_table providers_tbl in
    let results = List.map (fun (id, tbl) -> parse_provider id tbl) entries in
    let errs =
      List.filter_map
        (function
          | Error e -> Some e
          | Ok _ -> None)
        results
    in
    if errs <> []
    then Error (List.concat errs)
    else
      Ok
        (List.filter_map
           (function
             | Ok p -> Some p
             | _ -> None)
           results)
;;

(* --- Layer 2: Models --- *)

let parse_model (id : string) (tbl : Otoml.t)
  : (cascade_model_spec, parse_error list) result
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
    let max_thinking_budget =
      Otoml.find_opt tbl Otoml.get_integer [ "max-thinking-budget" ]
    in
    let streaming = Otoml.find_or ~default:true tbl Otoml.get_boolean [ "streaming" ] in
    Ok
      { id
      ; api_name
      ; tools_support
      ; max_context
      ; thinking_support
      ; max_thinking_budget
      ; streaming
      })
;;

let parse_models (toml : Otoml.t) : (cascade_model_spec list, parse_error list) result =
  match Otoml.find_opt toml Fun.id [ "models" ] with
  | None -> Ok []
  | Some models_tbl ->
    let entries = Otoml.get_table models_tbl in
    let results = List.map (fun (id, tbl) -> parse_model id tbl) entries in
    let errs =
      List.filter_map
        (function
          | Error e -> Some e
          | Ok _ -> None)
        results
    in
    if errs <> []
    then Error (List.concat errs)
    else
      Ok
        (List.filter_map
           (function
             | Ok m -> Some m
             | _ -> None)
           results)
;;

(* --- Reserved namespace detection --- *)

let reserved_namespaces =
  [ "providers"; "models"; "system"; "tier"; "tier-group"; "routes"; "profiles" ]
;;

let is_reserved (name : string) : bool = List.mem name reserved_namespaces

(* --- Layer 3 & 4: Bindings and Aliases from provider alias tables --- *)

type provider_table_entry =
  | Binding_entry of cascade_binding
  | Alias_entry of cascade_alias

let parse_binding_fields (provider_id : string) (model_id : string) (tbl : Otoml.t)
  : cascade_binding
  =
  let is_default = Otoml.find_or ~default:false tbl Otoml.get_boolean [ "is-default" ] in
  (* RFC-0058 §3.4: max-concurrent is REQUIRED. The sentinel value 0
     here makes the omission visible to the validator (R11) instead of
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
  { provider_id
  ; model_id
  ; is_default
  ; max_concurrent
  ; price_input
  ; price_output
  ; keep_alive
  ; num_ctx
  }
;;

let parse_alias_fields
      (provider_id : string)
      (model_id : string)
      (alias_name : string)
      (tbl : Otoml.t)
  : cascade_alias
  =
  let max_input = Otoml.find_opt tbl Otoml.get_integer [ "max-input" ] in
  let max_output = Otoml.find_opt tbl Otoml.get_integer [ "max-output" ] in
  let temperature = Otoml.find_opt tbl Otoml.get_float [ "temperature" ] in
  let thinking_enabled = Otoml.find_opt tbl Otoml.get_boolean [ "thinking-enabled" ] in
  let thinking_budget = Otoml.find_opt tbl Otoml.get_integer [ "thinking-budget" ] in
  { provider_id
  ; model_id
  ; name = alias_name
  ; max_input
  ; max_output
  ; temperature
  ; thinking_enabled
  ; thinking_budget
  }
;;

let parse_provider_alias_table (provider_id : string) (tbl : Otoml.t)
  : provider_table_entry list
  =
  let entries = Otoml.get_table tbl in
  List.concat_map
    (fun (model_id_or_alias, sub) ->
       match sub with
       | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
         let leaf_fields =
           List.filter
             (fun (_, v) ->
                match v with
                | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> false
                | _ -> true)
             fields
         in
         let sub_tables =
           List.filter
             (fun (_, v) ->
                match v with
                | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> true
                | _ -> false)
             fields
         in
         let binding =
           let synthetic_tbl = Otoml.TomlTable leaf_fields in
           parse_binding_fields provider_id model_id_or_alias synthetic_tbl
         in
         let aliases =
           List.map
             (fun (alias_name, alias_tbl) ->
                Alias_entry
                  (parse_alias_fields provider_id model_id_or_alias alias_name alias_tbl))
             sub_tables
         in
         Binding_entry binding :: aliases
       | _ -> [ Binding_entry (parse_binding_fields provider_id model_id_or_alias sub) ])
    entries
;;

let parse_bindings_and_aliases (toml : Otoml.t)
  : cascade_binding list * cascade_alias list
  =
  let top_entries = Otoml.get_table toml in
  (* Only top-level tables can describe a provider alias; scalar / array
     entries (e.g. an operator-authored ["comment = ..."]) would crash
     [Otoml.get_table] in [parse_provider_alias_table]. *)
  let provider_aliases =
    List.filter
      (fun (name, value) ->
         (not (is_reserved name))
         &&
         match value with
         | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> true
         | _ -> false)
      top_entries
  in
  let all_entries =
    List.concat_map
      (fun (provider_id, tbl) -> parse_provider_alias_table provider_id tbl)
      provider_aliases
  in
  let bindings =
    List.filter_map
      (function
        | Binding_entry b -> Some b
        | _ -> None)
      all_entries
  in
  let aliases =
    List.filter_map
      (function
        | Alias_entry a -> Some a
        | _ -> None)
      all_entries
  in
  bindings, aliases
;;

(* --- Layer 5a: Tiers --- *)

let strategy_of_string (s : string) : (cascade_strategy, string) result =
  match s with
  | "failover" -> Ok Failover
  | "capacity_aware" -> Ok Capacity_aware
  | "weighted_random" -> Ok Weighted_random
  | "circuit_breaker_cycling" -> Ok Circuit_breaker_cycling
  | "priority_tier" -> Ok Priority_tier
  | "sticky" -> Ok Sticky
  | "round_robin" -> Ok Round_robin
  | _ ->
    Error
      (Printf.sprintf
         "unknown strategy %S: expected one of failover, capacity_aware, \
          weighted_random, circuit_breaker_cycling, priority_tier, sticky, round_robin"
         s)
;;

let parse_cycle_policy (tbl : Otoml.t) : cascade_cycle_policy option =
  let max_cycles = Otoml.find_opt tbl Otoml.get_integer [ "max-cycles" ] in
  let backoff_base = Otoml.find_opt tbl Otoml.get_integer [ "backoff-base-ms" ] in
  let backoff_cap = Otoml.find_opt tbl Otoml.get_integer [ "backoff-cap-ms" ] in
  match max_cycles, backoff_base, backoff_cap with
  | Some mc, Some bb, Some bc ->
    Some { max_cycles = mc; backoff_base_ms = bb; backoff_cap_ms = bc }
  | _ -> None
;;

let parse_scoring_params (tbl : Otoml.t) : cascade_scoring_params option =
  let lat = Otoml.find_opt tbl Otoml.get_float [ "latency-baseline-ms" ] in
  let rlw = Otoml.find_opt tbl Otoml.get_float [ "rate-limit-recency-window-s" ] in
  let rld = Otoml.find_opt tbl Otoml.get_float [ "rate-limit-decay-base" ] in
  let rls = Otoml.find_opt tbl Otoml.get_integer [ "rate-limit-skip-after" ] in
  let sew = Otoml.find_opt tbl Otoml.get_float [ "server-error-recency-window-s" ] in
  let sed = Otoml.find_opt tbl Otoml.get_float [ "server-error-decay-base" ] in
  let ses = Otoml.find_opt tbl Otoml.get_integer [ "server-error-skip-after" ] in
  match lat, rlw, rld, rls, sew, sed, ses with
  | Some a, Some b, Some c, Some d, Some e, Some f, Some g ->
    Some
      { latency_baseline_ms = a
      ; rate_limit_recency_window_s = b
      ; rate_limit_decay_base = c
      ; rate_limit_skip_after = d
      ; server_error_recency_window_s = e
      ; server_error_decay_base = f
      ; server_error_skip_after = g
      }
  | _ -> None
;;

let parse_tier (name : string) (tbl : Otoml.t) : (cascade_tier, parse_error list) result =
  let path = Printf.sprintf "tier.%s" name in
  let members =
    match Otoml.find_opt tbl (Otoml.get_array Otoml.get_string) [ "members" ] with
    | Some m -> m
    | None -> []
  in
  let strategy_result =
    match Otoml.find_opt tbl Otoml.get_string [ "strategy" ] with
    | Some s -> strategy_of_string s
    | None -> Ok Failover
  in
  match strategy_result with
  | Error e -> Error (error (path ^ ".strategy") e)
  | Ok strategy ->
    let max_concurrent = Otoml.find_opt tbl Otoml.get_integer [ "max-concurrent" ] in
    let cycle_policy = parse_cycle_policy tbl in
    let sticky_ttl_ms = Otoml.find_opt tbl Otoml.get_integer [ "sticky-ttl-ms" ] in
    let scoring_params = parse_scoring_params tbl in
    Ok
      { name
      ; members
      ; strategy
      ; max_concurrent
      ; cycle_policy
      ; sticky_ttl_ms
      ; scoring_params
      }
;;

let parse_tiers (toml : Otoml.t) : (cascade_tier list, parse_error list) result =
  match Otoml.find_opt toml Fun.id [ "tier" ] with
  | None -> Ok []
  | Some tier_tbl ->
    let entries = Otoml.get_table tier_tbl in
    let results = List.map (fun (name, tbl) -> parse_tier name tbl) entries in
    let errs =
      List.filter_map
        (function
          | Error e -> Some e
          | Ok _ -> None)
        results
    in
    if errs <> []
    then Error (List.concat errs)
    else
      Ok
        (List.filter_map
           (function
             | Ok t -> Some t
             | _ -> None)
           results)
;;

(* --- Layer 5b: Tier Groups --- *)

let parse_tier_group (name : string) (tbl : Otoml.t)
  : (cascade_tier_group, parse_error list) result
  =
  let path = Printf.sprintf "tier-group.%s" name in
  let tiers =
    match Otoml.find_opt tbl (Otoml.get_array Otoml.get_string) [ "tiers" ] with
    | Some t -> t
    | None -> []
  in
  let strategy_result =
    match Otoml.find_opt tbl Otoml.get_string [ "strategy" ] with
    | Some s -> strategy_of_string s
    | None -> Ok Failover
  in
  match strategy_result with
  | Error e -> Error (error (path ^ ".strategy") e)
  | Ok strategy ->
    let fallback = Otoml.find_or ~default:false tbl Otoml.get_boolean [ "fallback" ] in
    Ok { name; tiers; strategy; fallback }
;;

let parse_tier_groups (toml : Otoml.t)
  : (cascade_tier_group list, parse_error list) result
  =
  match Otoml.find_opt toml Fun.id [ "tier-group" ] with
  | None -> Ok []
  | Some tg_tbl ->
    let entries = Otoml.get_table tg_tbl in
    let results = List.map (fun (name, tbl) -> parse_tier_group name tbl) entries in
    let errs =
      List.filter_map
        (function
          | Error e -> Some e
          | Ok _ -> None)
        results
    in
    if errs <> []
    then Error (List.concat errs)
    else
      Ok
        (List.filter_map
           (function
             | Ok g -> Some g
             | _ -> None)
           results)
;;

(* --- Layer 5c: Routes --- *)

let parse_routes (toml : Otoml.t) : cascade_route list =
  match Otoml.find_opt toml Fun.id [ "routes" ] with
  | None -> []
  | Some routes_tbl ->
    let entries = Otoml.get_table routes_tbl in
    List.filter_map
      (fun (name, tbl) ->
         match tbl with
         | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
           (match Otoml.find_opt tbl Otoml.get_string [ "target" ] with
            | Some target -> Some { name; target }
            | None -> None)
         | _ -> None)
      entries
;;

(* --- System targets --- *)

let parse_system_targets (toml : Otoml.t) : cascade_route list =
  match Otoml.find_opt toml Fun.id [ "system" ] with
  | None -> []
  | Some sys_tbl ->
    let entries = Otoml.get_table sys_tbl in
    List.filter_map
      (fun (name, tbl) ->
         match tbl with
         | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
           (match Otoml.find_opt tbl Otoml.get_string [ "target" ] with
            | Some target -> Some { name; target }
            | None ->
              (match Otoml.find_opt tbl Otoml.get_string [ "binding" ] with
               | Some target -> Some { name; target }
               | None -> None))
         | _ -> None)
      entries
;;

(* --- Top-level parse --- *)

let parse_toml (toml : Otoml.t) : (cascade_config, parse_error list) result =
  let all_errors = ref [] in
  let collect name = function
    | Ok _ -> ()
    | Error errs -> all_errors := !all_errors @ errs
  in
  let providers_result = parse_providers toml in
  let models_result = parse_models toml in
  let tiers_result = parse_tiers toml in
  let tier_groups_result = parse_tier_groups toml in
  collect "providers" providers_result;
  collect "models" models_result;
  collect "tiers" tiers_result;
  collect "tier_groups" tier_groups_result;
  let bindings, aliases = parse_bindings_and_aliases toml in
  let routes = parse_routes toml in
  let system_targets = parse_system_targets toml in
  if !all_errors <> []
  then Error !all_errors
  else (
    let providers =
      match providers_result with
      | Ok p -> p
      | Error _ -> []
    in
    let models =
      match models_result with
      | Ok m -> m
      | Error _ -> []
    in
    let tiers =
      match tiers_result with
      | Ok t -> t
      | Error _ -> []
    in
    let tier_groups =
      match tier_groups_result with
      | Ok g -> g
      | Error _ -> []
    in
    Ok
      { providers; models; bindings; aliases; tiers; tier_groups; routes; system_targets })
;;

let parse_string (content : string) : (cascade_config, parse_error list) result =
  match Otoml.Parser.from_string_result content with
  | Ok toml -> parse_toml toml
  | Error msg -> Error [ { path = "<parse>"; message = msg } ]
;;

let parse_file (path : string) : (cascade_config, parse_error list) result =
  try
    let toml = Otoml.Parser.from_file path in
    parse_toml toml
  with
  | Otoml.Parse_error (_, msg) -> Error [ { path; message = msg } ]
  | Sys_error msg -> Error [ { path; message = msg } ]
;;
