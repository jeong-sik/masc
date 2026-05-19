(** Scan a flat TOML doc for keys under [[keeper.oas_env]].  Only provider
    OAS prefixes and [MASC_KEEPER_OAS_*] are accepted.  The legacy
    [MASC_KEEPER_UNIFIED_MAX_TOKENS] key remains accepted as a narrow migration
    alias for the canonical [MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS].  Any other
    entries are dropped.  This guards against arbitrary process env injection
    via keeper TOML.  Values are coerced to strings via
    [string_of_toml_value_for_env] (bool -> "1"/"0"), so integers and booleans
    in TOML map to the string shapes the OAS transport build_args already
    understand. *)
let string_of_toml_value_for_env = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f -> Some (string_of_float f)
  | Keeper_toml_loader.Toml_bool true -> Some "1"
  | Keeper_toml_loader.Toml_bool false -> Some "0"
  | Keeper_toml_loader.Toml_string_array _ -> None
;;

let oas_env_key_prefix = "keeper.oas_env."

let oas_env_allowed_prefixes =
  [ "OAS_CLAUDE_"; "OAS_CODEX_"; "OAS_GEMINI_"; "MASC_KEEPER_OAS_" ]
;;

let keeper_unified_max_tokens_oas_env_key = "MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS"

let legacy_keeper_unified_max_tokens_oas_env_key =
  "MASC_KEEPER_UNIFIED_MAX_TOKENS"
;;

let oas_env_allowed_exact_keys = [ legacy_keeper_unified_max_tokens_oas_env_key ]

let oas_env_key_is_allowed suffix =
  List.mem suffix oas_env_allowed_exact_keys
  || List.exists
       (fun p ->
         String.length suffix > String.length p
         && String.sub suffix 0 (String.length p) = p)
       oas_env_allowed_prefixes
;;

(* Observability for the env-key allowlist drop branch.  Previously
   any [keeper.oas_env.<X>] entry whose suffix did not match
   [OAS_(CLAUDE|CODEX|GEMINI)_] or [MASC_KEEPER_OAS_*] was filtered out with
   no signal — operators could not tell whether a typo'd key
   (e.g. [OAS_CLUADE_API_KEY]) had been silently ignored.
   Closes the silent-drop gap noted in
   .tmp/memory-compacting-analysis.html (oas_env allowlist drop). *)
let () =
  Prometheus.register_counter
    ~name:Keeper_metrics.metric_keeper_oas_env_key_rejections
    ~help:
      "Total keeper.oas_env.<X> entries rejected by the allowlist \
       in [extract_oas_env_from_doc].  Each rejected key produces \
       a warn line; non-zero counts at startup mean the TOML \
       contains keys the runtime silently ignored."
    ()
;;

let extract_oas_env_from_doc (doc : Keeper_toml_loader.toml_doc)
    : (string * string) list =
  let prefix_len = String.length oas_env_key_prefix in
  List.filter_map
    (fun (k, v) ->
      if
        String.length k > prefix_len
        && String.starts_with k ~prefix:oas_env_key_prefix
      then (
        let suffix = String.sub k prefix_len (String.length k - prefix_len) in
        if oas_env_key_is_allowed suffix then
          Option.map (fun sv -> suffix, sv) (string_of_toml_value_for_env v)
        else (
          Prometheus.inc_counter
            Keeper_metrics.metric_keeper_oas_env_key_rejections
            ();
          Log.Keeper.warn
            "keeper.oas_env: dropping key=%S — suffix %S not in \
             allowlist (OAS_CLAUDE_* | OAS_CODEX_* | OAS_GEMINI_* | \
             MASC_KEEPER_OAS_<suffix>); fix the TOML or expand the allowlist"
            k
            suffix;
          ignore v;
          None))
      else None)
    doc
;;

let unified_max_tokens_override_of_oas_env ?keeper_name pairs =
  let key, raw_opt =
    match List.assoc_opt keeper_unified_max_tokens_oas_env_key pairs with
    | Some raw -> keeper_unified_max_tokens_oas_env_key, Some raw
    | None ->
      ( legacy_keeper_unified_max_tokens_oas_env_key
      , List.assoc_opt legacy_keeper_unified_max_tokens_oas_env_key pairs )
  in
  match raw_opt with
  | None -> None
  | Some raw ->
    let trimmed = String.trim raw in
    (match int_of_string_opt trimmed with
     | Some value ->
       let min_v = 256 in
       let max_v = 262_144 in
       Some (max min_v (min max_v value))
     | None ->
       let keeper =
         match keeper_name with
         | Some name -> name
         | None -> "(unknown)"
       in
       Log.Keeper.warn
         "keeper.oas_env: ignoring invalid %s=%S for keeper=%s; expected integer"
         key
         raw
         keeper;
       None)
;;

let oas_env_truthy value =
  match String.lowercase_ascii (String.trim value) with
  | "1" | "true" | "yes" | "on" -> true
  | _ -> false
;;

let oas_env_has_non_empty key pairs =
  match List.assoc_opt key pairs with
  | Some value when String.trim value <> "" -> true
  | _ -> false
;;

let effective_oas_env pairs =
  let gemini_mcp_disabled =
    match List.assoc_opt "OAS_GEMINI_NO_MCP" pairs with
    | Some value -> oas_env_truthy value
    | None -> false
  in
  let pairs =
    if
      gemini_mcp_disabled
      && not (oas_env_has_non_empty "OAS_GEMINI_APPROVAL_MODE" pairs)
    then pairs @ [ "OAS_GEMINI_APPROVAL_MODE", "plan" ]
    else pairs
  in
  (* Enable Gemini CLI MCP by default: when not explicitly disabled and
     no operator override exists, inject the "masc" server name so the
     Gemini CLI transport's --allowed-mcp-server-names flag allows the
     MASC MCP server instead of the __oas_no_mcp__ sentinel. *)
  if
    (not gemini_mcp_disabled)
    && not (oas_env_has_non_empty "OAS_GEMINI_ALLOWED_MCP" pairs)
  then pairs @ [ "OAS_GEMINI_ALLOWED_MCP", "masc" ]
  else pairs
;;
