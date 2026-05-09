type source_kind =
  | Json [@tla.symbol "json"]
  | Toml [@tla.symbol "toml"]
[@@deriving tla]

type source_info = {
  kind : source_kind;
  source_path : string;
  json_path : string;
  raw_json_editable : bool;
}

type materialize_result = {
  source : source_info;
  wrote_json : bool;
}

type source_state = {
  info : source_info;
  source_exists : bool;
  source_mtime : float option;
}

let source_kind_to_string = function
  | Json -> "json"
  | Toml -> "toml"

let toml_path_of_json_path config_path =
  Filename.concat (Filename.dirname config_path)
    Config_dir_resolver.cascade_toml_filename

let source_info ~config_path =
  let toml_path = toml_path_of_json_path config_path in
  if Fs_compat.file_exists toml_path then
    {
      kind = Toml;
      source_path = toml_path;
      json_path = config_path;
      raw_json_editable = false;
    }
  else
    {
      kind = Json;
      source_path = config_path;
      json_path = config_path;
      raw_json_editable = true;
    }

let source_state ~config_path =
  let info = source_info ~config_path in
  let source_mtime =
    try Some (Unix.stat info.source_path).Unix.st_mtime
    with
    | Unix.Unix_error _ | Sys_error _ -> None
  in
  { info; source_exists = Option.is_some source_mtime; source_mtime }

let toml_type_name = function
  | Otoml.TomlString _ -> "string"
  | Otoml.TomlInteger _ -> "integer"
  | Otoml.TomlFloat _ -> "float"
  | Otoml.TomlBoolean _ -> "boolean"
  | Otoml.TomlOffsetDateTime _ -> "offset_datetime"
  | Otoml.TomlLocalDateTime _ -> "local_datetime"
  | Otoml.TomlLocalDate _ -> "local_date"
  | Otoml.TomlLocalTime _ -> "local_time"
  | Otoml.TomlArray _ -> "array"
  | Otoml.TomlTable _ -> "table"
  | Otoml.TomlInlineTable _ -> "inline_table"
  | Otoml.TomlTableArray _ -> "table_array"

let errorf fmt = Printf.ksprintf (fun msg -> Error msg) fmt

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let table_fields ~path = function
  | Otoml.TomlTable fields
  | Otoml.TomlInlineTable fields ->
      Ok fields
  | value ->
      errorf "expected %s to be a TOML table, found %s" path
        (toml_type_name value)

let string_value ~path = function
  | Otoml.TomlString value -> Ok value
  | value ->
      errorf "expected %s to be a string, found %s" path
        (toml_type_name value)

let trimmed_nonempty_string ~path value =
  match string_value ~path value with
  | Ok raw ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then
        errorf "expected %s to be a non-empty string" path
      else
        Ok trimmed
  | Error _ as err -> err

let bool_value ~path = function
  | Otoml.TomlBoolean value -> Ok value
  | value ->
      errorf "expected %s to be a boolean, found %s" path
        (toml_type_name value)

let int_value ~path = function
  | Otoml.TomlInteger value -> Ok value
  | value ->
      errorf "expected %s to be an integer, found %s" path
        (toml_type_name value)

let float_value ~path = function
  | Otoml.TomlFloat value -> Ok value
  | Otoml.TomlInteger value -> Ok (float_of_int value)
  | value ->
      errorf "expected %s to be a float or integer, found %s" path
        (toml_type_name value)

let rec string_array_value ~path = function
  | Otoml.TomlArray items ->
      let rec loop acc index = function
        | [] -> Ok (List.rev acc)
        | item :: rest -> (
            match trimmed_nonempty_string ~path:(Printf.sprintf "%s[%d]" path index) item with
            | Ok value -> loop (value :: acc) (index + 1) rest
            | Error _ as err -> err)
      in
      loop [] 0 items
  | value ->
      errorf "expected %s to be an array, found %s" path
        (toml_type_name value)

let rec string_matrix_value ~path = function
  | Otoml.TomlArray rows ->
      let rec loop acc index = function
        | [] -> Ok (List.rev acc)
        | row :: rest -> (
            match string_array_value ~path:(Printf.sprintf "%s[%d]" path index) row with
            | Ok values -> loop (values :: acc) (index + 1) rest
            | Error _ as err -> err)
      in
      loop [] 0 rows
  | value ->
      errorf "expected %s to be an array of string arrays, found %s" path
        (toml_type_name value)

let model_entry_json ~path value =
  match value with
  | Otoml.TomlString _ -> (
      match trimmed_nonempty_string ~path value with
      | Ok model -> Ok (`String model)
      | Error _ as err -> err)
  | Otoml.TomlTable _
  | Otoml.TomlInlineTable _ -> (
      match table_fields ~path value with
      | Error _ as err -> err
      | Ok fields ->
          let model = ref None in
          let weight = ref None in
          let supports_tool_choice = ref None in
          let secondary = ref None in
          let secondary_supports_tool_choice = ref None in
          let rec loop = function
            | [] -> Ok ()
            | (key, field_value) :: rest -> (
                match key with
                | "model" -> (
                    match trimmed_nonempty_string ~path:(path ^ ".model") field_value with
                    | Ok value ->
                        model := Some value;
                        loop rest
                    | Error _ as err -> err)
                | "weight" -> (
                    (* #10571: weight=0 means "configured but disabled"
                       (cascade dispatcher skips the entry).  Pre-fix the
                       validator rejected weight=0, breaking dashboard
                       cascade.json materialization on every hot-reload
                       once #10097 introduced explicit weight=0 entries
                       to disable codex_cli without removing it from the
                       seed list.  Negative weights stay rejected — they
                       have no operational meaning. *)
                    match int_value ~path:(path ^ ".weight") field_value with
                    | Ok value when value >= 0 ->
                        weight := Some value;
                        loop rest
                    | Ok _ ->
                        errorf "expected %s.weight to be >= 0" path
                    | Error _ as err -> err)
                | "supports_tool_choice" -> (
                    match bool_value ~path:(path ^ ".supports_tool_choice") field_value with
                    | Ok value ->
                        supports_tool_choice := Some value;
                        loop rest
                    | Error _ as err -> err)
                | "secondary" -> (
                    (* RFC-0027 PR-9 dual-track fallback. Same string-trim
                       semantics as model: empty/whitespace rejected at
                       parse time so an empty secondary cannot silently
                       turn into an invalid provider scheme downstream. *)
                    match trimmed_nonempty_string
                            ~path:(path ^ ".secondary") field_value with
                    | Ok value ->
                        secondary := Some value;
                        loop rest
                    | Error _ as err -> err)
                | "secondary_supports_tool_choice" -> (
                    match bool_value
                            ~path:(path ^ ".secondary_supports_tool_choice")
                            field_value with
                    | Ok value ->
                        secondary_supports_tool_choice := Some value;
                        loop rest
                    | Error _ as err -> err)
                | other ->
                    errorf
                      "unknown field %S in %s; allowed fields are model, \
                       weight, supports_tool_choice, secondary, \
                       secondary_supports_tool_choice"
                      other path)
          in
          match loop fields with
          | Error _ as err -> err
          | Ok () -> (
              match !model with
              | None -> errorf "missing required field %s.model" path
              | Some model_value ->
                  (* Reject orphan secondary_supports_tool_choice with no
                     secondary declared — it's unambiguously a typo or
                     copy-paste error and silent acceptance hides it. *)
                  (match !secondary, !secondary_supports_tool_choice with
                   | None, Some _ ->
                       errorf
                         "field %s.secondary_supports_tool_choice declared \
                          without %s.secondary; remove the override or add \
                          a secondary model"
                         path path
                   | _ ->
                  let fields = [ ("model", `String model_value) ] in
                  let fields =
                    match !weight with
                    | Some value -> fields @ [ ("weight", `Int value) ]
                    | None -> fields
                  in
                  let fields =
                    match !supports_tool_choice with
                    | Some value ->
                        fields @ [ ("supports_tool_choice", `Bool value) ]
                    | None -> fields
                  in
                  let fields =
                    match !secondary with
                    | Some value -> fields @ [ ("secondary", `String value) ]
                    | None -> fields
                  in
                  let fields =
                    match !secondary_supports_tool_choice with
                    | Some value ->
                        fields @ [ ("secondary_supports_tool_choice",
                                    `Bool value) ]
                    | None -> fields
                  in
                  Ok (`Assoc fields))))
  | other ->
      errorf
        "expected %s to be a string or inline table model entry, found %s"
        path (toml_type_name other)

let model_array_value ~path = function
  | Otoml.TomlArray items ->
      let rec loop acc index = function
        | [] -> Ok (`List (List.rev acc))
        | item :: rest -> (
            match model_entry_json ~path:(Printf.sprintf "%s[%d]" path index) item with
            | Ok value -> loop (value :: acc) (index + 1) rest
            | Error _ as err -> err)
      in
      loop [] 0 items
  | value ->
      errorf "expected %s to be an array of model entries, found %s" path
        (toml_type_name value)

let api_key_env_json ~path value =
  match table_fields ~path value with
  | Error _ as err -> err
  | Ok fields ->
      let rec loop acc = function
        | [] -> Ok (`Assoc (List.rev acc))
        | (key, field_value) :: rest -> (
            match string_value ~path:(Printf.sprintf "%s.%s" path key) field_value with
            | Ok env_var -> loop ((key, `String env_var) :: acc) rest
            | Error _ as err -> err)
      in
      loop [] fields

(* Generic Otoml -> Yojson conversion used for namespaces that the
   materializer should pass through verbatim instead of treating as a
   cascade profile.  Currently used for the [admission] namespace
   introduced by RFC-0026 PR-B (#12926, #1089).

   Without this, every [admission.<keeper>] sub-table breaks the
   materializer (treated as a profile, sub-table keys rejected as
   "unknown field"), which fails cascade.json materialization and
   takes down every keeper that resolves a cascade through cascade.toml
   — not just the keepers with admission blocks.  The error is a
   single fleet-wide regression, so the materializer needs to know
   about the admission namespace explicitly. *)
let rec otoml_to_yojson (value : Otoml.t) : Yojson.Safe.t =
  match value with
  | Otoml.TomlString s -> `String s
  | Otoml.TomlInteger n -> `Int n
  | Otoml.TomlFloat f -> `Float f
  | Otoml.TomlBoolean b -> `Bool b
  | Otoml.TomlOffsetDateTime s
  | Otoml.TomlLocalDateTime s
  | Otoml.TomlLocalDate s
  | Otoml.TomlLocalTime s -> `String s
  | Otoml.TomlArray items ->
      `List (List.map otoml_to_yojson items)
  | Otoml.TomlTable fields ->
      `Assoc
        (List.map
           (fun (k, v) -> (k, otoml_to_yojson v))
           fields)
  | Otoml.TomlInlineTable fields ->
      `Assoc
        (List.map
           (fun (k, v) -> (k, otoml_to_yojson v))
           fields)
  | Otoml.TomlTableArray items ->
      `List (List.map otoml_to_yojson items)

let routes_json ~path value =
  match table_fields ~path value with
  | Error _ as err -> err
  | Ok fields ->
      let rec loop acc = function
        | [] -> Ok (`Assoc (List.rev acc))
        | (key, field_value) :: rest -> (
            match trimmed_nonempty_string ~path:(Printf.sprintf "%s.%s" path key) field_value with
            | Ok target -> loop ((key, `String target) :: acc) rest
            | Error _ as err -> err)
      in
      loop [] fields

let profile_field_json ~profile_name ~field_name field_value =
  let profile_path = profile_name ^ "." ^ field_name in
  match field_name with
  | "comment" -> (
      match string_value ~path:profile_path field_value with
      | Ok value -> Ok [ ("_comment_" ^ profile_name, `String value) ]
      | Error _ as err -> err)
  | "models" -> (
      match model_array_value ~path:profile_path field_value with
      | Ok value -> Ok [ (profile_name ^ "_models", value) ]
      | Error _ as err -> err)
  | "temperature" -> (
      match float_value ~path:profile_path field_value with
      | Ok value -> Ok [ (profile_name ^ "_temperature", `Float value) ]
      | Error _ as err -> err)
  | "max_tokens"
  | "max_cycles"
  | "backoff_base_ms"
  | "backoff_cap_ms"
  | "ollama_max_concurrent"
  | "cli_max_concurrent"
  | "sticky_ttl_ms"
  | "num_ctx"
  | "rate_limit_skip_after"
  | "server_error_skip_after" -> (
      match int_value ~path:profile_path field_value with
      | Ok value -> Ok [ (profile_name ^ "_" ^ field_name, `Int value) ]
      | Error _ as err -> err)
  | "latency_baseline_ms"
  | "rate_limit_recency_window_s"
  | "rate_limit_decay_base"
  | "server_error_recency_window_s"
  | "server_error_decay_base" -> (
      match float_value ~path:profile_path field_value with
      | Ok value -> Ok [ (profile_name ^ "_" ^ field_name, `Float value) ]
      | Error _ as err -> err)
  | "timeout_sec" -> (
      (* Legacy cascade.toml field from pre-route runtime configs. Timeout
         behavior is controlled by runtime/env timeout knobs now; accept the
         old field so one stale profile cannot block the whole catalog. *)
      match float_value ~path:profile_path field_value with
      | Ok _ -> Ok []
      | Error _ as err -> err)
  | "strategy" -> (
      match trimmed_nonempty_string ~path:profile_path field_value with
      | Ok value -> Ok [ (profile_name ^ "_strategy", `String value) ]
      | Error _ as err -> err)
  | "fallback_cascade" -> (
      match trimmed_nonempty_string ~path:profile_path field_value with
      | Ok value ->
          Ok [ (profile_name ^ "_fallback_cascade", `String value) ]
      | Error _ as err -> err)
  | "required_capability_profile" -> (
      (* RFC-0027 PR-2.  String-typed; loader (cascade_config_loader.ml)
         parses through Cascade_capability_profile.profile_of_string and
         fails with a [Catalog_error] on unknown values.  Materializer
         only enforces nonempty-string here; profile-name validity is
         the loader's responsibility (single source of truth for the
         enumeration). *)
      match trimmed_nonempty_string ~path:profile_path field_value with
      | Ok value ->
          Ok [ (profile_name ^ "_required_capability_profile", `String value) ]
      | Error _ as err -> err)
  | "keeper_assignable" -> (
      match bool_value ~path:profile_path field_value with
      | Ok value ->
          Ok [ (profile_name ^ "_keeper_assignable", `Bool value) ]
      | Error _ as err -> err)
  | "tiers" -> (
      match string_matrix_value ~path:profile_path field_value with
      | Ok rows ->
          Ok [ (profile_name ^ "_tiers", `List (List.map json_string_list rows)) ]
      | Error _ as err -> err)
  | "api_key_env" -> (
      match api_key_env_json ~path:profile_path field_value with
      | Ok value -> Ok [ (profile_name ^ "_api_key_env", value) ]
      | Error _ as err -> err)
  | "keep_alive" -> (
      (* Ollama [keep_alive] override surfaced from cascade.toml. Value is a
         duration string ("5m", "30m"), integer-as-string ("3600"), or "-1"
         to keep the model loaded indefinitely. Honored only when the
         resolved provider is Ollama. The downstream consumer in
         cascade_config_loader.ml (line 324-328) already reads
         "<profile>_keep_alive" via read_string_field; without this
         materializer arm the loader silently falls back to
         default_keep_alive and the per-cascade override is unreachable
         from TOML. *)
      match trimmed_nonempty_string ~path:profile_path field_value with
      | Ok value ->
          Ok [ (profile_name ^ "_keep_alive", `String value) ]
      | Error _ as err -> err)
  | "groups" -> (
      (* RFC-0041 hierarchical group/item profile format. Each element is an
         inline table describing a [Cascade_ref.cascade_group]. The array is
         materialized as [<profile>_groups] in JSON so the loader can use
         [Cascade_ref.cascade_group_of_json] for parsing.

         Accept both [TomlArray] (inline array of tables) and
         [TomlTableArray] (TOML [[...]] syntax) so operators are not forced
         into one concrete TOML style. *)
      match field_value with
      | Otoml.TomlArray items
      | Otoml.TomlTableArray items ->
          Ok [ (profile_name ^ "_groups", `List (List.map otoml_to_yojson items)) ]
      | _ ->
          errorf "expected %s to be an array of group tables, found %s"
            profile_path (toml_type_name field_value))
  | other ->
      errorf
        "unknown field %S in profile %s; allowed fields are comment, models, temperature, max_tokens, strategy, max_cycles, backoff_base_ms, backoff_cap_ms, ollama_max_concurrent, cli_max_concurrent, tiers, sticky_ttl_ms, latency_baseline_ms, rate_limit_recency_window_s, rate_limit_decay_base, rate_limit_skip_after, server_error_recency_window_s, server_error_decay_base, server_error_skip_after, keeper_assignable, fallback_cascade, required_capability_profile, api_key_env, keep_alive, num_ctx, timeout_sec, groups"
        other profile_name

let profile_table_json_fields ~profile_name value =
  match table_fields ~path:profile_name value with
  | Error _ as err -> err
  | Ok fields ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc |> List.concat)
        | (field_name, field_value) :: rest -> (
            match profile_field_json ~profile_name ~field_name field_value with
            | Ok rendered -> loop (rendered :: acc) rest
            | Error _ as err -> err)
      in
      loop [] fields

let render_toml_to_yojson toml =
  match table_fields ~path:"<root>" toml with
  | Error _ as err -> err
  | Ok fields ->
      let rec loop acc = function
        | [] -> Ok (`Assoc (List.rev acc |> List.concat))
        | (key, value) :: rest ->
            if String.equal key "comment" then
              match string_value ~path:"comment" value with
              | Ok text -> loop ([ ("_comment", `String text) ] :: acc) rest
              | Error _ as err -> err
            else if String.equal key "routes" then
              match routes_json ~path:"routes" value with
              | Ok routes -> loop ([ ("routes", routes) ] :: acc) rest
              | Error _ as err -> err
            else if String.equal key "admission" then
              (* RFC-0026 admission namespace — pass through to JSON
                 verbatim.  The schema is owned by
                 [Keeper_admission_policy.parse_admission_json] in
                 lib/keeper/, not by the cascade profile schema. *)
              loop ([ ("admission", otoml_to_yojson value) ] :: acc) rest
            else (
              match profile_table_json_fields ~profile_name:key value with
              | Ok rendered -> loop (rendered :: acc) rest
              | Error _ as err -> err)
      in
      loop [] fields

let render_toml_string_to_json_string content =
  match Otoml.Parser.from_string_result content with
  | Error msg -> Error msg
  | Ok toml -> (
      match render_toml_to_yojson toml with
      | Ok json -> Ok (Yojson.Safe.pretty_to_string json ^ "\n")
      | Error _ as err -> err)

let render_toml_file_to_json_string toml_path =
  try
    let content = Fs_compat.load_file toml_path in
    render_toml_string_to_json_string content
  with
  | Sys_error msg -> Error msg

(* #10259: degraded fallback for the keeper-name validator.

   When [render_toml_to_yojson] fails (strict field whitelist refuses
   an unknown key) the whole catalog becomes unavailable, even though
   the TOML itself parses fine and its top-level tables already
   enumerate every cascade the operator has configured.  That gap
   turns one parse error into a fleet-wide silent regression: keepers
   whose [cascade_name] is defined in [cascade.toml] but absent from
   the compile-time reserved list (e.g. operator-defined [ollama_only])
   get reconcile-rejected and the runtime falls back to a stale cached
   catalog.

   This function does the minimum needed by the validator: parse the
   TOML, walk the top-level table, and return the keys that look like
   cascade definitions.  Meta-keys starting with ['_'] ([_comment_*],
   [_schema], [_revision]) are filtered so that documentation
   /housekeeping fields don't leak into the accept list.

   On JSON-only sources, returns [Ok []] — JSON's catalog goes through
   [Cascade_config_loader] directly; a JSON load that fails is a
   different class of bug than the strict-field regression this guard
   is for. *)
let toml_section_names_result ~config_path =
  let info = source_info ~config_path in
  match info.kind with
  | Json -> Ok []
  | Toml -> (
      try
        let content = Fs_compat.load_file info.source_path in
        match Otoml.Parser.from_string_result content with
        | Error msg -> Error msg
        | Ok toml -> (
            match toml with
            | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
                let is_meta_key key =
                  String.length key > 0 && key.[0] = '_'
                in
                let is_reserved_table key = String.equal key "routes" in
                let names =
                  fields
                  |> List.filter_map (fun (key, value) ->
                         if is_meta_key key || is_reserved_table key then None
                         else
                           match value with
                           | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
                               Some key
                           | _ -> None)
                in
                Ok names
            | _ ->
                Error
                  (Printf.sprintf
                     "cascade.toml root is %s, expected table"
                     (toml_type_name toml)))
      with
      | Sys_error msg -> Error msg)

let ensure_materialized_json ~config_path =
  let source = source_info ~config_path in
  match source.kind with
  | Json -> Ok { source; wrote_json = false }
  | Toml -> (
      match render_toml_file_to_json_string source.source_path with
      | Error msg ->
          Error
            (Printf.sprintf
               "failed to materialize %s from %s: %s"
               source.json_path source.source_path msg)
      | Ok rendered_json ->
          let current_json =
            if Fs_compat.file_exists source.json_path then
              Some (Fs_compat.load_file source.json_path)
            else
              None
          in
          if current_json = Some rendered_json then
            Ok { source; wrote_json = false }
          else (
            Fs_compat.mkdir_p (Filename.dirname source.json_path);
            match Fs_compat.save_file_atomic source.json_path rendered_json with
            | Ok () -> Ok { source; wrote_json = true }
            | Error msg -> Error msg))
