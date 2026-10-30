(** Scan a flat TOML doc for keys under [[keeper.agent_core_env]]. Only current AGENT_CORE
    provider/control prefixes are accepted. Any other
    entries are dropped. This guards against arbitrary process env injection via
    keeper TOML. Values are coerced to strings via
    [string_of_toml_value_for_env] (bool -> "1"/"0"), so integers and booleans
    in TOML map to the string shapes the active AGENT_CORE env readers understand. *)
let string_of_toml_value_for_env = function
  | Keeper_toml_loader.Toml_string s -> Some s
  | Keeper_toml_loader.Toml_int i -> Some (string_of_int i)
  | Keeper_toml_loader.Toml_float f -> Some (string_of_float f)
  | Keeper_toml_loader.Toml_bool true -> Some "1"
  | Keeper_toml_loader.Toml_bool false -> Some "0"
  | ( Keeper_toml_loader.Toml_string_array _
    | Keeper_toml_loader.Toml_array _
    | Keeper_toml_loader.Toml_table _
    | Keeper_toml_loader.Toml_inline_table _
    | Keeper_toml_loader.Toml_table_array _
    | Keeper_toml_loader.Toml_offset_datetime _
    | Keeper_toml_loader.Toml_local_datetime _
    | Keeper_toml_loader.Toml_local_date _
    | Keeper_toml_loader.Toml_local_time _ ) ->
    None
;;

let agent_core_env_key_prefix = "keeper.agent_core_env."

let agent_core_env_key_is_allowed suffix =
  let env_prefix = "AGENT_CORE_" in
  let env_prefix_len = String.length env_prefix in
  String.starts_with suffix ~prefix:env_prefix
  && (try
        let after_agent_core =
          String.sub suffix env_prefix_len (String.length suffix - env_prefix_len)
        in
        String.contains after_agent_core '_'
      with Invalid_argument _ -> false)
;;

(* Observability for the env-key allowlist drop branch.  Previously
   any [keeper.agent_core_env.<X>] entry whose suffix did not match
   [AGENT_CORE_<PROVIDER>_<KEY>] was filtered out with
   no signal — operators could not tell whether a typo'd key
   (e.g. [AGENT_CORE_CLUADE_API_KEY]) had been silently ignored.
   Closes the silent-drop gap noted in
   .tmp/memory-compacting-analysis.html (agent_core_env allowlist drop). *)
let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string Agent_coreEnvKeyRejections)
    ~help:
      "Total keeper.agent_core_env.<X> entries rejected by the allowlist \
       in [extract_agent_core_env_from_doc].  Each rejected key produces \
       a warn line; non-zero counts at startup mean the TOML \
       contains keys the runtime silently ignored."
    ()
;;

let extract_agent_core_env_from_doc (doc : Keeper_toml_loader.toml_doc)
    : (string * string) list =
  let prefix_len = String.length agent_core_env_key_prefix in
  List.filter_map
    (fun (k, v) ->
      if
        String.length k > prefix_len
        && String.starts_with k ~prefix:agent_core_env_key_prefix
      then (
        let suffix = String.sub k prefix_len (String.length k - prefix_len) in
        if agent_core_env_key_is_allowed suffix then
          Option.map (fun sv -> suffix, sv) (string_of_toml_value_for_env v)
        else (
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string Agent_coreEnvKeyRejections)
            ();
          Log.Keeper.warn
            "keeper.agent_core_env: dropping key=%S — suffix %S not in \
             allowlist (AGENT_CORE_<PROVIDER>_...); \
             fix the TOML or expand the allowlist"
            k
            suffix;
          None))
      else None)
    doc
;;
