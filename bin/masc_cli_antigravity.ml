module Setup = Runtime_antigravity_setup
type account_action = Import_current | Sign_in | Use_reference of string
let ( let* ) = Result.bind
let report = function
  | Ok json -> print_endline (Yojson.Safe.to_string json); 0
  | Error error ->
    print_endline (Yojson.Safe.to_string (`Assoc ["schema", `String "masc.antigravity_setup_error.v1";
      "error", `String (Setup.error_message error)])); 1

let sign_in ~cli_path home =
  if not (Unix.isatty Unix.stdin) then Error Setup.Sign_in_required else (
    prerr_endline "The official Antigravity client will open sign-in in your browser. After signing in, press Ctrl-D at its prompt to return to MASC.";
    let pid = Unix.fork () in
    if pid = 0 then (
      try
        Unix.chdir (Setup.home_dir home);
        Unix.dup2 Unix.stderr Unix.stdout;
        Unix.execvpe cli_path [|cli_path|] (Setup.environment home)
      with _ -> Unix._exit 127);
    let (_ : Unix.process_status) = Masc_cli_setup.wait_for_child pid in
    Setup.capture_login home)

let account ~base_path ~cli_path ~timeout_s ~action =
  let result = try
    let base_path = Unix.realpath (Env_config.normalize_masc_base_path_input base_path) in
    let runtime_root = Filename.concat base_path Common.masc_dirname in
    let account_id = "setup-" ^ Random_id.hex ~bytes:16 in
    let* home = match action with
      | Use_reference oauth_source -> Setup.prepare_from_credential_file ~runtime_root ~account_id ~oauth_source
      | Import_current | Sign_in -> Setup.prepare ~runtime_root ~account_id in
    let* () = match action with
      | Use_reference _ -> Ok ()
      | Import_current -> (match Sys.getenv_opt "HOME" with
        | None -> Error Setup.Sign_in_required
        | Some source_home -> Setup.import_signed_in ~source_home home)
      | Sign_in -> sign_in ~cli_path home in
    let* credential = Setup.credential_reference home in
    let models, catalog_error = match Setup.discover_models ~cli_path ~timeout_s home with
      | Ok models -> Setup.models_json models, `Null
      | Error error -> Setup.models_json [], `String (Setup.error_message error) in
    match credential with
    | Runtime_schema.File path ->
      Ok (`Assoc ["schema", `String "masc.antigravity_account.v1";
        "credential_file", `String path; "catalog", models; "catalog_error", catalog_error;
        "provider_timeout_s", `Float Runtime_antigravity.default_timeout_s;
        "invocation_verified", `Bool false])
    | Env _ | Inline _ -> Error Setup.Unsafe_credential
    with Unix.Unix_error _ | Sys_error _ -> Error Setup.Private_home_unavailable in
  report result

let with_catalog_home ~oauth_source f =
  try
    let runtime_root = Filename.concat (Filename.get_temp_dir_name ()) ("masc-agy-models-" ^ Random_id.hex ~bytes:16) in
    Unix.mkdir runtime_root 0o700;
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree runtime_root) (fun () ->
      let* home = Setup.prepare_from_credential_file ~runtime_root ~account_id:"catalog" ~oauth_source in
      f home)
    with Unix.Unix_error _ | Sys_error _ -> Error Setup.Private_home_unavailable

let models ~cli_path ~timeout_s ~oauth_source =
  with_catalog_home ~oauth_source (fun home ->
    Setup.discover_models ~cli_path ~timeout_s home |> Result.map Setup.models_json) |> report

let context ~python_path ~cli_path ~timeout_s ~oauth_source ~model_id =
  let selected = with_catalog_home ~oauth_source (fun home ->
    let* models = Setup.discover_models ~cli_path ~timeout_s home in
    match List.find_opt (fun (model : Setup.model) -> model.id = model_id) models with
    | None -> Error Setup.Invalid_catalog
    | Some model ->
      (* Some CLI versions report the label as model.id. Require its unique
         association with the selected account model before accepting it. *)
      if List.length (List.filter (fun (row : Setup.model) -> row.label = model.label) models) <> 1 then
        Error Setup.Invalid_catalog else Ok model)
    |> Result.map_error Setup.error_message in
  let result =
    let* model = selected in
    Runtime_antigravity_context.observe ~python_path ~cli_path ~timeout_s ~oauth_source ~model
    |> Result.map_error Runtime_antigravity_context.error_message in
  match result with
  | Error message ->
    print_endline (Yojson.Safe.to_string (`Assoc ["schema", `String "masc.antigravity_setup_error.v1";
      "error", `String message])); 1
  | Ok observed ->
    let context = match observed with Setup.Unknown_context -> `Null | Observed_context tokens -> `Int tokens in
    print_endline (Yojson.Safe.to_string (`Assoc ["source", `String "antigravity_statusline";
      "model", `String model_id; "context", context; "invocation_verified", `Bool false])); 0
