module Upgrade = Server_upgrade_preparation
(* What the port a server announces said to one [GET /health]. *)
type compact_answer =
  | Answers of string option  (* A 200, and the version it names when one is read. *)
  | No_answer
type observation =
  | Free
  | Unknown_server
  | Same_workspace of { pid : int; health : compact_answer }
  | Same_workspace_on_another_port of { pid : int; port : int }
  | Owner_unannounced of { pid : int }
  | Account_server of { port : int; health : compact_answer }
let error_message = function
  | Upgrade.Admin_required -> "The running workspace rejected local operator access. Sign in before restarting it."
  | Incumbent_changed -> "The server that announces this port changed after inspection. Refresh setup before restarting it."
  | Owner_unavailable -> "The running workspace owner could not be verified."
  | Invalid_health -> "The server of this workspace did not answer its version on the selected port."
  | Already_requested -> "A graceful shutdown was already requested."
  | Closed -> "This server inspection is no longer active. Refresh setup."
  | Port_unavailable -> "The selected port could not be inspected."
let emit json = print_endline (Yojson.Safe.to_string json)
let with_http f = Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
  Eio_context.set_env env; Eio_context.set_switch sw;
  Eio_context.set_net (Eio.Stdenv.net env); Eio_context.set_clock (Eio.Stdenv.clock env);
  Masc_http_client.with_scoped_pool ~sw ~env (fun () -> f sw (Eio.Stdenv.clock env))))
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
   making anything ([Upgrade.owner_without_making]). *)
let owner ~base_path ~port =
  Upgrade.owner_without_making (Host_config.host ()).base_path_lease_root ~base_path ~port
  |> Result.map_error Server_startup_takeover.owner_capture_error_to_string
let owner_unread ~base_path reason =
  Printf.sprintf "The owner of %s could not be checked (%s). No server was changed." base_path reason
(* The kernel names the server and the port it announces. The answer of that
   port only says whether it serves and which version, read without
   credentials inside a window, since a stopped server accepts and says
   nothing. *)
let compact_answer ~clock ~port ~decode =
  match Masc_http_client.get_sync ~clock
    ~timeout_sec:Masc_http_client.default_request_timeout_sec ~headers:[]
    ~url:(Masc_network_defaults.masc_http_loopback_origin ~port ^ Server_health_paths.health) () with
  | Ok (200, body) -> Answers (decode body)
  | Ok _ | Error _ -> No_answer
(* HIGH-RISK-UNREVIEWED: the status the installer offers a stop on. Only the
   server the kernel names as lease owner and announcer of [port] is
   [same_workspace]; whatever answers on a port that no owner announces is
   [unknown_server]. An owner that cannot be read gives no status. *)
let inspect ~base_path ~port =
  let base_path = Masc_cli_setup.preflight_base_path base_path in
  let base_path = try Unix.realpath base_path with Unix.Unix_error _ -> base_path in
  let observed = with_http (fun _ clock ->
    match owner ~base_path ~port with
    | Error reason -> Error reason
    | Ok Upgrade.Unowned -> Ok (if port_free port then Free else Unknown_server)
    | Ok (Upgrade.Single_user_server_here server) ->
      Ok (Same_workspace { pid = Upgrade.single_user_server_pid server;
        health = compact_answer ~clock ~port ~decode:Upgrade.compact_health_version })
    | Ok (Upgrade.Single_user_server_elsewhere { pid; port = announced }) ->
      Ok (Same_workspace_on_another_port { pid; port = announced })
    | Ok (Upgrade.Owner_unannounced { pid }) -> Ok (Owner_unannounced { pid })
    | Ok (Upgrade.Account_server_here { pid = (_ : int) }) ->
      Ok (Account_server { port; health = compact_answer ~clock ~port ~decode:Server_accounts.health_version })
    | Ok (Upgrade.Account_server_elsewhere { pid = (_ : int); port = announced }) ->
      Ok (Account_server { port = announced;
        health = compact_answer ~clock ~port:announced ~decode:Server_accounts.health_version })) in
  match observed with
  | Error reason ->
    emit (`Assoc ["schema", `String "masc.setup_server_unread.v1"; "read_only", `Bool true;
      "error", `String (owner_unread ~base_path reason)]);
    1
  | Ok observed ->
  let answers = function
    | Answers (Some version) -> ["server_answers", `Bool true; "server_version", `String version]
    | Answers None -> ["server_answers", `Bool true]
    | No_answer -> ["server_answers", `Bool false] in
  let fields = match observed with
    | Free -> ["status", `String "free"]
    | Unknown_server -> ["status", `String "unknown_server"]
    | Same_workspace { pid; health } ->
      ["status", `String "same_workspace"; "server_pid", `Int pid] @ answers health
    | Same_workspace_on_another_port { pid; port } ->
      ["status", `String "same_workspace_on_another_port"; "server_pid", `Int pid; "server_port", `Int port]
    | Owner_unannounced { pid } -> ["status", `String "owner_unannounced"; "server_pid", `Int pid]
    | Account_server { port; health } ->
      ["status", `String "account_server"; "server_port", `Int port] @ answers health in
  let alternative = match observed with
    | Free | Same_workspace _ | Same_workspace_on_another_port _ | Owner_unannounced _ | Account_server _ -> []
    | Unknown_server ->
      (match Upgrade.suggest_loopback_port () with Ok port -> ["suggested_port", `Int port] | Error _ -> []) in
  emit (`Assoc (["schema", `String "masc.setup_server.v1"; "read_only", `Bool true;
    "installed_version", `String Runtime_build_version.current] @ fields @ alternative)); 0
(* HIGH-RISK-UNREVIEWED: the admin credential is minted only after the kernel
   names [server] again and its port answers [expected_version]
   ([Upgrade.authorize_initial]), and its bearer goes only to [server]
   ([Upgrade.prepare] and [Upgrade.request_termination] ask the kernel again
   before each send). *)
let with_selected_owner ~sw ~clock ~server ~agent ~expected_version ~login use =
  let open Result.Syntax in
  let* () = Upgrade.authorize_initial ~clock server ~expected_version ~login:(fun () -> login () = 0) in
  let base_path = Upgrade.single_user_server_base_path server in
  let* token = match Auth_login.read_persisted_http_token ~base_path ~agent_name:agent with
    | None -> Error Upgrade.Admin_required | Some token -> Ok token in
  let headers = ["authorization", "Bearer " ^ token; "x-masc-agent", agent] in
  let* owner = Upgrade.prepare ~sw ~clock ~headers server in
  Fun.protect ~finally:(fun () -> Upgrade.close owner) (fun () -> use owner)
type request_phase = Request_not_confirmed | Request_confirmed
type stop_refusal =
  | Owner_not_stopped of Upgrade.error
  | Owner_unread of { base_path : string; reason : string }
  | Nobody_holds_workspace
  | Account_server_holds_workspace
  | Owner_unannounced_stop of { base_path : string; port : int; pid : int }
  | Serves_another_port of { base_path : string; port : int; pid : int; announced : int }
let stop_refusal_message = function
  | Owner_not_stopped error -> error_message error
  | Owner_unread { base_path; reason } -> owner_unread ~base_path reason
  | Nobody_holds_workspace ->
    "No process holds the lease this MASC reads for this workspace, so no server was signed in \
     to or stopped."
  | Account_server_holds_workspace ->
    "This workspace is held by its account server, which no local operator signs in to. \
     masc restart stops and replaces it."
  | Owner_unannounced_stop { base_path; port; pid } ->
    Upgrade.owner_sentence ~base_path ~port (Upgrade.Owner_unannounced { pid })
    ^ " No server was signed in to or stopped."
  | Serves_another_port { base_path; port; pid; announced } ->
    Printf.sprintf "The server of %s (pid %d) serves port %d, not port %d. No server was signed \
                    in to or stopped; run setup with --port %d." base_path pid announced port announced
(* HIGH-RISK-UNREVIEWED: the stop below signs a local operator in and sends
   its bearer to the port. The kernel is asked first, as [masc restart] asks
   it, and before anything is made. Only the server of a single user that the
   kernel names as lease owner and announcer of [port] goes on. Where nothing
   holds the lease, what answers on the port is not the owner this command
   stops; an account server is not signed in to; an owner that announces
   nothing, or another port, is named and left alone. *)
let stoppable ~base_path ~port =
  match owner ~base_path ~port with
  | Error reason -> Error (Owner_unread { base_path; reason })
  | Ok (Upgrade.Single_user_server_here server) -> Ok server
  | Ok Upgrade.Unowned -> Error Nobody_holds_workspace
  | Ok (Upgrade.Account_server_here { pid = (_ : int) }
       | Upgrade.Account_server_elsewhere { pid = (_ : int); port = (_ : int) }) ->
    Error Account_server_holds_workspace
  | Ok (Upgrade.Owner_unannounced { pid }) -> Error (Owner_unannounced_stop { base_path; port; pid })
  | Ok (Upgrade.Single_user_server_elsewhere { pid; port = announced }) ->
    Error (Serves_another_port { base_path; port; pid; announced })
let stop ~base_path ~port ~agent ~expected_version ~login =
  let phase = ref Request_not_confirmed in
  let not_stopped answer = Result.map_error (fun error -> Owner_not_stopped error) answer in
  let result = try
    let base_path = Unix.realpath (Env_config.normalize_masc_base_path_input base_path) in
    with_http (fun sw clock ->
      let open Result.Syntax in
      let* server = stoppable ~base_path ~port in
      let* run_dir = not_stopped (owner_lease_run_dir ~base_path) in
      not_stopped @@
      with_selected_owner ~sw ~clock ~server ~agent ~expected_version ~login (fun owner ->
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
