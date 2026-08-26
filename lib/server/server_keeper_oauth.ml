(** See server_keeper_oauth.mli. *)

module Provider = Keeper_oauth_provider
module Session = Keeper_oauth_session
module Store = Keeper_oauth_client_store

let ( let* ) = Result.bind

(* Long enough for an operator to read a consent screen and decide, short
   enough that a verifier nobody came back for does not sit around. *)
let login_window_sec = 600.

(* What the provider's consent screen calls this client. Registration names
   the software, not the install: one masc has one client, and the Keeper it
   is being attached to is a masc-side fact that the provider has no use
   for. *)
let client_name = "masc"

(* In this process only, like the exchanges it holds. A restart between the
   two halves loses the login, which is the correct outcome -- see
   Keeper_oauth_pending. *)
let pending = Keeper_oauth_pending.create ()

(* One path for every provider. Which login a callback belongs to is the
   state it echoes, not the URL it arrives at, and a state is unguessable and
   redeemable once. *)
let callback_path = "/api/v1/keepers/oauth/callback"

let redirect_uri () =
  match Env_config_core.masc_http_base_url_result () with
  | Error message ->
    (* Guessing would build an authorize call the provider redirects
       somewhere this server is not, and the operator would see the
       provider's error rather than ours. *)
    Error (Printf.sprintf "this server does not know its own base URL: %s" message)
  | Ok base_url -> Ok (base_url ^ callback_path)
;;

let provider_of_id provider_id =
  let key = Filename.concat "identity" (provider_id ^ ".toml") in
  match Embedded_config.read key with
  | None -> Error (Printf.sprintf "no identity provider is declared as %S" provider_id)
  | Some contents ->
    Result.map_error Provider.error_to_string
      (Provider.load ~file_name:provider_id ~contents)
;;

(* Where this install keeps what it registered. Beside the workspace rather
   than inside a Keeper: the client is the same whichever Keeper logs in. *)
let identity_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "identity"
;;

let start ~base_path ~keeper ~provider_id ~now =
  let* provider = provider_of_id provider_id in
  let* redirect_uri = redirect_uri () in
  let dir = identity_dir ~base_path in
  let* configured_client_id = Store.load ~dir ~provider in
  let* started =
    Result.map_error Session.start_error_to_string
      (Session.start ~provider ~configured_client_id ~client_name ~redirect_uri
         ~keeper ~pending ~now ~ttl_sec:login_window_sec ())
  in
  let* () =
    if started.Session.registered_now
    then Store.save ~dir ~provider ~client_id:started.Session.client_id
    else Ok ()
  in
  Ok
    (`Assoc
      [ "keeper", `String keeper
      ; "provider", `String provider.Provider.id
      ; "provider_label", `String provider.Provider.label
      ; "authorize_url", `String started.Session.authorize_url
      ; "state", `String started.Session.state
      ; "registered_now", `Bool started.Session.registered_now
      ; "expires_at", `Float (now +. login_window_sec)
      ])
;;

type attached = {
  keeper : string;
  provider_id : string;
  provider_label : string;
  expires_at : float;
}

let finish ~base_path ~state ~code ~now =
  let* finished =
    Result.map_error Session.finish_error_to_string
      (Session.finish ~pending ~state ~code ~now ())
  in
  (* Which provider is the exchange's own answer, not the URL's: the
     declaration that named where these tokens go is the one that started
     this login. *)
  let* provider = provider_of_id finished.Session.provider_id in
  let keeper_name = finished.Session.keeper in
  let set_env ~name ~value =
    Keeper_secret_projection.set_env_entry ~base_path ~keeper_name
      ~scope:Keeper_secret_projection.Keeper_secret ~name ~value
  in
  (* The refresh token first. Every other write can be repeated by logging in
     again; losing this one means the Keeper works until the access token
     expires and then stops with nothing on disk to say why. *)
  let* () =
    Keeper_secret_projection.set_file_entry ~base_path ~keeper_name
      ~scope:Keeper_secret_projection.Keeper_secret
      ~container_path:provider.Provider.refresh_token_file
      ~value:finished.Session.refresh_token
  in
  let* () =
    set_env ~name:provider.Provider.access_token_env
      ~value:finished.Session.access_token
  in
  let* () =
    set_env ~name:provider.Provider.expires_at_env
      ~value:(Printf.sprintf "%.0f" finished.Session.expires_at)
  in
  Ok
    { keeper = keeper_name
    ; provider_id = provider.Provider.id
    ; provider_label = provider.Provider.label
    ; expires_at = finished.Session.expires_at
    }
;;
