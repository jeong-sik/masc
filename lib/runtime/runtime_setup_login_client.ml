type client = Codex | Claude | Antigravity | Mistral_vibe
type native = Runtime_account_home_layout.client = Codex_home | Claude_home
type browser = Host_browser | Idle_command of string
type login =
  | Native of { client : native; account_home : string }
  | Antigravity_home of
      { home : Runtime_antigravity_setup.t
      ; timeout_s : float
      ; host : Runtime_account_access.host_account
          (** The start the access allowed when the login home was prepared. *)
      }
  | Mistral_vibe_keyring of
      { host : Runtime_account_access.host_account
      }
(* A login and the browser decided for its sign-in. Whatever makes a login
   takes the browser, so a sign-in that was refused one has no home made for
   it, and the child is handed the browser that was decided. *)
type t = { login : login; browser : browser }
type observation = Authenticated | Login_completed | Credential_captured
open Result.Syntax

let filesystem action =
  try Eio_guard.run_in_systhread ~label:"setup-login-account-storage" action with
  | Unix.Unix_error _ | Sys_error _ -> Error "The selected private account directory is unavailable."

let directory = Runtime_account_home_folder.directory

let new_home ~runtime_root ~account_id ~client =
  filesystem (fun () -> Runtime_account_home_folder.make ~runtime_root ~account_id ~client)

let account_home_path ~runtime_root ~account_id ~client =
  let* native = match client with
    | Codex -> Ok Codex_home | Claude -> Ok Claude_home
    | Antigravity -> Error "An Antigravity login keeps no account home."
    | Mistral_vibe -> Error "A Mistral Vibe login stores credentials in the host OS keyring and keeps no account home." in
  filesystem (fun () -> Runtime_account_home_layout.home ~runtime_root native ~account_id)

let account_home ~runtime_root ~account_id ~client =
  let* home = account_home_path ~runtime_root ~account_id ~client in
  filesystem (fun () ->
    let* () = directory ~private_:true home in
    Ok home)

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

let selected_native ~browser client ~account_home =
  filesystem (fun () ->
    let* account_home = Runtime_account_home.of_string account_home in
    let* () = directory ~private_:false (Unix.realpath account_home) in
    Ok { login = Native {client; account_home}; browser })

let login_of ~runtime_root ~account_id ~client ~existing =
  match client with
  | Codex -> native_home ~runtime_root ~account_id ~client:Codex_home existing
  | Claude -> native_home ~runtime_root ~account_id ~client:Claude_home existing
  | Antigravity ->
    (* HIGH-RISK-UNREVIEWED: the login home holds a copy of a credential of the
       host, and a multi-account process shares no account of its host (plan D3b). *)
    let* host =
      Runtime_account_access.authorize_host Runtime_account_access.Antigravity
      |> Result.map_error Runtime_account_access.refusal_to_string
    in
    let* home, timeout_s = match existing with
      | None ->
        Runtime_antigravity_setup.prepare ~host ~runtime_root ~account_id
        |> Result.map (fun home -> home, Runtime_antigravity.default_timeout_s)
        |> Result.map_error Runtime_antigravity_setup.error_message
      | Some (Runtime_setup_accounts.Antigravity_account {credential_file = _; timeout_s}) ->
        (* This is a new sign-in, not an invocation on the selected credential.
           Seeding it would start agy's conversation instead of authentication.
           The previously selected credential remains available for recovery. *)
        Runtime_antigravity_setup.prepare ~host ~runtime_root ~account_id
        |> Result.map (fun home -> home, timeout_s)
        |> Result.map_error Runtime_antigravity_setup.error_message
      | Some (Runtime_setup_accounts.Native_home _) ->
        Error "The selected account belongs to another client transport."
    in Ok (Antigravity_home {home; timeout_s; host})
  | Mistral_vibe ->
    let* host =
      Runtime_account_access.authorize_host
        (Runtime_account_access.Acp_client Runtime_acp_client.Mistral_vibe)
      |> Result.map_error Runtime_account_access.refusal_to_string
    in
    (match existing with
     | None -> Ok (Mistral_vibe_keyring { host })
     | Some (Runtime_setup_accounts.Native_home _ | Runtime_setup_accounts.Antigravity_account _) ->
       Error "The selected account belongs to another client transport.")

let prepare ~browser ~runtime_root ~account_id ~client ~existing =
  Result.map (fun login -> { login; browser })
    (login_of ~runtime_root ~account_id ~client ~existing)

let home_dir t = match t.login with
  | Native {account_home; _} -> account_home
  | Antigravity_home {home; _} -> Runtime_antigravity_setup.home_dir home
  | Mistral_vibe_keyring _ ->
    Option.value (Env_config_core.raw_value_opt "HOME") ~default:"/"

let argv ~cli_path t = match t.login with
  | Native {client=Codex_home; _} -> [cli_path; "login"; "--device-auth"]
  | Native {client=Claude_home; _} -> [cli_path; "auth"; "login"]
  | Antigravity_home _ -> [cli_path]
  | Mistral_vibe_keyring _ -> [cli_path; "--setup"]

let client_environment = function
  | Native {client=Codex_home; account_home} ->
    Runtime_codex_app_server.login_environment ~account_home
    |> Result.map_error Runtime_codex_app_server.error_to_string
  | Native {client=Claude_home; account_home} ->
    Runtime_claude_code.login_environment ~account_home
    |> Result.map_error Runtime_claude_code.error_to_string
  | Antigravity_home {home; _} -> Ok (Runtime_antigravity_setup.environment home)
  | Mistral_vibe_keyring _ ->
    Ok
      (Runtime_acp_client.For_testing.build_environment
         ~base_env:(Unix.environment ())
         ~driver:Runtime_acp_client.Mistral_vibe
         ~extra_strip_env:[])

(* The variable that names the command an official client runs to open a
   link. Claude Code 2.1.326 runs the file it names, with the link as its one
   operand, in place of the opener of the system; the variables its
   documentation lists do not include it. The device-code sign-ins of Codex
   0.169.0 and Muse Code 1.4.20 print their link and started neither. *)
let browser_variable = "BROWSER"

(* POSIX [true] takes any operands, does nothing and exits 0. *)
let idle_command = "true"

let host_browser = Host_browser

(* HIGH-RISK-UNREVIEWED: the link Claude Code hands to the opener returns the
   approval to a port of this machine, so whoever approves it in a browser of
   this machine signs their own account in to the home of this login, whoever
   started the login. A child handed a command that opens nothing shows this
   machine nothing: the one who signs in opens the link the child prints and
   ends the sign-in as that client asks. Claude Code reads a code from its
   input; Codex and Muse Code take theirs on the page the link opens.

   A machine that has no such command refuses the sign-in here, and a login
   is made only with the answer ([prepare]). *)
let no_host_browser ?(getenv = Sys.getenv_opt) () =
  match
    Eio_guard.run_in_systhread ~label:"setup-login-browser-command" (fun () ->
      Executable_path.absolute_on_path ~getenv idle_command)
  with
  | None ->
    Error
      (Printf.sprintf
         "PATH holds no %s utility in an absolute directory, so this sign-in has no \
          command to give the official client in place of the browser of this machine."
         idle_command)
  | Some command -> Ok (Idle_command command)

let browser_command = function
  | Host_browser -> None
  | Idle_command command -> Some command

(* One binding, whatever the client's own environment carries: a client that
   reads the last of two would run the other one. *)
let handed browser environment =
  match browser with
  | Host_browser -> environment
  | Idle_command command ->
    let binding = browser_variable ^ "=" in
    let others =
      Array.to_list environment
      |> List.filter (fun entry -> not (String.starts_with ~prefix:binding entry))
    in
    Array.of_list ((binding ^ command) :: others)

let environment t = Result.map (handed t.browser) (client_environment t.login)

let is_pty t = match t.login with
  | Native _ -> false
  | Antigravity_home _ | Mistral_vibe_keyring _ -> true

let saved_login_check t = match t.login with
  | Native _ | Mistral_vibe_keyring _ -> None
  | Antigravity_home {home; _} -> Some (fun () ->
      match Runtime_antigravity_setup.login_saved home with
      | Ok saved -> Ok saved
      (* The running client may create/truncate/write its fallback file.
         Only a complete, parsed login ends it. After client exit, observe
         and publication still reject unreadable or unknown credentials. *)
      | Error (Runtime_antigravity_setup.Login_write_in_progress | Unrecognized_credential) -> Ok false
      | Error (Runtime_antigravity_setup.(Private_home_unavailable | Sign_in_required
          | Unsafe_credential | Unrecognized_managed_credential | Command_failed
          | Invalid_catalog | Keychain_unavailable) as error) ->
        Error (Runtime_antigravity_setup.error_message error))

let authorize ~account_request ~client ~account_home =
  let* captured = Runtime_official_account.capture ~client ~declaration:(Some account_home) in
  Runtime_account_access.authorize account_request (Runtime_account_access.seal captured)
  |> Result.map_error Runtime_account_access.refusal_to_string

let observe ~mgr ~clock ~cwd ~cli_path ~account_request t = match t.login with
  | Native {client=Codex_home; account_home} ->
    let* account = authorize ~account_request ~client:Codex ~account_home in
    let config = { (Runtime_codex_app_server.default_config ()) with cli_path } in
    let* result = Runtime_codex_app_server.probe_subscription ~mgr ~clock ~cwd ~account config
      |> Result.map_error Runtime_codex_app_server.error_to_string in
    (match result.subscription with
     | Runtime_codex_app_server.Chatgpt _ | Api_key -> Ok Authenticated
     | Provider_managed | Amazon_bedrock ->
       Error "Codex did not report authentication for this selected login account.")
  | Native {client=Claude_home; account_home} ->
    let* account = authorize ~account_request ~client:Claude_code ~account_home in
    let config = { (Runtime_claude_code.default_config ~cwd:account_home) with cli_path } in
    let* result = Runtime_claude_code.probe_subscription ~mgr ~clock ~cwd ~account config
      |> Result.map_error Runtime_claude_code.error_to_string in
    (match result.authentication with
     | Runtime_claude_code.Claude_ai | Api_key | OAuth_token -> Ok Authenticated
     | Third_party -> Error "Claude did not report authentication for this selected login account.")
  | Antigravity_home {home; _} ->
    Runtime_antigravity_setup.capture_login home
    |> Result.map (fun () -> Credential_captured)
    |> Result.map_error Runtime_antigravity_setup.error_message
  | Mistral_vibe_keyring { host = _ } ->
    let spawn_path =
      Runtime_official_cli_install.spawn_path
        Runtime_official_cli_install.Mistral_vibe
        ~command:cli_path
    in
    (match Process_eio.run_argv_with_status_split_or_refusal [ spawn_path; "--version" ] with
     | Ok (Unix.WEXITED 0, _, _) -> Ok Login_completed
     | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) | Error _ ->
       Error "Mistral Vibe CLI did not report a healthy version after setup.")

let publish ~workspace ~integration_id ~cli_path t = match t.login with
  | Native {account_home; _} ->
    Runtime_setup_accounts.register_home ~workspace ~integration_id ~cli_path ~account_home
    |> Result.map_error Runtime_setup_accounts.error_message
  | Mistral_vibe_keyring _ ->
    Error "Mistral Vibe stores credentials in the host OS keyring and publishes no separate setup credential copy."
  | Antigravity_home {home; timeout_s; host} ->
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
          ~host ~runtime_root ~account_id:"login" ~oauth_source
          |> Result.map_error (fun _ -> Runtime_setup_accounts.Import_failed) in
        let* credential = Runtime_antigravity_setup.credential_reference durable
          |> Result.map_error (fun _ -> Runtime_setup_accounts.Import_failed) in
        match credential with
        | Runtime_schema.File credential_file ->
          Ok {Runtime_setup_accounts.credential_file; timeout_s; catalog=`Null}
        | Runtime_schema.Env _ | Runtime_schema.Inline _ -> Error Runtime_setup_accounts.Import_failed)
    |> Result.map fst |> Result.map_error Runtime_setup_accounts.error_message
