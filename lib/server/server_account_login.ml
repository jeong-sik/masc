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
  | Redirect_not_read { provider; redirect_uri } ->
    Printf.sprintf
      "the redirect_uri of the %s login client of config.json (%S) is not a scheme, a host, an \
       optional port and a path, with nothing else before the path"
      (provider_name provider)
      redirect_uri
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
