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

let provider_name = function
  | Login_routes.Google -> "google"
  | Login_routes.Github -> "github"
;;

let refusal_to_string = function
  | Google_client_refused error ->
    "the google login client of config.json is refused: "
    ^ Login_client.environment_error_to_string error
  | Github_client_refused error ->
    "the github login client of config.json is refused: "
    ^ Login_client.environment_error_to_string error
  | Redirect_not_the_callback { provider; callback_path; redirect_path } ->
    Printf.sprintf
      "the redirect_uri of the %s login client of config.json has the path %S; the callback of this \
       server is %s"
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

(* The provider sends the browser back to the redirect, and this server
   answers a callback on one path. *)
let on_the_callback provider client =
  let callback_path = callback_path_of provider in
  let redirect_path = Uri.path (Uri.of_string (Login_client.redirect_uri client)) in
  if String.equal redirect_path callback_path
  then Ok client
  else Error (Redirect_not_the_callback { provider; callback_path; redirect_path })
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

(* The scheme, the host and the port of a URL, as an origin is written. *)
let origin_text uri =
  Uri.to_string (Uri.make ?scheme:(Uri.scheme uri) ?host:(Uri.host uri) ?port:(Uri.port uri) ())
;;

let on_the_base_url authority provider client =
  let redirect_origin = origin_text (Uri.of_string (Login_client.redirect_uri client)) in
  let on_it =
    match Server_request_authority.parse_serialized_origin redirect_origin with
    | Ok origin -> Server_request_authority.serialized_origin_matches_authority origin authority
    | Error `Malformed -> false
  in
  if on_it
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
         ; redirect_origin
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

let draw_bytes = 32

let routes ~clock ~zone { google; github } =
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
