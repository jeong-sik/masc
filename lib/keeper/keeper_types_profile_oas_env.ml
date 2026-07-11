(** Scan a flat TOML doc for keys under [[keeper.oas_env]]. Only current OAS
    provider/control prefixes and [MASC_KEEPER_OAS_*] are accepted. Any other
    entries are dropped. This guards against arbitrary process env injection via
    keeper TOML. Values are coerced to strings via
    [string_of_toml_value_for_env] (bool -> "1"/"0"), so integers and booleans
    in TOML map to the string shapes the active OAS env readers understand. *)
let string_of_toml_value_for_env = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f -> Some (string_of_float f)
  | Keeper_toml_loader.Toml_bool true -> Some "1"
  | Keeper_toml_loader.Toml_bool false -> Some "0"
  | Keeper_toml_loader.Toml_string_array _ -> None
;;

let oas_env_key_prefix = "keeper.oas_env."

let keeper_unified_max_tokens_oas_env_key = "MASC_KEEPER_OAS_UNIFIED_MAX_TOKENS"

let keeper_unified_max_tokens_toml_key =
  oas_env_key_prefix ^ keeper_unified_max_tokens_oas_env_key
;;

let oas_env_key_is_allowed suffix =
  String.starts_with suffix ~prefix:"MASC_KEEPER_OAS_"
  || (String.starts_with suffix ~prefix:"OAS_"
      && (try
            let after_oas =
              String.sub suffix 4 (String.length suffix - 4)
            in
            String.contains after_oas '_'
          with Invalid_argument _ -> false))
;;

(* Observability for the env-key allowlist drop branch.  Previously
   any [keeper.oas_env.<X>] entry whose suffix did not match
   [OAS_<PROVIDER>_<KEY>] or [MASC_KEEPER_OAS_*] was filtered out with
   no signal — operators could not tell whether a typo'd key
   (e.g. [OAS_CLUADE_API_KEY]) had been silently ignored.
   Closes the silent-drop gap noted in
   .tmp/memory-compacting-analysis.html (oas_env allowlist drop). *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string OasEnvKeyRejections)
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
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string OasEnvKeyRejections)
            ();
          Log.Keeper.warn
            "keeper.oas_env: dropping key=%S — suffix %S not in \
             allowlist (OAS_<PROVIDER>_* | MASC_KEEPER_OAS_<suffix>); \
             fix the TOML or expand the allowlist"
            k
            suffix;
          ignore v;
          None))
      else None)
    doc
;;

let validate_unified_max_tokens_toml_value doc =
  match List.assoc_opt keeper_unified_max_tokens_toml_key doc with
  | None -> Ok ()
  | Some (Keeper_toml_loader.Toml_int value) when value > 0 -> Ok ()
  | Some _ ->
    Error
      (Printf.sprintf
         "%s must be a positive integer TOML value"
         keeper_unified_max_tokens_toml_key)
;;

let parse_unified_max_tokens_override_of_oas_env pairs =
  let key = keeper_unified_max_tokens_oas_env_key in
  let raw_opt = List.assoc_opt key pairs in
  match raw_opt with
  | None -> Ok None
  | Some raw ->
    let trimmed = String.trim raw in
    (match int_of_string_opt trimmed with
     | Some value when value > 0 -> Ok (Some value)
     | Some _ ->
       Error
         (Printf.sprintf
            "keeper.oas_env.%s must be a positive integer, got %S"
            key
            raw)
     | None ->
       Error
         (Printf.sprintf
            "keeper.oas_env.%s must be a positive integer, got %S"
            key
            raw))
;;

let unified_max_tokens_override_of_oas_env ?keeper_name pairs =
  match parse_unified_max_tokens_override_of_oas_env pairs with
  | Ok value -> value
  | Error detail ->
       let keeper =
         match keeper_name with
         | Some name -> name
         | None -> "(unknown)"
       in
       Log.Keeper.warn
         "keeper.oas_env: invalid max_tokens override for keeper=%s: %s"
         keeper
         detail;
       None
;;
