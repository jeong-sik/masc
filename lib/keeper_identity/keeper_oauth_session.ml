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
    Printf.sprintf "could not register a client: %s"
      (Registration.error_to_string err)
  | No_pkce_s256 issuer ->
    Printf.sprintf
      "%s publishes no S256 challenge method; without PKCE the code is bearer \
       material in a redirect and this client holds no secret to fall back on"
      issuer
  | No_registration issuer ->
    Printf.sprintf
      "no client is configured and %s offers no registration endpoint; make \
       an app with this provider and post its client id to \
       /api/v1/keepers/oauth/client"
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

type finished = {
  keeper : string;
  provider_id : string;
  access_token : string;
  refresh_token : string;
  expires_at : float;
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
    (match tokens.Flow.refresh_token with
     | Some refresh_token ->
       Ok
         { keeper = flow_pending.Flow.keeper
         ; provider_id = flow_pending.Flow.provider_id
         ; access_token = tokens.Flow.access_token
         ; refresh_token
         ; expires_at = tokens.Flow.expires_at
         }
     | None ->
       (* [Flow.complete] rejects an answer without one, so reaching here
          would mean that check moved. Naming it keeps the two in step
          instead of quietly widening what this returns. *)
       Error (Exchange_failed Flow.No_refresh_token))
