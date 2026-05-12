(* RFC-0058 §9 Phase 9.3: cascade.json is no longer generated or
   consumed. The previous [Json] variant of [source_kind] modelled the
   "operator committed cascade.json without a TOML sibling" mode, which
   is now disallowed — TOML is the sole SSOT. The variant is kept as a
   single-arm union so external [source_kind_to_string] callers keep
   working; future cleanup may drop the type entirely. *)
type source_kind = Toml [@tla.symbol "toml"] [@@deriving tla]

type source_info =
  { kind : source_kind
  ; source_path : string
  }

type source_state =
  { info : source_info
  ; source_exists : bool
  ; source_mtime : float option
  }

let source_kind_to_string Toml = "toml"

let toml_path_of_json_path config_path =
  Filename.concat (Filename.dirname config_path) Config_dir_resolver.cascade_toml_filename
;;

(* Accept either a TOML path or a path that points to where a JSON file
   used to live — we always resolve to the TOML sibling. If neither
   exists we still return a path so callers can probe via
   [source_state.source_exists]; an actual read will fail loudly. *)
let source_info ~config_path =
  let toml_path = toml_path_of_json_path config_path in
  let source_path =
    if Fs_compat.file_exists toml_path
    then toml_path
    else if Filename.check_suffix config_path ".toml"
    then config_path
    else toml_path
  in
  { kind = Toml; source_path }
;;

let source_state ~config_path =
  let info = source_info ~config_path in
  let source_mtime =
    try Some (Unix.stat info.source_path).Unix.st_mtime with
    | Unix.Unix_error _ | Sys_error _ -> None
  in
  { info; source_exists = Option.is_some source_mtime; source_mtime }
;;

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
;;

let errorf fmt = Printf.ksprintf (fun msg -> Error msg) fmt
let json_string_list values = `List (List.map (fun value -> `String value) values)

let table_fields ~path = function
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> Ok fields
  | value -> errorf "expected %s to be a TOML table, found %s" path (toml_type_name value)
;;

let string_value ~path = function
  | Otoml.TomlString value -> Ok value
  | value -> errorf "expected %s to be a string, found %s" path (toml_type_name value)
;;

let trimmed_nonempty_string ~path value =
  match string_value ~path value with
  | Ok raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed ""
    then errorf "expected %s to be a non-empty string" path
    else Ok trimmed
  | Error _ as err -> err
;;

let bool_value ~path = function
  | Otoml.TomlBoolean value -> Ok value
  | value -> errorf "expected %s to be a boolean, found %s" path (toml_type_name value)
;;

let int_value ~path = function
  | Otoml.TomlInteger value -> Ok value
  | value -> errorf "expected %s to be an integer, found %s" path (toml_type_name value)
;;

let float_value ~path = function
  | Otoml.TomlFloat value -> Ok value
  | Otoml.TomlInteger value -> Ok (float_of_int value)
  | value ->
    errorf "expected %s to be a float or integer, found %s" path (toml_type_name value)
;;

let rec string_array_value ~path = function
  | Otoml.TomlArray items ->
    let rec loop acc index = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        (match
           trimmed_nonempty_string ~path:(Printf.sprintf "%s[%d]" path index) item
         with
         | Ok value -> loop (value :: acc) (index + 1) rest
         | Error _ as err -> err)
    in
    loop [] 0 items
  | value -> errorf "expected %s to be an array, found %s" path (toml_type_name value)
;;

let rec string_matrix_value ~path = function
  | Otoml.TomlArray rows ->
    let rec loop acc index = function
      | [] -> Ok (List.rev acc)
      | row :: rest ->
        (match string_array_value ~path:(Printf.sprintf "%s[%d]" path index) row with
         | Ok values -> loop (values :: acc) (index + 1) rest
         | Error _ as err -> err)
    in
    loop [] 0 rows
  | value ->
    errorf
      "expected %s to be an array of string arrays, found %s"
      path
      (toml_type_name value)
;;

let model_entry_json ~path value =
  match value with
  | Otoml.TomlString _ ->
    (match trimmed_nonempty_string ~path value with
     | Ok model -> Ok (`String model)
     | Error _ as err -> err)
  | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
    (match table_fields ~path value with
     | Error _ as err -> err
     | Ok fields ->
       let model = ref None in
       let weight = ref None in
       let supports_tool_choice = ref None in
       let secondary = ref None in
       let secondary_supports_tool_choice = ref None in
       let rec loop = function
         | [] -> Ok ()
         | (key, field_value) :: rest ->
           (match key with
            | "model" ->
              (match trimmed_nonempty_string ~path:(path ^ ".model") field_value with
               | Ok value ->
                 model := Some value;
                 loop rest
               | Error _ as err -> err)
            | "weight" ->
              (* #10571: weight=0 means "configured but disabled"
                       (cascade dispatcher skips the entry).  Pre-fix the
                       validator rejected weight=0, breaking dashboard
                       cascade.json materialization on every hot-reload
                       once #10097 introduced explicit weight=0 entries
                       to disable codex_cli without removing it from the
                       seed list.  Negative weights stay rejected — they
                       have no operational meaning. *)
              (match int_value ~path:(path ^ ".weight") field_value with
               | Ok value when value >= 0 ->
                 weight := Some value;
                 loop rest
               | Ok _ -> errorf "expected %s.weight to be >= 0" path
               | Error _ as err -> err)
            | "supports_tool_choice" ->
              (match bool_value ~path:(path ^ ".supports_tool_choice") field_value with
               | Ok value ->
                 supports_tool_choice := Some value;
                 loop rest
               | Error _ as err -> err)
            | "secondary" ->
              (* RFC-0027 PR-9 dual-track fallback. Same string-trim
                       semantics as model: empty/whitespace rejected at
                       parse time so an empty secondary cannot silently
                       turn into an invalid provider scheme downstream. *)
              (match trimmed_nonempty_string ~path:(path ^ ".secondary") field_value with
               | Ok value ->
                 secondary := Some value;
                 loop rest
               | Error _ as err -> err)
            | "secondary_supports_tool_choice" ->
              (match
                 bool_value ~path:(path ^ ".secondary_supports_tool_choice") field_value
               with
               | Ok value ->
                 secondary_supports_tool_choice := Some value;
                 loop rest
               | Error _ as err -> err)
            | other ->
              errorf
                "unknown field %S in %s; allowed fields are model, weight, \
                 supports_tool_choice, secondary, secondary_supports_tool_choice"
                other
                path)
       in
       (match loop fields with
        | Error _ as err -> err
        | Ok () ->
          (match !model with
           | None -> errorf "missing required field %s.model" path
           | Some model_value ->
             (* Reject orphan secondary_supports_tool_choice with no
                     secondary declared — it's unambiguously a typo or
                     copy-paste error and silent acceptance hides it. *)
             (match !secondary, !secondary_supports_tool_choice with
              | None, Some _ ->
                errorf
                  "field %s.secondary_supports_tool_choice declared without \
                   %s.secondary; remove the override or add a secondary model"
                  path
                  path
              | _ ->
                let fields = [ "model", `String model_value ] in
                let fields =
                  match !weight with
                  | Some value -> fields @ [ "weight", `Int value ]
                  | None -> fields
                in
                let fields =
                  match !supports_tool_choice with
                  | Some value -> fields @ [ "supports_tool_choice", `Bool value ]
                  | None -> fields
                in
                let fields =
                  match !secondary with
                  | Some value -> fields @ [ "secondary", `String value ]
                  | None -> fields
                in
                let fields =
                  match !secondary_supports_tool_choice with
                  | Some value ->
                    fields @ [ "secondary_supports_tool_choice", `Bool value ]
                  | None -> fields
                in
                Ok (`Assoc fields)))))
  | other ->
    errorf
      "expected %s to be a string or inline table model entry, found %s"
      path
      (toml_type_name other)
;;

let model_array_value ~path = function
  | Otoml.TomlArray items ->
    let rec loop acc index = function
      | [] -> Ok (`List (List.rev acc))
      | item :: rest ->
        (match model_entry_json ~path:(Printf.sprintf "%s[%d]" path index) item with
         | Ok value -> loop (value :: acc) (index + 1) rest
         | Error _ as err -> err)
    in
    loop [] 0 items
  | value ->
    errorf
      "expected %s to be an array of model entries, found %s"
      path
      (toml_type_name value)
;;

let api_key_env_json ~path value =
  match table_fields ~path value with
  | Error _ as err -> err
  | Ok fields ->
    let rec loop acc = function
      | [] -> Ok (`Assoc (List.rev acc))
      | (key, field_value) :: rest ->
        (match string_value ~path:(Printf.sprintf "%s.%s" path key) field_value with
         | Ok env_var -> loop ((key, `String env_var) :: acc) rest
         | Error _ as err -> err)
    in
    loop [] fields
;;

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
  | Otoml.TomlArray items -> `List (List.map otoml_to_yojson items)
  | Otoml.TomlTable fields ->
    `Assoc (List.map (fun (k, v) -> k, otoml_to_yojson v) fields)
  | Otoml.TomlInlineTable fields ->
    `Assoc (List.map (fun (k, v) -> k, otoml_to_yojson v) fields)
  | Otoml.TomlTableArray items -> `List (List.map otoml_to_yojson items)
;;

let routes_json ~path value =
  match table_fields ~path value with
  | Error _ as err -> err
  | Ok fields ->
    let rec loop acc = function
      | [] -> Ok (`Assoc (List.rev acc))
      | (key, field_value) :: rest ->
        let item_path = Printf.sprintf "%s.%s" path key in
        (* Two route encodings are accepted:
               1. Legacy:   [routes] keeper_turn = "tier:big_three"
               2. RFC-0058: [routes.keeper_turn] target = "tier-group.big_three"
               The latter is materialized as a JSON object, leaving target
               extraction to [Cascade_declarative_parser]. *)
        (match field_value with
         | Otoml.TomlTable _ | Otoml.TomlInlineTable _ ->
           loop ((key, otoml_to_yojson field_value) :: acc) rest
         | _ ->
           (match trimmed_nonempty_string ~path:item_path field_value with
            | Ok target -> loop ((key, `String target) :: acc) rest
            | Error _ as err -> err))
    in
    loop [] fields
;;

(** RFC-0058: Parse [profiles.<name>] TOML sections into a JSON structure.
    Each profile sub-table contains [required_capabilities] (string array)
    and optionally [provider_filter] (string). *)
let profiles_json ~path value =
  match table_fields ~path value with
  | Error _ as err -> err
  | Ok profile_tables ->
    let rec loop acc = function
      | [] -> Ok (`Assoc (List.rev acc))
      | (profile_name, profile_value) :: rest ->
        (match
           table_fields ~path:(Printf.sprintf "%s.%s" path profile_name) profile_value
         with
         | Error _ as err -> err
         | Ok fields ->
           let field_path field_name =
             Printf.sprintf "%s.%s.%s" path profile_name field_name
           in
           let required_caps =
             let rec find = function
               | [] -> Ok []
               | (key, v) :: _ when String.equal key "required_capabilities" ->
                 string_array_value ~path:(field_path key) v
               | _ :: rest -> find rest
             in
             find fields
           in
           let provider_filter =
             let rec find = function
               | [] -> Ok None
               | (key, v) :: _ when String.equal key "provider_filter" ->
                 (match string_value ~path:(field_path key) v with
                  | Ok s -> Ok (Some s)
                  | Error _ as err -> err)
               | _ :: rest -> find rest
             in
             find fields
           in
           (match required_caps, provider_filter with
            | Ok caps, Ok filter ->
              let json_fields =
                [ "required_capabilities", `List (List.map (fun s -> `String s) caps) ]
                @
                match filter with
                | None -> []
                | Some f -> [ "provider_filter", `String f ]
              in
              loop ((profile_name, `Assoc json_fields) :: acc) rest
            | (Error _ as err), _ -> err
            | _, (Error _ as err) -> err))
    in
    loop [] profile_tables
;;

let render_toml_to_yojson toml =
  match table_fields ~path:"<root>" toml with
  | Error _ as err -> err
  | Ok fields ->
    (* RFC-0058 v2 5-layer declarative namespaces. These tables describe
         providers, models, bindings, tiers, tier-groups, etc. and are
         consumed by the declarative loader. Passthrough preserves the TOML
         shape for JSON-shaped readers such as route decoding. *)
    let is_rfc_0058_namespace = function
      | "providers" | "models" | "tier" | "tier-group" -> true
      | _ -> false
    in
    let rec loop acc = function
      | [] -> Ok (`Assoc (List.rev acc |> List.concat))
      | (key, value) :: rest ->
        if String.equal key "comment"
        then (
          match string_value ~path:"comment" value with
          | Ok text -> loop ([ "_comment", `String text ] :: acc) rest
          | Error _ as err -> err)
        else if String.equal key "routes"
        then (
          match routes_json ~path:"routes" value with
          | Ok routes -> loop ([ "routes", routes ] :: acc) rest
          | Error _ as err -> err)
        else if String.equal key "profiles"
        then (
          (* RFC-0058: capability profile definitions — parsed into
                 a JSON "profiles" namespace consumed by
                 [Cascade_capability_profile]. *)
          match profiles_json ~path:"profiles" value with
          | Ok profiles -> loop ([ "profiles", profiles ] :: acc) rest
          | Error _ as err -> err)
        else if String.equal key "admission"
        then
          (* RFC-0026 admission namespace — pass through to JSON
                 verbatim.  The schema is owned by
                 [Keeper_admission_policy.parse_admission_json] in
                 lib/keeper/, not by the cascade profile schema. *)
          loop ([ "admission", otoml_to_yojson value ] :: acc) rest
        else if is_rfc_0058_namespace key
        then loop ([ key, otoml_to_yojson value ] :: acc) rest
        else (
          (* Layer-3 bindings appear as [<provider>.<model>] tables under
                 a top-level provider key (e.g. [claude_code.haiku]). Detect
                 by checking whether [key] matches a provider table that was
                 declared earlier under [providers]; if so, pass through. *)
          let is_provider_binding =
            List.exists
              (fun (k, v) ->
                 String.equal k "providers"
                 &&
                 match v with
                 | Otoml.TomlTable inner | Otoml.TomlInlineTable inner ->
                   List.exists (fun (pk, _) -> String.equal pk key) inner
                 | _ -> false)
              fields
          in
          if is_provider_binding
          then loop ([ key, otoml_to_yojson value ] :: acc) rest
          else
            errorf
              "legacy flat cascade TOML profile %S is no longer supported; use \
               RFC-0058 declarative namespaces ([providers.*], [models.*], \
               [<provider>.<binding>], [tier.*], [tier-group.*], [routes.*])"
              key)
    in
    loop [] fields
;;

let render_toml_string_to_json_string content =
  match Otoml.Parser.from_string_result content with
  | Error msg -> Error msg
  | Ok toml ->
    (match render_toml_to_yojson toml with
     | Ok json -> Ok (Yojson.Safe.pretty_to_string json ^ "\n")
     | Error _ as err -> err)
;;

let render_toml_file_to_json_string toml_path =
  try
    let content = Fs_compat.load_file toml_path in
    render_toml_string_to_json_string content
  with
  | Sys_error msg -> Error msg
;;

let render_toml_to_json_string ~config_path =
  let source = source_info ~config_path in
  match render_toml_file_to_json_string source.source_path with
  | Ok json -> Ok (source, json)
  | Error msg ->
    Error (Printf.sprintf "failed to materialize from %s: %s" source.source_path msg)
;;

(* RFC-0058 §9 Phase 9.3: [ensure_materialized_json] retired. cascade.json
   is no longer generated or consumed; rendering happens in-memory via
   [render_toml_to_json_string]. The disk-write path and
   [materialize_result] type are gone. *)
