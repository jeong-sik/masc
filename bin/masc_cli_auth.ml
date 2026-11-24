(* HIGH-RISK-UNREVIEWED: see the interface. *)

module A = Authz_activation
module T = Server_startup_takeover
module Config_root = Server_runtime_config_root_bootstrap

let ( let* ) = Result.bind
let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

let account_server_line =
  "a server boots the workspace as a multi-account installation: the account server, which \
   answers the health probes (GET /health, /health/live and /health/ready), the login routes \
   of the login clients in config.json, and the pages where a person connects their own \
   subscription and runs their own Keepers. It answers no route that reads the credentials \
   of a single user"
;;

(* [held] says why nothing happens when another process holds the lease, and
   what the person who ran the command does next. *)
let with_lease ~held ~base_path f =
  match Unix.realpath base_path with
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "the base path %s is not reachable: %s" base_path (Unix.error_message error))
  | base_path ->
    (match T.acquire_owner_lease (Host_config.host ()).base_path_lease_root base_path with
     | T.Base_path_already_owned { owner; lock_path } -> Error (held ~base_path ~lock_path owner)
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

(* A running account server issues invitations itself, so the person is sent
   there before the shared guidance on the lease. Only a workspace whose
   config.json asks for multi-account use boots that server; the holder of any
   other lease serves neither the console nor the route, and only the shared
   guidance is given. The lease does not identify its holder
   ({!T.base_path_owner}), so the sentence says what holds when the holder is
   the account server, and the shared guidance keeps the lock file and the
   warning about the recorded PID. The console is named by the address the
   link would carry; when that is missing or refused, the reason is given, since
   this command needs it as well. *)
let invite_held ~base_path ~lock_path owner =
  let shared = T.base_path_contention_message ~base_path ~lock_path owner in
  match Authz_boot_mode_read.asked ~base_path with
  | Ok Authz_boot_mode.Asks_single_user | Error (_ : Authz_boot_mode.refusal) -> shared
  | Ok Authz_boot_mode.Asks_multi_account ->
    let console, address_note =
      match public_base_url () with
      | Ok base -> base ^ Account_page.console_path, ""
      | Error reason ->
        Account_page.console_path, " It also needs an address for the link: " ^ reason ^ "."
    in
    Printf.sprintf
      "the lease of the workspace is held, so nothing is written. When its holder is \
       the account server of this workspace, an Admin who has signed in issues \
       invitations from it with no stop of the server: the 초대 링크 (invitations) \
       panel of the console at %s, or POST %s \
       (docs/guides/account-server-invitations.md). This command writes one only \
       while the lease is free.%s %s"
      console
      Login_invite_routes.path
      address_note
      shared
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
let under_lease ~held ~base_path write =
  with_lease ~held ~base_path (fun base_path ->
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
   reported, so the exit code does not claim it was printed. The link is
   flushed before the next steps, so a failure after it is not taken for a
   lost link: the exit code says whether the link was printed, and a lost step
   is reported on its own. *)
let print_link ~command ~base_url ~next invitation =
  Printf.printf
    "\nThe link works once, until %s, and is not shown again:\n  %s\n"
    (Time_codec.rfc3339_of_unix (float_of_int (A.expires_at_ms invitation) /. 1000.))
    (A.link ~base_url invitation);
  match flush stdout with
  | exception Sys_error detail ->
    Printf.eprintf
      "masc auth %s: the invitation is written, and its link did not reach the standard \
       output: %s; masc auth invite writes another\n"
      command
      detail;
    1
  | () ->
    Printf.printf
      "\nNext:\n%s"
      (String.concat
         ""
         (List.mapi (fun index step -> Printf.sprintf "  %d. %s\n" (index + 1) step) next));
    (match flush stdout with
     | () -> 0
     | exception Sys_error detail ->
       Printf.eprintf
         "masc auth %s: the link is printed, and the next steps did not reach the \
          standard output: %s\n"
         command
         detail;
       0)
;;

(* Both commands leave the workspace with no server on it. A trial on this
   machine runs the preview in place of the server (account-server-setup.md). *)
let start_step ~base_url ~base_path =
  Printf.sprintf
    "Start the account server where %s reaches it: masc start --base-path %s --port \
     <port>, with %s and the client secret of each login client of config.json \
     exported (docs/guides/account-server-setup.md, step 3). A trial on this machine \
     runs masc auth preview in its place (the same guide, \"Try it on this machine \
     first\")."
    base_url
    (Filename.quote base_path)
    Env_config_core.http_base_url_env_key
;;

let refused command reason =
  Printf.eprintf "masc auth %s: %s\n" command reason;
  1
;;

(* What people may connect is read from runtime.toml
   ([Server_runtime_setup_actions.config]), and a workspace that has none
   offers nothing: the integrations route answers 503 and every connection is
   refused. A bootstrap therefore puts the runtime.toml this build embeds at
   the path the account server reads, where no entry is. An entry that is
   there is the operator's and is kept.

   The file is placed after a boot is known to ask for the activation and
   before the activation, which is committed once and is not run twice. A
   placement that fails refuses the bootstrap with nothing activated, and the
   same command runs again. *)
type declaration =
  { path : string
  ; placement : Config_root.runtime_toml_placement
  }

let setup_guide_step_6 = "docs/guides/account-server-setup.md, step 6"

let declare_connections ~base_path =
  let path = Server_runtime_setup_actions.config_path ~base_path in
  match Config_root.place_embedded_runtime_toml ~path with
  | Ok placement -> Ok { path; placement }
  | Error (Config_root.Not_published reason) ->
    Error
      (Printf.sprintf
         "%s, which declares what people may connect, could not be made, and nothing \
          was activated: %s. Put a runtime.toml there (%s), or end what stopped the \
          command, and run it again."
         path
         reason
         setup_guide_step_6)
  | Error (Config_root.Not_synced reason) ->
    Error
      (Printf.sprintf
         "%s, which declares what people may connect, is in place, but its directory \
          could not be synced, and nothing was activated: %s. The next run keeps what \
          is there and syncs again."
         path
         reason)
;;

let declaration_line { path; placement } =
  match placement with
  | Config_root.Embedded_written ->
    Printf.sprintf
      "- %s is the runtime.toml this release ships: no entry was there. It declares \
       what people may connect, and an edit of it changes that (%s).\n"
      path
      setup_guide_step_6
  | Config_root.Existing_kept ->
    Printf.sprintf
      "- An entry was at %s and is left as it is. The account server reads what people \
       may connect from that path at each request (%s).\n"
      path
      setup_guide_step_6
;;

(* The writes of an activation that stop come after the placement, and
   leave the file it wrote. *)
let written_before_the_refusal { path; placement } =
  match placement with
  | Config_root.Embedded_written ->
    Printf.sprintf "; %s now holds the runtime.toml this release ships" path
  | Config_root.Existing_kept -> ""
;;

(* Every check of the activation comes before the placement: a command that
   a check refuses has made no file and no directory for runtime.toml. *)
let bootstrap ~base_path ~external_store =
  let activate ~base_path ~config_dir ~anonymous_mutations ~now_ms =
    let* prepared =
      Result.map_error
        A.error_to_string
        (A.prepare ~base_path ~config_dir ~external_store ~anonymous_mutations ~now_ms)
    in
    let* declaration = declare_connections ~base_path in
    match A.complete prepared with
    | Ok activated -> Ok (activated, declaration)
    | Error error ->
      Error (A.error_to_string error ^ written_before_the_refusal declaration)
  in
  match under_lease ~held:T.base_path_contention_message ~base_path activate with
  | Error reason -> refused "bootstrap" reason
  | Ok (base_url, ({ A.workspace_id; invitation }, declaration)) ->
    Printf.printf
      "Multi-account use is on for workspace %s.\n\
       - From now on %s.\n\
       - %s.\n\
       - The external store is %s.\n\
       %s\
       The first Admin is invited.\n"
      (Authz_types.Workspace_id.to_string workspace_id)
      account_server_line
      (String.capitalize_ascii Authz_boot_mode_read.turn_off_line)
      external_store
      (declaration_line declaration);
    print_link
      ~command:"bootstrap"
      ~base_url
      ~next:
        [ start_step ~base_url ~base_path
        ; "Hand the link to the person who becomes the first Admin. They open it and \
           sign in."
        ]
      invitation
;;

let invite ~base_path =
  let invite ~base_path ~config_dir ~anonymous_mutations ~now_ms =
    Result.map_error
      A.invite_error_to_string
      (A.invite ~base_path ~config_dir ~anonymous_mutations ~now_ms)
  in
  match under_lease ~held:invite_held ~base_path invite with
  | Error reason -> refused "invite" reason
  | Ok (base_url, invitation) ->
    (* No flush here: [print_link] flushes this line with the link. *)
    print_string
      "One more Admin is invited. Earlier invitations stay open until they are spent or \
       expire.\n";
    print_link
      ~command:"invite"
      ~base_url
      ~next:
        [ start_step ~base_url ~base_path
        ; "Hand the link to the person. They open it and sign in."
        ; Printf.sprintf
            "Once an Admin has signed in, Member and Admin invitations come from the \
             console at %s (초대 링크), with no stop of the server."
            (base_url ^ Account_page.console_path)
        ]
      invitation
;;

(* ---- masc auth service-credential (plan C4-9) ---- *)

module H = Authz_service_credential_host

(* The calls open the writer zone under the lease of the base path, as an
   invitation does. The setting of anonymous mutations is read first, so a
   setting a server would refuse writes nothing. *)
let under_lease_only ~base_path call =
  with_lease ~held:T.base_path_contention_message ~base_path (fun base_path ->
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
  match with_lease ~held:T.base_path_contention_message ~base_path turn_off with
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
      let* (_ : Runtime_account_access.published) =
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
        Server_accounts.add_routes_of_people
          routes
          ~env
          ~base_path
          (Masc.Http_server_eio.Router.create ())
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
           masc auth invite made with MASC_HTTP_BASE_URL=%s. It serves the login routes \
           and the unified dashboard of a signed-in person at %s, where the person connects their own \
           subscription and runs their Keepers on it. Stop it with Ctrl-C.\n%!"
          base_url
          base_url
          base_url
          Server_account_console.dashboard_path;
        (* As the account server does at its start: the page that stands in
           for the dashboard names no reason to the browser. *)
        (match Server_account_console.unreadable () with
         | None -> ()
         | Some reason ->
           Printf.printf
             "%s answers 503 in this preview: %s.\n%!"
             Server_account_console.dashboard_path
             reason);
        (* And which providers offer people no model to check. The access
           is published above. *)
        List.iter
          (fun line -> Printf.printf "%s.\n%!" line)
          (Server_person_integrations.start_lines ~base_path);
        (* What a stopped preview left ends beside the routes, as at the
           start of the account server. The access is published above. *)
        Server_stopped_work.start ~sw ~env ~zone ~base_path;
        Server_bootstrap_http.serve
          ~sw
          ~clock
          ~socket
          ~addr_label:(Printf.sprintf "%s:%d" preview_host port)
          ~request_handler:(preview_handler ~trust_policy router);
        Ok ()))
;;

let preview ~select_dashboard ~base_path ~port ~github_client_id =
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
    with_lease ~held:T.base_path_contention_message ~base_path (fun base_path ->
      let* anonymous_mutations = anonymous_mutations () in
      let* store =
        Result.map_error
          A.invite_error_to_string
          (A.active_store
             ~base_path
             ~config_dir:(Env_config_core.masc_config_dir_opt ())
             ~anonymous_mutations)
      in
      (* As masc start does once it holds the lease: the console reads the
         dashboard bundle this selects. *)
      select_dashboard ();
      serve_preview ~base_path ~store ~port github)
  in
  match run with
  | Ok () -> 0
  | Error reason -> refused "preview" reason
;;

