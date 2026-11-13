module Upgrade = Server_upgrade_preparation
(* What the port an account server announces said to one [GET /health]. *)
type account_health =
  | Answers of string option  (* A 200, and the version it names when one is read. *)
  | No_answer
type observation =
  | Free
  | Same_workspace of string
  | Other_workspace of string
  | Unknown_server
  | Account_server of { port : int; health : account_health }
let error_message = function
  | Upgrade.Admin_required -> "The running workspace rejected local operator access. Sign in before restarting it."
  | Different_workspace -> "This server belongs to another workspace. Choose a different port."
  | Incumbent_changed -> "The running server changed after inspection. Refresh setup before restarting it."
  | Owner_unavailable -> "The running workspace owner could not be verified."
  | Invalid_health -> "The selected port did not return a valid workspace identity."
  | Already_requested -> "A graceful shutdown was already requested."
  | Closed -> "This server inspection is no longer active. Refresh setup."
  | Port_unavailable -> "The selected port could not be inspected."
let emit json = print_endline (Yojson.Safe.to_string json)
let with_http f = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  Eio_context.set_env env; Eio_context.set_switch sw;
  Eio_context.set_net (Eio.Stdenv.net env); Eio_context.set_clock (Eio.Stdenv.clock env);
  Masc_http_client.with_scoped_pool ~sw ~env (fun () -> f sw (Eio.Stdenv.clock env))))
let decode ~base_path body =
  match Upgrade.decode_health body with
  | Ok identity when identity.base_path = base_path -> Same_workspace identity.version
  | Ok identity -> Other_workspace identity.base_path
  | Error _ -> Unknown_server
let port_free port =
  try
    let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,port)); true)
  with Unix.Unix_error _ -> false
(* The owner is found through the lease root of its BasePath. A root that
   cannot be made holds no lease to find, as a lease that cannot be read. *)
let owner_lease_run_dir ~base_path =
  Server_startup_takeover.lease_run_dir (Host_config.host ()).base_path_lease_root ~base_path
  |> Result.map_error (fun (_ : Server_startup_takeover.base_path_lock_rejection) ->
    Upgrade.Owner_unavailable)
(* What the kernel shows of the process that holds a workspace, read without
   making anything ([Upgrade.holder]). *)
let holder ~base_path ~port =
  Upgrade.holder (Host_config.host ()).base_path_lease_root ~base_path ~port
  |> Result.map_error Server_startup_takeover.owner_capture_error_to_string
let owner_unread ~base_path reason =
  Printf.sprintf "The owner of %s could not be checked (%s). No server was changed." base_path reason
(* What the port says of itself: the answer of this command before accounts. *)
let port_says ~clock ~base_path ~port =
  match Masc_http_client.get_sync ~clock ~headers:[]
    ~url:(Masc_network_defaults.masc_http_loopback_origin ~port ^ Server_health_paths.full) () with
  | Ok (200, body) -> decode ~base_path body
  | Ok _ | Error _ -> if port_free port then Free else Unknown_server
(* The [/health] of an account server names no workspace, so its port alone
   would read as another service. The kernel says which port the owner of the
   workspace announces, the one asked about or another. The answer of that
   port only says whether it serves and which version, and is read inside a
   window, since a stopped server accepts and says nothing. *)
let account_health ~clock ~port =
  match Masc_http_client.get_sync ~clock
    ~timeout_sec:Masc_http_client.default_request_timeout_sec ~headers:[]
    ~url:(Masc_network_defaults.masc_http_loopback_origin ~port ^ Server_health_paths.health) () with
  | Ok (200, body) -> Answers (Server_accounts.health_version body)
  | Ok _ | Error _ -> No_answer
let inspect ~base_path ~port =
  let base_path = Masc_cli_setup.preflight_base_path base_path in
  let base_path = try Unix.realpath base_path with Unix.Unix_error _ -> base_path in
  (* A port named free would be taken for a workspace a server can start
     on. No boot runs one on an account mode it does not know, so nothing is
     said of the port there. *)
  match Authz_boot_mode_read.asked ~base_path with
  | Error refusal ->
    emit (`Assoc ["schema", `String "masc.setup_server_unread.v1"; "read_only", `Bool true;
      "error", `String (Authz_boot_mode_read.refused_line ~base_path refusal
                        ^ ". No server was changed.")]);
    1
  | Ok asked ->
  let observed = with_http (fun _ clock ->
    match holder ~base_path ~port with
    | Ok (Upgrade.Held_by_account_server { port }) ->
      Ok (Account_server { port; health = account_health ~clock ~port })
    | Ok (Upgrade.Held_by_nobody | Upgrade.Held_without_announcement) ->
      Ok (port_says ~clock ~base_path ~port)
    | Error reason ->
      (* Whether an account server holds the workspace is not known. Where
         the config asks for accounts no status is given: a port named free
         could be taken for a workspace with no server. Where it does not,
         the port answers as it did before accounts, whatever the lease. *)
      (match asked with
       | Authz_boot_mode.Asks_multi_account -> Error reason
       | Authz_boot_mode.Asks_single_user -> Ok (port_says ~clock ~base_path ~port))) in
  match observed with
  | Error reason ->
    emit (`Assoc ["schema", `String "masc.setup_server_unread.v1"; "read_only", `Bool true;
      "error", `String (owner_unread ~base_path reason)]);
    1
  | Ok observed ->
  let fields = match observed with
    | Free -> ["status", `String "free"]
    | Same_workspace version -> ["status", `String "same_workspace"; "server_version", `String version]
    | Other_workspace path -> ["status", `String "other_workspace"; "server_workspace", `String path]
    | Unknown_server -> ["status", `String "unknown_server"]
    | Account_server { port; health } ->
      ["status", `String "account_server"; "server_port", `Int port]
      @ (match health with
         | Answers (Some version) -> ["server_answers", `Bool true; "server_version", `String version]
         | Answers None -> ["server_answers", `Bool true]
         | No_answer -> ["server_answers", `Bool false]) in
  let alternative = match observed with
    | Free | Same_workspace _ | Account_server _ -> []
    | Other_workspace _ | Unknown_server ->
      (match Upgrade.suggest_loopback_port () with Ok port -> ["suggested_port", `Int port] | Error _ -> []) in
  emit (`Assoc (["schema", `String "masc.setup_server.v1"; "read_only", `Bool true;
    "installed_version", `String Runtime_build_version.current] @ fields @ alternative)); 0
let with_selected_owner ~sw ~clock ~base_path ~port ~agent ~expected_version ~login use =
  let open Result.Syntax in
  let* () = match Masc_http_client.get_sync ~clock ~headers:[]
    ~url:(Masc_network_defaults.masc_http_loopback_origin ~port ^ Server_health_paths.full) () with
    | Ok (200, body) -> Upgrade.authorize_initial ~base_path ~expected_version ~body
        ~login:(fun () -> login () = 0)
    | Ok _ | Error _ -> Error Upgrade.Invalid_health in
  let* token = match Auth_login.read_persisted_http_token ~base_path ~agent_name:agent with
    | None -> Error Upgrade.Admin_required | Some token -> Ok token in
  let* run_dir = owner_lease_run_dir ~base_path in
  let headers = ["authorization", "Bearer " ^ token; "x-masc-agent", agent] in
  let* owner = Upgrade.prepare ~sw ~clock ~headers ~run_dir ~base_path ~port in
  Fun.protect ~finally:(fun () -> Upgrade.close owner) (fun () ->
    if (Upgrade.incumbent owner).version <> expected_version then Error Upgrade.Incumbent_changed
    else use owner)
type request_phase = Request_not_confirmed | Request_confirmed
type stop_refusal =
  | Owner_not_stopped of Upgrade.error
  | Owner_unread of { base_path : string; reason : string }
  | Nobody_holds_workspace
  | Account_server_holds_workspace
let stop_refusal_message = function
  | Owner_not_stopped error -> error_message error
  | Owner_unread { base_path; reason } -> owner_unread ~base_path reason
  | Nobody_holds_workspace ->
    "No process holds the lease this MASC reads for this workspace, so no server was signed in \
     to or stopped."
  | Account_server_holds_workspace ->
    "This workspace is held by its account server, which no local operator signs in to. \
     masc restart stops and replaces it."
(* The stop below signs a local operator in and sends its bearer to the port.
   The kernel is asked first, as [masc restart] asks it, and before anything
   is made: where nothing holds the lease, what answers on the port is not
   the owner this command stops (a server of a MASC that kept its lease
   elsewhere answers so too), and an owner that announces the port of an
   account server, the one asked about or another, is not signed in to,
   whatever answers on the port. An owner that announces
   nothing is taken for the server of a single user. An account server is
   one too until it announces; it does not answer the health of a single
   user on its port, and the stop goes no further than that answer. *)
let stoppable ~base_path ~port =
  match holder ~base_path ~port with
  | Error reason -> Error (Owner_unread { base_path; reason })
  | Ok Upgrade.Held_by_nobody -> Error Nobody_holds_workspace
  | Ok (Upgrade.Held_by_account_server { port = (_ : int) }) -> Error Account_server_holds_workspace
  | Ok Upgrade.Held_without_announcement -> Ok ()
let stop ~base_path ~port ~agent ~expected_version ~login =
  let phase = ref Request_not_confirmed in
  let not_stopped answer = Result.map_error (fun error -> Owner_not_stopped error) answer in
  let result = try
    let base_path = Unix.realpath (Env_config.normalize_masc_base_path_input base_path) in
    with_http (fun sw clock ->
      let open Result.Syntax in
      let* () = stoppable ~base_path ~port in
      let* run_dir = not_stopped (owner_lease_run_dir ~base_path) in
      not_stopped @@
      with_selected_owner ~sw ~clock ~base_path ~port ~agent ~expected_version ~login (fun owner ->
        match Upgrade.request_termination_and_observe owner ~observe:(fun () ->
          phase := Request_confirmed;
          prerr_endline "Waiting for this workspace to shut down gracefully. Ctrl-C stops waiting; setup never forces it down.";
          let rec wait attempts =
            let* state = Upgrade.replacement_readiness ~run_dir ~base_path ~port in
            match state with
            | Owner_draining when attempts > 0 ->
              Eio.Time.sleep clock 0.2; wait (attempts - 1)
            | Port_busy when attempts > 0 ->
              Eio.Time.sleep clock 0.2; wait (attempts - 1)
            | (Owner_draining | Port_busy | Replacement_can_start) as state -> Ok state in
          wait 25) with
        | Not_requested error -> Error error
        | Requested observation -> Ok observation))
    with Unix.Unix_error _ | Sys_error _ ->
      (match !phase with
       | Request_not_confirmed -> Error (Owner_not_stopped Upgrade.Owner_unavailable)
       | Request_confirmed -> Ok (Error Upgrade.Owner_unavailable)) in
  match result with
  | Error refusal -> emit (`Assoc ["schema", `String "masc.setup_server_error.v1";
    "termination_requested", `Bool false; "error", `String (stop_refusal_message refusal)]); 1
  | Ok observation ->
    let readiness, detail = match observation with
      | Ok Upgrade.Owner_draining -> "owner_draining", []
      | Ok Port_busy -> "port_busy", []
      | Ok Replacement_can_start -> "replacement_can_start", []
      | Error error -> "observation_failed", ["observation_error", `String (error_message error)] in
    emit (`Assoc (["schema", `String "masc.setup_server_shutdown.v1";
      "termination_requested", `Bool true; "readiness", `String readiness] @ detail)); 0
