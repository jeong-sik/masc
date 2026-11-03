(** Detaching one Keeper from one provider, over the route the TUI calls.

    The operator asked how to disconnect a service and there was no road: the
    five identity routes only ever wrote credentials. This suite drives the
    route the same way the TUI does -- an authenticated POST with the Keeper
    and the provider -- and reads the world afterwards: the refresh token is
    gone from the Keeper's secret scope, the tool catalog written for that
    provider is gone, and a receipt records what was removed and what the
    provider was asked to revoke. *)

open Alcotest

module Http = Masc.Http_server_eio

let check = Alcotest.check

let base_path () =
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-disconnect-route-%d-%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  Unix.mkdir path 0o700;
  path

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun name -> remove_tree (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"
;;

let dispatch_response ?(meth = "POST") ?token ~router ~path ~body () =
  Server_request_authority.with_current
    (loopback_request_authority ())
    (fun () ->
      let output = Buffer.create 1024 in
      let connection =
        Httpun.Server_connection.create (fun reqd ->
          Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
      in
      let authorization =
        Option.fold
          ~none:""
          ~some:(fun token -> "Authorization: Bearer " ^ token ^ "\r\n")
          token
      in
      let raw_request =
        Printf.sprintf
          "%s %s HTTP/1.1\r\n\
           Host: 127.0.0.1:8935\r\n\
           Origin: http://127.0.0.1:8935\r\n\
           %s\
           Content-Type: application/json\r\n\
           Content-Length: %d\r\n\
           \r\n\
           %s"
          meth path authorization (String.length body) body
      in
      let input =
        Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request
      in
      ignore
        (Httpun.Server_connection.read_eof connection input ~off:0
           ~len:(Bigstringaf.length input));
      let rec drain () =
        match Httpun.Server_connection.next_write_operation connection with
        | `Write iovecs ->
          let bytes =
            List.fold_left
              (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
                Buffer.add_string output
                  (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                total + iov.len)
              0 iovecs
          in
          Httpun.Server_connection.report_write_result connection (`Ok bytes);
          drain ()
        | `Yield | `Close _ -> ()
      in
      drain ();
      let raw = Buffer.contents output in
      let status = int_of_string (List.nth (String.split_on_char ' ' raw) 1) in
      let rec body_offset index =
        if index + 4 > String.length raw then fail ("no HTTP body: " ^ raw)
        else if String.sub raw index 4 = "\r\n\r\n" then index + 4
        else body_offset (index + 1)
      in
      let offset = body_offset 0 in
      status, String.sub raw offset (String.length raw - offset))
;;

let dispatch_json ?meth ?token ~router ~path ~body () =
  let status, body = dispatch_response ?meth ?token ~router ~path ~body () in
  status, Yojson.Safe.from_string body
;;

let member json key =
  match json with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> Alcotest.fail "the answer is not an object"
;;

let provider_or_fail id =
  match Keeper_oauth_declarations.find id with
  | Some (Keeper_oauth_declarations.Declared provider) -> provider
  | Some (Keeper_oauth_declarations.Unreadable { problem; _ }) ->
    Alcotest.failf "the %s declaration does not read: %s" id problem
  | None -> Alcotest.failf "no provider is declared as %s" id
;;

let keeper = "disconnect-route-fixture"

let with_disconnect_router f =
  let base_path = base_path () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      remove_tree base_path)
    (fun () ->
      Eio_main.run
      @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run
      @@ fun sw ->
      let state = Masc.Mcp_server.For_testing.create_state ~base_path in
      let config = Masc.Mcp_server.workspace_config state in
      ignore (Masc.Workspace.init config ~agent_name:(Some "test"));
      Server_auth.For_testing.restore_server_state (Some state);
      Auth.save_auth_config base_path
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      let token =
        match
          Auth.create_token base_path ~agent_name:"disconnect-owner"
            ~role:Masc_domain.Admin
        with
        | Ok (token, _) -> token
        | Error error -> fail (Masc_domain.masc_error_to_string error)
      in
      let clock = Eio.Stdenv.clock env in
      let router =
        Server_keeper_oauth_http.add_routes ~clock (Http.Router.create ())
      in
      f ~base_path ~clock ~router ~token)
;;

(* Put a Keeper in the state the login route would have left it in: a refresh
   token on file, an access token in the environment scope, and the tool
   catalog written for the provider. *)
let seed_attachment base_path provider =
  let scope = Masc.Keeper_secret_projection.Keeper_secret in
  (match
     Masc.Keeper_secret_projection.set_file_entry ~base_path ~keeper_name:keeper ~scope
       ~container_path:provider.Keeper_oauth_provider.refresh_token_file
       ~value:"a-refresh-token"
   with
   | Ok () -> ()
   | Error message -> Alcotest.failf "seeding the refresh token failed: %s" message);
  (match
     Masc.Keeper_secret_projection.set_env_entry ~base_path ~keeper_name:keeper ~scope
       ~name:provider.Keeper_oauth_provider.access_token_env
       ~value:"an-access-token"
   with
   | Ok () -> ()
   | Error message -> Alcotest.failf "seeding the access token failed: %s" message);
  let attachment = Keeper_oauth_pending.capture_attachment
    (Keeper_oauth_pending.for_base_path base_path) ~keeper
    ~provider_id:provider.Keeper_oauth_provider.id in
  let publication = match Keeper_oauth_pending.begin_catalog attachment with
    | Some publication -> publication
    | None -> Alcotest.fail "seeding the catalog was superseded" in
  match
    Masc.Keeper_identity_tools.save ~publication
      { Masc.Keeper_identity_tools.provider_id = provider.Keeper_oauth_provider.id
      ; provider_label = provider.Keeper_oauth_provider.label
      ; discovered_at = 0.
      ; tools = []
      }
  with
  | Keeper_oauth_pending.Published () -> ()
  | Keeper_oauth_pending.Publication_superseded -> Alcotest.fail "seeding the catalog was superseded"
  | Keeper_oauth_pending.Publication_failed message -> Alcotest.failf "seeding the catalog failed: %s" message
;;

let test_the_route_removes_the_token_the_catalog_and_writes_a_receipt () =
  with_disconnect_router
  @@ fun ~base_path ~clock:_ ~router ~token ->
  let provider = provider_or_fail "slack" in
  seed_attachment base_path provider;
  let status, answer =
    dispatch_json ~router ~token
      ~path:"/api/v1/keepers/oauth/disconnect"
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
             [ "keeper", `String keeper
             ; "provider", `String provider.Keeper_oauth_provider.id
             ]))
      ()
  in
  check int "the route answers 200" 200 status;
  check bool "and the answer names the provider" true
    (member answer "provider" = Some (`String provider.Keeper_oauth_provider.id));
  (* The refresh token is gone from the Keeper's secret scope. *)
  (match
     Masc.Keeper_secret_projection.read_file_entry ~base_path ~keeper_name:keeper
       ~scope:Masc.Keeper_secret_projection.Keeper_secret
       ~container_path:provider.Keeper_oauth_provider.refresh_token_file
   with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "the refresh token is still on file"
   | Error message -> Alcotest.failf "reading the refresh token failed: %s" message);
  (* The tool catalog is gone, so the next turn stops offering its tools. *)
  (match
     Masc.Keeper_identity_tools.load ~base_path ~keeper_name:keeper
       ~provider_id:provider.Keeper_oauth_provider.id
   with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "the tool catalog is still on file"
   | Error message -> Alcotest.failf "reading the catalog failed: %s" message);
  (* A receipt records what was removed. *)
  let receipt_path =
    Filename.concat
      (Filename.concat
         (Filename.concat
            (Filename.concat
               (Filename.concat base_path ".masc")
               "identity")
            "disconnects")
         keeper)
      (provider.Keeper_oauth_provider.id ^ ".json")
  in
  check bool "a receipt was written" true (Sys.file_exists receipt_path);
  let receipt =
    Yojson.Safe.from_file receipt_path
  in
  check bool "it names the provider" true
    (member receipt "provider" = Some (`String provider.Keeper_oauth_provider.id));
  check bool "and says the refresh token was deleted" true
    (match member receipt "deleted" with
     | Some (`Assoc fields) -> List.assoc_opt "refresh_token" fields = Some (`Bool true)
     | _ -> false)
;;

let test_an_unknown_keeper_or_provider_is_refused () =
  with_disconnect_router
  @@ fun ~base_path:_ ~clock:_ ~router ~token ->
  let status, answer =
    dispatch_json ~router ~token
      ~path:"/api/v1/keepers/oauth/disconnect"
      ~body:
        (Yojson.Safe.to_string
           (`Assoc [ "keeper", `String keeper; "provider", `String "not-a-provider" ]))
      ()
  in
  check int "an undeclared provider is a bad request" 400 status;
  check bool "with a reason" true (member answer "error" <> None)
;;

module Store = Keeper_oauth_client_store

let binding_path base_path provider =
  Masc.Keeper_identity_tools.client_binding_path ~base_path ~keeper_name:keeper
    ~provider_id:provider.Keeper_oauth_provider.id

let registered client_id =
  { Store.Registered.client_id; client_secret = None; secret_expires_at = None }

let workspace_config () =
  match Server_auth.current_server_state () with
  | Some state -> Masc.Mcp_server.workspace_config state
  | None -> Alcotest.fail "the fixture server state is not installed"

(* What the callback stores, stage by stage. The record of the client the
   last login used goes away with the old refresh token, so a publication
   cut between the token and the client leaves no client record -- never the
   new token beside the old client -- and the client stage records the
   client that redeemed this code. *)
let test_a_finished_login_records_the_client_that_redeemed_it () =
  with_disconnect_router
  @@ fun ~base_path ~clock:_ ~router:_ ~token:_ ->
  let provider = provider_or_fail "slack" in
  (match Store.save_binding ~path:(binding_path base_path provider)
           (Store.Bound_to_registered (registered "previous-login"))
   with
   | Ok () -> ()
   | Error message -> Alcotest.failf "seeding the previous binding failed: %s" message);
  let finished =
    { Keeper_oauth_session.keeper
    ; provider_id = provider.Keeper_oauth_provider.id
    ; access_token = "new-access"
    ; expiry = Keeper_oauth_session.Renewable { expires_at = Some 100.; refresh_token = "new-refresh" }
    ; client = Store.Registered (registered "this-login")
    }
  in
  let write stage =
    match Server_keeper_oauth.write_finished_credential ~base_path ~provider ~finished stage with
    | Ok () -> ()
    | Error message -> Alcotest.failf "the write failed: %s" message
  in
  write Keeper_oauth_pending.Refresh_token;
  check bool "the previous login's client is gone with its token" true
    (Store.load_binding ~path:(binding_path base_path provider) = Ok None);
  check bool "and the new refresh token is on file" true
    (Masc.Keeper_secret_projection.read_file_entry ~base_path ~keeper_name:keeper
       ~scope:Masc.Keeper_secret_projection.Keeper_secret
       ~container_path:provider.Keeper_oauth_provider.refresh_token_file
     = Ok (Some "new-refresh"));
  write Keeper_oauth_pending.Client;
  check bool "the client that redeemed this code is recorded" true
    (Store.load_binding ~path:(binding_path base_path provider)
     = Ok (Some (Store.Bound_to_registered (registered "this-login"))))
;;

(* Revocation names the client the token was issued to, not the install's
   app, and the record goes with the token. *)
let test_disconnect_revokes_with_the_logins_client_and_forgets_it () =
  with_disconnect_router
  @@ fun ~base_path ~clock ~router:_ ~token:_ ->
  let provider = provider_or_fail "slack" in
  seed_attachment base_path provider;
  let identity_dir = Masc.Keeper_identity_tools.identity_dir ~base_path in
  (match
     Store.save_app ~identity_dir ~provider
       { Store.App.client_id = "someone-elses-app"; client_secret = None; scopes = [] }
   with
   | Ok () -> ()
   | Error message -> Alcotest.failf "seeding the app failed: %s" message);
  (match Store.save_binding ~path:(binding_path base_path provider)
           (Store.Bound_to_registered (registered "per-login-client"))
   with
   | Ok () -> ()
   | Error message -> Alcotest.failf "seeding the binding failed: %s" message);
  let revoked = ref [] in
  let transports =
    { Masc.Keeper_identity_tools.mcp_post =
            { Mcp_client.deadline_s = 60.
            ; send = (fun ~deadline:_ ~url:_ ~headers:_ ~body:_ ->
                Alcotest.fail "disconnect reached the MCP server")
            }
    ; token_post = (fun ~url ~headers:_ ~body ->
          revoked := (url, body) :: !revoked;
          Ok (200, "{}"))
    ; discover = (fun ~mcp_url:_ ->
          Ok
            { Keeper_oauth_discovery.resource = "https://mcp.example.com/mcp"
            ; issuer = "https://auth.example.com"
            ; authorize_url = "https://auth.example.com/authorize"
            ; token_url = "https://auth.example.com/token"
            ; registration_url = None
            ; revocation_endpoint = Some "https://auth.example.com/revoke"
            ; scopes_supported = []
            ; supports_pkce_s256 = true
            })
    }
  in
  (match
     Server_keeper_oauth.disconnect ~transports ~clock ~config:(workspace_config ())
       ~keeper ~provider_id:provider.Keeper_oauth_provider.id ~now:0. ()
   with
   | Ok _ -> ()
   | Error message -> Alcotest.failf "disconnect failed: %s" message);
  let form body =
    List.map (fun (key, values) -> key, String.concat "," values) (Uri.query_of_encoded body)
  in
  (match !revoked with
   | [ (url, body) ] ->
     check string "sent to the revocation endpoint" "https://auth.example.com/revoke" url;
     check (option string) "named the client the token was issued to"
       (Some "per-login-client") (List.assoc_opt "client_id" (form body))
   | revocations ->
     Alcotest.failf "expected one revocation, saw %d" (List.length revocations));
  check bool "the record of the login's client is gone" true
    (Store.load_binding ~path:(binding_path base_path provider) = Ok None)
;;

(* When the client the token was issued to cannot be named, nothing is sent
   to the provider and the receipt says why: an empty client_id would only
   come back as the provider's refusal. *)
let test_disconnect_sends_no_revoke_without_the_logins_client () =
  let disconnect_with binding =
    with_disconnect_router
    @@ fun ~base_path ~clock ~router:_ ~token:_ ->
    let provider = provider_or_fail "slack" in
    seed_attachment base_path provider;
    let path = binding_path base_path provider in
    (match binding with
     | `Absent -> ()
     | `Unreadable ->
       (* Saved first so the directory is the store's own, then torn. *)
       (match Store.save_binding ~path (Store.Bound_to_registered (registered "torn")) with
        | Ok () -> ()
        | Error message -> Alcotest.failf "seeding the binding failed: %s" message);
       Out_channel.with_open_bin path (fun oc -> output_string oc "{not json"));
    let posted = ref 0 in
    let transports =
      { Masc.Keeper_identity_tools.mcp_post =
              { Mcp_client.deadline_s = 60.
              ; send = (fun ~deadline:_ ~url:_ ~headers:_ ~body:_ ->
                  Alcotest.fail "disconnect reached the MCP server")
              }
      ; token_post = (fun ~url:_ ~headers:_ ~body:_ ->
            incr posted;
            Ok (200, "{}"))
      ; discover = (fun ~mcp_url:_ ->
            Ok
              { Keeper_oauth_discovery.resource = "https://mcp.example.com/mcp"
              ; issuer = "https://auth.example.com"
              ; authorize_url = "https://auth.example.com/authorize"
              ; token_url = "https://auth.example.com/token"
              ; registration_url = None
              ; revocation_endpoint = Some "https://auth.example.com/revoke"
              ; scopes_supported = []
              ; supports_pkce_s256 = true
              })
      }
    in
    let receipt =
      match
        Server_keeper_oauth.disconnect ~transports ~clock ~config:(workspace_config ())
          ~keeper ~provider_id:provider.Keeper_oauth_provider.id ~now:0. ()
      with
      | Ok receipt -> receipt
      | Error message -> Alcotest.failf "disconnect failed: %s" message
    in
    let kind, detail =
      match receipt with
      | `Assoc fields ->
        (match List.assoc_opt "revocation" fields with
         | Some (`Assoc revocation) ->
           (match List.assoc_opt "kind" revocation, List.assoc_opt "detail" revocation with
            | Some (`String kind), Some (`String detail) -> kind, detail
            | _ -> Alcotest.fail "the revocation has no kind and detail")
         | _ -> Alcotest.fail "the receipt has no revocation")
      | _ -> Alcotest.fail "the receipt is not an object"
    in
    !posted, kind, detail
  in
  let outcomes =
    List.map
      (fun (label, binding) ->
         let posted, kind, detail = disconnect_with binding in
         check int (label ^ ": nothing was sent to the provider") 0 posted;
         check string (label ^ ": the receipt says it was not sent") "not_sent" kind;
         detail)
      [ "no record of the login's client", `Absent
      ; "an unreadable record", `Unreadable
      ]
  in
  match outcomes with
  | [ absent; unreadable ] ->
    check bool "a torn record is not reported as a missing one" false
      (String.equal absent unreadable)
  | _ -> Alcotest.fail "expected two outcomes"
;;

(* A provider that enforces the two rules real ones were measured to enforce
   on 2026-11-02: the authorize step accepts only a redirect URI registered
   for that client, and a refresh token is redeemed only by the client it was
   issued to. *)
module Fake_provider = struct
  type t =
    { mutable registrations : (string * string) list (* client_id, redirect_uri *)
    ; mutable codes : (string * string) list (* code, client_id *)
    ; mutable refresh_tokens : (string * string) list (* token, client_id *)
    ; mutable refused : string list
    }

  let create () = { registrations = []; codes = []; refresh_tokens = []; refused = [] }

  let register t ~registration_url:_ ~client_name:_ ~redirect_uri =
    let client_id = Printf.sprintf "client-%d" (List.length t.registrations + 1) in
    t.registrations <- (client_id, redirect_uri) :: t.registrations;
    Ok
      { Keeper_oauth_registration.client_id
      ; client_secret = None
      ; secret_expires_at = None
      ; issued_at = 0.
      }

  (* What the browser would come back with: a code, when the client and the
     redirect URI in the authorize URL were registered together. *)
  let authorize t url =
    let query = Uri.query (Uri.of_string url) in
    let one name =
      match List.assoc_opt name query with
      | Some [ value ] -> value
      | Some _ | None -> Alcotest.failf "authorize URL has no single %s" name
    in
    let client_id = one "client_id" and redirect_uri = one "redirect_uri" in
    if List.mem (client_id, redirect_uri) t.registrations
    then (
      let code = "code-for-" ^ client_id in
      t.codes <- (code, client_id) :: t.codes;
      Ok code)
    else (
      t.refused <- ("authorize:" ^ client_id) :: t.refused;
      Error "invalid redirect_uri")

  let token_post t ~url:_ ~headers:_ ~body =
    let form =
      List.map (fun (key, values) -> key, String.concat "," values) (Uri.query_of_encoded body)
    in
    let field name = Option.value (List.assoc_opt name form) ~default:"" in
    let client_id = field "client_id" in
    let issue () =
      let refresh = Printf.sprintf "refresh-%s-%d" client_id (List.length t.refresh_tokens) in
      t.refresh_tokens <- (refresh, client_id) :: t.refresh_tokens;
      Ok
        ( 200
        , Printf.sprintf {|{"access_token":"access-%s","refresh_token":%S,"expires_in":100}|}
            client_id refresh )
    in
    match field "grant_type" with
    | "authorization_code" when List.assoc_opt (field "code") t.codes = Some client_id -> issue ()
    | "refresh_token" when List.assoc_opt (field "refresh_token") t.refresh_tokens = Some client_id ->
      issue ()
    | grant ->
      t.refused <- (grant ^ ":" ^ client_id) :: t.refused;
      Ok (400, {|{"error":"invalid_grant"}|})

  let discover ~mcp_url:_ =
    Ok
      { Keeper_oauth_discovery.resource = "https://mcp.example.com/mcp"
      ; issuer = "https://auth.example.com"
      ; authorize_url = "https://auth.example.com/authorize"
      ; token_url = "https://auth.example.com/token"
      ; registration_url = Some "https://auth.example.com/register"
      ; revocation_endpoint = None
      ; scopes_supported = []
      ; supports_pkce_s256 = true
      }
end

(* The live failure, end to end: the server's callback moves from loopback to
   a public URL between two Keepers' logins. The second login must still
   attach, and the first Keeper must still renew with the client its token
   was issued to. Reusing one install-wide client fails the first at the
   authorize step; renewing with the install's newest client fails the
   second at the token endpoint. *)
let test_logins_survive_a_moved_callback_and_each_keeper_renews () =
  with_disconnect_router
  @@ fun ~base_path ~clock:_ ~router:_ ~token:_ ->
  let provider = provider_or_fail "linear" in
  let provider_id = provider.Keeper_oauth_provider.id in
  let fake = Fake_provider.create () in
  let pending = Keeper_oauth_pending.for_base_path base_path in
  let login ~keeper ~redirect_uri =
    let started =
      match
        Keeper_oauth_session.start ~discover:Fake_provider.discover
          ~register:(Fake_provider.register fake) ~provider ~app:None ~client_name:"masc"
          ~redirect_uri ~keeper ~pending ~now:0. ~ttl_sec:600. ()
      with
      | Ok started -> started
      | Error err ->
        Alcotest.failf "start failed: %s" (Keeper_oauth_session.start_error_to_string err)
    in
    let code =
      match Fake_provider.authorize fake started.Keeper_oauth_session.authorize_url with
      | Ok code -> code
      | Error why -> Alcotest.failf "%s: the provider refused the authorize step: %s" keeper why
    in
    let finished =
      match
        Keeper_oauth_session.finish ~post:(Fake_provider.token_post fake) ~pending
          ~state:started.Keeper_oauth_session.state ~code ~now:0. ()
      with
      | Ok finished -> finished
      | Error err ->
        Alcotest.failf "%s: finish failed: %s" keeper
          (Keeper_oauth_session.finish_error_to_string err)
    in
    match
      Keeper_oauth_pending.publish_credentials pending ~state:started.Keeper_oauth_session.state
        ~write:(Server_keeper_oauth.write_finished_credential ~base_path ~provider ~finished)
    with
    | Keeper_oauth_pending.Published _ ->
      ignore
        (Keeper_oauth_pending.finish pending ~state:started.Keeper_oauth_session.state
           (Ok (Keeper_oauth_pending.Tools_discovered 0)))
    | Keeper_oauth_pending.Publication_superseded -> Alcotest.fail "publication superseded"
    | Keeper_oauth_pending.Publication_failed why -> Alcotest.failf "publication failed: %s" why
  in
  login ~keeper:"first" ~redirect_uri:"http://127.0.0.1:8935/api/v1/keepers/oauth/callback";
  login ~keeper:"second"
    ~redirect_uri:"https://masc.example.org/api/v1/keepers/oauth/callback";
  check (list string) "each login registered its own client" [ "client-1"; "client-2" ]
    (List.rev_map fst fake.Fake_provider.registrations);
  let renew keeper_name =
    Masc.Keeper_identity_tools.renew_if_needed
      ~attachment:(Keeper_oauth_pending.capture_attachment pending ~keeper:keeper_name ~provider_id)
      ~token_post:(Fake_provider.token_post fake) ~discover:Fake_provider.discover ~base_path
      ~keeper_name ~provider ~now:0. ~access_token:"stale" ()
  in
  List.iter
    (fun (keeper_name, client_id) ->
      match renew keeper_name with
      | Ok credential ->
        check string (keeper_name ^ " renews through its own client")
          ("access-" ^ client_id) credential.Masc.Keeper_identity_tools.access_token
      | Error err ->
        Alcotest.failf "%s did not renew: %s" keeper_name
          (Masc.Keeper_identity_tools.renewal_error_message err))
    [ "first", "client-1"; "second", "client-2" ];
  check (list string) "the provider refused nothing" [] fake.Fake_provider.refused
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv name previous
      | None -> Unix.unsetenv name)
    f

(* The login route's own call: a loopback provider registers and authorizes
   with 127.0.0.1 on the bound port, and a provider without one with the base
   URL. Putting the base URL back at that call site fails here. *)
let test_a_login_names_the_callback_its_provider_accepts () =
  with_disconnect_router
  @@ fun ~base_path:_ ~clock ~router:_ ~token:_ ->
  with_env "MASC_HTTP_BASE_URL" "https://masc.example.org" @@ fun () ->
  with_env "MASC_HOST" "127.0.0.1" @@ fun () ->
  with_env "MASC_HTTP_PORT" "55137" @@ fun () ->
  let registered_for = ref [] in
  let register ~registration_url:_ ~client_name:_ ~redirect_uri =
    registered_for := redirect_uri :: !registered_for;
    Ok
      { Keeper_oauth_registration.client_id = "client-for-test"
      ; client_secret = None
      ; secret_expires_at = None
      ; issued_at = 0.
      }
  in
  let transports =
    { Masc.Keeper_identity_tools.mcp_post =
            { Mcp_client.deadline_s = 60.
            ; send = (fun ~deadline:_ ~url:_ ~headers:_ ~body:_ ->
                Alcotest.fail "a login start reached the MCP server")
            }
    ; token_post = (fun ~url:_ ~headers:_ ~body:_ -> Alcotest.fail "a login start redeemed a token")
    ; discover = Fake_provider.discover
    }
  in
  let authorize_redirect provider_id =
    match
      Server_keeper_oauth.start ~transports ~register ~clock ~config:(workspace_config ())
        ~keeper ~provider_id ~now:0. ()
    with
    | Error message -> Alcotest.failf "%s start failed: %s" provider_id message
    | Ok answer ->
      (match member answer "authorize_url" with
       | Some (`String url) ->
         (match List.assoc_opt "redirect_uri" (Uri.query (Uri.of_string url)) with
          | Some [ value ] -> value
          | Some _ | None -> Alcotest.failf "%s authorize URL has no redirect_uri" provider_id)
       | _ -> Alcotest.failf "%s answered no authorize_url" provider_id)
  in
  let loopback = "http://127.0.0.1:55137/api/v1/keepers/oauth/callback" in
  let public = "https://masc.example.org/api/v1/keepers/oauth/callback" in
  check string "asana authorizes with the loopback callback" loopback (authorize_redirect "asana");
  check string "linear authorizes with the base URL callback" public (authorize_redirect "linear");
  check (list string) "and each registered for the callback it authorizes with"
    [ loopback; public ] (List.rev !registered_for)
;;

let () =
  Alcotest.run "server_keeper_oauth_disconnect"
    [ ( "detaching a Keeper from a provider",
        [ Alcotest.test_case
            "the route removes the token, the catalog and writes a receipt"
            `Quick test_the_route_removes_the_token_the_catalog_and_writes_a_receipt;
          Alcotest.test_case "an undeclared provider is refused" `Quick
            test_an_unknown_keeper_or_provider_is_refused;
          Alcotest.test_case "a finished login records the client that redeemed it" `Quick
            test_a_finished_login_records_the_client_that_redeemed_it;
          Alcotest.test_case "disconnect revokes with the login's client and forgets it"
            `Quick test_disconnect_revokes_with_the_logins_client_and_forgets_it;
          Alcotest.test_case "disconnect sends no revoke without the login's client"
            `Quick test_disconnect_sends_no_revoke_without_the_logins_client;
          Alcotest.test_case "logins survive a moved callback and each keeper renews"
            `Quick test_logins_survive_a_moved_callback_and_each_keeper_renews;
          Alcotest.test_case "a login names the callback its provider accepts" `Quick
            test_a_login_names_the_callback_its_provider_accepts;
        ] );
    ]
