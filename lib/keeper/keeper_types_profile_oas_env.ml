(** Scan a flat TOML doc for keys under [[keeper.oas_env]]. Only current OAS
    provider/control prefixes are accepted. Any other
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

let oas_env_key_is_allowed suffix =
  String.starts_with suffix ~prefix:"OAS_"
  && (try
        let after_oas = String.sub suffix 4 (String.length suffix - 4) in
        String.contains after_oas '_'
      with Invalid_argument _ -> false)
;;

(* Observability for the env-key allowlist drop branch.  Previously
   any [keeper.oas_env.<X>] entry whose suffix did not match
   [OAS_<PROVIDER>_<KEY>] was filtered out with
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
             allowlist (OAS_<PROVIDER>_...); \
             fix the TOML or expand the allowlist"
            k
            suffix;
          ignore v;
          None))
      else None)
    doc
;;
