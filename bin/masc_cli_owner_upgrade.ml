module Upgrade = Server_upgrade_preparation
type observation = Free | Same_workspace of string | Other_workspace of string | Unknown_server
let error_message = function
  | Upgrade.Admin_required -> "The running workspace rejected local operator access. Sign in before restarting it."
  | Different_workspace -> "This server belongs to another workspace. Choose a different port."
  | Incumbent_changed -> "The running server changed after inspection. Refresh setup before restarting it."
  | Owner_unavailable -> "The running workspace owner could not be verified. No process was stopped."
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
let inspect ~base_path ~port =
  let base_path = Masc_cli_setup.preflight_base_path base_path in
  let base_path = try Unix.realpath base_path with Unix.Unix_error _ -> base_path in
  let observed = with_http (fun _ clock ->
    match Masc_http_client.get_sync ~clock ~headers:[]
      ~url:(Printf.sprintf "http://127.0.0.1:%d/health?full=1" port) () with
    | Ok (200, body) -> decode ~base_path body
    | Ok _ | Error _ -> if port_free port then Free else Unknown_server) in
  let fields = match observed with
    | Free -> ["status", `String "free"]
    | Same_workspace version -> ["status", `String "same_workspace"; "server_version", `String version]
    | Other_workspace path -> ["status", `String "other_workspace"; "server_workspace", `String path]
    | Unknown_server -> ["status", `String "unknown_server"] in
  let alternative = match observed with
    | Free | Same_workspace _ -> []
    | Other_workspace _ | Unknown_server ->
      (match Upgrade.suggest_loopback_port () with Ok port -> ["suggested_port", `Int port] | Error _ -> []) in
  emit (`Assoc (["schema", `String "masc.setup_server.v1"; "read_only", `Bool true;
    "installed_version", `String Runtime_build_version.current] @ fields @ alternative)); 0
let stop ~base_path ~port ~agent ~expected_version ~login =
  let result = try
    let base_path = Unix.realpath (Env_config.normalize_masc_base_path_input base_path) in
    with_http (fun sw clock ->
      let ( let* ) = Result.bind in
      let* () = match Masc_http_client.get_sync ~clock ~headers:[]
        ~url:(Printf.sprintf "http://127.0.0.1:%d/health?full=1" port) () with
        | Ok (200, body) -> Upgrade.authorize_initial ~base_path ~expected_version ~body
            ~login:(fun () -> login () = 0)
        | _ -> Error Upgrade.Invalid_health in
      let* token = match Auth_login.read_persisted_token ~base_path ~agent_name:agent with
        | None -> Error Upgrade.Admin_required | Some token -> Ok token in
      let run_dir = (Host_config.host ()).base_path_lease_dir in
      let headers = ["authorization", "Bearer " ^ token; "x-masc-agent", agent] in
      let* owner = Upgrade.prepare ~sw ~clock ~headers ~run_dir ~base_path ~port in
      Fun.protect ~finally:(fun () -> Upgrade.close owner) (fun () ->
        if (Upgrade.incumbent owner).version <> expected_version then Error Upgrade.Incumbent_changed else
        let* () = Upgrade.request_termination owner in
        prerr_endline "Waiting for this workspace to shut down gracefully. Ctrl-C stops waiting; setup never forces it down.";
        let rec wait () =
          let* state = Upgrade.replacement_readiness ~run_dir ~base_path ~port in
          match state with
          | Owner_draining -> Eio.Time.sleep clock 0.2; wait ()
          | Port_busy -> Ok false
          | Replacement_can_start -> Ok true in
        wait ()))
    with Unix.Unix_error _ | Sys_error _ -> Error Upgrade.Owner_unavailable in
  match result with
  | Error error -> emit (`Assoc ["schema", `String "masc.setup_server_error.v1";
    "error", `String (error_message error)]); 1
  | Ok port_available -> emit (`Assoc ["schema", `String "masc.setup_server_stopped.v1";
    "owner_stopped", `Bool true; "port_available", `Bool port_available]); 0
