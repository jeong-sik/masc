type client = Codex | Claude | Antigravity | Muse
type native = Codex_home | Claude_home | Muse_home
type t =
  | Native of { client : native; account_home : string }
  | Antigravity_home of { home : Runtime_antigravity_setup.t; timeout_s : float }
type observation = Authenticated | Login_completed | Credential_captured
let ( let* ) = Result.bind

let filesystem action =
  try Eio_guard.run_in_systhread ~label:"setup-login-account-storage" action with
  | Unix.Unix_error _ | Sys_error _ -> Error "The selected private account directory is unavailable."

let directory ~private_ path =
  let stat = Unix.lstat path in
  if stat.st_kind = Unix.S_DIR && stat.st_uid = Unix.geteuid ()
     && stat.st_perm land (if private_ then 0o077 else 0o022) = 0
  then Ok () else Error "The selected account path must be an owned, protected directory."

let child parent leaf =
  let path = Filename.concat parent leaf in
  (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let* () = directory ~private_:true path in
  let fd = Unix.openfile parent [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
  Ok path

let new_home ~runtime_root ~account_id ~client = filesystem (fun () ->
  if not (Fs_compat.is_capability_leaf account_id) then Error "Invalid login account identity."
  else if Filename.is_relative runtime_root then Error "The runtime directory must be absolute."
  else
    let runtime_root = Unix.realpath runtime_root in
    let* () = directory ~private_:false runtime_root in
    let* clients = child runtime_root "official-clients" in
    let* client_root = child clients (match client with
      | Codex_home -> "codex" | Claude_home -> "claude" | Muse_home -> "muse") in
    child client_root account_id)

let native_home ~runtime_root ~account_id ~client existing =
  let* account_home = match existing with
    | None -> new_home ~runtime_root ~account_id ~client
    | Some (Runtime_setup_accounts.Native_home {account_home}) ->
      (* Claude's keychain service hashes this spelling. Never canonicalize the
         returned identity, even when validating its physical owner. *)
      filesystem (fun () ->
        let* account_home = Runtime_account_home.of_string account_home in
        let* () = directory ~private_:false (Unix.realpath account_home) in
        Ok account_home)
    | Some (Runtime_setup_accounts.Antigravity_account _) ->
      Error "The selected account belongs to another client transport."
  in Ok (Native {client; account_home})

let prepare ~runtime_root ~account_id ~client ~existing =
  match client with
  | Codex -> native_home ~runtime_root ~account_id ~client:Codex_home existing
  | Claude -> native_home ~runtime_root ~account_id ~client:Claude_home existing
  | Muse -> native_home ~runtime_root ~account_id ~client:Muse_home existing
  | Antigravity ->
    let* home, timeout_s = match existing with
      | None ->
        Runtime_antigravity_setup.prepare ~runtime_root ~account_id
        |> Result.map (fun home -> home, Runtime_antigravity.default_timeout_s)
        |> Result.map_error Runtime_antigravity_setup.error_message
      | Some (Runtime_setup_accounts.Antigravity_account {credential_file; timeout_s}) ->
        Runtime_antigravity_setup.prepare_from_credential_file ~runtime_root
          ~account_id ~oauth_source:credential_file
        |> Result.map (fun home -> home, timeout_s)
        |> Result.map_error Runtime_antigravity_setup.error_message
      | Some (Runtime_setup_accounts.Native_home _) ->
        Error "The selected account belongs to another client transport."
    in Ok (Antigravity_home {home; timeout_s})

let home_dir = function
  | Native {account_home; _} -> account_home
  | Antigravity_home {home; _} -> Runtime_antigravity_setup.home_dir home

let argv ~cli_path = function
  | Native {client=Codex_home; _} -> [cli_path; "login"; "--device-auth"]
  | Native {client=Claude_home; _} -> [cli_path; "auth"; "login"]
  | Native {client=Muse_home; _} -> Runtime_muse_serve.login_argv ~cli_path
  | Antigravity_home _ -> [cli_path]

let environment = function
  | Native {client=Codex_home; account_home} ->
    Runtime_codex_app_server.client_environment (Some account_home)
    |> Result.map_error Runtime_codex_app_server.error_to_string
  | Native {client=Claude_home; account_home} ->
    Ok (Runtime_claude_code.client_environment (Some account_home))
  | Native {client=Muse_home; account_home} ->
    Ok (Runtime_muse_serve.login_environment ~account_home)
  | Antigravity_home {home; _} -> Ok (Runtime_antigravity_setup.environment home)

let is_pty = function Native _ -> false | Antigravity_home _ -> true

let observe ~mgr ~clock ~cwd ~cli_path = function
  | Native {client=Codex_home; account_home} ->
    let config = { (Runtime_codex_app_server.default_config ()) with
      cli_path; account_home=Some account_home } in
    let* result = Runtime_codex_app_server.probe_subscription ~mgr ~clock ~cwd config
      |> Result.map_error Runtime_codex_app_server.error_to_string in
    (match result.subscription with
     | Runtime_codex_app_server.Chatgpt _ | Api_key -> Ok Authenticated
     | Provider_managed | Amazon_bedrock ->
       Error "Codex did not report authentication for this selected login account.")
  | Native {client=Claude_home; account_home} ->
    let config = { (Runtime_claude_code.default_config ~cwd:account_home) with
      cli_path; account_home=Some account_home } in
    let* result = Runtime_claude_code.probe_subscription ~mgr ~clock ~cwd config
      |> Result.map_error Runtime_claude_code.error_to_string in
    (match result.authentication with
     | Runtime_claude_code.Claude_ai | Api_key | OAuth_token -> Ok Authenticated
     | Third_party -> Error "Claude did not report authentication for this selected login account.")
  | Native {client=Muse_home; account_home} ->
    Runtime_muse_home.prepare ~account_home
    |> Result.map (fun _ -> Login_completed)
    |> Result.map_error Runtime_muse_home.error_to_string
  | Antigravity_home {home; _} ->
    Runtime_antigravity_setup.capture_login home
    |> Result.map (fun () -> Credential_captured)
    |> Result.map_error Runtime_antigravity_setup.error_message

let publish ~workspace ~integration_id ~cli_path = function
  | Native {account_home; _} ->
    Runtime_setup_accounts.register_home ~workspace ~integration_id ~cli_path ~account_home
    |> Result.map_error Runtime_setup_accounts.error_message
  | Antigravity_home {home; timeout_s} ->
    let* credential = Runtime_antigravity_setup.credential_reference home
      |> Result.map_error Runtime_antigravity_setup.error_message in
    let* oauth_source = match credential with
      | Runtime_schema.File path -> Ok path
      | Runtime_schema.Env _ | Runtime_schema.Inline _ ->
        Error "Antigravity login did not capture a private credential file."
    in
    Runtime_setup_accounts.create ~workspace ~integration_id ~cli_path
      ~import:(fun ~base_path ->
        let runtime_root = Common.masc_dir_from_base_path ~base_path in
        let* durable = Runtime_antigravity_setup.prepare_from_credential_file
          ~runtime_root ~account_id:"login" ~oauth_source
          |> Result.map_error (fun _ -> Runtime_setup_accounts.Import_failed) in
        let* credential = Runtime_antigravity_setup.credential_reference durable
          |> Result.map_error (fun _ -> Runtime_setup_accounts.Import_failed) in
        match credential with
        | Runtime_schema.File credential_file ->
          Ok {Runtime_setup_accounts.credential_file; timeout_s; catalog=`Null}
        | Runtime_schema.Env _ | Runtime_schema.Inline _ -> Error Runtime_setup_accounts.Import_failed)
    |> Result.map fst |> Result.map_error Runtime_setup_accounts.error_message
