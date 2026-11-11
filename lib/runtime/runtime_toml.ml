(** Declarative Runtime TOML parser.

    Parses RFC-0058
    layers 1-3 plus [[runtime].default] into a self-standing
    {!Runtime_schema.config}. Reserved top-level namespaces: providers,
    models, model_sets, runtime, web_search, exec (the [\[exec.ssh.endpoints.*\]] SSH
    endpoint registry, Phase 1 SSH lane spec §4.2). Dropped routing namespaces
    system, routes, and profiles are rejected rather than ignored. A top-level
    table whose name [\[providers\]] declares carries that provider's model
    bindings as sub-tables; every other top-level table belongs to a different
    parser and is left alone.

    Routing layers are intentionally NOT parsed (see {!Runtime_toml} mli):
    Layer 4 aliases, Layer 5 routes/system/profiles, and the
    strategy/cycle-policy/scoring tables are dropped from
    {!Runtime_schema}, so this parser neither reads nor populates them. *)

include Runtime_toml_base
include Runtime_toml_providers
include Runtime_toml_models
include Runtime_toml_registries
include Runtime_toml_bindings

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
  match Otoml.find_opt toml Fun.id [ Ns.(key Runtime); "assignments" ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    let oks, errs =
      List.partition_map
        (fun (keeper_name, value) ->
          match value with
          | Otoml.TomlString runtime_id -> Left (keeper_name, runtime_id)
          | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
          | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
          | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTable _ | Otoml.TomlInlineTable _
          | Otoml.TomlTableArray _ -> Right
              { path = Ns.(path Runtime) ("assignments." ^ keeper_name)
              ; message = "keeper runtime assignment must be a string runtime id"
              })
        entries
    in
    if errs <> [] then Error errs else Ok oks
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) ->
    Error
      [ { path = Ns.(path Runtime) "assignments"
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
  | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
  | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ -> Error (error path (key ^ " must be a string runtime id"))
;;

let parse_runtime_media_failover ~path value =
  (* RFC-0265 — ordered runtime ids for modality-gated reroute. A genuine type
     mismatch (a scalar where an ordered array is required — a bare string cannot
     mean a list) is surfaced as a load [Error], consistent with the sibling
     string leaves ({!parse_runtime_string_leaf}), instead of silently degrading
     to [] (the repo's Unknown→Permissive anti-pattern). An explicit empty array
     [] is preserved as the intentional derive-from-declared-caps signal; id typos
     in a well-typed array are still caught loudly by
     {!Runtime_config_validation.validate_runtime_references}, which now judges every [runtime]
     field that names a routing target. *)
  try Ok (Otoml.get_array Otoml.get_string value) with
  | Otoml.Type_error msg ->
    Error
      (error
         path
         (Printf.sprintf "media_failover must be an array of string runtime ids; got %s" msg))
;;

let parse_runtime_section (toml : Otoml.t) : (runtime_section, parse_error list) result =
  match Otoml.find_opt toml Fun.id [ Ns.(key Runtime) ] with
  | None -> Ok empty_runtime_section
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    let section, errs =
      List.fold_left
        (fun (section, errs) (key, value) ->
           match key with
           | "default" ->
             (match parse_runtime_string_leaf ~path:(Ns.(key Runtime) ^ ".default") ~key value with
              | Ok default_runtime_id ->
                { section with default_runtime_id = Some default_runtime_id }, errs
              | Error e -> section, errs @ e)
           | "media_failover" ->
             (match parse_runtime_media_failover ~path:(Ns.(key Runtime) ^ ".media_failover") value with
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
           | "exact_output_lanes" | "addon_exact_lanes" ->
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
                   (Ns.(path Runtime) key)
                   (Printf.sprintf
                      "unknown [runtime] key %S; expected default, \
                       media_failover, [runtime.lanes], \
                       [runtime.exact_output_lanes], [runtime.addon_exact_lanes], \
                       [runtime.assignments], or a table-valued [runtime.<profile>]"
                      key) )
        )
        (empty_runtime_section, [])
        entries
    in
    if errs <> [] then Error errs else Ok section
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> Error (error (Ns.(key Runtime)) "[runtime] must be a TOML table")
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
  let path = Ns.(path Runtime) ("lanes." ^ id) in
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
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> []
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
  match Otoml.find_opt toml Fun.id [ Ns.(key Runtime); "lanes" ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    partition_results
      (List.map
         (fun (id, value) ->
            match value with
            | Otoml.TomlTable _ | Otoml.TomlInlineTable _ -> parse_lane ~id value
            | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
            | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
            | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> Error
                (error
                   (Ns.(path Runtime) ("lanes." ^ id))
                   "lane must be a table"))
         entries)
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) ->
    Error (error (Ns.(path Runtime) "lanes") "[runtime.lanes] must be a table of lane tables")
;;

let parse_exact_output_lane ~(owner : Runtime_schema.exact_lane_owner) (tbl : Otoml.t)
  : (Runtime_schema.exact_output_lane_decl, parse_error list) result
  =
  let ( let* ) = Result.bind in
  let path = Runtime_schema.exact_lane_table_name owner in
  let unknown_key_errors =
    match tbl with
    | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
      List.concat_map
        (fun (key, _) ->
           if
             String.equal key "enabled"
             || String.equal key "slots"
             || String.equal key "cli_slots"
             || String.equal key "max_output_tokens"
             || String.equal key "thinking"
           then []
           else
             error
               (path ^ "." ^ key)
               (Printf.sprintf
                  "unknown exact-output lane key %S; expected enabled, slots, cli_slots, \
                   max_output_tokens or thinking"
                  key))
        entries
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> []
  in
  let enabled_result = typed_find_or "a boolean" path tbl "enabled" Otoml.get_boolean ~default:true in
  let slots_result =
    match Otoml.find_opt tbl Fun.id [ "slots" ] with
    (* Absent reads as empty, the same as [cli_slots] below. The lane's rule is
       one slot across the two lists, refused further down; requiring the key
       on top of that only made a CLI-only lane carry an empty one. *)
    | None -> Ok []
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
  let max_output_tokens_result =
    match Otoml.find_opt tbl Fun.id [ "max_output_tokens" ] with
    | None -> Ok None
    | Some value ->
      (try
         let n = Otoml.get_integer value in
         if n <= 0
         then
           Error
             (error
                (path ^ ".max_output_tokens")
                (Printf.sprintf
                   "exact-output lane max_output_tokens must be a positive \
                    integer; got %d"
                   n))
         else Ok (Some n)
       with Otoml.Type_error msg ->
         Error
           (error
              (path ^ ".max_output_tokens")
              (Printf.sprintf
                 "exact-output lane max_output_tokens must be an integer; got %s"
                 msg)))
  in
  let thinking_result =
    match Otoml.find_opt tbl Fun.id [ "thinking" ] with
    | None -> Ok None
    | Some value ->
      (try Ok (Some (Otoml.get_boolean value)) with
       | Otoml.Type_error msg ->
         Error
           (error
              (path ^ ".thinking")
              (Printf.sprintf
                 "exact-output lane thinking must be true or false; got %s"
                 msg)))
  in
  let slots_result =
    match slots_result, cli_slots_result, max_output_tokens_result, thinking_result with
    | Error slot_errors, Error cli_errors, _, _ ->
      Error (slot_errors @ cli_errors)
    | Error slot_errors, Ok _, _, _ -> Error slot_errors
    | Ok _, Error cli_errors, _, _ -> Error cli_errors
    | Ok _, Ok _, Error budget_errors, _ -> Error budget_errors
    | Ok _, Ok _, Ok _, Error thinking_errors -> Error thinking_errors
    | Ok slots, Ok cli_slots, Ok max_output_tokens, Ok thinking ->
      Ok (slots, cli_slots, max_output_tokens, thinking)
  in
  let* enabled = enabled_result in
  let* () =
    match owner with
    | Runtime_schema.Builtin lane
      when not enabled && Standalone_lane.obligation lane = Standalone_lane.Required ->
      Error (error (path ^ ".enabled") "required exact-output lane cannot be disabled")
    (* An add-on lane is always Optional: no server start depends on it. *)
    | Runtime_schema.Builtin _ | Runtime_schema.Addon _ -> Ok ()
  in
  match unknown_key_errors, slots_result with
  | _ :: _, Error slot_errors -> Error (slot_errors @ unknown_key_errors)
  | _ :: _, Ok _ -> Error unknown_key_errors
  | [], (Error _ as error) -> error
  | [], Ok ([], [], _, _) when enabled ->
    Error (error path "exact-output lane must have at least one slot")
  | [], Ok (slot_ids, cli_slot_ids, max_output_tokens, thinking) ->
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
         | Ok () ->
           Ok { Runtime_schema.owner; enabled; slot_ids; cli_slot_ids; max_output_tokens; thinking })
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
  match Otoml.find_opt toml Fun.id [ Ns.(key Runtime); "exact_output_lanes" ] with
  | None -> Ok []
  | Some (Otoml.TomlTable entries | Otoml.TomlInlineTable entries) ->
    partition_results
      (List.map
         (fun (id, value) ->
            match value with
            (* A table under a name no lane has would parse, publish, and then
               never be read: the standalone-lane projection draws one row per
               [Standalone_lane.t], so a misspelt lane vanished from every
               surface while the real lane read as unconfigured. *)
            | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
              (match Standalone_lane.of_id id with
               | Some lane -> parse_exact_output_lane ~owner:(Runtime_schema.Builtin lane) value
               | None ->
                 Error
                   (error
                      (Ns.(path Runtime) ("exact_output_lanes." ^ id))
                      (Printf.sprintf
                         "unknown exact-output lane %S; expected one of %s"
                         id
                         (String.concat
                            ", "
                            (List.map Standalone_lane.to_id Standalone_lane.all)))))
            | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
            | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
            | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> Error
                (error
                   (Ns.(path Runtime) ("exact_output_lanes." ^ id))
                   "exact-output lane must be a table"))
         entries)
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) ->
    Error
      (error
         (Ns.(path Runtime) "exact_output_lanes")
         "[runtime.exact_output_lanes] must be a table of lane tables")
;;

(* [runtime.addon_exact_lanes.<declaration id>.<output>]: the operator binds
   slots to a Lane Add-on installation's named exact output. Each table takes
   the keys and rules of a built-in lane table. Declarations load after this
   file, so a pair no installation declares still loads; nothing is checked
   against them here. *)
let parse_addon_exact_output_lanes (toml : Otoml.t)
  : (Runtime_schema.exact_output_lane_decl list, parse_error list) result
  =
  let table_path = Ns.(path Runtime) "addon_exact_lanes" in
  let not_a_table path what = Error (error path (what ^ " must be a table")) in
  let parse_output declaration_id (output, value) =
    let path =
      String.concat "." [ table_path; Toml_line_editor.render_key declaration_id; Toml_line_editor.render_key output ]
    in
    match Runtime_schema.addon_lane ~declaration_id ~output with
    | Error message -> Error (error path message)
    | Ok lane ->
      match value with
      | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
        parse_exact_output_lane ~owner:(Runtime_schema.Addon lane) value
      | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
      | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
      | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ->
        not_a_table path "an add-on exact-output lane"
  in
  let parse_declaration (declaration_id, value) =
    let path = table_path ^ "." ^ Toml_line_editor.render_key declaration_id in
    match value with
    | _ when String.trim declaration_id = "" -> Error (error path "a declaration id must not be blank")
    | Otoml.TomlTable [] | Otoml.TomlInlineTable [] -> Error (error path "names no exact output")
    | Otoml.TomlTable outputs | Otoml.TomlInlineTable outputs ->
      partition_results (List.map (parse_output declaration_id) outputs)
    | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
    | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
    | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ ->
      not_a_table path "a declaration's exact outputs"
  in
  match Otoml.find_opt toml Fun.id [ Ns.(key Runtime); "addon_exact_lanes" ] with
  | None -> Ok []
  | Some (Otoml.TomlTable declarations | Otoml.TomlInlineTable declarations) ->
    partition_results (List.map parse_declaration declarations) |> Result.map List.concat
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) ->
    not_a_table table_path "[runtime.addon_exact_lanes]"
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
            | Runtime_schema.Gemini_api
            | Runtime_schema.Vertex_gemini_api
            | Runtime_schema.Codex_app_server_runtime
            | Runtime_schema.Antigravity_cli_runtime
            | Runtime_schema.Claude_code_runtime
            | Runtime_schema.Muse_serve_runtime
            | Runtime_schema.Vibe_cli_runtime ) as api_format) ->
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

(* [admission-priority-run-limit] orders the queue for an account's permits.
   Only an HTTP request admitted through [max-concurrent] waits in that
   queue: official-client runtimes run outside it, and a binding without
   [max-concurrent] is not admitted. A provider whose bindings cannot use
   the limit would carry a declaration that orders nothing, so it is refused
   here, naming the provider. *)
let validate_priority_run_limit_providers
      (providers : Runtime_schema.provider list)
      (bindings : Runtime_schema.binding list)
  : parse_error list
  =
  List.concat_map
    (fun (provider : Runtime_schema.provider) ->
       match provider.admission_priority_run_limit with
       | None -> []
       | Some limit ->
         let refuse reason =
           error
             (Ns.(path Providers) provider.id
              ^ "."
              ^ Runtime_schema.admission_priority_run_limit_key)
             (Printf.sprintf
                "%s = %d orders the permit queue of provider %S, but %s. Remove it, \
                 or declare it where requests wait for a permit."
                Runtime_schema.admission_priority_run_limit_key
                limit
                provider.id
                reason)
         in
         (match provider.api_format with
          | Runtime_schema.Codex_app_server_runtime
          | Runtime_schema.Antigravity_cli_runtime
          | Runtime_schema.Claude_code_runtime
          | Runtime_schema.Muse_serve_runtime
          | Runtime_schema.Vibe_cli_runtime ->
            refuse
              (Printf.sprintf
                 "%s runs as an official client outside account admission"
                 (Runtime_schema.show_api_format provider.api_format))
          | Runtime_schema.Messages_api
          | Runtime_schema.Chat_completions_api
          | Runtime_schema.Gemini_api
          | Runtime_schema.Vertex_gemini_api
          | Runtime_schema.Ollama_api ->
            if
              List.exists
                (fun (binding : Runtime_schema.binding) ->
                   String.equal binding.provider_id provider.id
                   && Option.is_some binding.max_concurrent)
                bindings
            then []
            else refuse "none of its bindings declares max-concurrent"))
    providers
;;

(* --- [typesafeai] --- *)

let typesafeai_keys =
  [ "enabled"
  ; "destinations"
  ; "board_attention"
  ; "board_attention_confidence_floor"
  ; "absorb_gate"
  ; "context_review"
  ; "skill_applicability"
  ; "librarian_preflight"
  ; "workspace_memory_selection_enabled"
  ; "memory_recall"
  ; "memory_recall_scope"
  ; "memory_recall_keepers"
  ; "excluded_keepers"
  ]
;;

let typesafeai_destination_keys = [ "endpoint"; "model"; "api_key_env" ]

let result_errors = function
  | Ok _ -> []
  | Error errors -> errors
;;

(* A keeper name in [excluded_keepers] or [memory_recall_keepers]: a keeper is
   named by its directory name, so an empty name or one with whitespace names
   nothing and would exclude nothing, or recall for nobody, while looking as
   if it did. Whether the name is a keeper of this base path is checked at
   boot, where the keepers are known. [None] is a key that is not there. *)
let parse_typesafeai_keeper_names ~(path : string) ~(key : string) (tbl : Otoml.t) =
  match typed_find "an array of strings" path tbl key (Otoml.get_array Otoml.get_string) with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some names) ->
    let bad =
      List.concat_map
        (fun name ->
           if String.trim name = "" || String.exists (fun c -> c = ' ' || c = '\t' || c = '\n' || c = '\r') name
           then
             error
               (path ^ "." ^ key)
               (Printf.sprintf "keeper name %S must be non-empty without whitespace" name)
           else [])
        names
    in
    if bad = [] then Ok (Some names) else Error bad
;;

let parse_typesafeai_excluded_keepers ~(path : string) (tbl : Otoml.t) =
  Result.map
    (Option.value ~default:[])
    (parse_typesafeai_keeper_names ~path ~key:"excluded_keepers" tbl)
;;

(* What the three memory recall keys declare, before the switch decides
   anything: the switch, and the scope the scope keys name whether the switch
   is on or off. A file that switched recall off by hand keeps its list here,
   which {!Runtime_schema.memory_recall} cannot say (off has no scope). *)
type memory_recall_declaration =
  { switch : bool
  ; scope : Runtime_schema.memory_recall_scope option
  }

let memory_recall_scope_key path = path ^ ".memory_recall_scope"

(* [memory_recall] is the switch and [memory_recall_scope] says which keepers:
   "all", or "listed" with the names in [memory_recall_keepers]. A "listed"
   scope with no names is refused, and so is a list next to "all" or to no
   scope. No way of leaving a key out or writing it empty reaches every
   keeper, and a list is never ignored while it looks like a limit. The scope
   keys are read whatever the switch says: a misspelt scope is refused while
   the switch is off. A switch that is on without a scope is answered here as
   [{ switch = true; scope = None }]; refusing it is the decision of
   [parse_typesafeai_memory_recall]. *)
let parse_typesafeai_memory_recall_declaration ~(path : string) (tbl : Otoml.t)
  : (memory_recall_declaration, parse_error list) result
  =
  let scope_key = memory_recall_scope_key path in
  let keepers_key = path ^ ".memory_recall_keepers" in
  let keepers_only_listed =
    error
      keepers_key
      "needs memory_recall_scope = \"listed\"; remove the list or set that scope"
  in
  let switch =
    typed_find_or "a boolean" path tbl "memory_recall" Otoml.get_boolean ~default:false
  in
  let scope =
    match
      ( typed_find "a string" path tbl "memory_recall_scope" Otoml.get_string
      , parse_typesafeai_keeper_names ~path ~key:"memory_recall_keepers" tbl )
    with
    | Error scope_errors, Error keeper_errors -> Error (scope_errors @ keeper_errors)
    | Error scope_errors, Ok _ -> Error scope_errors
    | Ok _, Error keeper_errors -> Error keeper_errors
    | Ok None, Ok None -> Ok None
    | Ok None, Ok (Some _) | Ok (Some "all"), Ok (Some _) -> Error keepers_only_listed
    | Ok (Some "all"), Ok None -> Ok (Some Runtime_schema.All_keepers)
    | Ok (Some "listed"), Ok (Some (first :: rest)) ->
      Ok (Some (Runtime_schema.Listed_keepers (first, rest)))
    | Ok (Some "listed"), Ok (None | Some []) ->
      Error
        (error
           keepers_key
           "memory_recall_scope = \"listed\" needs at least one keeper name; an empty list does \
            not mean every keeper")
    | Ok (Some other), Ok _ ->
      Error
        (error
           scope_key
           (Printf.sprintf "must be \"all\" or \"listed\", got %S" other))
  in
  match switch, scope with
  | Error switch_errors, Error scope_errors -> Error (switch_errors @ scope_errors)
  | Error switch_errors, Ok _ -> Error switch_errors
  | Ok _, Error scope_errors -> Error scope_errors
  | Ok switch, Ok scope -> Ok { switch; scope }
;;

(* The switch and the scope are one value for everyone who asks whether a
   keeper is covered: no scope is read from a switch that is off. *)
let parse_typesafeai_memory_recall ~(path : string) (tbl : Otoml.t)
  : (Runtime_schema.memory_recall, parse_error list) result
  =
  match parse_typesafeai_memory_recall_declaration ~path tbl with
  | Error errors -> Error errors
  | Ok { switch = false; scope = _ } -> Ok Runtime_schema.Memory_recall_off
  | Ok { switch = true; scope = Some scope } -> Ok (Runtime_schema.Memory_recall_on scope)
  | Ok { switch = true; scope = None } ->
    Error
      (error
         (memory_recall_scope_key path)
         "memory_recall = true needs memory_recall_scope: \"all\" or \"listed\" with \
          memory_recall_keepers")
;;

(* One entry of [destinations]: the table naming where to post, which model
   to ask for, and which environment variable holds that server's key. Every
   field is required. [api_key_env] is a variable name, not a value, so it
   must look like one: non-empty, no whitespace. *)
let parse_typesafeai_destination ~(path : string) (entry : Otoml.t)
  : (Runtime_schema.typesafeai_destination, parse_error list) result
  =
  match entry with
  | Otoml.TomlTable entries | Otoml.TomlInlineTable entries ->
    let unknown = unknown_table_keys ~path ~expected:typesafeai_destination_keys entries in
    let required key =
      match exact_non_empty_string_opt_field ~path entry key with
      | Ok (Some value) -> Ok value
      | Ok None -> Error (error (path ^ "." ^ key) (key ^ " is required"))
      | Error _ as error -> error
    in
    let endpoint = required "endpoint" in
    let model = required "model" in
    let api_key_env =
      match required "api_key_env" with
      | Ok name
        when String.exists (fun c -> c = ' ' || c = '\t' || c = '\n' || c = '\r') name ->
        Error
          (error
             (path ^ ".api_key_env")
             (Printf.sprintf
                "api_key_env %S must name an environment variable without whitespace"
                name))
      | (Ok _ | Error _) as other -> other
    in
    (match unknown, endpoint, model, api_key_env with
     | [], Ok endpoint, Ok model, Ok api_key_env ->
       Ok { Runtime_schema.endpoint; model; api_key_env }
     | ([] | _ :: _), (Ok _ | Error _), (Ok _ | Error _), (Ok _ | Error _) ->
       Error
         (unknown @ result_errors endpoint @ result_errors model @ result_errors api_key_env))
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _ | Otoml.TomlBoolean _
  | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _
  | Otoml.TomlLocalTime _ | Otoml.TomlArray _ | Otoml.TomlTableArray _ -> Error
      (error path "each destination must be a table with endpoint, model and api_key_env")
;;

(* [destinations]: an absent key means the vendor's own server alone; a
   present array names every server asked, in order, and must name at least
   one. The same server asked for the same model twice would be asked twice,
   so that pair is refused. *)
let parse_typesafeai_destinations ~(path : string) (tbl : Otoml.t)
  : ( Runtime_schema.typesafeai_destination * Runtime_schema.typesafeai_destination list
    , parse_error list )
    result
  =
  let key_path = path ^ ".destinations" in
  match Otoml.find_opt tbl Fun.id [ "destinations" ] with
  | None -> Ok Runtime_schema.default_typesafeai.Runtime_schema.destinations
  (* An array of inline tables and [[typesafeai.destinations]] headers are the
     same list written two ways. *)
  | Some (Otoml.TomlArray entries | Otoml.TomlTableArray entries) ->
    let parsed =
      List.mapi
        (fun index entry ->
           parse_typesafeai_destination ~path:(Printf.sprintf "%s[%d]" key_path index) entry)
        entries
    in
    (match List.concat_map result_errors parsed, List.filter_map Result.to_option parsed with
     | [], first :: rest ->
       let same (a : Runtime_schema.typesafeai_destination) (b : Runtime_schema.typesafeai_destination) =
         String.equal a.endpoint b.endpoint && String.equal a.model b.model
       in
       let rec first_duplicate = function
         | [] -> None
         | destination :: later ->
           if List.exists (same destination) later then Some destination else first_duplicate later
       in
       (match first_duplicate (first :: rest) with
        | None -> Ok (first, rest)
        | Some duplicate ->
          Error
            (error
               key_path
               (Printf.sprintf
                  "destination %s (%s) is listed twice"
                  duplicate.endpoint
                  duplicate.model)))
     | [], [] ->
       Error
         (error
            key_path
            "destinations must name at least one server; leave the key out for the vendor's own")
     | errors, _ -> Error errors)
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlTable _) | Some (Otoml.TomlInlineTable _) -> Error (error key_path "destinations must be an array of tables")
;;

(* [board_attention_confidence_floor] is a confidence Jev reports, so it is a
   number from 0 to 1. A value outside that range would settle every answer or
   none while looking like a floor. *)
let parse_typesafeai_confidence_floor ~(path : string) (tbl : Otoml.t) ~default =
  let key = "board_attention_confidence_floor" in
  match typed_find_or "a float" path tbl key Otoml.get_float ~default with
  | Error _ as refused -> refused
  | Ok floor
    when Float.is_nan floor || Float.compare floor 0.0 < 0 || Float.compare floor 1.0 > 0 ->
    Error
      (error
         (path ^ "." ^ key)
         (Printf.sprintf "must be a number from 0 to 1, got %g" floor))
  | Ok floor -> Ok floor
;;

(* [\[typesafeai\]] -- the TypeSafe AI lane; the key is not here. An absent
   table is {!Runtime_schema.default_typesafeai}; a present one is read
   strictly, so a misspelt key is a load error rather than a switch that
   silently did nothing. *)
let parse_typesafeai (toml : Otoml.t)
  : (Runtime_schema.typesafeai, parse_error list) result
  =
  let path = Ns.(key Typesafeai) in
  match Otoml.find_opt toml Fun.id [ path ] with
  | None -> Ok Runtime_schema.default_typesafeai
  | Some ((Otoml.TomlTable entries | Otoml.TomlInlineTable entries) as tbl) ->
    let unknown = unknown_table_keys ~path ~expected:typesafeai_keys entries in
    let d = Runtime_schema.default_typesafeai in
    let enabled = typed_find_or "a boolean" path tbl "enabled" Otoml.get_boolean ~default:d.lane_enabled in
    let destinations = parse_typesafeai_destinations ~path tbl in
    let board_attention =
      typed_find_or "a boolean" path tbl "board_attention" Otoml.get_boolean ~default:d.board_attention
    in
    let board_attention_confidence_floor =
      parse_typesafeai_confidence_floor
        ~path
        tbl
        ~default:d.board_attention_confidence_floor
    in
    let absorb_gate =
      typed_find_or "a boolean" path tbl "absorb_gate" Otoml.get_boolean ~default:d.absorb_gate
    in
    let context_review =
      typed_find_or "a boolean" path tbl "context_review" Otoml.get_boolean ~default:d.context_review
    in
    let skill_applicability =
      typed_find_or "a boolean" path tbl "skill_applicability" Otoml.get_boolean ~default:d.skill_applicability
    in
    let excluded_keepers = parse_typesafeai_excluded_keepers ~path tbl in
    let librarian_preflight =
      typed_find_or "a boolean" path tbl "librarian_preflight" Otoml.get_boolean
        ~default:d.librarian_preflight
    in
    let workspace_memory_selection_enabled =
      typed_find_or "a boolean" path tbl "workspace_memory_selection_enabled" Otoml.get_boolean
        ~default:d.workspace_memory_selection_enabled
    in
    let memory_recall = parse_typesafeai_memory_recall ~path tbl in
    (match
       ( unknown
       , enabled
       , destinations
       , board_attention
       , board_attention_confidence_floor
       , absorb_gate
       , context_review
       , skill_applicability
       , librarian_preflight
       , workspace_memory_selection_enabled
       , memory_recall
       , excluded_keepers )
     with
     | ( []
       , Ok lane_enabled
       , Ok destinations
       , Ok board_attention
       , Ok board_attention_confidence_floor
       , Ok absorb_gate
       , Ok context_review
       , Ok skill_applicability
       , Ok librarian_preflight
       , Ok workspace_memory_selection_enabled
       , Ok memory_recall
       , Ok excluded_keepers ) ->
       Ok
         { Runtime_schema.lane_enabled
         ; destinations
         ; board_attention
         ; board_attention_confidence_floor
         ; absorb_gate
         ; context_review
         ; skill_applicability
         ; librarian_preflight
         ; workspace_memory_selection_enabled
         ; memory_recall
         ; excluded_keepers
         }
     | ( ([] | _ :: _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _)
       , (Ok _ | Error _) ) ->
       Error
         (unknown
          @ result_errors enabled
          @ result_errors destinations
          @ result_errors board_attention
          @ result_errors board_attention_confidence_floor
          @ result_errors absorb_gate
          @ result_errors context_review
          @ result_errors skill_applicability
          @ result_errors librarian_preflight
          @ result_errors workspace_memory_selection_enabled
          @ result_errors memory_recall
          @ result_errors excluded_keepers))
  | Some (Otoml.TomlString _) | Some (Otoml.TomlInteger _) | Some (Otoml.TomlFloat _)
  | Some (Otoml.TomlBoolean _) | Some (Otoml.TomlOffsetDateTime _)
  | Some (Otoml.TomlLocalDateTime _) | Some (Otoml.TomlLocalDate _) | Some (Otoml.TomlLocalTime _)
  | Some (Otoml.TomlArray _) | Some (Otoml.TomlTableArray _) -> Error (error path "[typesafeai] must be a TOML table")
;;

let parse_table ~home (toml : Otoml.t) : (Runtime_schema.config, parse_error list) result =
  let obsolete_namespaces_result = reject_obsolete_top_level_namespaces toml in
  let providers_result = parse_providers ~home toml in
  let models_result = parse_models toml in
  let runtime_section_result = parse_runtime_section toml in
  let assignments_result = parse_keeper_assignments toml in
  let bindings_result = parse_bindings toml in
  let lanes_result = parse_lanes toml in
  let exact_output_lanes_result =
    match parse_exact_output_lanes toml, parse_addon_exact_output_lanes toml with
    | Ok builtin, Ok addon -> Ok (builtin @ addon)
    | Error errors, Ok _ | Ok _, Error errors -> Error errors
    | Error builtin, Error addon -> Error (builtin @ addon)
  in
  let exec_ssh_endpoints_result = parse_exec_endpoints toml in
  let egress_allowlists_result = parse_egress_allowlists toml in
  let lsp_servers_result = parse_lsp_servers toml in
  let typesafeai_result = parse_typesafeai toml in
  let browser_result = Browser_configuration.parse toml
    |> Result.map_error (fun message -> error (Ns.key Ns.Browser) message) in
  let machines_result = Machine_configuration.parse toml
    |> Result.map_error (fun message -> error (Ns.key Ns.Machines) message) in
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
    @ errs egress_allowlists_result
    @ errs lsp_servers_result
    @ errs typesafeai_result
    @ errs browser_result
    @ errs machines_result
  in
  if all_errors <> []
  then Error all_errors
  else (
    let providers =
      extract_after_all_errors_guard ~label:(Ns.(key Providers)) providers_result
    in
    let models = extract_after_all_errors_guard ~label:(Ns.(key Models)) models_result in
    let keeper_assignments =
      extract_after_all_errors_guard ~label:"assignments" assignments_result
    in
    let bindings =
      extract_after_all_errors_guard ~label:"bindings" bindings_result
    in
    let runtime_section =
      extract_after_all_errors_guard ~label:(Ns.(key Runtime)) runtime_section_result
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
    let egress_allowlists =
      extract_after_all_errors_guard ~label:"egress_allowlists" egress_allowlists_result
    in
    let lsp_servers =
      extract_after_all_errors_guard ~label:"lsp_servers" lsp_servers_result
    in
    let browser = extract_after_all_errors_guard ~label:(Ns.key Ns.Browser) browser_result in
    let machines = extract_after_all_errors_guard ~label:(Ns.key Ns.Machines) machines_result in
    let typesafeai = extract_after_all_errors_guard ~label:(Ns.(key Typesafeai)) typesafeai_result in
    (* Cross-table Gates: whether a declaration can take effect depends on
       another table -- a binding field on its provider's request builder, a
       provider's run limit on its bindings' permit queue. *)
    match
      validate_ollama_only_binding_fields providers bindings
      @ validate_priority_run_limit_providers providers bindings
    with
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
        ; egress_allowlists
        ; lsp_servers
        ; typesafeai
        ; browser
        ; machines
        })
;;

(* [home] is what a ["~/"] credential path expands under. It is the one thing
   outside the document that a config depends on, so it is an argument here
   and read from the environment by the entry points below. *)
let parse_document ~home = function
  | Otoml.TomlTable _ as toml -> parse_table ~home toml
  | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
  | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
  | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
  | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ->
      Error [{path="<parse>"; message="otoml returned a non-table document root"}]
;;

let parse_toml toml = parse_document ~home:(Env_config_core.home_dir_opt ()) toml

(* What one source text and one home come to. A syntax failure keeps what
   Otoml raised, because {!parse_string} and {!parse_file} word it
   differently. *)
type source_reading =
  | Interpreted of (Runtime_schema.config, parse_error list) result
  | Syntax_refused of (int * int) option * string
  | Duplicate_key_refused of string
  | Otoml_failed of string

let read_source ~home content =
  match Otoml.Parser.from_string content with
  | toml -> Interpreted (parse_document ~home toml)
  | exception Otoml.Parse_error (position, message) -> Syntax_refused (position, message)
  | exception Otoml.Duplicate_key message -> Duplicate_key_refused message
  | exception Failure message -> Otoml_failed message
;;

(* The reading of the source text last parsed. A running server parses the
   same runtime.toml again and again on the caller's domain, which is the
   main one: a [Remote_ssh] Keeper on every Execute call, the repository
   pulls reader on every refresh. One parse of a 74 KB runtime.toml took 12 to
   183 ms and allocated 16 MB ([Otoml.Parser.from_file] alone, 30 runs on a
   loaded host, 2026-11-11).

   A reading is a function of the text and the home, so the same text under
   the same home answers with the reading already made. Callers still read
   the file on each call, so an edit applies to the next one. A warning the
   parser logs for a value is logged when the text is parsed, not on each
   call that reuses the reading. *)
type kept_reading =
  { content : string
  ; home : string option
  ; reading : source_reading
  }

let last_reading : kept_reading option Atomic.t = Atomic.make None

let source_reading content =
  let home = Env_config_core.home_dir_opt () in
  match Atomic.get last_reading with
  | Some last
    when String.equal last.content content && Option.equal String.equal last.home home ->
    last.reading
  | Some _ | None ->
    let reading = read_source ~home content in
    Atomic.set last_reading (Some { content; home; reading });
    reading
;;

let parse_string (content : string) : (Runtime_schema.config, parse_error list) result =
  let unparsable message = Error [ { path = "<parse>"; message } ] in
  match source_reading content with
  | Interpreted result -> result
  | Syntax_refused (position, message) ->
    unparsable (Otoml.Parser.format_parse_error position message)
  | Duplicate_key_refused message -> unparsable message
  | Otoml_failed message -> unparsable (Printf.sprintf "otoml internal error: %s" message)
;;

let memory_recall_declaration_of_string (content : string)
  : (memory_recall_declaration, parse_error list) result
  =
  match Otoml.Parser.from_string_result content with
  | Error msg -> Error [ { path = "<parse>"; message = msg } ]
  | Ok toml ->
    let path = Ns.(key Typesafeai) in
    (match Otoml.find_opt toml Fun.id [ path ] with
     | None -> Ok { switch = false; scope = None }
     | Some ((Otoml.TomlTable _ | Otoml.TomlInlineTable _) as tbl) ->
       parse_typesafeai_memory_recall_declaration ~path tbl
     | Some
         ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
         | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
         | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
         | Otoml.TomlTableArray _ ) -> Error (error path "[typesafeai] must be a TOML table"))
;;

(* The legacy keys this text still carries, dotted paths like
   ["models.gpt-5.max-prompt-bytes"], for a save to name in its warning.
   Read straight off the parsed TOML rather than threading a side channel
   through [parse_toml]: the keys are ignored there, and the reader that has
   to name them is the caller, which already holds the document. *)
let ignored_legacy_keys (content : string) : string list =
  match Otoml.Parser.from_string_result content with
  | Error _ -> []
  | Ok toml ->
    let entries_of = function
      | Otoml.TomlTable entries | Otoml.TomlInlineTable entries -> entries
      | Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
      | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _ | Otoml.TomlLocalDateTime _
      | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _ | Otoml.TomlArray _
      | Otoml.TomlTableArray _ -> []
    in
    let model_entries id =
      match Otoml.find_opt toml Fun.id [ "models"; id ] with
      | Some tbl -> entries_of tbl
      | None -> []
    in
    let models =
      match Otoml.find_opt toml Fun.id [ "models" ] with
      | Some tbl ->
        List.filter_map
          (fun (id, _) -> if id <> "" then Some id else None)
          (entries_of tbl)
      | None -> []
    in
    List.concat_map
      (fun id ->
         let caps =
           match List.assoc_opt "capabilities" (model_entries id) with
           | Some tbl -> entries_of tbl
           | None -> []
         in
         List.filter_map
           (fun (key, _) ->
              if List.mem key legacy_model_keys
              then Some (Printf.sprintf "models.%s.%s" id key)
              else if List.mem key legacy_model_capability_keys
              then Some (Printf.sprintf "models.%s.capabilities.%s" id key)
              else None)
           (model_entries id)
         @ List.filter_map
              (fun (key, _) ->
                 if List.mem key legacy_model_capability_keys
                 then Some (Printf.sprintf "models.%s.capabilities.%s" id key)
                 else None)
              caps)
      models
    |> List.sort_uniq String.compare
;;

(* A duplicate key and an Otoml failure leave as the exceptions
   [Otoml.Parser.from_file] raised for them. *)
let parse_file (path : string) : (Runtime_schema.config, parse_error list) result =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error message -> Error [ { path; message } ]
  | content ->
    (match source_reading content with
     | Interpreted result -> result
     | Syntax_refused (_, message) -> Error [ { path; message } ]
     | Duplicate_key_refused message -> raise (Otoml.Duplicate_key message)
     | Otoml_failed message -> failwith message)
;;
