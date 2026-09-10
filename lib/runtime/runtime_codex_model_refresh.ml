let ( let* ) = Result.bind
let invalid = "Codex returned invalid model context metadata."
let fields = function
  | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Ok fields
  | _ -> Error invalid
let cache_rows home =
  let path = Filename.concat home "models_cache.json" in
  if not (Sys.file_exists path) then Ok None else
  try
    let* root = fields (Yojson.Safe.from_string (Fs_compat.load_file path)) in
    match List.assoc_opt "models" root with
    | Some (`List rows) ->
      let* rows = List.fold_left (fun acc row ->
        let* result = acc in
        let* row = fields row in
        match List.assoc_opt "slug" row, List.assoc_opt "context_window" row with
        | Some (`String slug), Some (`Int context) when String.trim slug <> "" && context > 0 ->
          if List.mem_assoc slug result then Error invalid else Ok ((slug,context) :: result)
        | _ -> Error invalid) (Ok []) rows in
      Ok (Some rows)
    | _ -> Error invalid
  with Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _ -> Error invalid
let run ~mgr ~clock ~cwd ~directory ~cli_path ~timeout_s =
  let* home = Runtime_verification_codex_home.prepare ~directory
    |> Result.map_error (fun _ -> "The selected Codex connection could not be isolated for refresh.") in
  let config = { (Runtime_codex_app_server.default_config ()) with
    cli_path; isolated_home = Some home; admission_timeout_s = timeout_s;
    timeout_s = Some timeout_s } in
  let* models = Runtime_codex_app_server.list_models ~mgr ~clock ~cwd config
    |> Result.map_error (fun _ -> "Codex model refresh failed. Sign in or check the selected connection, then refresh again.") in
  let* contexts = cache_rows home in
  let rows = List.map (fun (row : Runtime_codex_app_server.listed_model) ->
    let context = Option.bind contexts (List.assoc_opt row.model) in
    `Assoc ["id", `String row.model; "label", `String row.display_name;
      "is_default", `Bool row.is_default;
      "context", (match context with Some value -> `Int value | None -> `Null)]) models in
  Ok (`Assoc ["schema", `String "masc.codex_model_refresh.v1";
    "source", `String (match contexts with Some _ -> "isolated_cli_cache" | None -> "cli_list_without_context_cache");
    "account_availability_verified", `Bool false;
    "models", `List rows])
