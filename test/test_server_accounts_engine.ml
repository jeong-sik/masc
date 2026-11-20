(* The engine of a multi-account installation (RFC
   a-persons-keeper-runs-on-the-engine, S1, §5): the account server starts it
   on the access it published, and the engine comes up on that access with
   no Keeper definition of its own.

   The access, the run registries and the persistence of the Keepers are set
   once per process, so this executable boots once, and its one case reads
   all it checks from that boot. It does not link masc_test_deps, which
   publishes the access of a single user when it starts. The process is
   prepared as the HTTP boot prepares it before the engine (bin/main_eio.ml):
   a canonical base path in MASC_BASE_PATH, the random generator, the
   Eio-aware locks, the clock, the lease with the facts of its stores, and a
   server session switch, which cancels the lanes of the engine when the case
   ends. *)

open Masc
module Read = Authz_boot_mode_read

let workspace =
  match Authz_types.Workspace_id.of_string "workspace-1" with
  | Ok id -> id
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let at_ms = 1_700_000_000_000
let no_login_client = {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|}

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
  let* (_ : string list) = header_lines [] in
  let+ body = Eio.Buf_read.take_all in
  status_line, body
;;

(* One HTTP/1.1 GET on a connection of its own: the status and the body. *)
let get ~net ~port ~headers path =
  Eio.Switch.run (fun sw ->
    let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
    Eio.Flow.copy_string
      (Printf.sprintf
         "GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n%sConnection: close\r\n\r\n"
         path
         port
         (String.concat "" (List.map (fun (name, value) -> name ^ ": " ^ value ^ "\r\n") headers)))
      flow;
    let status_line, body = Eio.Buf_read.parse_exn ~max_size:max_response_bytes response flow in
    match String.split_on_char ' ' status_line with
    | (_ : string) :: status :: (_ : string list) ->
      (match int_of_string_opt status with
       | Some status -> status, body
       | None -> Alcotest.failf "no status in %S" status_line)
    | [] | [ (_ : string) ] -> Alcotest.failf "no status in %S" status_line)
;;

(* The reason a refusal of the account server gives. *)
let error_of label body =
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String error) -> error
     | Some _ | None -> Alcotest.failf "%s: no reason in %S" label body)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Alcotest.failf "%s: the answer is not an object: %S" label body
  | exception Yojson.Json_error detail -> Alcotest.failf "%s: %s: %S" label detail body
;;

(* A token the engine put in the environment of the process. Its value is
   sent and never printed. *)
let token_of name =
  match Sys.getenv_opt name with
  | Some value when not (String.equal (String.trim value) "") -> value
  | Some _ | None -> Alcotest.failf "the engine put no %s in the environment" name
;;

(* An activated installation that has no config root, and the judgment of its
   boot. Each runs in an Eio loop of its own, as [masc auth bootstrap] and the
   entry of the boot run them: the bootstrap must be called from a fiber, and
   only the judged value leaves the loop. No TLS listener, no public identity
   and the default HTTP mode: the listener is the loopback port alone,
   whatever the shell of the run holds. An empty value is read as unset. *)
let installation_judged ~base ~config ~store =
  Eio_main.run
  @@ fun (_ : Eio_unix.Stdenv.base) ->
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
   | Error error -> Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error));
  write_file (Auth.auth_config_file base) no_login_client;
  match Read.boot ~base_path:base ~config_dir:(Some config) ~anonymous_mutations:false with
  | Ok (Read.Multi_account multi_account) -> multi_account
  | Ok (Read.Single_user (_ : Read.single_user)) -> Alcotest.fail "the boot found a single user"
  | Error (first, rest) -> Alcotest.failf "the boot refused: %s" (String.concat "; " (first :: rest))
;;

(* What the case waits for comes within the time the startup watchdog gives
   the engine, or the case fails rather than waits on. *)
let within_the_watchdog ~clock what promise =
  match
    Eio.Time.with_timeout clock (Server_startup_state.watchdog_timeout_sec ()) (fun () ->
      Ok (Eio.Promise.await promise))
  with
  | Ok value -> value
  | Error `Timeout -> Alcotest.failf "%s did not come within the startup watchdog" what
;;

let test_the_engine_comes_up_on_the_access_of_the_installation () =
  Unix.putenv "MASC_HTTPS_PORT" "0";
  Unix.putenv "MASC_HTTP_BASE_URL" "";
  Unix.putenv "MASC_USE_H2" "auto";
  (* The entry of the boot hands the engine a canonical base path
     (bin/main_eio.ml), and so does this case. *)
  let root = Unix.realpath (Filename.temp_dir "server-accounts-engine-" "") in
  Fun.protect ~finally:(fun () -> remove_tree root)
  @@ fun () ->
  let base = Filename.concat root "base" in
  let config = Filename.concat root "config" in
  let store = Filename.concat (Filename.concat root "store") "external.jsonl" in
  let owner = Filename.concat root "owner" in
  Unix.mkdir base 0o700;
  Unix.mkdir owner 0o700;
  let multi_account = installation_judged ~base ~config ~store in
  let lease =
    match Server_startup_takeover.acquire_base_path_lock ~run_dir:owner base with
    | Server_startup_takeover.Base_path_acquired lease -> lease
    | Server_startup_takeover.Base_path_already_owned _
    | Server_startup_takeover.Base_path_rejected _ ->
      Alcotest.fail "the lease of the installation was not acquired"
  in
  Fun.protect ~finally:(fun () -> Server_startup_takeover.release_base_path_lease lease)
  @@ fun () ->
  (match Server_startup_takeover.keep_store_facts lease with
   | Server_startup_takeover.Store_facts_kept -> ()
   | Server_startup_takeover.Lease_not_held -> Alcotest.fail "the lease just taken is not held");
  Unix.putenv Env_config_core.base_path_env_key base;
  Workspace_utils_backend_setup.cache_resolved_base_path base;
  Eio_main.run
  @@ fun env ->
  Crypto_rng.ensure_default ();
  Eio_guard.enable ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Server_session_switch.run
  @@ fun ~runtime_sw sw ->
  let port = free_port () in
  let started, start = Eio.Promise.create () in
  let listening, set_listening = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    match
      Server_accounts.run
        ~sw
        ~env
        ~address:loopback
        ~port
        ~lease
        ~on_ready:(Eio.Promise.resolve set_listening)
        ~start_engine:(fun access ->
          Eio.Promise.resolve
            start
            ( access
            , Server_runtime_bootstrap.start_engine
                ~sw
                ~runtime_sw
                ~env
                ~accept_store_quarantine:false
                access ))
        multi_account
    with
    | Ok () -> ()
    | Error refusal -> Alcotest.fail (Server_accounts.refusal_to_string refusal));
  let clock = Eio.Stdenv.clock env in
  let access, engine = within_the_watchdog ~clock "the start of the engine" started in
  (match Runtime_account_access.published_access access with
   | Runtime_account_access.Multi_account { zone = _; base_path; now = _ } ->
     Alcotest.(check string) "the engine starts on the access of the installation" base base_path
   | Runtime_account_access.Single_user (_ : Read.single_user) ->
     Alcotest.fail "the engine started on the access of a single user");
  (* A failure before readiness ends the process. A failure in the lanes
     after readiness leaves the promise unresolved and the phase degraded, so
     the wait is bounded. *)
  let state = within_the_watchdog ~clock "the state of the engine" engine in
  let startup = Server_startup_state.snapshot () in
  Alcotest.(check bool) "the engine is ready" true startup.Server_startup_state.state_ready;
  (match startup.Server_startup_state.phase with
   | Server_startup_state.Ready | Server_startup_state.Lazy -> ()
   | Server_startup_state.Blocking -> Alcotest.fail "the engine answered while still blocking"
   | Server_startup_state.Degraded ->
     (match startup.Server_startup_state.last_error with
      | Some error -> Alcotest.failf "the engine is degraded: %s" error
      | None -> Alcotest.fail "the engine is degraded with no error recorded"));
  Alcotest.(check string)
    "the state of the engine is of the base path of the installation"
    base
    (Mcp_server.workspace_config state).Workspace.base_path;
  Alcotest.(check (option (list string)))
    "the folder of Keeper definitions holds none after the engine made the config root"
    (Some [])
    (Keeper_types_profile_toml_io.keeper_toml_files
       (Config_dir_resolver.keepers_dir_for_base_path ~base_path:base));
  (* The engine put the admin token and the internal Keeper token of the
     operator in the environment of the process. The gate of the account
     server reads both as legacy credentials, and a route of a person refuses
     them (RFC §5, "the tokens of the operator reach no person"). *)
  within_the_watchdog ~clock "the listener of the account server" listening;
  let net = Eio.Stdenv.net env in
  let legacy = Auth_gate.reason_to_string Auth_gate.Legacy_credential_forbidden in
  List.iter
    (fun (label, header) ->
      let status, body = get ~net ~port ~headers:[ header ] Auth_preview.provider_accounts_path in
      Alcotest.(check int) (label ^ ": the status") 401 status;
      Alcotest.(check string) (label ^ ": the reason") legacy (error_of label body))
    [ ( "the admin token of the boot"
      , (Server_auth.authorization_header_name, "Bearer " ^ token_of Env_config_core.admin_token_env_key)
      )
    ; ( "the internal Keeper token of the boot"
      , (Server_auth.internal_token_header_name, token_of Auth.internal_keeper_token_env_key) )
    ]
;;

let () =
  Alcotest.run
    "server_accounts_engine"
    [ ( "the engine of a multi-account installation"
      , [ Alcotest.test_case
            "it comes up on the access of the installation"
            `Quick
            test_the_engine_comes_up_on_the_access_of_the_installation
        ] )
    ]
;;
