(* The account server of a multi-account installation (plan S1a): what its
   table may hold, and the server itself, started on the installation that the
   entry of the boot judged, on real files in a temporary directory and a
   loopback port. Its access is published once per process, so one case
   serves, the case whose boot stops does so before the publication, and the
   executable does not link masc_test_deps, which publishes the access of a
   single user. *)

open Masc
module Read = Authz_boot_mode_read

let workspace =
  match Authz_types.Workspace_id.of_string "workspace-1" with
  | Ok id -> id
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let at_ms = 1_700_000_000_000

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* ---- what the table may hold ---- *)

let nothing _request _reqd = ()
let nothing_with_state _state _request _reqd = ()
let answered (_ : Httpun.Request.t) reqd = Http_server_eio.Response.json_value (`Assoc []) reqd

let kind_label register =
  match Server_account_table.checked register with
  | Ok (_ : Server_account_table.t) -> "served"
  | Error { Server_account_table.path; access } ->
    Printf.sprintf "%s is %s" path (Yojson.Safe.to_string (Route_access.to_json access))
;;

(* A public route, as the probes of the account server are registered. That
   the table of the server itself is taken is the boot of the case below. *)
let public router =
  Server_route.get Server_route.Always_public Server_health_paths.health nothing router
;;

let test_table_kinds () =
  Alcotest.(check string) "a public route" "served" (kind_label public);
  Alcotest.(check string)
    "a route that authenticates a browser session itself"
    "served"
    (kind_label (fun router ->
       public router
       |> Server_route.post
            (Server_route.Self_authenticated Route_access.Browser_session)
            "/auth/logout"
            nothing));
  Alcotest.(check string)
    "the MCP endpoint of a person, which judges every request itself"
    "served"
    (kind_label (fun router ->
       public router
       |> Server_route.post (Server_route.Self_authenticated Route_access.Person_mcp) Server_person_mcp.path nothing));
  Alcotest.(check string)
    "a route behind a wrapper of the single-user server"
    {|/api/v1/status is {"kind":"read_auth"}|}
    (kind_label (fun router ->
       public router |> Server_route.get Server_route.Read_auth "/api/v1/status" nothing_with_state));
  Alcotest.(check string)
    "the dev-token route of the single-user server"
    {|/api/v1/dashboard/dev-token is {"kind":"self_authenticated","reason":"loopback_dev_token"}|}
    (kind_label (fun router ->
       public router
       |> Server_route.get
            (Server_route.Self_authenticated Route_access.Loopback_dev_token)
            "/api/v1/dashboard/dev-token"
            nothing))
;;

(* One raw request through an httpun connection that dispatches on the
   table: the status of the answer. *)
let status_from_table table ~meth ~path =
  Eio_main.run (fun (_ : Eio_unix.Stdenv.base) ->
    let output = Buffer.create 256 in
    let connection =
      Httpun.Server_connection.create (fun reqd ->
        Server_account_table.dispatch table (Httpun.Reqd.request reqd) (Http_reqd.of_httpun reqd))
    in
    let raw =
      Printf.sprintf "%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n" meth path
    in
    let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw) raw in
    let (_ : int) =
      Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input)
    in
    let rec drain () =
      match Httpun.Server_connection.next_write_operation connection with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result connection (`Ok written);
        drain ()
      | `Yield | `Close (_ : int) -> ()
    in
    drain ();
    match String.split_on_char ' ' (Buffer.contents output) with
    | (_ : string) :: status :: (_ : string list) -> int_of_string_opt status
    | [] | [ (_ : string) ] -> None)
;;

let refused (_ : Httpun.Request.t) reqd = Http_server_eio.Response.method_not_allowed reqd

(* A router is one shared table that a registration changes in place, and the
   registration function can keep the router it was given. The table is a copy
   that the check made: a route that is registered afterwards is not in it,
   whatever its kind. Every method of its path is the 404 of a table that
   never held it, and a route of the table that it would replace answers as
   before. *)
let test_a_route_added_after_the_check () =
  let kept = ref None in
  let table =
    match
      Server_account_table.checked (fun router ->
        kept := Some router;
        Server_route.get Server_route.Always_public Server_health_paths.health answered router)
    with
    | Ok table -> table
    | Error refusal -> Alcotest.fail (Server_account_table.refusal_to_string refusal)
  in
  let late = "/api/v1/dashboard/dev-token" in
  Alcotest.(check (option int))
    "a route of the table"
    (Some 200)
    (status_from_table table ~meth:"GET" ~path:Server_health_paths.health);
  (match !kept with
   | None -> Alcotest.fail "the registration was not called"
   | Some router ->
     let (_ : Http_server_eio.Router.t) =
       router
       |> Server_route.get
            (Server_route.Self_authenticated Route_access.Loopback_dev_token)
            late
            answered
       |> Server_route.get
            (Server_route.Self_authenticated Route_access.Loopback_dev_token)
            Server_health_paths.health
            refused
     in
     ());
  Alcotest.(check (option int))
    "a route that was registered after the check"
    (Some 404)
    (status_from_table table ~meth:"GET" ~path:late);
  (* A router that holds the path answers another method of it with a 405. *)
  Alcotest.(check (option int))
    "another method of its path"
    (Some 404)
    (status_from_table table ~meth:"POST" ~path:late);
  Alcotest.(check (option int))
    "the route of the table that a later one would replace"
    (Some 200)
    (status_from_table table ~meth:"GET" ~path:Server_health_paths.health)
;;

(* ---- the server ---- *)

let write_file path text =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> Out_channel.output_string channel text);
  Unix.chmod path 0o600
;;

(* A port that was free a moment ago. *)
let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET ((_ : Unix.inet_addr), port) -> port
      | Unix.ADDR_UNIX (_ : string) -> Alcotest.fail "a TCP socket has no path")
;;

let loopback =
  match Server_bootstrap_http.parse_bind_address "127.0.0.1" with
  | Ok address -> address
  | Error error -> Alcotest.fail (Server_bootstrap_http.bind_address_error_to_string error)
;;

let max_response_bytes = 1 lsl 20

(* The status line, the header lines up to the empty one, and the rest. *)
let response =
  let open Eio.Buf_read.Syntax in
  let rec header_lines lines =
    let* line = Eio.Buf_read.line in
    if String.equal line "" then Eio.Buf_read.return (List.rev lines) else header_lines (line :: lines)
  in
  let* status_line = Eio.Buf_read.line in
  let* headers = header_lines [] in
  let+ body = Eio.Buf_read.take_all in
  status_line, headers, body
;;

(* One HTTP/1.1 request on a connection of its own: the status, the header
   lines and the body. *)
let exchange ~net ~port ?host ?(headers = []) ~meth path =
  let host = Option.value host ~default:(Printf.sprintf "127.0.0.1:%d" port) in
  Eio.Switch.run (fun sw ->
    let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
    Eio.Flow.copy_string
      (Printf.sprintf
         "%s %s HTTP/1.1\r\nHost: %s\r\n%sConnection: close\r\n\r\n"
         meth
         path
         host
         (String.concat "" (List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n") headers)))
      flow;
    let status_line, headers, body =
      Eio.Buf_read.parse_exn ~max_size:max_response_bytes response flow
    in
    match String.split_on_char ' ' status_line with
    | (_ : string) :: status :: (_ : string list) ->
      (match int_of_string_opt status with
       | Some status -> status, headers, body
       | None -> Alcotest.failf "no status in %S" status_line)
    | [] | [ (_ : string) ] -> Alcotest.failf "no status in %S" status_line)
;;

(* The status and the body of {!exchange}. *)
let request ~net ~port ?host ~meth path =
  let status, (_ : string list), body = exchange ~net ~port ?host ~meth path in
  status, body
;;

exception Served

let multi_account_of ~base ~config =
  match Read.boot ~base_path:base ~config_dir:(Some config) ~anonymous_mutations:false with
  | Ok (Read.Multi_account multi_account) -> multi_account
  | Ok (Read.Single_user (_ : Read.single_user)) -> Alcotest.fail "the boot found a single user"
  | Error (first, rest) -> Alcotest.failf "the boot refused: %s" (String.concat "; " (first :: rest))
;;

let seconds_to_serve = 30.

type installation =
  { base : string
  ; config : string
  ; store : string
  ; multi_account : Read.multi_account
  }

(* An activated installation that the entry of the boot judged. No TLS
   listener, no public identity and the default HTTP mode: the listener is
   the loopback port alone, whatever the shell of the run holds. An empty
   value is read as unset. *)
let no_login_client = {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|}

(* The variable of the secret that the GitHub client of a case names. The
   cases that name it set it; no case sets [unset_secret_env]. *)
let github_secret_env = "MASC_TEST_ACCOUNTS_GITHUB_SECRET"
let unset_secret_env = "MASC_TEST_ACCOUNTS_UNSET_SECRET"

let with_login_client ~member ~redirect_uri ~client_secret_env =
  Yojson.Safe.to_string
    (`Assoc
        [ "enabled", `Bool true
        ; "require_token", `Bool true
        ; "account_mode", `String "Multi_account"
        ; ( member
          , `Assoc
              [ "client_id", `String "client-of-the-case"
              ; "redirect_uri", `String redirect_uri
              ; "client_secret_env", `String client_secret_env
              ] )
        ])
;;

let with_github_client = with_login_client ~member:"github"
let with_google_client = with_login_client ~member:"google"

let https_redirect = "https://masc.example" ^ Server_login_http.github_callback_path

let with_installation ?(auth_config = no_login_client) f =
  Unix.putenv "MASC_HTTPS_PORT" "0";
  Unix.putenv "MASC_HTTP_BASE_URL" "";
  Unix.putenv "MASC_USE_H2" "auto";
  Eio_main.run (fun env ->
    let root = Filename.temp_dir "server-accounts-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base = Filename.concat root "base" in
        let config = Filename.concat root "config" in
        let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
        Unix.mkdir base 0o700;
        (match
           Authz_bootstrap.fresh_bootstrap
             { Authz_bootstrap.base_path = base
             ; config_dir = Some config
             ; external_store = store
             ; workspace_id = workspace
             ; now_ms = (fun () -> at_ms)
             }
         with
         | Ok _ -> ()
         | Error error ->
           Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error));
        write_file (Auth.auth_config_file base) auth_config;
        f env { base; config; store; multi_account = multi_account_of ~base ~config }))
;;

let uncertain_label : Authz_zone.uncertain -> string = function
  | Authz_zone.Log_is_stopped _ -> "the log is stopped"
  | Authz_zone.Store_is_stopped _ -> "the store is stopped"
  | Authz_zone.Files_disagree _ -> "the files disagree"
  | Authz_zone.Store_answers_nothing -> "the store answers nothing"
;;

let mode_label : Authz_mode_state.t -> string = function
  | Authz_mode_state.Not_bootstrapped -> "not bootstrapped"
  | Authz_mode_state.Multi_account (_ : Authz_types.Workspace_id.t) -> "multi-account"
  | Authz_mode_state.Off (_ : Authz_types.Workspace_id.t) -> "off"
;;

let open_error_label : Authz_zone.open_error -> string = function
  | Authz_zone.Store_not_opened _ -> "the store did not open"
  | Authz_zone.Log_not_opened _ -> "the log did not open"
  | Authz_zone.Not_bootstrapped { path = _ } -> "not bootstrapped"
  | Authz_zone.Log_not_checked { path = _; detail = _ } -> "the log cannot be checked"
  | Authz_zone.Store_not_there { path = _ } -> "the store is not there"
  | Authz_zone.Store_not_checked { path = _; detail = _ } -> "the store cannot be checked"
;;

let refusal_label : Server_accounts.refusal -> string = function
  | Server_accounts.Http_mode_refused _ -> "HTTP mode refused"
  | Server_accounts.Zone_not_opened error -> "zone not opened: " ^ open_error_label error
  | Server_accounts.Zone_not_trusted uncertain -> "zone not trusted: " ^ uncertain_label uncertain
  | Server_accounts.Zone_not_multi_account mode -> "zone not multi-account: " ^ mode_label mode
  | Server_accounts.Login_client_refused
      (Server_account_login.Github_client_refused (Login_client.Secret_variable_unset name)) ->
    "github client refused: the variable " ^ name ^ " is not set"
  | Server_accounts.Login_client_refused
      (Server_account_login.Github_client_refused
         (Login_client.Client_refused Login_client.Redirect_uri_not_https)) ->
    "github client refused: the redirect is not https"
  | Server_accounts.Login_client_refused
      (Server_account_login.Github_client_refused
         (Login_client.Client_refused
            (Login_client.Client_id_empty | Login_client.Client_secret_empty)))
  | Server_accounts.Login_client_refused (Server_account_login.Google_client_refused _) ->
    "another login client refusal"
  | Server_accounts.Login_client_refused
      (Server_account_login.Redirect_not_the_callback
         { provider = Login_routes.Github; callback_path; redirect_path }) ->
    Printf.sprintf "github redirect on %s, the callback is %s" redirect_path callback_path
  | Server_accounts.Login_client_refused
      (Server_account_login.Redirect_not_the_callback
         { provider = Login_routes.Google; callback_path; redirect_path }) ->
    Printf.sprintf "google redirect on %s, the callback is %s" redirect_path callback_path
  | Server_accounts.Login_client_refused
      (Server_account_login.Redirect_not_on_the_base_url
         { provider = Login_routes.Github; base_url_origin; redirect_origin }) ->
    Printf.sprintf "github redirect on %s, the base URL is on %s" redirect_origin base_url_origin
  | Server_accounts.Login_client_refused
      (Server_account_login.Redirect_not_on_the_base_url
         { provider = Login_routes.Google; base_url_origin = _; redirect_origin = _ }) ->
    "google redirect not on the base URL"
  | Server_accounts.Login_client_refused
      (Server_account_login.Redirect_not_read { provider = Login_routes.Github; redirect_uri }) ->
    Printf.sprintf "github redirect not read: %S" redirect_uri
  | Server_accounts.Login_client_refused
      (Server_account_login.Redirect_not_read { provider = Login_routes.Google; redirect_uri }) ->
    Printf.sprintf "google redirect not read: %S" redirect_uri
  | Server_accounts.Route_of_another_kind _ -> "route of another kind"
  | Server_accounts.Https_listener_refused _ -> "HTTPS listener refused"
  | Server_accounts.Listener_not_bound { host; port = _; reason = _ } ->
    "listener not bound on " ^ host
  | Server_accounts.Port_not_announced _ -> "port not announced"
  | Server_accounts.Access_not_published _ -> "access not published"
  | Server_accounts.Trust_policy_refused _ -> "trust policy refused"
;;

exception Still_serving

(* The cases below stop before the access of the process is published, so
   the case that serves can still publish it. A boot that does not stop
   serves until its switch is cancelled, so the wait for the refusal has an
   end: the exception cancels the switch and what the server forked on it. *)
(* The directory of the owner lease of an installation, beside its base. *)
let owner_dir multi_account =
  Filename.concat (Filename.dirname (Read.multi_account_base_path multi_account)) "owner"
;;

(* The account server announces its port under the BasePath lease, which the
   process of [masc start] holds when it boots one. *)
let with_lease multi_account f =
  let run_dir = owner_dir multi_account in
  if not (Sys.file_exists run_dir) then Unix.mkdir run_dir 0o700;
  match
    Server_startup_takeover.acquire_base_path_lock
      ~run_dir
      (Read.multi_account_base_path multi_account)
  with
  | Server_startup_takeover.Base_path_acquired lease ->
    Fun.protect
      ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
      (fun () -> f lease)
  | Server_startup_takeover.Base_path_already_owned _
  | Server_startup_takeover.Base_path_rejected _ ->
    Alcotest.fail "the lease of the installation was not acquired"
;;

let boot_outcome_under lease env ~port multi_account =
  match
    Eio.Switch.run (fun sw ->
      Eio.Fiber.first
        (fun () ->
          match Server_accounts.run ~sw ~env ~address:loopback ~port ~lease multi_account with
          | Ok () -> "returned"
          | Error refusal -> refusal_label refusal)
        (fun () ->
          Eio.Time.sleep (Eio.Stdenv.clock env) seconds_to_serve;
          raise Still_serving))
  with
  | outcome -> outcome
  | exception Still_serving -> "still serving"
;;

let boot_outcome env ~port multi_account =
  with_lease multi_account @@ fun lease -> boot_outcome_under lease env ~port multi_account
;;

(* The judgment read a store that matched the log. A store that is gone when
   the zone opens is not opened, and nothing is made where it was: a volume
   that is mounted again finds its mount point as it left it. *)
let test_stops_when_the_store_is_gone () =
  with_installation (fun env { base = _; config = _; store; multi_account } ->
    let directory = Filename.dirname store in
    remove_tree directory;
    Alcotest.(check string)
      "the boot over a store that is gone"
      "zone not opened: the store is not there"
      (boot_outcome env ~port:(free_port ()) multi_account);
    Alcotest.(check bool) "no directory is made for the store" false (Sys.file_exists directory))
;;

(* A store that holds no line when the zone opens is the store of row 8: the
   zone opens, cannot be trusted, and the boot stops as that row stops. *)
let test_stops_when_the_store_was_emptied () =
  with_installation (fun env { base = _; config = _; store; multi_account } ->
    Out_channel.with_open_gen
      [ Open_wronly; Open_trunc; Open_binary ]
      0o600
      store
      (fun (_ : Out_channel.t) -> ());
    Alcotest.(check string)
      "the boot over a store that was emptied"
      "zone not trusted: the store answers nothing"
      (boot_outcome env ~port:(free_port ()) multi_account))
;;

(* The judgment read a log in Multi_account. An Off that is written before
   the zone opens leaves a zone that can be trusted and that serves no
   account. *)
let test_stops_when_the_accounts_were_turned_off () =
  with_installation (fun env { base; config; store = _; multi_account } ->
    (match
       Authz_off.turn_off ~base_path:base ~config_dir:(Some config) ~now_ms:(fun () -> at_ms + 1)
     with
     | Ok (_ : Authz_types.Workspace_id.t) -> ()
     | Error error -> Alcotest.failf "the Off was refused: %s" (Authz_off.error_to_string error));
    Alcotest.(check string)
      "the boot over a log that was turned off"
      "zone not multi-account: off"
      (boot_outcome env ~port:(free_port ()) multi_account))
;;

let recorded_port ~base =
  match Workspace_connection.read ~base_path:base with
  | Ok recorded -> Option.map Workspace_connection.to_int recorded
  | Error error -> Alcotest.fail (Workspace_connection.error_message error)
;;

(* The HTTP mode of the process is read once and kept
   ([Env_config.Transport.configure_h2_from_env]); a value outside its
   vocabulary is refused and not kept. This case therefore runs before every
   case that reads the mode: after one of them the value below is not read. *)
(* A login client that config.json names and that cannot be built stops the
   boot: the server does not come up with the login of that provider left
   out. The port is not bound yet, so nothing is recorded for the CLI. *)
let test_stops_when_a_login_client_is_refused () =
  Unix.putenv github_secret_env "secret-of-the-case";
  List.iter
    (fun (auth_config, expected) ->
      with_installation ~auth_config (fun env { base; config = _; store = _; multi_account } ->
        Alcotest.(check string)
          "the boot over a login client that is refused"
          expected
          (boot_outcome env ~port:(free_port ()) multi_account);
        Alcotest.(check (option int)) "no port is recorded for the CLI" None (recorded_port ~base)))
    [ ( with_github_client ~redirect_uri:https_redirect ~client_secret_env:unset_secret_env
      , "github client refused: the variable " ^ unset_secret_env ^ " is not set" )
    ; ( with_github_client
          ~redirect_uri:("http://masc.example" ^ Server_login_http.github_callback_path)
          ~client_secret_env:github_secret_env
      , "github client refused: the redirect is not https" )
    ; ( with_github_client
          ~redirect_uri:"https://masc.example/auth/oidc/callback"
          ~client_secret_env:github_secret_env
      , "github redirect on /auth/oidc/callback, the callback is /auth/github/callback" )
    ; ( with_github_client ~redirect_uri:"https://masc.example" ~client_secret_env:github_secret_env
      , "github redirect on , the callback is /auth/github/callback" )
    ; ( with_github_client
          ~redirect_uri:(https_redirect ^ "/")
          ~client_secret_env:github_secret_env
      , "github redirect on /auth/github/callback/, the callback is /auth/github/callback" )
      (* The provider is sent the redirect as it is written and the router
         finds a route by the bytes of a path, so a path that only decodes
         or resolves to the callback is one this server answers 404 on
         ([test_serves_its_table_alone]). *)
    ; ( with_github_client
          ~redirect_uri:"https://masc.example/%61uth/github/callback"
          ~client_secret_env:github_secret_env
      , "github redirect on /%61uth/github/callback, the callback is /auth/github/callback" )
    ; ( with_github_client
          ~redirect_uri:"https://masc.example/auth%2Fgithub/callback"
          ~client_secret_env:github_secret_env
      , "github redirect on /auth%2Fgithub/callback, the callback is /auth/github/callback" )
    ; ( with_github_client
          ~redirect_uri:"https://masc.example/auth/../auth/github/callback"
          ~client_secret_env:github_secret_env
      , "github redirect on /auth/../auth/github/callback, the callback is /auth/github/callback"
      )
    ; ( with_google_client
          ~redirect_uri:"https://masc.example/auth/oidc/%63allback"
          ~client_secret_env:github_secret_env
      , "google redirect on /auth/oidc/%63allback, the callback is /auth/oidc/callback" )
    ; ( with_google_client
          ~redirect_uri:"https://masc.example/auth/oidc%2Fcallback"
          ~client_secret_env:github_secret_env
      , "google redirect on /auth/oidc%2Fcallback, the callback is /auth/oidc/callback" )
    ; ( with_google_client
          ~redirect_uri:"https://masc.example/auth/./oidc/callback"
          ~client_secret_env:github_secret_env
      , "google redirect on /auth/./oidc/callback, the callback is /auth/oidc/callback" )
    ]
;;

(* The operator told the server its public address. A login client whose
   redirect is on another origin would send every login to another server.
   With no base URL the server knows no public address and compares nothing
   ([test_serves_its_table_alone] boots that way). *)
let redirect_check_label = function
  | Ok Server_account_login.Compared_with_the_base_url -> "compared"
  | Ok Server_account_login.No_base_url -> "no base URL"
  | Error refusal -> refusal_label (Server_accounts.Login_client_refused refusal)
;;

(* A redirect is read as the operator wrote it: an origin and a path. The
   origin is the same one in another case of its scheme or its host and with
   the default port written out; the path is the callback byte for byte.
   What is not an https URL of a host is refused by the client itself. *)
let test_reads_a_redirect_as_it_is_written () =
  let base_url =
    match
      Server_request_authority.make_trust_policy
        ~bind_host:"127.0.0.1"
        ~bind_port:8935
        ~https_port:None
        ~explicit_base_url:(Some "https://masc.example")
    with
    | Ok policy -> Some (Server_request_authority.projection_context policy)
    | Error error -> Alcotest.fail (Server_request_authority.trust_policy_error_to_string error)
  in
  let outcome_of login_clients =
    match
      Server_account_login.clients_of_config
        ~getenv:(fun (_ : string) -> Some "secret-of-the-case")
        login_clients
    with
    | Ok clients ->
      redirect_check_label (Server_account_login.redirects_on_the_server ~base_url clients)
    | Error refusal -> refusal_label (Server_accounts.Login_client_refused refusal)
  in
  let member redirect_uri =
    Some
      { Masc_domain.client_id = "client-of-the-case"
      ; redirect_uri
      ; client_secret_env = github_secret_env
      }
  in
  let github = Server_login_http.github_callback_path in
  let google = Server_login_http.google_callback_path in
  List.iter
    (fun (redirect_uri, expected) ->
      Alcotest.(check string)
        (Printf.sprintf "the GitHub redirect %S" redirect_uri)
        expected
        (outcome_of { Read.google = None; github = member redirect_uri }))
    [ "https://masc.example" ^ github, "compared"
    ; "HTTPS://MASC.Example" ^ github, "compared"
    ; "https://masc.example:443" ^ github, "compared"
    ; ( "https://masc.example:8443" ^ github
      , "github redirect on https://masc.example:8443, the base URL is on https://masc.example" )
    ; ( "https://masc.ex%61mple" ^ github
      , "github redirect on https://masc.ex%61mple, the base URL is on https://masc.example" )
    ; ( "https://masc.example:" ^ github
      , Printf.sprintf "github redirect not read: %S" ("https://masc.example:" ^ github) )
    ; ( "https://masc.example:99999999999999999999" ^ github
      , Printf.sprintf
          "github redirect not read: %S"
          ("https://masc.example:99999999999999999999" ^ github) )
    ; ( "https://person@masc.example" ^ github
      , Printf.sprintf "github redirect not read: %S" ("https://person@masc.example" ^ github) )
    ; ( "https://masc.example/%61uth/github/callback"
      , "github redirect on /%61uth/github/callback, the callback is " ^ github )
    ; ( "https://masc.example/auth/%2e%2e/auth/github/callback"
      , "github redirect on /auth/%2e%2e/auth/github/callback, the callback is " ^ github )
    ; ( "https://masc.example/auth/github/c%41llback"
      , "github redirect on /auth/github/c%41llback, the callback is " ^ github )
    ; ( "https://masc.example/Auth/github/callback"
      , "github redirect on /Auth/github/callback, the callback is " ^ github )
    ; ( "https://masc.example/" ^ github
      , "github redirect on /" ^ github ^ ", the callback is " ^ github )
    ; ( "https://masc.example" ^ github ^ "\n"
      , "github redirect on " ^ github ^ "\n, the callback is " ^ github )
    ; "https://masc.example" ^ github ^ "?", "github client refused: the redirect is not https"
    ; "https://masc.example" ^ github ^ "#", "github client refused: the redirect is not https"
    ];
  List.iter
    (fun (redirect_uri, expected) ->
      Alcotest.(check string)
        (Printf.sprintf "the Google redirect %S" redirect_uri)
        expected
        (outcome_of { Read.google = member redirect_uri; github = None }))
    [ "https://masc.example" ^ google, "compared"
    ; "https://Masc.Example:443" ^ google, "compared"
    ; ( "https://masc.example/auth/oidc/%63allback"
      , "google redirect on /auth/oidc/%63allback, the callback is " ^ google )
    ; ( "https://masc.example:" ^ google
      , Printf.sprintf "google redirect not read: %S" ("https://masc.example:" ^ google) )
    ]
;;

let test_compares_a_redirect_with_the_base_url () =
  let clients =
    match
      Server_account_login.clients_of_config
        ~getenv:(fun (_ : string) -> Some "secret-of-the-case")
        { Read.google = None
        ; github =
            Some
              { Masc_domain.client_id = "client-of-the-case"
              ; redirect_uri = https_redirect
              ; client_secret_env = github_secret_env
              }
        }
    with
    | Ok clients -> clients
    | Error refusal -> Alcotest.fail (Server_account_login.refusal_to_string refusal)
  in
  List.iter
    (fun (explicit_base_url, expected) ->
      let base_url =
        Option.map
          (fun (_ : string) ->
            match
              Server_request_authority.make_trust_policy
                ~bind_host:"127.0.0.1"
                ~bind_port:8935
                ~https_port:None
                ~explicit_base_url
            with
            | Ok policy -> Server_request_authority.projection_context policy
            | Error error ->
              Alcotest.fail (Server_request_authority.trust_policy_error_to_string error))
          explicit_base_url
      in
      Alcotest.(check string)
        ("under the base URL " ^ Option.value explicit_base_url ~default:"(none)")
        expected
        (redirect_check_label (Server_account_login.redirects_on_the_server ~base_url clients)))
    [ None, "no base URL"
    ; Some "https://masc.example", "compared"
    ; Some "https://masc.example:443", "compared"
    ; Some "https://MASC.example", "compared"
    ; ( Some "https://other.example"
      , "github redirect on https://masc.example, the base URL is on https://other.example" )
    ; ( Some "https://masc.example:8443"
      , "github redirect on https://masc.example, the base URL is on https://masc.example:8443" )
    ; ( Some "http://masc.example"
      , "github redirect on https://masc.example, the base URL is on http://masc.example" )
    ]
;;

(* The boot makes that comparison before it announces its port. *)
let test_stops_when_a_redirect_is_not_on_the_base_url () =
  Unix.putenv github_secret_env "secret-of-the-case";
  with_installation
    ~auth_config:
      (with_github_client ~redirect_uri:https_redirect ~client_secret_env:github_secret_env)
    (fun env { base; config = _; store = _; multi_account } ->
      Unix.putenv "MASC_HTTP_BASE_URL" "https://other.example";
      Fun.protect
        ~finally:(fun () -> Unix.putenv "MASC_HTTP_BASE_URL" "")
        (fun () ->
          Alcotest.(check string)
            "the boot under a base URL the redirect is not on"
            "github redirect on https://masc.example, the base URL is on https://other.example"
            (boot_outcome env ~port:(free_port ()) multi_account);
          Alcotest.(check (option int)) "no port is recorded for the CLI" None (recorded_port ~base)))
;;

let test_stops_on_an_http_mode_outside_its_vocabulary () =
  with_installation (fun env { base; config = _; store; multi_account } ->
    (* The store is gone too: a boot that opened the zone before it read the
       mode would stop on the store. *)
    remove_tree (Filename.dirname store);
    Unix.putenv "MASC_USE_H2" "sometimes";
    Alcotest.(check string)
      "the boot under an HTTP mode outside its vocabulary"
      "HTTP mode refused"
      (boot_outcome env ~port:(free_port ()) multi_account);
    Alcotest.(check (option int)) "no port is recorded" None (recorded_port ~base))
;;

(* A port that another socket listens on. *)
let test_stops_when_the_port_is_taken () =
  with_installation (fun env { base; config = _; store = _; multi_account } ->
    let taken = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close taken)
      (fun () ->
        Unix.bind taken (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
        Unix.listen taken 1;
        let port =
          match Unix.getsockname taken with
          | Unix.ADDR_INET ((_ : Unix.inet_addr), port) -> port
          | Unix.ADDR_UNIX (_ : string) -> Alcotest.fail "a TCP socket has no path"
        in
        Alcotest.(check string)
          "the boot on a port that is taken"
          "listener not bound on 127.0.0.1"
          (boot_outcome env ~port multi_account);
        (* A boot that stopped leaves no port for the CLI of the workspace. *)
        Alcotest.(check (option int)) "no port is recorded" None (recorded_port ~base)))
;;

(* The file the announcement lock is taken on is a directory, so the port
   that bound cannot be announced. The boot stops before the access of the
   process is published. *)
let test_stops_when_the_port_cannot_be_announced () =
  with_installation (fun env { base; config = _; store = _; multi_account } ->
    let run_dir = owner_dir multi_account in
    Unix.mkdir run_dir 0o700;
    Unix.mkdir
      (Server_startup_takeover.For_testing.lease_path
         ~run_dir:(Unix.realpath run_dir)
         ~canonical_base_path:(Unix.realpath base)
       ^ ".account-server")
      0o700;
    Alcotest.(check string)
      "the boot whose port cannot be announced"
      "port not announced"
      (boot_outcome env ~port:(free_port ()) multi_account);
    Alcotest.(check (option int)) "no port is recorded" None (recorded_port ~base))
;;

(* The base URL of the process names no HTTP(S) identity, so the trust policy
   is refused after the port bound. The boot stops before it announces: a
   command that reads the announcement reads a server that goes on to serve.
   The kernel is asked while the lease is still held, because the release of
   the lease withdraws an announcement. *)
let test_stops_before_it_announces_when_the_trust_policy_refuses () =
  with_installation (fun env { base; config = _; store = _; multi_account } ->
    Unix.putenv "MASC_HTTP_BASE_URL" "ftp://127.0.0.1";
    let port = free_port () in
    with_lease multi_account
    @@ fun lease ->
    Alcotest.(check string)
      "the boot under a base URL that names no HTTP identity"
      "trust policy refused"
      (boot_outcome_under lease env ~port multi_account);
    (match
       Server_startup_takeover.account_server_port_holder
         ~run_dir:(owner_dir multi_account)
         ~base_path:base
         ~port
     with
     | Ok None -> ()
     | Ok (Some pid) ->
       Alcotest.failf "pid %d holds the announcement of the port of a boot that stopped" pid
     | Error rejection ->
       Alcotest.fail (Server_startup_takeover.base_path_lock_rejection_to_string rejection));
    Alcotest.(check (option int)) "no port is recorded" None (recorded_port ~base))
;;

let json_of label body =
  match Yojson.Safe.from_string body with
  | json -> json
  | exception Yojson.Json_error detail -> Alcotest.failf "%s: %s: %S" label detail body
;;

(* ---- the console ---- *)

(* Runs [f root] while the assets of the process are read from the
   directory [root] of the case. [bundle] is the files of its dashboard
   bundle, each under its name in the bundle, or [None] for a directory that
   holds no bundle. The checkout the suite runs in then decides no answer. An
   empty value of the variable reads as no value ([Host_config]), so the
   bundle the suite was started with comes back afterwards. *)
let with_assets_directory bundle f =
  let variable = "MASC_ASSETS_DIR" in
  let inherited = Option.value (Sys.getenv_opt variable) ~default:"" in
  let root = Filename.temp_dir "server-accounts-bundle-" "" in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv variable inherited;
      remove_tree root)
    (fun () ->
      (match bundle with
       | None -> ()
       | Some files ->
         let dashboard = Filename.concat root "dashboard" in
         Unix.mkdir dashboard 0o700;
         List.iter (fun (name, bytes) -> write_file (Filename.concat dashboard name) bytes) files);
      Unix.putenv variable root;
      f root)
;;

let with_bundle files f = with_assets_directory (Some files) (fun (_ : string) -> f ())

let holds ~part text =
  let part_length = String.length part in
  let last = String.length text - part_length in
  let rec same_from index offset =
    offset = part_length
    || (Char.equal text.[index + offset] part.[offset] && same_from index (offset + 1))
  in
  let rec from index = index <= last && (same_from index 0 || from (index + 1)) in
  from 0
;;

(* The value of the one header line of this name. *)
let header name lines =
  let prefix = name ^ ": " in
  match
    List.filter_map
      (fun line ->
        if String.starts_with ~prefix (String.lowercase_ascii line)
        then Some (String.sub line (String.length prefix) (String.length line - String.length prefix))
        else None)
      lines
  with
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None
;;

(* The directives of a policy, sorted. A nonce of 64 hex digits, as the
   server draws it, reads as [N]: its value differs per answer. *)
let directives policy =
  let hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  let without_nonce directive =
    match String.split_on_char '\'' directive with
    | [ before; value; after ]
      when String.starts_with ~prefix:"nonce-" value
           && String.length value = String.length "nonce-" + 64
           && String.for_all hex (String.sub value (String.length "nonce-") 64) ->
      before ^ "'nonce-N'" ^ after
    | _ -> directive
  in
  String.split_on_char ';' policy
  |> List.map (fun directive -> without_nonce (String.trim directive))
  |> List.sort String.compare
;;

let console_page = "<!doctype html><title>the console of the case</title>"

(* The policy of the console, as [directives] reads it. The whole policy is
   named: a directive that opens the page to another origin, or to inline
   code, does not come in unnoticed. *)
let console_directives =
  [ "base-uri 'none'"
  ; "connect-src 'self'"
  ; "default-src 'none'"
  ; "form-action 'none'"
  ; "frame-ancestors 'none'"
  ; "script-src 'self'"
  ; "style-src 'self'"
  ; "style-src-attr 'none'"
  ]
;;
let console_script = "export const built = 'the console of the case';\n"
let operator_page = "<!doctype html><title>the operator dashboard of the case</title>"
let operator_script = "export const built = 'the operator dashboard of the case';\n"

let test_serves_its_table_alone () =
  Unix.putenv github_secret_env "secret-of-the-case";
  with_installation
    ~auth_config:
      (with_github_client ~redirect_uri:https_redirect ~client_secret_env:github_secret_env)
    (fun env { base; config = _; store = _; multi_account } ->
    let port = free_port () in
    let net = Eio.Stdenv.net env in
    with_lease multi_account
    @@ fun lease ->
    let serve sw =
      let ready, set_ready = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        match
          Server_accounts.run
            ~sw
            ~env
            ~address:loopback
            ~port
            ~lease
            ~on_ready:(Eio.Promise.resolve set_ready)
            multi_account
        with
        | Ok () -> ()
        | Error refusal -> Alcotest.fail (Server_accounts.refusal_to_string refusal));
      Eio.Promise.await ready;
      let status, body = request ~net ~port ~meth:"GET" Server_health_paths.health in
      Alcotest.(check int) "GET /health" 200 status;
      (match json_of "GET /health" body with
       | `Assoc fields ->
         Alcotest.(check (option string))
           "the version a command line reads from the health answer"
           (match List.assoc_opt "version" fields with
            | Some (`String version) -> Some version
            | Some _ | None -> None)
           (Server_accounts.health_version body);
         Alcotest.(check (option string))
           "the account mode of the health answer"
           (Some "Multi_account")
           (match List.assoc_opt "account_mode" fields with
            | Some (`String mode) -> Some mode
            | Some _ | None -> None);
         (* Anyone who reaches the listener reads this answer, so the test
            names all of it: a field of the host or of the workspace (the
            build record carries the path of the executable) does not come in
            unnoticed. *)
         Alcotest.(check (list string))
           "the health answer holds the server, its version and the mode, and no more"
           [ "account_mode"; "server"; "version" ]
           (List.sort String.compare (List.map fst fields));
         Alcotest.(check bool)
           "every field of the health answer is a string"
           true
           (List.for_all
              (fun ((_ : string), value) ->
                match value with
                | `String (_ : string) -> true
                | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> false)
              fields)
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
         Alcotest.failf "the health answer is not an object: %S" body);
      (* The probes say that the listener answers and that a decision can
         rest on the zone, and nothing of the process: the whole answer is
         compared. *)
      List.iter
        (fun (path, expected) ->
          let status, body = request ~net ~port ~meth:"GET" path in
          Alcotest.(check int) ("GET " ^ path) 200 status;
          Alcotest.(check string)
            ("the whole answer of " ^ path)
            expected
            (Yojson.Safe.to_string (json_of path body)))
        [ Server_health_paths.liveness, {|{"live":true}|}
        ; Server_health_paths.readiness, {|{"ready":true}|}
        ];
      (* The routes of the single-user server are not in the table, the ones
         it answers without a credential included. *)
      List.iter
        (fun (meth, path) ->
          Alcotest.(check int) (meth ^ " " ^ path) 404 (fst (request ~net ~port ~meth path)))
        [ "GET", "/api/v1/dashboard/dev-token"
        ; "GET", "/api/v1/status"
        ; "GET", "/ws"
        ; "GET", "/api/v1/keepers"
        ];
      (* The callback of the client of config.json is found by the bytes of
         its path. A path that decodes or resolves to it is not in the table,
         which is why the boot reads the path of a redirect as it is written
         ([test_reads_a_redirect_as_it_is_written]). *)
      Alcotest.(check bool)
        ("GET " ^ Server_login_http.github_callback_path ^ " is in the table")
        true
        (fst (request ~net ~port ~meth:"GET" Server_login_http.github_callback_path) <> 404);
      List.iter
        (fun path ->
          Alcotest.(check int) ("GET " ^ path) 404 (fst (request ~net ~port ~meth:"GET" path)))
        [ "/%61uth/github/callback"
        ; "/auth%2Fgithub/callback"
        ; "/auth/../auth/github/callback"
        ];
      (* The MCP endpoint of a person takes one message for one answer: the
         table holds no stream and no session to close on its path. *)
      List.iter
        (fun meth ->
          Alcotest.(check int)
            (meth ^ " " ^ Server_person_mcp.path)
            405
            (fst (request ~net ~port ~meth Server_person_mcp.path)))
        [ "GET"; "DELETE" ];
      (* The pages of a person are in the table, open, and each answer has
         a script nonce of its own. GitHub is the client of config.json, so
         the button of its login can be pressed. *)
      List.iter
        (fun path ->
          let status, headers, body = exchange ~net ~port ~meth:"GET" path in
          let lower = List.map String.lowercase_ascii headers in
          Alcotest.(check int) ("GET " ^ path) 200 status;
          Alcotest.(check int)
            ("one content security policy with a script nonce on " ^ path)
            1
            (List.length
               (List.filter
                  (String.starts_with ~prefix:"content-security-policy: default-src 'none'; script-src 'nonce-")
                  lower));
          Alcotest.check
            Account_page_reading.outcome
            ("the GitHub login can be started from " ^ path)
            (Ok Account_page_reading.Open)
            (Account_page_reading.login ~start:"/auth/github/start" body))
        [ "/"; Authz_activation.invitation_path ];
      (* The console of a signed-in person. A bundle that does not hold its
         build: the page says so with a 503 and runs nothing, and the rest of
         the table answers as it does. *)
      with_bundle [] (fun () ->
        let status, headers, body =
          exchange ~net ~port ~meth:"GET" Server_account_console.page_path
        in
        Alcotest.(check int) "the console of a bundle that does not hold it" 503 status;
        (* The reason goes to the log of the server, not to whoever reaches
           the listener. *)
        (match Server_account_console.unreadable () with
         | None -> Alcotest.fail "a bundle without the console reads as one that has it"
         | Some reason ->
           Alcotest.(check bool)
             "the page that stands in does not say why"
             false
             (holds ~part:reason body));
        Alcotest.(check (option string))
          "a link of the page that stands in carries no address of this server"
          (Some "same-origin")
          (header "referrer-policy" headers);
        Alcotest.(check (option (list string)))
          "the page that stands in applies its own sheet and runs no script"
          (Some
             [ "base-uri 'none'"
             ; "default-src 'none'"
             ; "form-action 'none'"
             ; "frame-ancestors 'none'"
             ; "style-src 'nonce-N'"
             ])
          (Option.map directives (header "content-security-policy" headers));
        Alcotest.(check (option string))
          "nothing between the server and the browser keeps the page that stands in"
          (Some "no-store")
          (header "cache-control" headers);
        Alcotest.(check int)
          "a file of a build the bundle does not hold"
          404
          (fst (request ~net ~port ~meth:"GET" (Server_account_console.page_path ^ "/assets/app.js")));
        Alcotest.(check int)
          "the home page of a server whose bundle holds no console"
          200
          (fst (request ~net ~port ~meth:"GET" "/")));
      (* A directory that holds no bundle: the page and the files of the
         build are a 503, and no answer names where the server looked. *)
      with_assets_directory None (fun root ->
        List.iter
          (fun path ->
            let status, body = request ~net ~port ~meth:"GET" path in
            Alcotest.(check int) ("GET " ^ path ^ " without a bundle") 503 status;
            Alcotest.(check bool)
              ("the answer of " ^ path ^ " names no directory of the server")
              false
              (holds ~part:root body))
          [ Server_account_console.page_path; Server_account_console.page_path ^ "/assets/app.js" ]);
      (* A bundle that holds the build of the console beside the operator
         dashboard. *)
      with_bundle
        [ "accounts/index.html", console_page
        ; "accounts/assets/app.js", console_script
        ; "index.html", operator_page
        ; "assets/operator.js", operator_script
        ]
        (fun () ->
          let status, headers, body =
            exchange ~net ~port ~meth:"GET" Server_account_console.page_path
          in
          Alcotest.(check int) "the console" 200 status;
          Alcotest.(check string) "it is the page of the build, byte for byte" console_page body;
          Alcotest.(check (option (list string)))
            "the policy of the console"
            (Some console_directives)
            (Option.map directives (header "content-security-policy" headers));
          Alcotest.(check (option string))
            "a browser does not keep the page"
            (Some "no-store")
            (header "cache-control" headers);
          (* A link of the console that leaves this origin tells the other
             site nothing of the address it was followed from. *)
          Alcotest.(check (option string))
            "a link to another site carries no address of this server"
            (Some "same-origin")
            (header "referrer-policy" headers);
          (let status, headers, body =
             exchange ~net ~port ~meth:"GET" (Server_account_console.page_path ^ "/assets/app.js")
           in
           Alcotest.(check int) "a file of the build" 200 status;
           Alcotest.(check string) "it is the file of the build, byte for byte" console_script body;
           Alcotest.(check (option string))
             "it is answered as a script"
             (Some "application/javascript; charset=utf-8")
             (header "content-type" headers);
           (* A file of the build that a browser opens as a document runs
              under the limits of the page. *)
           Alcotest.(check (option (list string)))
             "a file of the build carries the policy of the console"
             (Some console_directives)
             (Option.map directives (header "content-security-policy" headers));
           Alcotest.(check (option string))
             "a browser keeps a file of the build, which is named after its bytes"
             (Some "public, max-age=31536000, immutable")
             (header "cache-control" headers));
          (* A query names no other file: the page and a file of the build
             with one are the same bytes as without. *)
          List.iter
            (fun (path, expected) ->
              let status, body = request ~net ~port ~meth:"GET" path in
              Alcotest.(check int) ("GET " ^ path) 200 status;
              Alcotest.(check string) ("the answer of " ^ path ^ " is the same bytes") expected body)
            [ Server_account_console.page_path ^ "?from=home", console_page
            ; Server_account_console.page_path ^ "/assets/app.js?v=1", console_script
            ];
          (* Nothing else of the bundle has an address on this server: not
             below the assets of the console, by any spelling of the way up,
             and not at the addresses of the single-user server. *)
          List.iter
            (fun path ->
              let status, body = request ~net ~port ~meth:"GET" path in
              Alcotest.(check int) ("GET " ^ path) 404 status;
              Alcotest.(check bool)
                ("no file of the bundle is the answer of " ^ path)
                false
                (List.exists
                   (fun part -> holds ~part body)
                   [ console_page; console_script; operator_page; operator_script ]))
            [ Server_account_console.page_path ^ "/assets/"
            ; Server_account_console.page_path ^ "/assets//app.js"
            ; Server_account_console.page_path ^ "/assets/../index.html"
            ; Server_account_console.page_path ^ "/assets/../../index.html"
            ; Server_account_console.page_path ^ "/assets/../../assets/operator.js"
            ; Server_account_console.page_path ^ "/assets/..%2f..%2findex.html"
            ; Server_account_console.page_path ^ "/assets/%2e%2e/index.html"
            ; Server_account_console.page_path ^ "/assets/missing.js"
            ; Server_account_console.page_path ^ "/index.html"
            ; "/accounts/index.html"
            ; "/dashboard"
            ; "/dashboard/assets/operator.js"
            ];
          (* The sheet the console links is the first part of the sheet of
             the pages the server writes itself, so the two look alike. A
             browser that holds it is told so and gets no bytes again. *)
          let sheet_path = Server_account_console.page_path ^ "/base.css" in
          let status, headers, body = exchange ~net ~port ~meth:"GET" sheet_path in
          Alcotest.(check int) "the sheet the console links" 200 status;
          Alcotest.(check (option string))
            "it is answered as a sheet"
            (Some "text/css; charset=utf-8")
            (header "content-type" headers);
          Alcotest.(check bool) "it is the base sheet" true (String.equal body Account_page.base_sheet);
          (* The address stays and the bytes change with the binary. *)
          Alcotest.(check (option string))
            "a browser asks for it again on every use"
            (Some "no-cache")
            (header "cache-control" headers);
          Alcotest.(check bool)
            "the home page carries the same sheet"
            true
            (holds ~part:Account_page.base_sheet (snd (request ~net ~port ~meth:"GET" "/")));
          match header "etag" headers with
          | None -> Alcotest.fail "the sheet has no entity tag"
          | Some tag ->
            (* The tag follows the bytes: a browser that holds the sheet of
               another binary is sent the sheet of this one. *)
            Alcotest.(check string)
              "the tag of the sheet is the tag of its bytes"
              (Printf.sprintf
                 "\"%s\""
                 (Http_server_eio.Response.etag_of_body Account_page.base_sheet))
              tag;
            let status, (_ : string list), body =
              exchange ~net ~port ~headers:[ "If-None-Match", tag ] ~meth:"GET" sheet_path
            in
            Alcotest.(check int) "the sheet, asked by a browser that holds it" 304 status;
            Alcotest.(check string) "no bytes go again" "" body);
      (* The routes of a person are in the table, and a request with no
         credential is refused by the route. *)
      List.iter
        (fun path ->
          Alcotest.(check int)
            ("GET " ^ path ^ " with no credential")
            401
            (fst (request ~net ~port ~meth:"GET" path)))
        [ "/api/v1/auth/whoami"; Auth_preview.provider_accounts_path; Auth_preview_keeper.keepers_path ];
      Alcotest.(check int)
        "an MCP message with no credential"
        401
        (fst (request ~net ~port ~meth:"POST" Server_person_mcp.path));
      (* The login routes are in the table. GitHub is the client of
         config.json: a start with no Origin gets as far as the route, which
         refuses it. Google has no member, so its start is the 404 of the
         route, in the words of the route. *)
      Alcotest.(check int)
        "the start of the configured provider, with no Origin"
        403
        (fst (request ~net ~port ~meth:"POST" "/auth/github/start"));
      (* A start from the pages of this server takes a pending login: it is
         sent to the provider with the client of config.json, and the browser
         gets the cookie of the login in flight. *)
      (let status, headers, (_ : string) =
         exchange
           ~net
           ~port
           ~headers:[ "Origin", Printf.sprintf "http://127.0.0.1:%d" port ]
           ~meth:"POST"
           "/auth/github/start"
       in
       let lower = List.map String.lowercase_ascii headers in
       Alcotest.(check int) "the start of the configured provider, from this origin" 303 status;
       Alcotest.(check bool)
         "it goes to the authorization page of GitHub with the client of config.json"
         true
         (List.exists
            (String.starts_with
               ~prefix:
                 "location: https://github.com/login/oauth/authorize?client_id=client-of-the-case&")
            lower);
       Alcotest.(check int)
         "it sets one cookie, of the login in flight"
         1
         (List.length (List.filter (String.starts_with ~prefix:"set-cookie: __host-masc_oidc_txn=") lower)));
      (* The transport of a login makes its connections from the environment
         and under the switch that the boot gave it. *)
      Alcotest.(check bool)
        "the transport of a login has the environment of the process"
        true
        (Option.is_some (Eio_context.get_env_opt ()));
      Alcotest.(check bool)
        "the transport of a login has the switch of the server"
        true
        (Option.is_some (Eio_context.get_switch_opt ()));
      (let status, body = request ~net ~port ~meth:"POST" "/auth/oidc/start" in
       Alcotest.(check int) "the start of a provider with no client" 404 status;
       Alcotest.(check bool)
         "the 404 is the answer of the login route and not of the router"
         false
         (String.equal body (snd (request ~net ~port ~meth:"POST" "/api/v1/status"))));
      Alcotest.(check int)
        "a method the table does not hold for a path it holds"
        405
        (fst (request ~net ~port ~meth:"OPTIONS" Server_health_paths.health));
      Alcotest.(check int)
        "a Host that is not the listener"
        400
        (fst (request ~net ~port ~host:"example.com" ~meth:"GET" Server_health_paths.health));
      (* The host reads the port from the kernel while the server holds the
         lease. This process is the holder, so it is answered from its own
         table; the read through the kernel is a case of the takeover suite. *)
      (match
         Server_startup_takeover.account_server_announcement
           ~run_dir:(owner_dir multi_account)
           ~base_path:base
       with
       | Ok (Some { Server_startup_takeover.pid; port = announced }) ->
         Alcotest.(check int) "the port that is announced" port announced;
         Alcotest.(check int) "the process that announces it" (Unix.getpid ()) pid
       | Ok None -> Alcotest.fail "the server announced no port"
       | Error rejection ->
         Alcotest.fail (Server_startup_takeover.base_path_lock_rejection_to_string rejection));
      (* The CLI of the workspace finds the port without being told. *)
      Alcotest.(check (option int)) "the port the workspace records" (Some port) (recorded_port ~base);
      raise Served
    in
    match
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) seconds_to_serve (fun () ->
        Eio.Switch.run serve)
    with
    | () -> Alcotest.fail "the server returned"
    | exception Served -> ())
;;

let () =
  Alcotest.run
    "server_accounts"
    [ ( "account server"
      , [ Alcotest.test_case "the kinds its table may hold" `Quick test_table_kinds
        ; Alcotest.test_case "a route added after the check" `Quick test_a_route_added_after_the_check
        ; Alcotest.test_case
            "the boot stops on an HTTP mode outside its vocabulary"
            `Quick
            test_stops_on_an_http_mode_outside_its_vocabulary
        ; Alcotest.test_case "the boot stops when the store is gone" `Quick test_stops_when_the_store_is_gone
        ; Alcotest.test_case "the boot stops when the store was emptied" `Quick test_stops_when_the_store_was_emptied
        ; Alcotest.test_case
            "the boot stops when the accounts were turned off"
            `Quick
            test_stops_when_the_accounts_were_turned_off
        ; Alcotest.test_case
            "the boot stops when a login client is refused"
            `Quick
            test_stops_when_a_login_client_is_refused
        ; Alcotest.test_case "the boot stops when the port is taken" `Quick test_stops_when_the_port_is_taken
        ; Alcotest.test_case
            "a redirect is compared with the base URL"
            `Quick
            test_compares_a_redirect_with_the_base_url
        ; Alcotest.test_case
            "the boot stops when a redirect is not on the base URL"
            `Quick
            test_stops_when_a_redirect_is_not_on_the_base_url
        ; Alcotest.test_case
            "the boot stops when the port cannot be announced"
            `Quick
            test_stops_when_the_port_cannot_be_announced
        ; Alcotest.test_case
            "the boot stops before it announces when the trust policy refuses"
            `Quick
            test_stops_before_it_announces_when_the_trust_policy_refuses
        ; Alcotest.test_case
            "a redirect is read as it is written"
            `Quick
            test_reads_a_redirect_as_it_is_written
        ; Alcotest.test_case "it serves its table alone" `Quick test_serves_its_table_alone
        ] )
    ]
;;
