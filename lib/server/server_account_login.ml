(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

type refusal =
  | Google_client_refused of Login_client.environment_error
  | Github_client_refused of Login_client.environment_error
  | Redirect_not_the_callback of
      { provider : Login_routes.provider
      ; callback_path : string
      ; redirect_path : string
      }
  | Redirect_not_on_the_base_url of
      { provider : Login_routes.provider
      ; base_url_origin : string
      ; redirect_origin : string
      }
  | Redirect_not_read of
      { provider : Login_routes.provider
      ; redirect_uri : string
      }

let provider_name = function
  | Login_routes.Google -> "google"
  | Login_routes.Github -> "github"
;;

type disabled_reason =
  | Not_configured
  | Secret_env_missing of { env_var : string }
  | Client_id_empty
  | Client_secret_empty of { env_var : string option }
  | Redirect_uri_not_https
  | Redirect_uri_malformed
  | Redirect_uri_callback_mismatch of
      { expected_path : string
      ; actual_path : string
      }
  | Redirect_uri_origin_mismatch of
      { base_url_origin : string
      ; redirect_origin : string
      }

let disabled_reason_code = function
  | Not_configured -> "not_configured"
  | Secret_env_missing _ -> "secret_env_missing"
  | Client_id_empty -> "client_id_empty"
  | Client_secret_empty _ -> "client_secret_empty"
  | Redirect_uri_not_https -> "redirect_uri_not_https"
  | Redirect_uri_malformed -> "redirect_uri_malformed"
  | Redirect_uri_callback_mismatch _ -> "redirect_uri_callback_mismatch"
  | Redirect_uri_origin_mismatch _ -> "redirect_uri_origin_mismatch"
;;

let disabled_reason_detail = function
  | Not_configured -> "no OAuth login client block is configured in config.json"
  | Secret_env_missing { env_var } ->
    Printf.sprintf "client secret environment variable %s is unset" env_var
  | Client_id_empty -> "client_id in config.json is empty"
  | Client_secret_empty { env_var = Some env_var } ->
    Printf.sprintf "client secret environment variable %s is empty" env_var
  | Client_secret_empty { env_var = None } ->
    "client secret environment variable is empty"
  | Redirect_uri_not_https ->
    "redirect_uri must be an https:// URL with a host and no query or fragment"
  | Redirect_uri_malformed ->
    "redirect_uri is not a valid scheme, host, optional port, and path"
  | Redirect_uri_callback_mismatch { expected_path; actual_path } ->
    Printf.sprintf
      "redirect_uri path %S does not match the server callback path %s"
      actual_path
      expected_path
  | Redirect_uri_origin_mismatch { base_url_origin; redirect_origin } ->
    Printf.sprintf
      "redirect_uri origin %s does not match %s origin %s"
      redirect_origin
      Env_config_core.http_base_url_env_key
      base_url_origin
;;

let disabled_reason_to_json reason =
  let extra =
    match reason with
    | Not_configured | Client_id_empty | Redirect_uri_not_https | Redirect_uri_malformed -> []
    | Secret_env_missing { env_var } -> [ "env_var", `String env_var ]
    | Client_secret_empty { env_var = Some env_var } -> [ "env_var", `String env_var ]
    | Client_secret_empty { env_var = None } -> []
    | Redirect_uri_callback_mismatch { expected_path; actual_path } ->
      [ "expected_path", `String expected_path; "actual_path", `String actual_path ]
    | Redirect_uri_origin_mismatch { base_url_origin; redirect_origin } ->
      [ "base_url_origin", `String base_url_origin
      ; "redirect_origin", `String redirect_origin
      ; "base_url_env", `String Env_config_core.http_base_url_env_key
      ]
  in
  `Assoc
    ([ "code", `String (disabled_reason_code reason)
     ; "detail", `String (disabled_reason_detail reason)
     ]
     @ extra)
;;

let disabled_reason_of_environment_error ?env_var = function
  | Login_client.Secret_variable_unset env_var -> Secret_env_missing { env_var }
  | Login_client.Client_refused Login_client.Client_id_empty -> Client_id_empty
  | Login_client.Client_refused Login_client.Client_secret_empty ->
    Client_secret_empty { env_var }
  | Login_client.Client_refused Login_client.Redirect_uri_not_https -> Redirect_uri_not_https
;;

let disabled_reason_of_refusal = function
  | Google_client_refused error ->
    Login_routes.Google, disabled_reason_of_environment_error error
  | Github_client_refused error ->
    Login_routes.Github, disabled_reason_of_environment_error error
  | Redirect_not_the_callback { provider; callback_path; redirect_path } ->
    ( provider
    , Redirect_uri_callback_mismatch
        { expected_path = callback_path; actual_path = redirect_path } )
  | Redirect_not_on_the_base_url { provider; base_url_origin; redirect_origin } ->
    provider, Redirect_uri_origin_mismatch { base_url_origin; redirect_origin }
  | Redirect_not_read { provider; redirect_uri = _ } -> provider, Redirect_uri_malformed
;;

let refusal_to_string refusal =
  let _, reason = disabled_reason_of_refusal refusal in
  let code = disabled_reason_code reason in
  let detail =
    match refusal with
    | Google_client_refused error ->
      "the google login client of config.json is refused: "
      ^ Login_client.environment_error_to_string error
    | Github_client_refused error ->
      "the github login client of config.json is refused: "
      ^ Login_client.environment_error_to_string error
    | Redirect_not_the_callback { provider; callback_path; redirect_path } ->
      Printf.sprintf
        "the redirect_uri of the %s login client of config.json has the path %S; the callback of \
         this server is %s"
        (provider_name provider)
        redirect_path
        callback_path
    | Redirect_not_on_the_base_url { provider; base_url_origin; redirect_origin } ->
      Printf.sprintf
        "the redirect_uri of the %s login client of config.json is on %s; the base URL of this \
         server (%s) is on %s"
        (provider_name provider)
        redirect_origin
        Env_config_core.http_base_url_env_key
        base_url_origin
    | Redirect_not_read { provider; redirect_uri = _ } ->
      Printf.sprintf
        "the redirect_uri of the %s login client of config.json was refused: %s"
        (provider_name provider)
        (disabled_reason_detail reason)
  in
  Printf.sprintf "[%s] %s" code detail
;;

type clients =
  { google : Login_routes.google_login option
  ; github : Login_client.t option
  }

let client ~getenv (configured : Masc_domain.login_client) =
  Login_client.of_environment
    ~getenv
    ~client_id:configured.client_id
    ~redirect_uri:configured.redirect_uri
    ~client_secret_env:configured.client_secret_env
;;

let callback_path_of = function
  | Login_routes.Google -> Server_login_http.google_callback_path
  | Login_routes.Github -> Server_login_http.github_callback_path
;;

(* HIGH-RISK-UNREVIEWED: what the boot compares to decide that the provider
   sends the browser of a login back to this server.

   A redirect as the operator wrote it: the origin, read by the parser of
   {!Server_request_authority}, and the path, byte for byte. The provider is
   sent the text, the browser follows it, and the router of this server
   looks the path of a request up as its bytes ([Http_server_eio]), so the
   path is not read through [Uri.path]: that gives [/auth/github/callback]
   for [/%61uth/github/callback] (uri 4.4.0), a path this server answers 404
   on. *)
type written_redirect =
  { origin : Server_request_authority.serialized_origin
  ; origin_text : string
  ; path : string
  }

let scheme_separator = "://"

(* RFC 3986 section 3: [scheme ":" "//" authority path]. The scheme holds no
   [:] and the authority ends at the first [/]. Whether what stands before
   that [/] is a scheme, [://] and an authority is the parser's to say; it
   refuses a userinfo, a [?], a [#] and a port it cannot read. *)
let read_redirect written =
  match String.index_opt written ':' with
  | None -> Error `Malformed
  | Some scheme_end ->
    let length = String.length written in
    let authority_start = scheme_end + String.length scheme_separator in
    if authority_start > length
    then Error `Malformed
    else (
      let path_start =
        Option.value (String.index_from_opt written authority_start '/') ~default:length
      in
      let origin_text = String.sub written 0 path_start in
      Result.map
        (fun origin ->
          { origin; origin_text; path = String.sub written path_start (length - path_start) })
        (Server_request_authority.parse_serialized_origin origin_text))
;;

let redirect_of provider client =
  let redirect_uri = Login_client.redirect_uri client in
  Result.map_error
    (fun `Malformed -> Redirect_not_read { provider; redirect_uri })
    (read_redirect redirect_uri)
;;

(* The provider sends the browser back to the redirect, and this server
   answers a callback on one path. *)
let on_the_callback provider client =
  let callback_path = callback_path_of provider in
  let* redirect = redirect_of provider client in
  if String.equal redirect.path callback_path
  then Ok client
  else
    Error (Redirect_not_the_callback { provider; callback_path; redirect_path = redirect.path })
;;

let clients_of_config ~getenv (configured : Authz_boot_mode_read.login_clients) =
  let* google =
    match configured.google with
    | None -> Ok None
    | Some configured ->
      (match client ~getenv configured with
       | Ok client ->
         let* client = on_the_callback Login_routes.Google client in
         Ok (Some { Login_routes.client; cache = Oidc_google_exchange.cache () })
       | Error error -> Error (Google_client_refused error))
  in
  let* github =
    match configured.github with
    | None -> Ok None
    | Some configured ->
      (match client ~getenv configured with
       | Ok client -> Result.map Option.some (on_the_callback Login_routes.Github client)
       | Error error -> Error (Github_client_refused error))
  in
  Ok { google; github }
;;

type redirect_check =
  | Compared_with_the_base_url
  | No_base_url

let on_the_base_url authority provider client =
  let* redirect = redirect_of provider client in
  if Server_request_authority.serialized_origin_matches_authority redirect.origin authority
  then Ok ()
  else
    Error
      (Redirect_not_on_the_base_url
         { provider
         ; base_url_origin =
             Printf.sprintf
               "%s://%s"
               (Server_request_authority.scheme_to_string
                  (Server_request_authority.scheme authority))
               (Server_request_authority.rendered authority)
         ; redirect_origin = redirect.origin_text
         })
;;

let redirects_on_the_server ~base_url { google; github } =
  match base_url with
  | None -> Ok No_base_url
  | Some authority ->
    let* () =
      match google with
      | None -> Ok ()
      | Some { Login_routes.client; cache = _ } ->
        on_the_base_url authority Login_routes.Google client
    in
    let* () =
      match github with
      | None -> Ok ()
      | Some client -> on_the_base_url authority Login_routes.Github client
    in
    Ok Compared_with_the_base_url
;;

type provider_preflight =
  | Enabled
  | Disabled of disabled_reason

type preflight =
  { google : provider_preflight
  ; github : provider_preflight
  }

let preflight_provider ~getenv ~base_url provider = function
  | None -> Disabled Not_configured
  | Some (configured : Masc_domain.login_client) ->
    (match client ~getenv configured with
     | Error error ->
       Disabled
         (disabled_reason_of_environment_error
            ~env_var:configured.client_secret_env
            error)
     | Ok built ->
       (match on_the_callback provider built with
        | Error refusal -> Disabled (snd (disabled_reason_of_refusal refusal))
        | Ok built ->
          (match base_url with
           | None -> Enabled
           | Some authority ->
             (match on_the_base_url authority provider built with
              | Ok () -> Enabled
              | Error refusal -> Disabled (snd (disabled_reason_of_refusal refusal))))))
;;

let preflight_of_config ~getenv ~base_url (configured : Authz_boot_mode_read.login_clients) =
  { google = preflight_provider ~getenv ~base_url Login_routes.Google configured.google
  ; github = preflight_provider ~getenv ~base_url Login_routes.Github configured.github
  }
;;

let provider_preflight_to_json = function
  | Enabled -> `Assoc [ "enabled", `Bool true ]
  | Disabled reason ->
    `Assoc [ "enabled", `Bool false; "reason", disabled_reason_to_json reason ]
;;

let preflight_to_json { google; github } =
  `Assoc
    [ "google", provider_preflight_to_json google
    ; "github", provider_preflight_to_json github
    ]
;;

let draw_bytes = 32

let routes ~clock ~zone ({ google; github } : clients) =
  { Login_routes.zone
  ; transactions = Oidc_login_transaction.create ()
  ; google
  ; github
  ; get = Server_login_http.get ~clock
  ; post = Server_login_http.post ~clock
  ; now = Ptime_clock.now
  ; draw = (fun () -> Random_id.hex ~bytes:draw_bytes)
  }
;;
