(** See server_keeper_oauth.mli. *)

module Provider = Keeper_oauth_provider
module Session = Keeper_oauth_session
module Store = Keeper_oauth_client_store
module Declarations = Keeper_oauth_declarations

let ( let* ) = Result.bind

(* Attach-time hops -- discovery, client registration, the code exchange --
   are short JSON round trips of the same class as the Slack and Discord REST
   calls and run under the shared request timeout those use. The MCP session
   behind a catalog refresh runs under the keeper's no-progress threshold,
   which {!Keeper_identity_tools.http_transports} owns. *)
let rest_timeout_sec = Masc_http_client.default_request_timeout_sec

let register_with ~clock ~registration_url ~client_name ~redirect_uri =
  Keeper_oauth_registration.register
    ~post:(Keeper_oauth_registration.http_post ~clock ~timeout_sec:rest_timeout_sec)
    ~registration_url ~client_name ~redirect_uri ()

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
  match Declarations.find provider_id with
  | None -> Error (Printf.sprintf "no identity provider is declared as %S" provider_id)
  | Some (Declarations.Declared provider) -> Ok provider
  | Some (Declarations.Unreadable { problem; _ }) ->
    Error (Printf.sprintf "the %S declaration cannot be read: %s" provider_id problem)
;;

(* Where this install keeps what it registered. Beside the workspace rather
   than inside a Keeper: the client is the same whichever Keeper logs in. *)
let identity_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "identity"
;;

(* What this install knows about the client a login would use, and never which
   client it is. These states must stay distinct: a lapsed registration is
   renewed automatically by the next login, while [none] means there is no
   app to reuse, and an unreadable store must not invite an operator to write
   over credentials that may still be there. An app the operator typed in is
   written with an expiry of zero, so it remains [on_file]. *)
type client_state =
  | Client_on_file
  | Client_lapsed
  | Client_none
  | Client_problem of string

let client_state ~base_path ~provider ~now =
  match Store.load ~dir:(identity_dir ~base_path) ~provider with
  | Ok (Some credentials) when Store.secret_expired credentials ~now ->
    Client_lapsed
  | Ok (Some _) -> Client_on_file
  | Ok None -> Client_none
  | Error problem -> Client_problem problem
;;

let client_state_to_json = function
  | Client_on_file -> `Assoc [ "kind", `String "on_file" ]
  | Client_lapsed -> `Assoc [ "kind", `String "lapsed" ]
  | Client_none -> `Assoc [ "kind", `String "none" ]
  | Client_problem problem ->
    `Assoc [ "kind", `String "problem"; "problem", `String problem ]
;;

let declarations_json ~base_path ~now =
  `List
    (List.map
       (function
         | Declarations.Declared provider ->
           `Assoc
             [ "id", `String provider.Provider.id
             ; "label", `String provider.Provider.label
             ; ( "client_state"
               , client_state ~base_path ~provider ~now |> client_state_to_json )
             ]
         | Declarations.Unreadable { id; problem } ->
           `Assoc [ "id", `String id; "problem", `String problem ])
       (Declarations.all ()))
;;

(* An app an operator made themselves, for a provider that registers none.
   Kept where a registered one is kept, because it is the same thing arriving
   by a different road: one per provider for this install, not one per
   Keeper. A secret is optional -- some providers issue an app without one --
   and clearing it is saying "this app has none" rather than "leave what is
   there", so an absent field and an empty one mean the same. *)
let set_client ~base_path ~provider_id ~client_id ~client_secret ~scopes =
  let* provider = provider_of_id provider_id in
  let trimmed = String.trim client_id in
  if String.equal trimmed ""
  then Error "a client id is required"
  else
    let client_secret =
      match client_secret with
      | Some secret when String.trim secret <> "" -> Some (String.trim secret)
      | Some _ | None -> None
    in
    let scopes =
      List.filter
        (fun scope -> not (String.equal scope ""))
        (String.split_on_char ' ' (String.trim scopes))
    in
    let* () =
      Store.save ~dir:(identity_dir ~base_path) ~provider
        { Store.client_id = trimmed
        ; client_secret
          (* An app the operator made and typed in here. There is no
             registration answer to read a deadline from, and the operator is
             the one who renews it, so this records what RFC 7591 spells "0":
             nothing on this side expires it. Leaving it unrecorded would let
             {!Store.secret_expired} read the operator's own app as lapsed and
             register over it. *)
        ; secret_expires_at = Some 0.
        ; scopes
        }
    in
    Ok
      (`Assoc
        [ "provider", `String provider.Provider.id
        ; "provider_label", `String provider.Provider.label
        ; "client_id", `String trimmed
          (* Never the secret back. What an operator needs to know is
             whether one is on file. *)
        ; "has_client_secret", `Bool (client_secret <> None)
          (* Echoed, unlike the secret: an operator needs to see what will
             actually be asked for, and a scope list is not a credential. *)
        ; "scopes", `List (List.map (fun scope -> `String scope) scopes)
        ])
;;

let start ~clock ~base_path ~keeper ~provider_id ~now =
  let* provider = provider_of_id provider_id in
  let transports = Keeper_identity_tools.http_transports ~clock in
  match provider.Provider.credential_source with
  | Provider.Github_cli { hostname } ->
    (match Keeper_github_identity.stored_token ~base_path ~keeper_name:keeper ~hostname with
     | Error problem ->
       Error
         (Printf.sprintf
            "GitHub uses %s's GitHub CLI token (%s). Please switch to the GitHub tab or run 'gh auth login' to authenticate this keeper."
            keeper problem)
     | Ok _ ->
       let* catalog =
         Keeper_identity_tools.refresh ~mcp_post:transports.Keeper_identity_tools.mcp_post
           ~base_path ~keeper_name:keeper ~provider ~now ()
       in
       Ok
         (`Assoc
           [ "keeper", `String keeper
           ; "provider", `String provider.Provider.id
           ; "provider_label", `String provider.Provider.label
           ; "attached", `Bool true
           ; "tool_count", `Int (List.length catalog.Keeper_identity_tools.tools)
           ; ( "message"
             , `String
                 (Printf.sprintf
                    "%s GitHub CLI token attached (%d tools discovered)."
                    keeper (List.length catalog.Keeper_identity_tools.tools)) )
           ]))
  | Provider.Oauth_exchange ->
    let* redirect_uri = redirect_uri () in
    let dir = identity_dir ~base_path in
    let* configured = Store.load ~dir ~provider in
    let* started =
      Result.map_error Session.start_error_to_string
        (Session.start ~discover:transports.Keeper_identity_tools.discover
           ~register:(register_with ~clock) ~provider ~configured ~client_name
           ~redirect_uri ~keeper ~pending ~now ~ttl_sec:login_window_sec ())
    in
    let* () =
      if started.Session.registered_now
      then Store.save ~dir ~provider started.Session.credentials
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

let refresh_tools ~clock ~base_path ~keeper ~provider_id ~now =
  let* provider = provider_of_id provider_id in
  let* catalog =
    Keeper_identity_tools.refresh
      ~mcp_post:(Keeper_identity_tools.http_transports ~clock).Keeper_identity_tools.mcp_post
      ~base_path ~keeper_name:keeper ~provider ~now ()
  in
  Ok
    (`Assoc
      [ "keeper", `String keeper
      ; "provider", `String catalog.Keeper_identity_tools.provider_id
      ; "provider_label", `String catalog.Keeper_identity_tools.provider_label
      ; "discovered_at", `Float catalog.Keeper_identity_tools.discovered_at
      ; ( "tools"
        , `List
            (List.map
               (fun (tool : Mcp_client.tool) -> `String tool.Mcp_client.name)
               catalog.Keeper_identity_tools.tools) )
      ])
;;

let attached_tools_json ~base_path ~keeper =
  (* Read once for the listing. The screen this feeds carries the on/off
     switch, so what it shows must be the store's answer — an unreadable
     store is shown as a problem on each attached row, never as "on". *)
  let switched_off =
    Keeper_identity_switch.disabled_providers_for_keeper ~base_path
      ~keeper_name:keeper
  in
  let switch_fields provider_id =
    match switched_off with
    | Ok off -> [ "enabled", `Bool (not (List.mem provider_id off)) ]
    | Error problem -> [ "switch_problem", `String problem ]
  in
  `List
    (List.map
       (fun declaration ->
         let id = Declarations.id_of declaration in
         match declaration with
         | Declarations.Unreadable { problem; _ } ->
           `Assoc [ "provider", `String id; "problem", `String problem ]
         | Declarations.Declared provider ->
           (match
              Keeper_identity_tools.load ~base_path ~keeper_name:keeper
                ~provider_id:provider.Provider.id
            with
            | Error problem ->
              `Assoc [ "provider", `String id; "problem", `String problem ]
            | Ok None ->
              `Assoc
                [ "provider", `String id
                ; "provider_label", `String provider.Provider.label
                ; "attached", `Bool false
                ; ( "also_on"
                  , `List
                      (List.map
                         (fun name -> `String name)
                         (Keeper_identity_tools.keepers_with ~base_path
                            ~provider_id:provider.Provider.id
                            ~excluding:keeper)) )
                ]
            | Ok (Some catalog) ->
              `Assoc
                ([ "provider", `String id
                 ; "provider_label", `String provider.Provider.label
                 ; "attached", `Bool true
                 ]
                 @ switch_fields provider.Provider.id
                 @ [ ( "also_on"
                     , `List
                         (List.map
                            (fun name -> `String name)
                            (Keeper_identity_tools.keepers_with ~base_path
                               ~provider_id:provider.Provider.id
                               ~excluding:keeper)) )
                   ; ( "discovered_at"
                     , `Float catalog.Keeper_identity_tools.discovered_at )
                   ; ( "tools"
                     , `List
                         (List.map
                            (fun (tool : Mcp_client.tool) ->
                              `String tool.Mcp_client.name)
                            catalog.Keeper_identity_tools.tools) )
                   ])))
       (Declarations.all ()))
;;

type attached = {
  keeper : string;
  provider_id : string;
  provider_label : string;
  expires_at : float option;
  warning : string option;
  tool_discovery : (int, string) result;
}

let finish ~clock ~base_path ~state ~code ~now =
  let* finished =
    Result.map_error Session.finish_error_to_string
      (Session.finish
         ~post:(Keeper_oauth_flow.http_post ~clock ~timeout_sec:rest_timeout_sec)
         ~pending ~state ~code ~now ())
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
  let refresh_token, expires_at =
    match finished.Session.expiry with
    | Session.Never -> None, None
    | Session.Renewable { expires_at; refresh_token } -> Some refresh_token, expires_at
    | Session.Expiring_without_renewal expires_at -> None, Some expires_at
  in
  (* The refresh token first. Every other write can be repeated by logging in
     again; losing this one means the Keeper works until the access token
     expires and then stops with nothing on disk to say why. *)
  let* () =
    match refresh_token with
    | None ->
      Keeper_secret_projection.delete_file_entry ~base_path ~keeper_name
        ~scope:Keeper_secret_projection.Keeper_secret
        ~container_path:provider.Provider.refresh_token_file
    | Some value ->
      Keeper_secret_projection.set_file_entry ~base_path ~keeper_name
        ~scope:Keeper_secret_projection.Keeper_secret
        ~container_path:provider.Provider.refresh_token_file ~value
  in
  let* () =
    set_env ~name:provider.Provider.access_token_env
      ~value:finished.Session.access_token
  in
  (* Written even when there is no expiry, and empty is what says so. A
     Keeper that was attached to this provider before may have a moment
     recorded from that login; leaving it there would have the renewal check
     read a stale clock against a credential that does not answer to it. *)
  let* () =
    set_env ~name:provider.Provider.expires_at_env
      ~value:
        (match expires_at with
         | None -> ""
         | Some expires_at -> Printf.sprintf "%.0f" expires_at)
  in
  (* The credentials are on disk by now, so this can fail without undoing
     the attachment. Its outcome is carried rather than logged: the operator
     is looking at a page right now. *)
  let tool_discovery =
    Result.map
      (fun catalog -> List.length catalog.Keeper_identity_tools.tools)
      (Keeper_identity_tools.refresh
         ~mcp_post:(Keeper_identity_tools.http_transports ~clock).Keeper_identity_tools.mcp_post
         ~base_path ~keeper_name ~provider ~now ())
  in
  Ok
    { keeper = keeper_name
    ; provider_id = provider.Provider.id
    ; provider_label = provider.Provider.label
    ; expires_at
    ; warning = Session.expiry_warning finished.Session.expiry
    ; tool_discovery
    }
;;
