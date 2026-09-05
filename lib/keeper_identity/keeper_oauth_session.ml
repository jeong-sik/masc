(** See keeper_oauth_session.mli. This is the operation; storing what comes
    out of it belongs to the caller. *)

module Provider = Keeper_oauth_provider
module Discovery = Keeper_oauth_discovery
module Registration = Keeper_oauth_registration
module Flow = Keeper_oauth_flow
module Pending = Keeper_oauth_pending
module Store = Keeper_oauth_client_store

type start_error =
  | Discovery_failed of Discovery.error
  | Registration_failed of Registration.error
  | No_pkce_s256 of string
  | No_registration of string

let start_error_to_string = function
  | Discovery_failed err ->
    Printf.sprintf "could not find out where authorization lives: %s"
      (Discovery.error_to_string err)
  | Registration_failed err ->
    Printf.sprintf
      "could not register a client: %s; in TUI press 'A' (내 앱 쓰기) to set your Client ID and Secret (or POST /api/v1/keepers/oauth/client)"
      (Registration.error_to_string err)
  | No_pkce_s256 issuer ->
    Printf.sprintf
      "%s publishes no S256 challenge method; without PKCE the code is bearer \
       material in a redirect and this client holds no secret to fall back on"
      issuer
  | No_registration issuer ->
    Printf.sprintf
      "no client is configured and %s offers no registration endpoint; in TUI press 'A' (내 앱 쓰기) to set your Client ID and Secret (or POST /api/v1/keepers/oauth/client)"
      issuer

type started = {
  authorize_url : string;
  state : string;
  credentials : Keeper_oauth_client_store.credentials;
  registered_now : bool;
}

let ( let* ) = Result.bind

let default_discover ~mcp_url = Discovery.discover ~mcp_url ()

let default_register ~registration_url ~client_name ~redirect_uri =
  Registration.register ~registration_url ~client_name ~redirect_uri ()

let start
      ?(discover = default_discover)
      ?(register = default_register)
      ~(provider : Provider.t)
      ~configured
      ~client_name
      ~redirect_uri
      ~keeper
      ~pending
      ~now
      ~ttl_sec
      ()
  =
  let* discovered =
    Result.map_error
      (fun err -> Discovery_failed err)
      (discover ~mcp_url:provider.Provider.mcp_url)
  in
  (* Refused, not downgraded. A public client that cannot prove the
     redemption has nothing else to prove it with. *)
  if not discovered.Discovery.supports_pkce_s256
  then Error (No_pkce_s256 discovered.Discovery.issuer)
  else
    let* credentials, registered_now =
      match configured with
      (* An operator who made their own app keeps using it. Registering
         anyway would leave a second client behind for no reason. *)
      | Some ({ Store.client_id; _ } as credentials)
        when String.trim client_id <> "" -> Ok (credentials, false)
      | Some _ | None ->
        (match discovered.Discovery.registration_url with
         | None -> Error (No_registration discovered.Discovery.issuer)
         | Some registration_url ->
           Result.map
             (fun (r : Registration.registered) ->
               ( { Store.client_id = r.Registration.client_id
                 ; client_secret = r.Registration.client_secret
                   (* Nothing recorded: a client this install registered can
                      be granted whatever the resource publishes. *)
                 ; scopes = []
                 }
               , true ))
             (Result.map_error
                (fun err -> Registration_failed err)
                (register ~registration_url ~client_name ~redirect_uri)))
    in
    let client_id = credentials.Store.client_id in
    let flow_pending =
      Flow.begin_authorization ~provider ~discovered ~client_id
        ~scopes:credentials.Store.scopes ~redirect_uri
        ~keeper
    in
    Pending.remember pending ~now ~ttl_sec
      { Pending.pending = flow_pending
      ; discovered
      ; client_id
      ; client_secret = credentials.Store.client_secret
      };
    Ok
      { authorize_url = flow_pending.Flow.authorize_url
      ; state = flow_pending.Flow.state
      ; credentials
      ; registered_now
      }

type finish_error =
  | Unknown_state
  | Exchange_failed of Flow.exchange_error

let finish_error_to_string = function
  | Unknown_state ->
    "no login is waiting on this state; it may have been finished already, or \
     taken longer than the window, or started before a restart"
  | Exchange_failed err ->
    Printf.sprintf "the exchange did not complete: %s"
      (Flow.exchange_error_to_string err)

type expiry =
  | Never
  | Renewable of { expires_at : float option; refresh_token : string }
  | Expiring_without_renewal of float

(* Only the shape that ends in a lost provider gets a warning. Saying
   something about every one of them trains an operator to skip the line
   that mattered. *)
let expiry_warning = function
  | Never | Renewable _ -> None
  | Expiring_without_renewal expires_at ->
    Some
      (Printf.sprintf
         "This credential expires (%s) and the provider returned no refresh \
          token, so it cannot be renewed. The Keeper will stop reaching this \
          provider at that point and you will have to attach it again."
         (let t = Unix.gmtime expires_at in
          Printf.sprintf "%04d-%02d-%02d %02d:%02d UTC" (t.Unix.tm_year + 1900)
            (t.Unix.tm_mon + 1) t.Unix.tm_mday t.Unix.tm_hour t.Unix.tm_min))

type finished = {
  keeper : string;
  provider_id : string;
  access_token : string;
  expiry : expiry;
}

let finish ?post ~pending ~state ~code ~now () =
  match Pending.take pending ~now ~state with
  | None -> Error Unknown_state
  | Some in_flight ->
    let flow_pending = in_flight.Pending.pending in
    let* tokens =
      Result.map_error
        (fun err -> Exchange_failed err)
        (Flow.complete ?post ~discovered:in_flight.Pending.discovered
           ~client_id:in_flight.Pending.client_id
           ?client_secret:in_flight.Pending.client_secret ~pending:flow_pending
           ~code
           ~state ~now ())
    in
    (* The four pairings the answer can carry, read into the three that mean
       something different to whoever stores them. A token with no expiry
       and no refresh token is not a failed login: it is a credential that
       lasts until the provider revokes it. *)
    let expiry =
      match tokens.Flow.refresh_token, tokens.Flow.expires_at with
      | Some refresh_token, expires_at -> Renewable { expires_at; refresh_token }
      | None, None -> Never
      | None, Some expires_at -> Expiring_without_renewal expires_at
    in
    Ok
      { keeper = flow_pending.Flow.keeper
      ; provider_id = flow_pending.Flow.provider_id
      ; access_token = tokens.Flow.access_token
      ; expiry
      }
