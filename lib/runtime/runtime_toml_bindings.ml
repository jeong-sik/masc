(** Layer 3 of the Runtime TOML parser: the binding tables of each provider
    and the model sets that generate bindings. It also refuses the obsolete
    top-level namespaces. *)

open Runtime_toml_base

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

let unknown_binding_keys ~path ~binding_keys entries =
  List.concat_map
    (fun (key, _) ->
       if List.mem key binding_keys
       then []
       else
         error
           (path ^ "." ^ key)
           (Printf.sprintf
              "unknown binding key %S; a model binding declares only %s"
              key
              (String.concat ", " binding_keys)))
    entries
;;

let parse_binding_fields (provider_id : string) (model_id : string) (tbl : Otoml.t)
  : (Runtime_schema.binding, parse_error list) result
  =
  let path = Printf.sprintf "%s.%s" provider_id model_id in
  (* The keys a binding declares are the keys this function reads: every read
     below goes through these two readers, which note the key. Anything else
     under [<provider>.<model>] is refused, a nested table included -- a
     misspelled [max-concurent] would otherwise load as a binding without
     the cap the operator meant to declare. So every read below stays
     unconditional and bound before the check at the top of the [let*] chain:
     a read placed after it, or only in one branch, would refuse its own key. *)
  let read_keys = ref [] in
  let typed_find kind path tbl key getter =
    read_keys := key :: !read_keys;
    typed_find kind path tbl key getter
  in
  let typed_find_or kind path tbl key getter ~default =
    Result.map (Option.value ~default) (typed_find kind path tbl key getter)
  in
  (* [max-concurrent] is an explicit operator override, not a required binding
     property. Absence means "no static client-side cap", and it also means no
     endpoint admission at all: [Provider_admission] holds a permit only for
     a binding that declares this key, so an undeclared binding dispatches
     straight out, and its provider's [admission-priority-run-limit] does not
     reach it. What remains for it is live health/backoff and whatever the
     provider itself refuses with (e.g. HTTP 429): this side stops sending
     only once the other side says no.

     Whether HTTP bindings should be required to declare it is open; the
     measurements are on #25401.

     An explicit non-positive value is a configuration error: 0 was historically
     used as an omission sentinel, and negative values are meaningless. Reject
     them at load time rather than silently downgrading to "no cap". *)
  let enabled_result = typed_find "a boolean" path tbl "enabled" Otoml.get_boolean in
  let is_default_result = typed_find "a boolean" path tbl "is-default" Otoml.get_boolean in
  let wizard_default_result =
    typed_find "a boolean" path tbl "wizard-default" Otoml.get_boolean
  in
  let disable_parallel_tool_use_result =
    typed_find_or "a boolean" path tbl "disable-parallel-tool-use"
      Otoml.get_boolean ~default:false
  in
  let max_context_result =
    match typed_find "an integer" path tbl "max-context" Otoml.get_integer with
    | Ok (Some n) when n <= 0 ->
      Error (error (path ^ ".max-context") "max-context must be a positive integer")
    | (Ok (None) | Error _ | Ok (Some _)) as result -> result
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
  (* Request-side output budget. AGENT_CORE omits the wire field when this is
     absent, so the provider's own default decides -- 65536 on ollama.com/v1,
     which is where a collapsed generation runs to. Positive or omitted: 0 would
     mean "ask for no output at all", which no caller wants and every envelope
     rejects differently. *)
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
    | (Ok (None) | Error _ | Ok (Some _)) as other -> other
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
    | (Ok (None) | Error _ | Ok (Some _)) as other -> other
  in
  let return_progress_result =
    typed_find "a boolean" path tbl "return-progress" Otoml.get_boolean
  in
  let ( let* ) = Result.bind in
  let* () =
    match
      unknown_binding_keys
        ~path
        ~binding_keys:(List.rev !read_keys)
        (Otoml.get_table tbl)
    with
    | [] -> Ok ()
    | errors -> Error errors
  in
  let* enabled_opt = enabled_result in
  let enabled = match enabled_opt with Some value -> value | None -> true in
  let* is_default_opt = is_default_result in
  let is_default = Option.value is_default_opt ~default:false (* DET-OK: fallback to false if omitted *) in
  let* wizard_default_opt = wizard_default_result in
  let wizard_default =
    Option.value wizard_default_opt ~default:false
    (* DET-OK: omitted means not selected for install wizard. *)
  in
  let* max_context = max_context_result in
  let* max_concurrent = max_concurrent_result in
  let* disable_parallel_tool_use = disable_parallel_tool_use_result in
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
    ; max_context
    ; max_concurrent
    ; disable_parallel_tool_use
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

(* Parse one provider table ([<provider>.*]) into its bindings. Each direct
   sub-key is a model binding table. *)
let parse_provider_table (provider_id : string) (tbl : Otoml.t)
  : (Runtime_schema.binding list, parse_error list) result
  =
  let entries = Otoml.get_table tbl in
  partition_results
    (List.map
       (fun (model_id, sub) ->
          let path = Printf.sprintf "%s.%s" provider_id model_id in
          if is_toml_table sub
          then parse_binding_fields provider_id model_id sub
          else
            Error
              (error
                 path
                 (Printf.sprintf
                    "[%s] holds model bindings; %S must be a [%s] table"
                    provider_id
                    model_id
                    path)))
       entries)
;;

(* Top-level table names that own a binding group, taken from the [\[providers\]]
   keys as written rather than from successfully parsed providers: a malformed
   provider row must be reported as a provider error, not silently reclassify its
   bindings as some other namespace. *)
let declared_provider_ids (toml : Otoml.t) : string list =
  match Otoml.find_opt toml Fun.id [ Ns.(key Providers) ] with
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) -> List.map fst entries
  | Some (Otoml.TomlString _) | None | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> []
;;

(* Sets are source-level declarations, expanded into the same typed bindings
   as explicit tables. The runtime has one provider × model resolution path;
   account homes, credentials, quotas and overrides still belong to providers
   and bindings rather than being copied into model specifications. *)
let parse_model_sets (toml : Otoml.t)
  : ((string * string list) list, parse_error list) result
  =
  let namespace = Ns.(key Model_sets) in
  let declared_models =
    match Otoml.find_opt toml Fun.id [ Ns.(key Models) ] with
    | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
      List.map fst entries
    | Some (Otoml.TomlString _) | None | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
    | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
    | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
    | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> []
  in
  let parse_set (id, tbl) =
    let path = Ns.(path Model_sets) id in
    if not (is_toml_table tbl)
    then Error (error path "model set must be a TOML table")
    else (
      let unknown =
        List.concat_map
          (fun (key, _) ->
             if String.equal key "models" then []
             else error (path ^ "." ^ key) "unknown model set key; expected models")
          (Otoml.get_table tbl)
      in
      match typed_find "an array of strings" path tbl "models"
              (Otoml.get_array Otoml.get_string) with
      | Error errors -> Error (unknown @ errors)
      | Ok None -> Error (unknown @ error (path ^ ".models") "models is required")
      | Ok (Some models) ->
        let references =
          List.concat_map
            (fun model ->
               if List.mem model declared_models then []
               else error (path ^ ".models") (Printf.sprintf "unknown model %S" model))
            models
        in
        let duplicates =
          if List.length models = List.length (List.sort_uniq String.compare models)
          then []
          else error (path ^ ".models") "model ids must not repeat"
        in
        match unknown @ references @ duplicates with
        | [] -> Ok (id, models)
        | errors -> Error errors)
  in
  match Otoml.find_opt toml Fun.id [ namespace ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    partition_results (List.map parse_set entries)
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> Error (error namespace "model_sets must be a TOML table")
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
  let ( let* ) = Result.bind in
  let* sets = parse_model_sets toml in
  let* explicit =
    Result.map List.concat
      (partition_results
         (List.map
            (fun (provider_id, tbl) -> parse_provider_table provider_id tbl)
            provider_tables))
  in
  let provider_set_bindings provider_id =
    let path = Ns.(path Providers) provider_id in
    match Otoml.find_opt toml Fun.id [ Ns.(key Providers); provider_id ] with
    | None -> Ok []
    | Some tbl when is_toml_table tbl ->
      (match typed_find "a string" path tbl "model-set" Otoml.get_string with
       | Error errors -> Error errors
       | Ok None -> Ok []
       | Ok (Some name) ->
         (match List.assoc_opt name sets with
          | None ->
            Error (error (path ^ ".model-set") (Printf.sprintf "unknown model set %S" name))
          | Some models ->
            let missing =
              List.filter
                (fun model_id ->
                   not (List.exists (fun (binding : Runtime_schema.binding) ->
                     String.equal binding.provider_id provider_id
                     && String.equal binding.model_id model_id) explicit))
                models
            in
            partition_results
              (List.map
                 (fun model_id -> parse_binding_fields provider_id model_id (Otoml.TomlTable []))
                 missing)))
    | Some _ -> Ok [] (* parse_providers reports the malformed provider. *)
  in
  let* generated = partition_results (List.map provider_set_bindings declared) in
  Ok (explicit @ List.concat generated)
;;
