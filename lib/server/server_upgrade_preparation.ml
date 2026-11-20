open Result.Syntax

type single_user_listener = {run_dir:string; base_path:string; port:int; pid:int}
let listener_pid (listener : single_user_listener) = listener.pid
let listener_port (listener : single_user_listener) = listener.port
let listener_base_path (listener : single_user_listener) = listener.base_path
type 'here kernel_owner =
  | Single_user_server_here of 'here
  | Single_user_server_elsewhere of { pid : int; port : int }
  | Account_server_here of { pid : int }
  | Account_server_elsewhere of { pid : int; port : int }
  | Owner_unannounced of { pid : int }
  | Unowned
type owner = single_user_listener kernel_owner
(* HIGH-RISK-UNREVIEWED: this read decides which port gets the bearer of the
   operator (#51321). [here] turns the pid of the lease owner into the answer
   when that process holds the byte of [port] on the file of the server of a
   single user. Only [owner] passes a [here] that makes a
   [single_user_listener]; [For_testing.owner] answers with the bare pid. What
   answers on the port never decides it. The sends of a credential in this
   module, in [Masc_cli_runtime_config_remote] and in [Masc_cli_model_resume],
   and the two steps of [masc setup] (the sign-in and the Keeper boot), go
   only to a [Single_user_server_here]. Other senders of the bearer, such as
   [masc keeper up], [masc keeper-create] and the requests of the TUI, do
   not make this read. *)
let owner_with ~here ~lease_owner ~single_holder ~account_holder ~single_seen ~account_seen ~port =
  match lease_owner () with
  | Error (Server_startup_takeover.Owner_identity_unavailable No_owner) -> Ok Unowned
  | Error
      ( Server_startup_takeover.Owner_lease_rejected _
      | Server_startup_takeover.Owner_identity_unavailable
          (Owner_changed | Unsupported | Unavailable | Closed)
      | Server_startup_takeover.Current_process_owner as error ) -> Error error
  | Ok pid ->
    let read answer =
      Result.map_error (fun rejection -> Server_startup_takeover.Owner_lease_rejected rejection) answer in
    let* single = read (single_holder ()) in
    match single with
    | Some holder when holder = pid -> Ok (Single_user_server_here (here pid))
    | Some (_ : int) | None ->
      let* account = read (account_holder ()) in
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
         let* single_seen = read (single_seen ()) in
         match elsewhere single_seen with
         | Some announced -> Ok (Single_user_server_elsewhere { pid; port = announced })
         | None ->
           let* account_seen = read (account_seen ()) in
           (match elsewhere account_seen with
            | Some announced -> Ok (Account_server_elsewhere { pid; port = announced })
            | None ->
              (* No announcement names [pid]. The lease was read before the
                 announcements, so an owner that left meanwhile, or a successor
                 that took the lease and announced, would be reported as [pid]
                 announcing nothing. The lease is asked once more, and the
                 answer names [pid] only while it still holds it. *)
              (match lease_owner () with
               | Error (Server_startup_takeover.Owner_identity_unavailable No_owner) -> Ok Unowned
               | Error
                   ( Server_startup_takeover.Owner_lease_rejected _
                   | Server_startup_takeover.Owner_identity_unavailable
                       (Owner_changed | Unsupported | Unavailable | Closed)
                   | Server_startup_takeover.Current_process_owner as error ) -> Error error
               | Ok now ->
                 if now = pid then Ok (Owner_unannounced { pid })
                 else
                   Error
                     (Server_startup_takeover.Owner_identity_unavailable
                        Owner_process_identity.Owner_changed))))
(* The reads compare pids and signal nothing, so the lease owner is read
   without a handle on it: a host that gives no pidfd still answers. *)
let owner ~run_dir ~base_path ~port =
  owner_with ~port
    ~here:(fun pid -> {run_dir; base_path; port; pid})
    ~lease_owner:(fun () -> Server_startup_takeover.existing_owner_pid ~run_dir ~base_path)
    ~single_holder:(fun () -> Server_startup_takeover.single_user_server_port_holder ~run_dir ~base_path ~port)
    ~account_holder:(fun () -> Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port)
    ~single_seen:(fun () -> Server_startup_takeover.single_user_server_announcement ~run_dir ~base_path)
    ~account_seen:(fun () -> Server_startup_takeover.account_server_announcement ~run_dir ~base_path)
(* HIGH-RISK-UNREVIEWED: a command that signs a local operator in, and sends
   its bearer to a port, refuses on this answer before it does either. *)
let owner_without_making (root : Host_config.base_path_lease_root) ~base_path ~port =
  let rejected rejection = Error (Server_startup_takeover.Owner_lease_rejected rejection) in
  match Server_startup_takeover.lease_file_present root ~base_path with
  | Error rejection -> rejected rejection
  | Ok false -> Ok Unowned
  | Ok true ->
    (match Server_startup_takeover.lease_run_dir root ~base_path with
     | Error rejection -> rejected rejection
     | Ok run_dir -> owner ~run_dir ~base_path ~port)
let lease_directory (root : Host_config.base_path_lease_root) ~base_path =
  match root with
  | Host_config.Beside_base_path -> Filename.concat base_path Common.owner_lease_dirname
  | Host_config.Lease_dir_override dir -> dir
type departure =
  | Announcement_withdrawn of { pid : int }
  | Owner_now of owner
  | Owner_unreadable of Server_startup_takeover.owner_capture_error
type error = Invalid_health | Sign_in_failed | Admin_required | Server_starting
  | Admin_check_unanswered | Owner_unavailable
  | Incumbent_changed
  | Not_confirmed of { listener : single_user_listener; departure : departure }
  | Already_requested | Closed | Port_unavailable
type http_answer = (int * string, string) result
type phase = Prepared | Requested | Released
type t = {authorize:unit -> (unit,error) result; signal:unit -> (unit,error) result;
  release:unit -> unit; lock:Eio.Mutex.t; mutable phase:phase}
let confirm listener =
  match owner ~run_dir:listener.run_dir ~base_path:listener.base_path ~port:listener.port with
  | Ok (Single_user_server_here current) when current.pid = listener.pid -> Ok ()
  | Ok (Owner_unannounced { pid }) when pid = listener.pid -> Error (Announcement_withdrawn { pid })
  | Ok (( Single_user_server_here (_ : single_user_listener)
        | Single_user_server_elsewhere { pid = (_ : int); port = (_ : int) }
        | Account_server_here { pid = (_ : int) }
        | Account_server_elsewhere { pid = (_ : int); port = (_ : int) }
        | Owner_unannounced { pid = (_ : int) }
        | Unowned ) as now) -> Error (Owner_now now)
  | Error unread -> Error (Owner_unreadable unread)
let owner_sentence ~lease_dir ~base_path ~port = function
  | Single_user_server_here listener ->
    Printf.sprintf "The server of %s (pid %d) serves port %d." base_path listener.pid port
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
       cause has its own way on, so all five are said. *)
    Printf.sprintf "pid %d holds %s but announces no port that this command saw. It may be \
                    starting: wait and run the command again. It may be shutting down: run the \
                    command again once it has exited. It may announce another port, which the \
                    lock of another process hid from this read: run the command again with the \
                    --port it was started with. It may listen on an address that 127.0.0.1 does \
                    not reach, which its log says when it starts: commands on this host cannot \
                    use it until it is started with --host 127.0.0.1 or --host 0.0.0.0. Or a \
                    MASC that announces no port started it: stop it with kill %d and run masc \
                    start."
      pid base_path pid
  | Unowned ->
    (* A server that reads its lease from another directory is not seen here,
       so the directory that was read is named. *)
    Printf.sprintf "No process holds the lease of %s under %s." base_path lease_dir
let departure_sentence listener departure =
  let { run_dir; base_path; port; pid = (_ : int) } = listener in
  let changed what =
    Printf.sprintf "The server of %s changed after this command checked it: %s" base_path what in
  match departure with
  | Announcement_withdrawn { pid } ->
    Printf.sprintf "The server of %s (pid %d) withdrew its announcement of port %d after this \
                    command checked it, as a server does when it shuts down."
      base_path pid port
  | Owner_now now -> changed (owner_sentence ~lease_dir:run_dir ~base_path ~port now)
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
       (match List.assoc_opt Server_health_public.version_field fields with
        | Some (`String version) when String.trim version <> "" -> Some version
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)
        | None -> None))
(* The departure goes to the caller whole: the pid and the cause are what the
   operator is told when a stop is given up. *)
let confirmed listener () =
  Result.map_error (fun departure -> Not_confirmed { listener; departure }) (confirm listener)
(* A failed login is this command's own: the running server has not seen a
   credential yet, so it has refused none (#36877). *)
let authorize_initial_with ~confirm ~version ~expected_version ~login =
  let* () = confirm () in
  match version () with
  | None -> Error Invalid_health
  | Some version when version <> expected_version -> Error Incumbent_changed
  | Some (_ : string) -> if login () then Ok () else Error Sign_in_failed
let loopback_url listener path = Masc_network_defaults.masc_http_loopback_origin ~port:listener.port ^ path
let get ~clock ~headers url =
  Masc_http_client.get_sync ~clock ~timeout_sec:Masc_http_client.default_request_timeout_sec
    ~headers ~url ()
(* HIGH-RISK-UNREVIEWED: [login] mints the admin credential of the workspace,
   so it runs only after the kernel named [listener] again and the port it
   announces answered the version the operator selected. *)
let authorize_initial ~clock listener ~expected_version ~login =
  let version () =
    match get ~clock ~headers:[] (loopback_url listener Server_health_paths.health) with
    | Ok (200, body) -> compact_health_version body
    | Ok ((_ : int), (_ : string)) | Error (_ : string) -> None in
  authorize_initial_with ~confirm:(confirmed listener) ~version ~expected_version ~login
(* Whether the answer of [/health/ready] says the server has not finished
   starting: the [ready] field the server writes as [false] until its state is
   published. An answer that cannot be read says nothing either way. *)
let says_starting : http_answer -> bool = function
  | Error (_ : string) -> false
  | Ok ((_ : int), body) ->
    (match Yojson.Safe.from_string body with
     | `Assoc fields -> List.assoc_opt "ready" fields = Some (`Bool false)
     | _ -> false
     | exception Yojson.Json_error _ -> false)
(* A server that is still starting answers every route behind a credential
   with a 503 before it reads the credential, so it is asked for readiness
   first and the bearer is not sent to it. The readiness read carries no
   credential and can wait up to the request timeout, while the server may
   close its listener, so the kernel is asked after it and right before the
   bearer, with no request between them. Of the answers to the bearer, 401
   and 403 are the server refusing the credential it read; any other status,
   and no answer, is not a verdict on the credential. *)
let admin_admission ~confirm ~readiness ~access =
  if says_starting (readiness ()) then Error Server_starting else
  let* () = confirm () in
  match access () with
  | Ok (200, (_ : string)) -> Ok ()
  | Ok ((401 | 403), (_ : string)) -> Error Admin_required
  | Ok ((_ : int), (_ : string)) | Error (_ : string) -> Error Admin_check_unanswered
let prepare_with ~sw ~capture ~confirm ~readiness ~access =
  let authorize () = admin_admission ~confirm ~readiness ~access in
  let* signal, raw_release = capture () in
  let released = Atomic.make false in
  let release () = if not (Atomic.exchange released true) then raw_release () in
  Eio.Switch.on_release sw release;
  let checked =
    let* () = authorize () in
    Ok {authorize;signal;release;lock=Eio.Mutex.create ();phase=Prepared}
  in
  (match checked with Ok _ -> () | Error _ -> release ());
  checked
(* HIGH-RISK-UNREVIEWED: the second request with the bearer, and the SIGTERM
   after it, go out only after the kernel names the prepared listener again
   ([authorize] asks it right before the bearer). *)
let request_termination owner =
  Eio.Mutex.use_rw ~protect:true owner.lock (fun () ->
    match owner.phase with
    | Released -> Error Closed
    | Requested -> Error Already_requested
    | Prepared ->
      let* () = owner.authorize () in
      let* () = owner.signal () in owner.phase <- Requested; Ok ())
let close owner = Eio.Mutex.use_rw ~protect:true owner.lock (fun () ->
  if owner.phase <> Released then (owner.release (); owner.phase <- Released))
(* The capture of the stop found nobody, or another process, where the kernel
   had named [listener]. What holds the workspace now is read for the
   refusal, so the operator is told the pid that left and what replaced it.
   A kernel that names [listener] again by then still refuses: the capture
   holds no handle on it. *)
let departed listener =
  match confirmed listener () with
  | Error refusal -> Error refusal
  | Ok () -> Error Incumbent_changed
(* HIGH-RISK-UNREVIEWED: the only place in the stop that puts the bearer of
   the operator in request headers (#51321). The port is the one inside
   [listener], so no port that the kernel did not confirm can be named here.
   The owner handle that the SIGTERM goes through is captured first and must
   be the process the kernel named, so the signal and the check below name
   one process. Readiness is asked without credentials, then the kernel
   again, and only then is the bearer sent; [request_termination] repeats
   the last three steps before the second request. An owner that left, or a
   port that changed hands, ends in a refusal with no bearer sent. *)
let prepare ~sw ~clock ~listener ~token ~agent =
  let headers = ["authorization", "Bearer " ^ token; "x-masc-agent", agent] in
  let readiness () = get ~clock ~headers:[] (loopback_url listener Server_health_paths.readiness) in
  let access () = get ~clock ~headers (loopback_url listener "/api/v1/runtime/config/raw") in
  let capture () =
    match Server_startup_takeover.capture_existing_owner ~run_dir:listener.run_dir
            ~base_path:listener.base_path with
    | Ok handle when Owner_process_identity.pid handle = listener.pid ->
      Ok ((fun () -> Owner_process_identity.request_termination handle
          |> Result.map_error (fun _ -> Owner_unavailable)),
        (fun () -> Owner_process_identity.close handle))
    | Ok handle -> Owner_process_identity.close handle; departed listener
    | Error
        (Server_startup_takeover.Owner_identity_unavailable
           (Owner_process_identity.No_owner | Owner_process_identity.Owner_changed)) ->
      departed listener
    | Error
        ( Server_startup_takeover.Owner_lease_rejected _
        | Server_startup_takeover.Owner_identity_unavailable
            (Owner_process_identity.Unsupported | Owner_process_identity.Unavailable
            | Owner_process_identity.Closed)
        | Server_startup_takeover.Current_process_owner ) -> Error Owner_unavailable in
  prepare_with ~sw ~capture ~confirm:(confirmed listener) ~readiness ~access
let suggest_loopback_port () =
  try
    let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_,port) -> Ok port | Unix.ADDR_UNIX _ -> Error Port_unavailable)
  with Unix.Unix_error _ -> Error Port_unavailable
module For_testing = struct
  let owner ~lease_owner = owner_with ~here:Fun.id ~lease_owner
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
