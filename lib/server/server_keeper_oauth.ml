(** See server_keeper_oauth.mli. *)

module Provider = Keeper_oauth_provider
module Session = Keeper_oauth_session
module Store = Keeper_oauth_client_store
module Declarations = Keeper_oauth_declarations

open Result.Syntax

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
   the software, not the install or the login: the Keeper being attached is a
   masc-side fact that the provider has no use for. *)
let client_name = "masc"

(* Callbacks, tool discovery and renewal share the process-local owner. *)
let pending_for_base_path = Keeper_oauth_pending.for_base_path

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

(* RFC 8252 7.3: a provider that accepts only native-app redirects takes
   http://127.0.0.1:<port>/... or http://[::1]:<port>/... and refuses a
   public host. Those two literals are the whole of what 7.3 names, so a
   server has to have bound one of them, or every interface, for the browser
   that consents to land on it. Bound anywhere else -- 127.0.0.2 included,
   which a provider reads as plain http -- saying so beats a callback that
   lands nowhere.

   A wildcard bind is read as reachable on 127.0.0.1. That holds when the
   operator's browser runs on this machine, which is the case the Identity
   tab and the manual tell the operator they need. *)
let loopback_redirect_uri () =
  let host = Env_config_core.masc_host () in
  let port = Env_config_core.masc_http_port () in
  let literal =
    match Ipaddr.of_string host with
    | Ok (Ipaddr.V4 address) when Ipaddr.V4.(compare address any) = 0
                                  || Ipaddr.V4.(compare address localhost) = 0 ->
      Some (Ipaddr.V4.to_string Ipaddr.V4.localhost)
    | Ok (Ipaddr.V6 address) when Ipaddr.V6.(compare address unspecified) = 0 ->
      Some (Ipaddr.V4.to_string Ipaddr.V4.localhost)
    | Ok (Ipaddr.V6 address) when Ipaddr.V6.(compare address localhost) = 0 ->
      Some ("[" ^ Ipaddr.V6.to_string Ipaddr.V6.localhost ^ "]")
    | Ok (Ipaddr.V4 _ | Ipaddr.V6 _) | Error _ -> None
  in
  match literal with
  | Some literal -> Ok (Printf.sprintf "http://%s:%s%s" literal port callback_path)
  | None ->
    Error
      (Printf.sprintf
         "this provider accepts only an RFC 8252 loopback callback \
          (127.0.0.1 or [::1]), and this server listens on %s"
         host)
;;

let redirect_uri_for (provider : Provider.t) =
  match provider.Provider.callback with
  | Provider.Server_callback -> redirect_uri ()
  | Provider.Loopback_callback -> loopback_redirect_uri ()
;;

let callback_result_json = function
  | Ok url -> `Assoc [ "url", `String url ]
  | Error problem -> `Assoc [ "problem", `String problem ]
;;

(* The callback a login started now would name, for a screen to show. An
   operator who makes their own app has to register exactly this URL, and an
   operator who moved the server wants to see what it answers at. *)
let callback_json () = callback_result_json (redirect_uri ())
;;

(* A row names its own callback only when it is not the server's: the
   loopback providers. The kind is on the wire so a reader decodes it into
   its own variant instead of inferring it from the key being there. *)
let row_callback_fields (provider : Provider.t) =
  match provider.Provider.callback with
  | Provider.Server_callback -> []
  | Provider.Loopback_callback ->
    [ ( "callback"
      , `Assoc
          (("kind", `String "loopback")
           :: (match loopback_redirect_uri () with
               | Ok url -> [ "url", `String url ]
               | Error problem -> [ "problem", `String problem ])) )
    ]
;;

let provider_of_id provider_id =
  match Declarations.find provider_id with
  | None -> Error (Printf.sprintf "no identity provider is declared as %S" provider_id)
  | Some (Declarations.Declared provider) -> Ok provider
  | Some (Declarations.Unreadable { problem; _ }) ->
    Error (Printf.sprintf "the %S declaration cannot be read: %s" provider_id problem)
;;

let identity_dir = Keeper_identity_tools.identity_dir

(* Whether an operator app is on file for a provider. Three states, because
   an unreadable app is not an absent one: an operator invited to type an app
   over an unreadable file would replace credentials that may still be good. *)
type app_state =
  | App_on_file
  | App_none
  | App_problem of string

let app_state ~base_path ~provider =
  match Store.load_app ~identity_dir:(identity_dir ~base_path) ~provider with
  | Ok (Some _) -> App_on_file
  | Ok None -> App_none
  | Error problem -> App_problem problem
;;

let app_state_to_json = function
  | App_on_file -> `Assoc [ "kind", `String "on_file" ]
  | App_none -> `Assoc [ "kind", `String "none" ]
  | App_problem problem ->
    `Assoc [ "kind", `String "problem"; "problem", `String problem ]
;;

let declarations_json ~base_path =
  `List
    (List.map
       (function
         | Declarations.Declared provider ->
           `Assoc
             ([ "id", `String provider.Provider.id
              ; "label", `String provider.Provider.label
              ; "app_state", app_state ~base_path ~provider |> app_state_to_json
              ]
              @ row_callback_fields provider)
         | Declarations.Unreadable { id; problem } ->
           `Assoc [ "id", `String id; "problem", `String problem ])
       (Declarations.all ()))
;;

(* An app an operator made themselves, for a provider that registers none or
   whose granted scopes the operator wants to decide. One per client group for
   this install, not one per Keeper. A secret is optional -- some providers issue an app without one --
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
      Store.save_app ~identity_dir:(identity_dir ~base_path) ~provider
        { Store.App.client_id = trimmed; client_secret; scopes }
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

let start ?transports ?register ~clock ~(config : Workspace.config) ~keeper ~provider_id ~now () =
  let base_path = config.Workspace.base_path in
  let* provider = provider_of_id provider_id in
  let transports =
    match transports with
    | Some transports -> transports
    | None -> Keeper_identity_tools.http_transports ~clock
  in
  let register =
    match register with
    | Some register -> register
    | None -> register_with ~clock
  in
  match provider.Provider.credential_source with
  | Provider.Github_cli { hostname } ->
    let attachment =
      Keeper_oauth_pending.capture_attachment (pending_for_base_path base_path)
        ~keeper ~provider_id:provider.id
    in
    (match Keeper_github_login_lane.stored_token ~config ~keeper_name:keeper ~hostname with
     | Error
         (( Keeper_github_login_lane.Remote_ssh_identity_on_endpoint _
          | Keeper_github_login_lane.Keeper_meta_unreadable _ ) as refusal) ->
       (* Neither is fixed by logging in again, so neither gets that advice. *)
       Error (Keeper_github_login_lane.stored_token_error_to_string refusal)
     | Error (Keeper_github_login_lane.Host_identity_unavailable _ as problem) ->
       Error
         (Printf.sprintf
            "GitHub uses %s's GitHub CLI token (%s). Please switch to the GitHub tab or run 'gh auth login' to authenticate this keeper."
            keeper
            (Keeper_github_login_lane.stored_token_error_to_string problem))
     | Ok _ ->
       let* catalog =
         Keeper_identity_tools.refresh ~attachment ~mcp_post:transports.Keeper_identity_tools.mcp_post
           ~config ~keeper_name:keeper ~provider ~now ()
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
    let* redirect_uri = redirect_uri_for provider in
    let* app = Store.load_app ~identity_dir:(identity_dir ~base_path) ~provider in
    let* started =
      Result.map_error Session.start_error_to_string
        (Session.start ~discover:transports.Keeper_identity_tools.discover
           ~register ~provider ~app ~client_name
           ~redirect_uri ~keeper ~pending:(pending_for_base_path base_path) ~now ~ttl_sec:login_window_sec ())
    in
    Ok
      (`Assoc
        [ "keeper", `String keeper
        ; "provider", `String provider.Provider.id
        ; "provider_label", `String provider.Provider.label
        ; "authorize_url", `String started.Session.authorize_url
        ; "attempt_id", `String started.Session.attempt_id
        ; "expires_at", `Float (now +. login_window_sec)
        ])
;;

let refresh_tools ~clock ~(config : Workspace.config) ~keeper ~provider_id ~now =
  let* provider = provider_of_id provider_id in
  let attachment =
    Keeper_oauth_pending.capture_attachment (pending_for_base_path config.base_path)
      ~keeper ~provider_id:provider.id
  in
  let* catalog =
    Keeper_identity_tools.refresh ~attachment
      ~mcp_post:(Keeper_identity_tools.http_transports ~clock).Keeper_identity_tools.mcp_post
      ~config ~keeper_name:keeper ~provider ~now ()
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
                ([ "provider", `String id
                 ; "provider_label", `String provider.Provider.label
                 ; "attached", `Bool false
                 ; "app_state", app_state ~base_path ~provider |> app_state_to_json
                 ]
                 @ row_callback_fields provider
                 @ [ ( "also_on"
                  , `List
                      (List.map
                         (fun name -> `String name)
                         (Keeper_identity_tools.keepers_with ~base_path
                            ~provider_id:provider.Provider.id
                            ~excluding:keeper)) )
                   ])
            | Ok (Some catalog) ->
              `Assoc
                ([ "provider", `String id
                 ; "provider_label", `String provider.Provider.label
                 ; "attached", `Bool true
                 ; "app_state", app_state ~base_path ~provider |> app_state_to_json
                 ]
                 @ row_callback_fields provider
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

(* One credential write of a finished login, by stage. The order is
   {!Keeper_oauth_pending.publish_credentials}'s: refresh token, client, access
   token, expiry.

   The refresh token first. Every other write can be repeated by logging in
   again; losing this one means the Keeper works until the access token
   expires and then stops with nothing on disk to say why. The record of the
   client an earlier login used is removed in the same step, before the new
   token lands: a publication interrupted between the token and the client
   then leaves no client record, which renewal reports as "attach again",
   rather than the new token beside the old login's client, which a provider
   refuses with its own wording. *)
let write_finished_credential ~base_path ~(provider : Provider.t)
    ~(finished : Session.finished) stage =
  let keeper_name = finished.Session.keeper in
  let binding_path =
    Keeper_identity_tools.client_binding_path ~base_path ~keeper_name
      ~provider_id:provider.Provider.id
  in
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
  match stage with
  | Keeper_oauth_pending.Refresh_token ->
    let* () = Store.delete_binding ~path:binding_path in
    (match refresh_token with
     | None ->
       Keeper_secret_projection.delete_file_entry ~base_path ~keeper_name
         ~scope:Keeper_secret_projection.Keeper_secret
         ~container_path:provider.Provider.refresh_token_file
     | Some value ->
       Keeper_secret_projection.set_file_entry ~base_path ~keeper_name
         ~scope:Keeper_secret_projection.Keeper_secret
         ~container_path:provider.Provider.refresh_token_file ~value)
  | Keeper_oauth_pending.Client ->
    Store.save_binding ~path:binding_path
      (Store.binding_of_login_client finished.Session.client)
  | Keeper_oauth_pending.Access_token ->
    set_env ~name:provider.Provider.access_token_env ~value:finished.Session.access_token
  | Keeper_oauth_pending.Expiry ->
    (* Clear a previous login's expiry even when this token never expires. *)
    set_env ~name:provider.Provider.expires_at_env
      ~value:(match expires_at with
        | None -> ""
        | Some expires_at -> Printf.sprintf "%.0f" expires_at)
;;

let publish_finished ~clock ~(config : Workspace.config) ~state ~finished ~now =
  let base_path = config.Workspace.base_path in
  (* Which provider is the exchange's own answer, not the URL's: the
     declaration that named where these tokens go is the one that started
     this login. *)
  let* provider = provider_of_id finished.Session.provider_id in
  let keeper_name = finished.Session.keeper in
  let expires_at =
    match finished.Session.expiry with
    | Session.Never | Session.Renewable { expires_at = None; _ } -> None
    | Session.Renewable { expires_at = Some at; _ } | Session.Expiring_without_renewal at -> Some at
  in
  (* All credential writes run inside [publish_credentials]: a newer start for this
     Keeper and provider supersedes the admitted callback only between two
     publications, never in the middle of one, and a publication that was
     superseded before its first write writes nothing. Superseding the table
     entry alone would only make the final [finish] a no-op after the older
     exchange had already overwritten the newer attempt's tokens. *)
  let write = write_finished_credential ~base_path ~provider ~finished in
  let* attachment =
    match
      Keeper_oauth_pending.publish_credentials (pending_for_base_path base_path)
        ~state ~write
    with
    | Keeper_oauth_pending.Published attachment -> Ok attachment
    | Keeper_oauth_pending.Publication_failed detail ->
        Error ("credential publication did not complete; stored values may have changed: " ^ detail)
    | Keeper_oauth_pending.Publication_superseded ->
      Error
        "this login was superseded by disconnect or a newer attempt for the same Keeper and \
         provider; its credentials were not written"
  in
  (* The credentials are on disk by now, so this can fail without undoing
     the attachment. Its outcome is carried rather than logged: the operator
     is looking at a page right now. *)
  let tool_discovery =
    Result.map
      (fun catalog -> List.length catalog.Keeper_identity_tools.tools)
      (match Keeper_identity_tools.refresh ~attachment
         ~mcp_post:(Keeper_identity_tools.http_transports ~clock).Keeper_identity_tools.mcp_post
         ~config ~keeper_name ~provider ~now () with
       | result -> result
       | exception exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           (* All credential writes completed before discovery began. Keep
              that fact even if discovery is cancelled or raises. *)
           ignore (Keeper_oauth_pending.finish (pending_for_base_path base_path) ~state
             (Ok Keeper_oauth_pending.Credentials_published_discovery_failed));
           Printexc.raise_with_backtrace exn backtrace)
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

let finish ~clock ~(config : Workspace.config) ~state ~code ~now =
  let pending = pending_for_base_path config.Workspace.base_path in
  let finish_result result =
    let settlement = Keeper_oauth_pending.finish pending ~state
      (match result with
       | Error _ -> Error ()
       | Ok attached -> Ok (match attached.tool_discovery with
           | Ok count -> Keeper_oauth_pending.Tools_discovered count
           | Error _ -> Keeper_oauth_pending.Credentials_published_discovery_failed)) in
    match settlement with
    | Keeper_oauth_pending.Recorded -> result
    | Keeper_oauth_pending.Not_admitted ->
        (match result with
         | Error _ -> result
         | Ok _ -> Error "this login was superseded by disconnect or a newer attempt; it is no longer admitted")
  in
  match Session.finish
      ~post:(Keeper_oauth_flow.http_post ~clock ~timeout_sec:rest_timeout_sec)
      ~pending ~state ~code ~now () with
  | Error error -> Error (Session.finish_error_to_string error)
  | Ok finished ->
      (match publish_finished ~clock ~config ~state ~finished ~now with
       | result -> finish_result result
       | exception exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           ignore (Keeper_oauth_pending.finish pending ~state (Error ()));
           Printexc.raise_with_backtrace exn backtrace)

let attempt_status_json ~base_path ~now ~keeper ~provider_id ~attempt_id =
  let fields = match Keeper_oauth_pending.status (pending_for_base_path base_path)
      ~now ~keeper ~provider_id ~attempt_id with
    | None -> ["kind", `String "unavailable"]
    | Some (Awaiting_consent expires_at) -> ["kind", `String "awaiting_consent"; "expires_at", `Float expires_at]
    | Some Callback_admitted -> ["kind", `String "callback_admitted"]
    | Some (Completed completion) -> ["kind", `String "completed";
        "credential_publication", `String "published";
        "tool_discovery", (match completion with
          | Tools_discovered count -> `Assoc ["kind", `String "discovered"; "count", `Int count]
          | Credentials_published_discovery_failed -> `Assoc ["kind", `String "failed"])]
    | Some Failed -> ["kind", `String "failed"]
    | Some (Credential_publication_incomplete progress) ->
        let name = function
          | Keeper_oauth_pending.Refresh_token -> "refresh_token"
          | Keeper_oauth_pending.Client -> "client"
          | Keeper_oauth_pending.Access_token -> "access_token"
          | Keeper_oauth_pending.Expiry -> "expiry" in
        ["kind", `String "credential_publication_incomplete";
         "completed_writes", `List (List.map (fun stage -> `String (name stage)) progress.completed_writes);
         "interrupted_write", `String (name progress.interrupted_write);
         "interrupted_write_effect", `String "unknown"]
    | Some Expired -> ["kind", `String "expired"]
    | Some Superseded -> ["kind", `String "superseded"] in
  `Assoc fields

let reject_callback ~base_path ~state ~now =
  let pending = pending_for_base_path base_path in
  match Keeper_oauth_pending.take pending ~now ~state with
  | None -> ()
  | Some _ -> ignore (Keeper_oauth_pending.finish pending ~state (Error ()))

(* Detaching one Keeper from one provider. Three separate acts, reported
   separately because they can disagree: the local token is deleted, the
   tool catalog that made the attachment visible to the Keeper's runtime is
   deleted, and the provider is asked to forget the token. The first two
   always happen; the third is best effort and its outcome is carried, not
   assumed. An operator told "the provider could not be reached" still has a
   Keeper with no token, which is the part this process controls. *)

type revocation =
  | Revoke_not_published
      (** the provider publishes no revocation endpoint, or there was no
          token of ours to revoke (a GitHub CLI provider's credential belongs
          to [gh]) *)
  | Revoke_not_sent of string
      (** the client the token was issued to could not be named, so no
          request was sent *)
  | Revoke_revoked  (** the endpoint answered a success *)
  | Revoke_failed of string  (** the endpoint answered a refusal, or nothing *)

let revocation_to_json = function
  | Revoke_not_published -> `Assoc [ "kind", `String "not_published" ]
  | Revoke_not_sent detail ->
    `Assoc [ "kind", `String "not_sent"; "detail", `String detail ]
  | Revoke_revoked -> `Assoc [ "kind", `String "revoked" ]
  | Revoke_failed detail ->
    `Assoc [ "kind", `String "failed"; "detail", `String detail ]
;;

(* Why a disconnect could not name the client its token was issued to. The
   store's own wording ends in "attach it again", which is advice for a
   renewal, not for a Keeper being disconnected. *)
let unnamed_client_reason : Store.redeem_error -> string = function
  | Store.Not_bound -> "no record of the client this keeper's login used"
  | Store.Binding_unreadable problem ->
    Printf.sprintf "the record of the login's client cannot be read: %s" problem
  | Store.App_unreadable problem ->
    Printf.sprintf "the app on file cannot be read: %s" problem
  | Store.App_gone { client_id } ->
    Printf.sprintf "the login's app %s is no longer on file" client_id
  | Store.App_replaced { bound; current } ->
    Printf.sprintf "the login used app %s and the app on file is now %s" bound current
  | Store.Registration_lapsed { client_id } ->
    Printf.sprintf "the login's client %s has an expired secret" client_id
;;

let disconnect_receipt_path ~base_path ~keeper_name ~provider_id =
  Filename.concat
    (Filename.concat
       (Filename.concat (identity_dir ~base_path) "disconnects")
       (Workspace_utils.safe_filename keeper_name))
    (provider_id ^ ".json")
;;

let rec ensure_dir path =
  if String.equal path "" || String.equal path "." || String.equal path "/"
     || Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then ensure_dir parent;
    try Unix.mkdir path 0o700 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

(* The receipt is the record an operator can read after the screen has moved
   on: what was deleted, and what the provider said. Written after the local
   deletion so a receipt never describes work that did not happen. *)
let write_disconnect_receipt ~base_path ~keeper_name ~provider_id json =
  let path = disconnect_receipt_path ~base_path ~keeper_name ~provider_id in
  Keeper_identity_tools.write_json_snapshot ~path json
;;

let disconnect ?transports ~clock ~(config : Workspace.config) ~keeper ~provider_id
    ~now () =
  let base_path = config.Workspace.base_path in
  let* provider = provider_of_id provider_id in
  let keeper_name = keeper in
  let* detached =
    Keeper_identity_tools.detach_local ~base_path ~keeper_name ~provider
  in
  let refresh_token = detached.Keeper_identity_tools.refresh_token in
  let tools_removed = detached.Keeper_identity_tools.tools_removed in
  let had_refresh_token =
    match refresh_token with
    | Some value -> not (String.equal (String.trim value) "")
    | None -> false
  in
  let revocation =
    match provider.Provider.credential_source with
    | Provider.Github_cli _ ->
      (* [gh] minted and holds this credential; masc never wrote a token of
         its own and cannot revoke one it does not have. Clearing the account
         store is the operator's act, in [gh]. *)
      Revoke_not_published
    | Provider.Oauth_exchange when not had_refresh_token -> Revoke_not_published
    | Provider.Oauth_exchange ->
      let transports =
        match transports with
        | Some transports -> transports
        | None -> Keeper_identity_tools.http_transports ~clock
      in
      (match
         transports.Keeper_identity_tools.discover
           ~mcp_url:provider.Provider.mcp_url
       with
       | Error _ ->
         (* Discovery is how the endpoint is found at all. Without it there
            is nowhere to send the token, which is "not attempted", not
            "failed". *)
         Revoke_not_published
       | Ok discovered ->
         (match discovered.Keeper_oauth_discovery.revocation_endpoint with
          | None -> Revoke_not_published
          | Some url ->
            (* RFC 7009 has the client identify itself, and the token
               belongs to the client this Keeper's login used. When that
               client cannot be named, a request with an empty client_id
               would only come back as the provider's refusal and hide the
               reason, so none is sent and the receipt says why. The
               deletion above never depended on this. *)
            let client =
              match detached.Keeper_identity_tools.client with
              | Ok None -> Error Store.Not_bound
              | Error problem -> Error (Store.Binding_unreadable problem)
              | Ok (Some binding) ->
                Store.redeeming_client ~identity_dir:(identity_dir ~base_path)
                  ~provider ~binding ~now
            in
            (match client with
             | Error reason -> Revoke_not_sent (unnamed_client_reason reason)
             | Ok (client_id, client_secret) ->
               (match
                  Keeper_oauth_flow.revoke
                    ~post:transports.Keeper_identity_tools.token_post
                    ?client_secret ~url ~client_id
                    ~token:(Option.value refresh_token ~default:"")
                    ~token_type_hint:"refresh_token" ()
                with
                | Ok () -> Revoke_revoked
                | Error error ->
                  Revoke_failed (Keeper_oauth_flow.revoke_error_to_string error)))))
  in
  let receipt =
    `Assoc
      [ "keeper", `String keeper_name
      ; "provider", `String provider.Provider.id
      ; "provider_label", `String provider.Provider.label
      ; "at", `Float now
      ; ( "deleted"
        , `Assoc
            [ "refresh_token", `Bool had_refresh_token
            ; "tool_catalog", `Bool tools_removed
            ] )
      ; ( "cleared_env"
        , `List
            [ `String provider.Provider.access_token_env
            ; `String provider.Provider.expires_at_env
            ] )
      ; "revocation", revocation_to_json revocation
      ]
  in
  let* () =
    write_disconnect_receipt ~base_path ~keeper_name
      ~provider_id:provider.Provider.id receipt
  in
  Ok receipt
;;

