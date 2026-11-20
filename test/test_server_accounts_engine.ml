(* The engine of a multi-account installation (RFC
   a-persons-keeper-runs-on-the-engine, S1, §5): the account server starts it
   on the access it published. The engine comes up on that access with no
   Keeper definition of its own, and a store it refuses ends the process.

   The access, the run registries and the persistence of the Keepers are set
   once per process, so each boot has a process of its own: the boot that
   comes up runs in this one, and the boot that ends its process runs in a
   child of this executable. The executable does not link masc_test_deps,
   which publishes the access of a single user when it starts. A process is
   prepared as the HTTP boot prepares it before the engine (bin/main_eio.ml):
   the lease with the facts of its stores, a canonical base path in
   MASC_BASE_PATH, the random generator, the Eio-aware locks, the clock, and a
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

(* ---- the installation and the process ---- *)

type installation =
  { root : string
  ; base : string
  ; config : string
  ; owner : string
  }

(* The places of an installation below [root]. *)
let installation_at root =
  { root
  ; base = Filename.concat root "base"
  ; config = Filename.concat root "config"
  ; owner = Filename.concat root "owner"
  }
;;

(* No TLS listener, no public identity and the default HTTP mode: the
   listener is the loopback port alone, whatever the shell of the run holds.
   An empty value is read as unset. A child process of the case inherits
   them. *)
let listen_on_loopback_alone () =
  Unix.putenv "MASC_HTTPS_PORT" "0";
  Unix.putenv "MASC_HTTP_BASE_URL" "";
  Unix.putenv "MASC_USE_H2" "auto"
;;

(* An activated installation with no config root, in a temporary directory
   that the case removes. The entry of the boot hands the engine a canonical
   base path (bin/main_eio.ml), and so does this case. The bootstrap runs in
   an Eio loop of its own, as [masc auth bootstrap] runs it: it must be
   called from a fiber.

   The config root is the one of the installation, whatever the shell of the
   run holds: no MASC_CONFIG_DIR, which a run that allows test overrides
   would follow out of the temporary directory, and the default bootstrap,
   which makes the folder of definitions the case reads. An empty value is
   read as unset, and the child process of a case inherits it. *)
let with_installation run =
  Unix.putenv Env_config_core.config_dir_env_key "";
  Unix.putenv "MASC_CONFIG_BOOTSTRAP" "";
  let root = Unix.realpath (Filename.temp_dir "server-accounts-engine-" "") in
  Fun.protect ~finally:(fun () -> remove_tree root)
  @@ fun () ->
  let installation = installation_at root in
  Unix.mkdir installation.base 0o700;
  Unix.mkdir installation.owner 0o700;
  Eio_main.run (fun (_ : Eio_unix.Stdenv.base) ->
    match
      Authz_bootstrap.fresh_bootstrap
        { Authz_bootstrap.base_path = installation.base
        ; config_dir = Some installation.config
        ; external_store = Filename.concat (Filename.concat root "store") "external.jsonl"
        ; workspace_id = workspace
        ; now_ms = (fun () -> at_ms)
        }
    with
    | Ok _ -> ()
    | Error error -> Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error));
  write_file (Auth.auth_config_file installation.base) no_login_client;
  run installation
;;

(* The judgment of the boot, in an Eio loop of its own as the entry of the
   boot runs it. Only the judged value leaves the loop. *)
let judged installation =
  Eio_main.run
  @@ fun (_ : Eio_unix.Stdenv.base) ->
  match
    Read.boot
      ~base_path:installation.base
      ~config_dir:(Some installation.config)
      ~anonymous_mutations:false
  with
  | Ok (Read.Multi_account multi_account) -> multi_account
  | Ok (Read.Single_user (_ : Read.single_user)) -> Alcotest.fail "the boot found a single user"
  | Error (first, rest) -> Alcotest.failf "the boot refused: %s" (String.concat "; " (first :: rest))
;;

(* The process as the HTTP entry prepares it before the engine: the BasePath
   lease with the facts of its stores, the canonical base path in
   MASC_BASE_PATH, and in the loop of the server the random generator, the
   Eio-aware locks, the clock and a server session switch. *)
let with_the_process_of_a_server installation run =
  let lease =
    match
      Server_startup_takeover.acquire_base_path_lock ~run_dir:installation.owner installation.base
    with
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
  Unix.putenv Env_config_core.base_path_env_key installation.base;
  Workspace_utils_backend_setup.cache_resolved_base_path installation.base;
  Eio_main.run
  @@ fun env ->
  Crypto_rng.ensure_default ();
  Eio_guard.enable ();
  Time_compat.set_clock (Eio.Stdenv.clock env);
  Server_session_switch.run (fun ~runtime_sw sw -> run ~env ~runtime_sw ~sw lease)
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

(* ---- the engine that comes up ---- *)

let test_the_engine_comes_up_on_the_access_of_the_installation () =
  listen_on_loopback_alone ();
  with_installation
  @@ fun installation ->
  let multi_account = judged installation in
  let base = installation.base in
  with_the_process_of_a_server installation
  @@ fun ~env ~runtime_sw ~sw lease ->
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
          let engine =
            Server_runtime_bootstrap.start_engine
              ~sw
              ~runtime_sw
              ~env
              ~accept_store_quarantine:false
              access
          in
          Eio.Promise.resolve start (access, engine);
          engine)
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
  (* A failure before readiness ends the process. The promise is resolved at
     readiness, before the lanes start, so a lane that failed by the time the
     case reads the phase shows as degraded below. *)
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
  (* The probe of the account server waits for this engine, which is ready
     above. *)
  let status, body = get ~net ~port ~headers:[] Server_health_paths.readiness in
  Alcotest.(check (pair int string))
    "the readiness of the account server once its engine is ready"
    (200, {|{"ready":true}|})
    (status, Yojson.Safe.to_string (Yojson.Safe.from_string body));
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

(* ---- the engine that a store refuses ---- *)

(* The boot of an installation whose store the engine refuses ends its
   process, so it runs in a child: this executable again, with [child_flag]
   and the root of the installation. *)
let child_flag = "--boot-the-installation-at"

(* What the child leaves beside the installation for the parent. It makes
   [engine_started] when the account server hands the engine the access, and
   [own_failure], with the exception, when it ends on an exception of its
   own. The parent counts an end of the child as the engine's only with the
   first and without the second. *)
let engine_started root = Filename.concat root "engine-started"
let own_failure root = Filename.concat root "own-failure"

(* The child: the judgment, the process of a server and the account server,
   which starts the engine. *)
let boot_the_installation_at root =
  let installation = installation_at root in
  let multi_account = judged installation in
  with_the_process_of_a_server installation
  @@ fun ~env ~runtime_sw ~sw lease ->
  match
    Server_accounts.run
      ~sw
      ~env
      ~address:loopback
      ~port:(free_port ())
      ~lease
      ~start_engine:(fun access ->
        write_file (engine_started root) "";
        Server_runtime_bootstrap.start_engine ~sw ~runtime_sw ~env ~accept_store_quarantine:false access)
      multi_account
  with
  | Ok () -> ()
  | Error refusal -> Alcotest.fail (Server_accounts.refusal_to_string refusal)
;;

let poll_interval_s = 0.05

(* The status of the child when the parent saw it end by [deadline], or
   [None]. A child still running after [deadline] is killed and reaped. The
   time is read after each wait, so an end seen by [deadline] came by it. *)
let rec end_of_child pid ~deadline =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> end_of_child pid ~deadline
  | 0, (_ : Unix.process_status) ->
    if Unix.gettimeofday () > deadline then Unix.kill pid Sys.sigkill;
    Unix.sleepf poll_interval_s;
    end_of_child pid ~deadline
  | (_ : int), status -> if Unix.gettimeofday () > deadline then None else Some status
;;

let test_a_refused_store_ends_the_process () =
  listen_on_loopback_alone ();
  with_installation
  @@ fun installation ->
  (* A Keeper configuration journal that does not decode. The first step of
     the engine reads it before it builds any state, and refuses it
     (Keeper_config_recovery_failed). *)
  write_file
    (Keeper_config_journal.journal_path_for_base_path ~base_path:installation.base)
    "not a journal";
  (* The startup watchdog of the child ends an engine that is not ready one
     period after the engine starts, and the engine starts after the spawn.
     The parent waits one period from before the spawn, so an end it sees
     within the wait is not the watchdog's. *)
  let deadline = Unix.gettimeofday () +. Server_startup_state.watchdog_timeout_sec () in
  let pid =
    Unix.create_process
      Sys.executable_name
      [| Sys.executable_name; child_flag; installation.root |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
  in
  let ended = end_of_child pid ~deadline in
  let root = installation.root in
  if Sys.file_exists (own_failure root)
  then
    Alcotest.failf
      "the child ended on an exception of its own: %s"
      (In_channel.with_open_bin (own_failure root) In_channel.input_all);
  Alcotest.(check bool) "the account server started the engine" true (Sys.file_exists (engine_started root));
  match ended with
  | None -> Alcotest.fail "the process did not end before the startup watchdog could end it"
  | Some (Unix.WEXITED 0) -> Alcotest.fail "the process ended with 0"
  | Some (Unix.WEXITED (_ : int)) -> ()
  | Some (Unix.WSIGNALED signal) -> Alcotest.failf "the process ended on signal %d" signal
  | Some (Unix.WSTOPPED signal) -> Alcotest.failf "the process stopped on signal %d" signal
;;

(* The case of the refused store runs first: it boots in a child, and this
   process has started no engine when it spawns one. *)
let () =
  match Array.to_list Sys.argv with
  | [ (_ : string); flag; root ] when String.equal flag child_flag ->
    (try boot_the_installation_at root with
     | exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       write_file (own_failure root) (Printexc.to_string exn);
       Printexc.raise_with_backtrace exn backtrace)
  | (_ : string list) ->
    Alcotest.run
      "server_accounts_engine"
      [ ( "the engine of a multi-account installation"
        , [ Alcotest.test_case
              "a store it refuses ends the process"
              `Quick
              test_a_refused_store_ends_the_process
          ; Alcotest.test_case
              "it comes up on the access of the installation"
              `Quick
              test_the_engine_comes_up_on_the_access_of_the_installation
          ] )
      ]
;;
