module Setup = Runtime_antigravity_setup
type account_action = Import_current | Sign_in | Use_reference of string
open Result.Syntax
let refused message =
  print_endline (Yojson.Safe.to_string (`Assoc ["schema", `String "masc.antigravity_setup_error.v1";
    "error", `String message])); 1

let report = function
  | Ok json -> print_endline (Yojson.Safe.to_string json); 0
  | Error error -> refused (Setup.error_message error)

(* HIGH-RISK-UNREVIEWED: every command copies a credential of the host into a
   private HOME and starts the client on it. This host tool publishes its
   account access after its judgment of the base path, and only a single-user
   workspace shares its host account (plan D3b). *)
let host ~base_path =
  let* () =
    Runtime_account_access.publish_host_tool ~base_path
      ~config_dir:(Env_config_core.masc_config_dir_opt ())
    |> Result.map_error (fun (first, rest) -> String.concat "; " (first :: rest))
  in
  Runtime_account_access.authorize_host Runtime_account_access.Antigravity
  |> Result.map_error Runtime_account_access.refusal_to_string

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
  match host ~base_path with
  | Error message -> refused message
  | Ok host ->
  let result = try
    let base_path = Unix.realpath (Env_config.normalize_masc_base_path_input base_path) in
    let runtime_root = Filename.concat base_path Common.masc_dirname in
    let account_id = "setup-" ^ Random_id.hex ~bytes:16 in
    let* home = match action with
      | Use_reference oauth_source ->
        Setup.prepare_from_credential_file ~host ~runtime_root ~account_id ~oauth_source
      | Import_current | Sign_in -> Setup.prepare ~host ~runtime_root ~account_id in
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

let with_catalog_home ~host ~oauth_source f =
  try
    let runtime_root = Filename.temp_dir "masc-agy-models-" "" |> Unix.realpath in
    Fun.protect ~finally:(fun () -> Fs_compat.remove_tree runtime_root) (fun () ->
      let* home =
        Setup.prepare_from_credential_file ~host ~runtime_root ~account_id:"catalog" ~oauth_source
      in
      f home)
    with Unix.Unix_error _ | Sys_error _ -> Error Setup.Private_home_unavailable

let models ~base_path ~cli_path ~timeout_s ~oauth_source =
  match host ~base_path with
  | Error message -> refused message
  | Ok host ->
  with_catalog_home ~host ~oauth_source (fun home ->
    Setup.discover_models ~cli_path ~timeout_s home |> Result.map Setup.models_json) |> report

let context ~base_path ~python_path ~cli_path ~timeout_s ~oauth_source ~model_id =
  match host ~base_path with
  | Error message -> refused message
  | Ok host ->
  let selected = with_catalog_home ~host ~oauth_source (fun home ->
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
    Runtime_antigravity_context.observe ~host ~python_path ~cli_path ~timeout_s ~oauth_source ~model
    |> Result.map_error Runtime_antigravity_context.error_message in
  match result with
  | Error message -> refused message
  | Ok observed ->
    let context = match observed with Setup.Unknown_context -> `Null | Observed_context tokens -> `Int tokens in
    print_endline (Yojson.Safe.to_string (`Assoc ["source", `String "antigravity_statusline";
      "model", `String model_id; "context", context; "invocation_verified", `Bool false])); 0
