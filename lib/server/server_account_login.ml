(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

type refusal =
  | Google_client_refused of Login_client.environment_error
  | Github_client_refused of Login_client.environment_error

let refusal_to_string = function
  | Google_client_refused error ->
    "the google login client of config.json is refused: "
    ^ Login_client.environment_error_to_string error
  | Github_client_refused error ->
    "the github login client of config.json is refused: "
    ^ Login_client.environment_error_to_string error
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

let clients_of_config ~getenv (configured : Authz_boot_mode_read.login_clients) =
  let* google =
    match configured.google with
    | None -> Ok None
    | Some configured ->
      (match client ~getenv configured with
       | Ok client ->
         Ok (Some { Login_routes.client; cache = Oidc_google_exchange.cache () })
       | Error error -> Error (Google_client_refused error))
  in
  let* github =
    match configured.github with
    | None -> Ok None
    | Some configured ->
      (match client ~getenv configured with
       | Ok client -> Ok (Some client)
       | Error error -> Error (Github_client_refused error))
  in
  Ok { google; github }
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
