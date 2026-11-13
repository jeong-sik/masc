type error = Invalid_health | Admin_required | Owner_unavailable
  | Incumbent_changed | Already_requested | Closed | Port_unavailable
type phase = Prepared | Requested | Released
type t = {confirm:unit -> (unit,error) result;
  authorize:unit -> bool; signal:unit -> (unit,error) result; release:unit -> unit;
  lock:Eio.Mutex.t; mutable phase:phase}
open Result.Syntax

type single_user_server = {run_dir:string; base_path:string; port:int; pid:int}
let single_user_server_pid server = server.pid
let single_user_server_port server = server.port
let single_user_server_base_path server = server.base_path
type owner =
  | Single_user_server_here of single_user_server
  | Single_user_server_elsewhere of { pid : int; port : int }
  | Account_server_here of { pid : int }
  | Account_server_elsewhere of { pid : int; port : int }
  | Owner_unannounced of { pid : int }
  | Unowned
(* HIGH-RISK-UNREVIEWED: every command line that sends the workspace bearer,
   the admin credential or a private operator token sends it only to a
   [Single_user_server_here], and this read is the only one that makes one:
   the kernel owner of the lease of [base_path] must be the process that
   holds the byte of [port] on the file of the server of a single user. What
   answers on the port never decides it. *)
let owner ~run_dir ~base_path ~port =
  match Server_startup_takeover.capture_existing_owner ~run_dir ~base_path with
  | Error (Owner_identity_unavailable No_owner) -> Ok Unowned
  | Error
      ( Server_startup_takeover.Owner_lease_rejected _
      | Server_startup_takeover.Owner_identity_unavailable
          (Owner_changed | Unsupported | Unavailable | Closed)
      | Server_startup_takeover.Current_process_owner as error ) -> Error error
  | Ok handle ->
    let pid = Owner_process_identity.pid handle in
    Owner_process_identity.close handle;
    let read answer =
      Result.map_error (fun rejection -> Server_startup_takeover.Owner_lease_rejected rejection) answer in
    let* single = read (Server_startup_takeover.single_user_server_port_holder ~run_dir ~base_path ~port) in
    match single with
    | Some holder when holder = pid -> Ok (Single_user_server_here {run_dir; base_path; port; pid})
    | Some (_ : int) | None ->
      let* account = read (Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port) in
      (match account with
       | Some holder when holder = pid -> Ok (Account_server_here { pid })
       | Some (_ : int) | None ->
         (* The owner holds the byte of this port on neither file. Which port it
            does announce is for the answer to name, and that is all the
            whole-file reads are for: they can miss the owner behind the lock
            of another process, and then the owner is taken for one that
            announces nothing. *)
         let elsewhere = function
           | Some { Server_startup_takeover.pid = announcer; port = announced }
             when announcer = pid && announced <> port -> Some announced
           | Some (_ : Server_startup_takeover.account_server_announcement) | None -> None in
         let* single_seen = read (Server_startup_takeover.single_user_server_announcement ~run_dir ~base_path) in
         match elsewhere single_seen with
         | Some announced -> Ok (Single_user_server_elsewhere { pid; port = announced })
         | None ->
           let* account_seen = read (Server_startup_takeover.account_server_announcement ~run_dir ~base_path) in
           (match elsewhere account_seen with
            | Some announced -> Ok (Account_server_elsewhere { pid; port = announced })
            | None ->
              (* No announcement names [pid]. The lease was read before the
                 announcements, so an owner that left meanwhile, or a successor
                 that took the lease and announced, would be reported as [pid]
                 announcing nothing. The lease is asked once more, and the
                 answer names [pid] only while it still holds it. *)
              (match Server_startup_takeover.capture_existing_owner ~run_dir ~base_path with
               | Error (Owner_identity_unavailable No_owner) -> Ok Unowned
               | Error
                   ( Server_startup_takeover.Owner_lease_rejected _
                   | Server_startup_takeover.Owner_identity_unavailable
                       (Owner_changed | Unsupported | Unavailable | Closed)
                   | Server_startup_takeover.Current_process_owner as error ) -> Error error
               | Ok again ->
                 let now = Owner_process_identity.pid again in
                 Owner_process_identity.close again;
                 if now = pid then Ok (Owner_unannounced { pid })
                 else
                   Error
                     (Server_startup_takeover.Owner_identity_unavailable
                        Owner_process_identity.Owner_changed))))
let owner_without_making (root : Host_config.base_path_lease_root) ~base_path ~port =
  let rejected rejection = Error (Server_startup_takeover.Owner_lease_rejected rejection) in
  match Server_startup_takeover.lease_file_present root ~base_path with
  | Error rejection -> rejected rejection
  | Ok false -> Ok Unowned
  | Ok true ->
    (match Server_startup_takeover.lease_run_dir root ~base_path with
     | Error rejection -> rejected rejection
     | Ok run_dir -> owner ~run_dir ~base_path ~port)
type departure =
  | Announcement_withdrawn of { pid : int }
  | Owner_now of owner
  | Owner_unreadable of Server_startup_takeover.owner_capture_error
let confirm server =
  match owner ~run_dir:server.run_dir ~base_path:server.base_path ~port:server.port with
  | Ok (Single_user_server_here current) when current.pid = server.pid -> Ok ()
  | Ok (Owner_unannounced { pid }) when pid = server.pid -> Error (Announcement_withdrawn { pid })
  | Ok (( Single_user_server_here (_ : single_user_server)
        | Single_user_server_elsewhere { pid = (_ : int); port = (_ : int) }
        | Account_server_here { pid = (_ : int) }
        | Account_server_elsewhere { pid = (_ : int); port = (_ : int) }
        | Owner_unannounced { pid = (_ : int) }
        | Unowned ) as now) -> Error (Owner_now now)
  | Error unread -> Error (Owner_unreadable unread)
let owner_sentence ~base_path ~port = function
  | Single_user_server_here server ->
    Printf.sprintf "The server of %s (pid %d) serves port %d." base_path server.pid port
  | Single_user_server_elsewhere { pid; port = announced } ->
    Printf.sprintf "The server of %s (pid %d) serves port %d, not port %d. Run the command again \
                    with --port %d." base_path pid announced port announced
  | Account_server_here { pid } ->
    Printf.sprintf "The account server of %s (pid %d) serves port %d. This command works with the \
                    server of a single user; masc restart replaces the account server."
      base_path pid port
  | Account_server_elsewhere { pid; port = announced } ->
    Printf.sprintf "The account server of %s (pid %d) serves port %d. This command works with the \
                    server of a single user; masc restart --port %d replaces the account server."
      base_path pid announced announced
  | Owner_unannounced { pid } ->
    (* The kernel shows a lease owner and no announcement, and not why. Each
       cause has its own way on, so all four are said. *)
    Printf.sprintf "pid %d holds %s but announces no port. It may be starting: wait and run the \
                    command again. It may be shutting down: run the command again once it has \
                    exited. It may listen on an address that 127.0.0.1 does not reach, which \
                    its log says when it starts: commands on this host cannot use it until it \
                    is started with --host 127.0.0.1 or --host 0.0.0.0. Or a MASC that announces \
                    no port started it: stop it with kill %d and run masc start."
      pid base_path pid
  | Unowned -> Printf.sprintf "No process holds %s." base_path
let departure_sentence ~base_path ~port departure =
  let changed what =
    Printf.sprintf "The server of %s changed after this command checked it: %s" base_path what in
  match departure with
  | Announcement_withdrawn { pid } ->
    Printf.sprintf "The server of %s (pid %d) withdrew its announcement of port %d after this \
                    command checked it, as a server does when it shuts down."
      base_path pid port
  | Owner_now now -> changed (owner_sentence ~base_path ~port now)
  | Owner_unreadable unread ->
    changed
      (Printf.sprintf "its owner could not be read (%s)."
         (Server_startup_takeover.owner_capture_error_to_string unread))
let compact_health_version body =
  let unique = function
    | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Some fields
    | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None in
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> None
  | json ->
    (match unique json with
     | None -> None
     | Some fields ->
       (match List.assoc_opt "version" fields with
        | Some (`String version) when String.trim version <> "" -> Some version
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)
        | None -> None))
let departure_error = function
  | Announcement_withdrawn { pid = (_ : int) } | Owner_now (_ : owner) -> Incumbent_changed
  | Owner_unreadable (_ : Server_startup_takeover.owner_capture_error) -> Owner_unavailable
let confirmed server () = Result.map_error departure_error (confirm server)
let authorize_initial_with ~confirm ~version ~expected_version ~login =
  let* () = confirm () in
  match version () with
  | None -> Error Invalid_health
  | Some version when version <> expected_version -> Error Incumbent_changed
  | Some (_ : string) -> if login () then Ok () else Error Admin_required
let loopback_url server path = Masc_network_defaults.masc_http_loopback_origin ~port:server.port ^ path
(* HIGH-RISK-UNREVIEWED: [login] mints the admin credential of the workspace,
   so it runs only after the kernel named [server] again and the port it
   announces answered the version the operator selected. *)
let authorize_initial ~clock server ~expected_version ~login =
  let version () =
    match Masc_http_client.get_sync ~clock ~timeout_sec:Masc_http_client.default_request_timeout_sec
            ~headers:[] ~url:(loopback_url server Server_health_paths.health) () with
    | Ok (200, body) -> compact_health_version body
    | Ok ((_ : int), (_ : string)) | Error (_ : string) -> None in
  authorize_initial_with ~confirm:(confirmed server) ~version ~expected_version ~login
let prepare_with ~sw ~capture ~confirm ~authorize =
  let* signal, raw_release = capture () in
  let released = Atomic.make false in
  let release () = if not (Atomic.exchange released true) then raw_release () in
  Eio.Switch.on_release sw release;
  let checked =
    let* () = confirm () in
    if not (authorize ()) then Error Admin_required else
      Ok {confirm;authorize;signal;release;lock=Eio.Mutex.create ();phase=Prepared}
  in
  (match checked with Ok _ -> () | Error _ -> release ());
  checked
(* HIGH-RISK-UNREVIEWED: the second send of the bearer, and the SIGTERM after
   it, go out only after the kernel names the prepared server again. *)
let request_termination owner =
  Eio.Mutex.use_rw ~protect:true owner.lock (fun () ->
    match owner.phase with
    | Released -> Error Closed
    | Requested -> Error Already_requested
    | Prepared ->
      let* () = owner.confirm () in
      if not (owner.authorize ()) then Error Admin_required
      else let* () = owner.signal () in owner.phase <- Requested; Ok ())
let close owner = Eio.Mutex.use_rw ~protect:true owner.lock (fun () ->
  if owner.phase <> Released then (owner.release (); owner.phase <- Released))
(* HIGH-RISK-UNREVIEWED: the first send of the bearer. The owner handle that
   the SIGTERM goes through is captured first and must be the process the
   kernel named; then the kernel is asked again, and only then is the bearer
   sent. *)
let prepare ~sw ~clock ~headers server =
  let authorize () =
    match Masc_http_client.get_sync ~clock ~timeout_sec:Masc_http_client.default_request_timeout_sec
            ~url:(loopback_url server "/api/v1/runtime/config/raw") ~headers () with
    | Ok (200, _) -> true | Ok _ | Error _ -> false in
  let capture () =
    match Server_startup_takeover.capture_existing_owner ~run_dir:server.run_dir ~base_path:server.base_path with
    | Error (_ : Server_startup_takeover.owner_capture_error) -> Error Owner_unavailable
    | Ok handle when Owner_process_identity.pid handle <> server.pid ->
      Owner_process_identity.close handle; Error Incumbent_changed
    | Ok handle -> Ok ((fun () -> Owner_process_identity.request_termination handle
          |> Result.map_error (fun _ -> Owner_unavailable)),
        (fun () -> Owner_process_identity.close handle)) in
  prepare_with ~sw ~capture ~confirm:(confirmed server) ~authorize
let suggest_loopback_port () =
  try
    let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_,port) -> Ok port | Unix.ADDR_UNIX _ -> Error Port_unavailable)
  with Unix.Unix_error _ -> Error Port_unavailable
module For_testing = struct
  let authorize_initial = authorize_initial_with
  let prepare = prepare_with
end

type replacement_readiness = Owner_draining | Port_busy | Replacement_can_start
type termination_outcome =
  | Not_requested of error
  | Requested of (replacement_readiness, error) result
let request_termination_and_observe owner ~observe =
  match request_termination owner with
  | Error error -> Not_requested error
  | Ok () ->
    let readiness =
      try observe () with Unix.Unix_error _ | Sys_error _ -> Error Owner_unavailable in
    Requested readiness
let replacement_readiness ~run_dir ~base_path ~port =
  match Server_startup_takeover.capture_existing_owner ~run_dir ~base_path with
  | Ok owner -> Owner_process_identity.close owner; Ok Owner_draining
  | Error (Owner_identity_unavailable No_owner) ->
    if port < 1 || port > 65535 then Error Port_unavailable else
    (try
       let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
       Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
         Unix.setsockopt socket Unix.SO_REUSEADDR true;
         try Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,port));
           Ok Replacement_can_start
         with Unix.Unix_error (Unix.EADDRINUSE, _, _) -> Ok Port_busy)
     with Unix.Unix_error _ -> Error Port_unavailable)
  | Error (Server_startup_takeover.Owner_lease_rejected _)
  | Error
      (Server_startup_takeover.Owner_identity_unavailable
         (Owner_changed | Unsupported | Unavailable | Closed))
  | Error (Server_startup_takeover.Current_process_owner) -> Error Owner_unavailable
let stop_account_server ~run_dir ~base_path ~port =
  match Server_startup_takeover.capture_existing_owner ~run_dir ~base_path with
  | Error (_ : Server_startup_takeover.owner_capture_error) -> Error Owner_unavailable
  | Ok owner ->
    Fun.protect ~finally:(fun () -> Owner_process_identity.close owner) (fun () ->
      match Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port with
      | Error (_ : Server_startup_takeover.base_path_lock_rejection) -> Error Owner_unavailable
      | Ok (Some holder) when holder = Owner_process_identity.pid owner ->
        (match Owner_process_identity.request_termination owner with
         | Ok () -> Ok ()
         | Error Owner_process_identity.Owner_changed -> Error Incumbent_changed
         | Error (Owner_process_identity.No_owner | Unsupported | Unavailable | Closed) ->
           Error Owner_unavailable)
      | Ok (Some (_ : int)) | Ok None -> Error Incumbent_changed)
type readiness_answer =
  | Answered_ready
  | Not_ready
type replacement_sighting =
  | Replacement_serves
  | Another_process_announces of { pid : int }
  | Nobody_announces
  | Announcement_unreadable of Server_startup_takeover.base_path_lock_rejection
  | No_ready_answer
let replacement_sighting ~child_pid answer ~port_holder =
  match answer with
  | Not_ready -> No_ready_answer
  | Answered_ready ->
    (match port_holder () with
     | Ok (Some holder) when holder = child_pid -> Replacement_serves
     | Ok (Some holder) -> Another_process_announces { pid = holder }
     | Ok None -> Nobody_announces
     | Error rejection -> Announcement_unreadable rejection)
