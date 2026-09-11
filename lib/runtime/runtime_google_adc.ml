type runner = string list -> (string, unit) result

let refresh_with ~run () =
  match run [ "gcloud"; "auth"; "application-default"; "print-access-token"; "--quiet" ] with
  | Error () -> Error Llm_provider.Provider_config.Credential_unavailable
  | Ok output ->
    let token = String.trim output in
    if token = "" || String.exists (function '\000' .. '\032' | '\127' -> true | _ -> false) token then
      Error Llm_provider.Provider_config.Invalid_credential_response
    else Ok (Llm_provider.Secret.of_string token)

let run argv =
  match Process_eio.run_argv_with_status_split_or_refusal
    ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Env_config_sandbox.Shell_timeout.Read ()) argv with
  | Ok (Unix.WEXITED 0, stdout, _) -> Ok stdout
  | Ok _ | Error _ -> Error ()

let credential_source () =
  Llm_provider.Provider_config.Refreshable_credential (refresh_with ~run)
