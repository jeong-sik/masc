(* HIGH-RISK-UNREVIEWED: see the interface. *)

module A = Authz_activation
module T = Server_startup_takeover

let ( let* ) = Result.bind
let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

let account_server_line =
  "a server boots the workspace as a multi-account installation: the account server, which \
   answers the health probes (GET /health, /health/live and /health/ready), the login routes \
   of the login clients in config.json, and the pages where a person connects their own \
   subscription and runs their own Keepers. It answers no route that reads the credentials \
   of a single user"
;;

let with_lease ~base_path f =
  match Unix.realpath base_path with
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "the base path %s is not reachable: %s" base_path (Unix.error_message error))
  | base_path ->
    (match T.acquire_owner_lease (Host_config.host ()).base_path_lease_root base_path with
     | T.Base_path_already_owned { owner; lock_path } ->
       Error (T.base_path_contention_message ~base_path ~lock_path owner)
     | T.Base_path_rejected rejection -> Error (T.base_path_lock_rejection_to_string rejection)
     | T.Base_path_acquired lease ->
       Fun.protect ~finally:(fun () -> T.release_base_path_lease lease) (fun () -> f base_path))
;;

(* The person opens the link from wherever they are, so its base is the public
   address the operator states, as for a Play invite. MASC_HOST and
   MASC_HTTP_PORT of this shell need not be where the server listens. *)
let public_base_url () =
  let key = Env_config_core.http_base_url_env_key in
  match Env_config_core.masc_http_base_url_opt () with
  | None ->
    Error
      (key
       ^ " is not set, so the link has no address; set it to the http(s) address the \
          person opens")
  | Some base ->
    if Masc.Play_invite.is_http_public_base_url base
    then Ok base
    else
      (* The value is not echoed: a refused URL can carry a password. *)
      Error
        (key
         ^ " is not an http(s) origin with no user, path, query or fragment, so it cannot \
            carry the link")
;;

(* What a server started from this shell would read. A server started from
   another environment reads its own. *)
let anonymous_mutations () =
  Result.map
    Server_auth_config.allow_anonymous_mutations
    (Result.map_error
       Server_auth_config.resolve_error_to_string
       (Server_auth_config.resolve (Server_auth_config.read_env ())))
;;

(* Both are read before anything is written, so a link that could not be
   printed, or a setting a server would refuse, writes nothing. *)
let under_lease ~base_path write =
  with_lease ~base_path (fun base_path ->
    let* base_url = public_base_url () in
    let* anonymous_mutations = anonymous_mutations () in
    let* written =
      Eio_main.run (fun _env ->
        write
          ~base_path
          ~config_dir:(Env_config_core.masc_config_dir_opt ())
          ~anonymous_mutations
          ~now_ms)
    in
    Ok (base_url, written))
;;

(* The invitation is committed by now. A link that did not reach the output is
   reported, so the exit code does not claim it was printed. *)
let print_link ~command ~base_url invitation =
  Printf.printf
    "The person signs in once with this link before %s. It is not shown again:\n%s\n"
    (Time_codec.rfc3339_of_unix (float_of_int (A.expires_at_ms invitation) /. 1000.))
    (A.link ~base_url invitation);
  match flush stdout with
  | () -> 0
  | exception Sys_error detail ->
    Printf.eprintf
      "masc auth %s: the invitation is written, and its link did not reach the standard \
       output: %s; masc auth invite writes another\n"
      command
      detail;
    1
;;

let refused command reason =
  Printf.eprintf "masc auth %s: %s\n" command reason;
  1
;;

let bootstrap ~base_path ~external_store =
  let activate ~base_path ~config_dir ~anonymous_mutations ~now_ms =
    Result.map_error
      A.error_to_string
      (A.activate ~base_path ~config_dir ~external_store ~anonymous_mutations ~now_ms)
  in
  match under_lease ~base_path activate with
  | Error reason -> refused "bootstrap" reason
  | Ok (base_url, { A.workspace_id; invitation }) ->
    Printf.printf
      "The installation is activated for multi-account use, workspace %s.\n\
       From now on %s. %s. The external store is %s.\n\
       The first Admin is invited.\n"
      (Authz_types.Workspace_id.to_string workspace_id)
      account_server_line
      (String.capitalize_ascii Authz_boot_mode_read.turn_off_line)
      external_store;
    print_link ~command:"bootstrap" ~base_url invitation
;;

let invite ~base_path =
  let invite ~base_path ~config_dir ~anonymous_mutations ~now_ms =
    Result.map_error
      A.invite_error_to_string
      (A.invite ~base_path ~config_dir ~anonymous_mutations ~now_ms)
  in
  match under_lease ~base_path invite with
  | Error reason -> refused "invite" reason
  | Ok (base_url, invitation) ->
    (* No flush here: [print_link] flushes once and reports a failure. *)
    print_string
      "One more Admin is invited. Earlier invitations stay open until they are spent or \
       expire.\n";
    print_link ~command:"invite" ~base_url invitation
;;

(* ---- masc auth service-credential (plan C4-9) ---- *)

module H = Authz_service_credential_host

(* The calls open the writer zone under the lease of the base path, as an
   invitation does. The setting of anonymous mutations is read first, so a
   setting a server would refuse writes nothing. *)
let under_lease_only ~base_path call =
  with_lease ~base_path (fun base_path ->
    let* anonymous_mutations = anonymous_mutations () in
    Eio_main.run (fun _env ->
      Result.map_error
        H.error_to_string
        (call
           ~base_path
           ~config_dir:(Env_config_core.masc_config_dir_opt ())
           ~anonymous_mutations
           ~now_ms)))
;;

let service_credential_issue ~base_path ~service =
  match
    under_lease_only ~base_path (fun ~base_path ~config_dir ~anonymous_mutations ~now_ms ->
      H.issue ~base_path ~config_dir ~anonymous_mutations ~now_ms ~service)
  with
  | Error reason -> refused "service-credential issue" reason
  | Ok token ->
    let id =
      Authz_types.Service_credential_id.to_string
        (Authz_credential_token.Service_credential.id token)
    in
    (* The credential is committed by now. When the token does not reach the
       output, the standard error names the credential, so the operator
       revokes this one and no other; the token is not printed again. A reader
       that went away gives EPIPE here instead of killing the process. SIGPIPE
       stays ignored until the process ends, so the flush at exit of the
       unwritten token fails quietly and the exit code stays 1. *)
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
    (match
       Printf.printf
         "The service %s has a new credential, %s. Its token is not shown again:\n%s\n"
         service
         id
         (Authz_credential_token.Service_credential.to_string token);
       flush stdout
     with
     | () -> 0
     | exception Sys_error detail ->
       Printf.eprintf
         "masc auth service-credential issue: the credential %s is written, and its \
          token did not reach the standard output: %s; revoke it with masc auth \
          service-credential revoke --credential %s and issue another\n%!"
         id
         detail
         id;
       1)
;;

let service_credential_revoke ~base_path ~credential =
  match
    under_lease_only ~base_path (fun ~base_path ~config_dir ~anonymous_mutations ~now_ms ->
      H.revoke ~base_path ~config_dir ~anonymous_mutations ~now_ms ~credential)
  with
  | Error reason -> refused "service-credential revoke" reason
  | Ok () ->
    Printf.printf "The credential %s is revoked.\n" credential;
    0
;;

let status_label = function
  | Authz_service_credential_state.Open -> "open"
  | Authz_service_credential_state.Revoked -> "revoked"
;;

let service_credential_list ~base_path =
  match under_lease_only ~base_path H.list with
  | Error reason -> refused "service-credential list" reason
  | Ok [] ->
    print_endline "No Service credential is issued.";
    0
  | Ok listed ->
    List.iter
      (fun { H.credential_id; service_id; issued_at_ms; status } ->
        Printf.printf
          "%s\t%s\t%s\t%s\n"
          (Authz_types.Service_credential_id.to_string credential_id)
          (Authz_types.Service_id.to_string service_id)
          (Time_codec.rfc3339_of_unix (float_of_int issued_at_ms /. 1000.))
          (status_label status))
      listed;
    0
;;

(* The Off depends on the log and the external store alone, so neither the
   public address nor the anonymous-mutation setting is read. *)
let off ~base_path =
  let turn_off base_path =
    Eio_main.run (fun _env ->
      Result.map_error
        Authz_off.error_to_string
        (Authz_off.turn_off ~base_path ~config_dir:(Env_config_core.masc_config_dir_opt ()) ~now_ms))
  in
  match with_lease ~base_path turn_off with
  | Error reason -> refused "off" reason
  | Ok workspace_id ->
    Printf.printf
      "The accounts of workspace %s are turned off.\n\
       Once config.json does not ask for Multi_account (take account_mode out), a server \
       boots a single user. The records of the accounts stay read-only: no turn runs for a \
       Keeper or on a Runtime of the log, and no client starts on a home under \
       .masc/accounts. This build does not turn the accounts on again.\n"
      (Authz_types.Workspace_id.to_string workspace_id);
    0
;;

(* ---- masc auth preview (plan, preview scope P3) ---- *)

let github_client_secret_env = "MASC_GITHUB_CLIENT_SECRET"
let default_preview_port = 8940
let preview_host = "127.0.0.1"
let preview_backlog = 16

(* The listener admits only the authority it binds, as the server does
   before it routes (Server_request_authority). *)
let preview_handler ~trust_policy router (_ : Eio.Net.Sockaddr.stream) gluten_reqd =
  let reqd = gluten_reqd.Gluten.Reqd.reqd in
  let neutral_reqd = Masc.Http_reqd.of_gluten gluten_reqd in
  let request = Httpun.Reqd.request reqd in
  match Server_request_authority.classify_http1_request ~trust_policy request with
  | Server_request_authority.Single authority ->
    Server_request_authority.with_current authority (fun () ->
      Masc.Http_server_eio.Router.dispatch router request neutral_reqd)
  | Server_request_authority.Missing
  | Server_request_authority.Multiple
  | Server_request_authority.Malformed
  | Server_request_authority.Untrusted ->
    Masc.Http_server_eio.Response.text
      ~status:`Bad_request
      (Printf.sprintf "the Host of the request is not %s" preview_host)
      neutral_reqd
;;

let serve_preview ~base_path ~store ~port github =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Crypto_rng.ensure_default ();
      Eio_context.set_env env;
      Eio_context.set_switch sw;
      Eio_context.set_net (Eio.Stdenv.net env);
      let clock = Eio.Stdenv.clock env in
      let log_path = Authz_log.path_of_base_path ~base_path in
      let* zone =
        Result.map_error
          (fun error -> "the authorization zone is not opened: " ^ Authz_zone.open_error_to_string error)
          (Authz_zone.open_at_start ~now_ms ~log_path ~store_path:store)
      in
      (* A login check and a verification start an official client only on a
         home of the person who asked (plan D2-4). *)
      let* () =
        Result.map_error
          Runtime_account_access.publish_error_to_string
          (Runtime_account_access.publish
             (Runtime_account_access.Multi_account
                { zone; base_path; now = (fun () -> Eio.Time.now clock) }))
      in
      let* trust_policy =
        Result.map_error
          Server_request_authority.trust_policy_error_to_string
          (Server_request_authority.make_trust_policy
             ~bind_host:preview_host
             ~bind_port:port ~https_port:None
             ~explicit_base_url:None)
      in
      let routes =
        Server_account_login.routes
          ~clock
          ~zone
          { Server_account_login.google = None; github = Some github }
      in
      let router =
        Masc.Http_server_eio.Router.create ()
        |> Server_login_http.add_routes routes
        |> Server_login_http.add_person_routes routes ~env ~base_path
      in
      let address = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
      match
        Server_bootstrap_http.listen_tcp_result
          ~sw
          ~net:(Eio.Stdenv.net env)
          ~backlog:preview_backlog
          address
      with
      | Error reason ->
        Error (Printf.sprintf "%s:%d is not listened on: %s" preview_host port reason)
      | Ok socket ->
        let base_url = Printf.sprintf "http://%s:%d" preview_host port in
        Printf.printf
          "The multi-account preview listens on %s. Open %s/ in a browser, or the link of \
           masc auth invite made with MASC_HTTP_BASE_URL=%s. It serves the login routes, \
           the connection of a person's own subscription, and their Keepers, whose turns run \
           on that subscription. Stop it with Ctrl-C.\n%!"
          base_url
          base_url
          base_url;
        (* The deletions of conversations a stopped preview left end beside
           the routes, as at the start of the account server. *)
        Eio.Fiber.fork ~sw (fun () -> Server_keeper_conversation_purge.resume ~env ~zone ~base_path);
        Server_bootstrap_http.serve
          ~sw
          ~clock
          ~socket
          ~addr_label:(Printf.sprintf "%s:%d" preview_host port)
          ~request_handler:(preview_handler ~trust_policy router);
        Ok ()))
;;

let preview ~base_path ~port ~github_client_id =
  let github =
    match Sys.getenv_opt github_client_secret_env with
    | None -> Error (github_client_secret_env ^ " is not set")
    | Some client_secret ->
      Result.map_error
        Login_client.loopback_error_to_string
        (Login_client.loopback
           ~client_id:github_client_id
           ~client_secret
           ~port
           ~path:Server_login_http.github_callback_path)
  in
  let run =
    let* github = github in
    with_lease ~base_path (fun base_path ->
      let* anonymous_mutations = anonymous_mutations () in
      let* store =
        Result.map_error
          A.invite_error_to_string
          (A.active_store
             ~base_path
             ~config_dir:(Env_config_core.masc_config_dir_opt ())
             ~anonymous_mutations)
      in
      serve_preview ~base_path ~store ~port github)
  in
  match run with
  | Ok () -> 0
  | Error reason -> refused "preview" reason
;;

