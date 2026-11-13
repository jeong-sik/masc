type error = Invalid_health | Different_workspace | Admin_required | Server_starting
  | Admin_check_unanswered | Owner_unavailable
  | Incumbent_changed | Already_requested | Closed | Port_unavailable
type http_answer = (int * string, string) result
type incumbent = {base_path:string; version:string}
type phase = Prepared | Requested | Released
type t = {incumbent:incumbent; observe:unit -> (string,error) result;
  authorize:unit -> (unit,error) result; signal:unit -> (unit,error) result; release:unit -> unit;
  lock:Eio.Mutex.t; mutable phase:phase}
open Result.Syntax
let decode_health body =
  let unique = function
    | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) -> Some fields
    | _ -> None in
  try
    match unique (Yojson.Safe.from_string body) with
    | None -> Error Invalid_health
    | Some fields ->
      (match List.assoc_opt "version" fields, Option.bind (List.assoc_opt "paths" fields) unique with
       | Some (`String version), Some paths ->
         (match List.assoc_opt "effective_base_path" paths with
          | Some (`String path) ->
            let actual = Unix.realpath path in
            if String.trim version = "" then Error Invalid_health
            else Ok {base_path=actual;version}
          | _ -> Error Invalid_health)
       | _ -> Error Invalid_health)
  with Yojson.Json_error _ | Unix.Unix_error _ -> Error Invalid_health
let decode ~base_path body =
  let* incumbent = decode_health body in
  if incumbent.base_path = base_path then Ok incumbent else Error Different_workspace
let authorize_initial ~base_path ~expected_version ~body ~login =
  let* incumbent = decode ~base_path body in
  if incumbent.version <> expected_version then Error Incumbent_changed
  else if login () then Ok () else Error Admin_required
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
   first and the bearer is not sent to it. Of the answers to the bearer, 401
   and 403 are the server refusing the credential it read; any other status,
   and no answer, is not a verdict on the credential. *)
let admin_admission ~readiness ~access =
  if says_starting (readiness ()) then Error Server_starting else
  match access () with
  | Ok (200, (_ : string)) -> Ok ()
  | Ok ((401 | 403), (_ : string)) -> Error Admin_required
  | Ok ((_ : int), (_ : string)) | Error (_ : string) -> Error Admin_check_unanswered
let prepare_with ~sw ~base_path ~observe ~readiness ~access ~capture =
  let authorize () = admin_admission ~readiness ~access in
  let* base_path = try Ok (Unix.realpath base_path) with Unix.Unix_error _ -> Error Different_workspace in
  let* body = observe () in
  let* incumbent = decode ~base_path body in
  let* () = authorize () in
  let* signal, raw_release = capture () in
  let released = Atomic.make false in
  let release () = if not (Atomic.exchange released true) then raw_release () in
  Eio.Switch.on_release sw release;
  let checked =
    let* body = observe () in
    let* current = decode ~base_path body in
    if current <> incumbent then Error Incumbent_changed else
      Ok {incumbent;observe;authorize;signal;release;lock=Eio.Mutex.create ();phase=Prepared}
  in
  (match checked with Ok _ -> () | Error _ -> release ());
  checked
let incumbent owner = owner.incumbent
let request_termination owner =
  Eio.Mutex.use_rw ~protect:true owner.lock (fun () ->
    match owner.phase with
    | Released -> Error Closed
    | Requested -> Error Already_requested
    | Prepared ->
      let* body = owner.observe () in
      let* current = decode ~base_path:owner.incumbent.base_path body in
      if current <> owner.incumbent then Error Incumbent_changed
      else let* () = owner.authorize () in
        let* () = owner.signal () in owner.phase <- Requested; Ok ())
let close owner = Eio.Mutex.use_rw ~protect:true owner.lock (fun () ->
  if owner.phase <> Released then (owner.release (); owner.phase <- Released))
let prepare ~sw ~clock ~headers ~run_dir ~base_path ~port =
  if port < 1 || port > 65535 then Error Invalid_health else
  let* base_path = try Ok (Unix.realpath base_path) with Unix.Unix_error _ -> Error Different_workspace in
  let url path = Masc_network_defaults.masc_http_loopback_origin ~port ^ path in
  let observe () = match Masc_http_client.get_sync ~clock ~url:(url Server_health_paths.full) ~headers:[] () with
    | Ok (200, body) -> Ok body | Ok _ | Error _ -> Error Invalid_health in
  let readiness () = Masc_http_client.get_sync ~clock ~url:(url Server_health_paths.readiness) ~headers:[] () in
  let access () = Masc_http_client.get_sync ~clock ~url:(url "/api/v1/runtime/config/raw") ~headers () in
  let capture () = match Server_startup_takeover.capture_existing_owner ~run_dir ~base_path with
    | Error _ -> Error Owner_unavailable
    | Ok handle -> Ok ((fun () -> Owner_process_identity.request_termination handle
          |> Result.map_error (fun _ -> Owner_unavailable)),
        (fun () -> Owner_process_identity.close handle)) in
  prepare_with ~sw ~base_path ~observe ~readiness ~access ~capture
let suggest_loopback_port () =
  try
    let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_,port) -> Ok port | Unix.ADDR_UNIX _ -> Error Port_unavailable)
  with Unix.Unix_error _ -> Error Port_unavailable
module For_testing = struct let prepare = prepare_with end

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
type account_server =
  | Account_server_on_port of { pid : int }
  | Account_server_on_another_port of { pid : int; port : int }
  | Owner_announces_nothing
  | No_owner
let account_server ~run_dir ~base_path ~port =
  match Server_startup_takeover.capture_existing_owner ~run_dir ~base_path with
  | Error (Owner_identity_unavailable No_owner) -> Ok No_owner
  | Error
      ( Server_startup_takeover.Owner_lease_rejected _
      | Server_startup_takeover.Owner_identity_unavailable
          (Owner_changed | Unsupported | Unavailable | Closed)
      | Server_startup_takeover.Current_process_owner as error ) -> Error error
  | Ok owner ->
    let pid = Owner_process_identity.pid owner in
    Owner_process_identity.close owner;
    let read answer =
      Result.map_error (fun rejection -> Server_startup_takeover.Owner_lease_rejected rejection) answer in
    let* holder = read (Server_startup_takeover.account_server_port_holder ~run_dir ~base_path ~port) in
    if holder = Some pid then Ok (Account_server_on_port { pid }) else
    (* The owner does not hold the byte of this port. Which port it does
       announce is for the refusal to name, and that is all the whole-file
       read is for: it can miss the owner behind the lock of another process,
       and then the owner is taken for one that announces nothing. An owner
       that it shows on this very port announced after the byte was read: the
       answer stays what the byte said, and the next read of the byte finds
       it. *)
    let* seen = read (Server_startup_takeover.account_server_announcement ~run_dir ~base_path) in
    (match seen with
     | Some { Server_startup_takeover.pid = announcer; port = announced }
       when announcer = pid && announced <> port ->
       Ok (Account_server_on_another_port { pid; port = announced })
     | Some (_ : Server_startup_takeover.account_server_announcement) | None ->
       Ok Owner_announces_nothing)
type holder =
  | Held_by_nobody
  | Held_without_announcement
  | Held_by_account_server of { port : int }
(* HIGH-RISK-UNREVIEWED: a command that signs a local operator in, and sends
   its bearer to a port, refuses on this answer before it does either. *)
let holder (root : Host_config.base_path_lease_root) ~base_path ~port =
  let rejected rejection = Error (Server_startup_takeover.Owner_lease_rejected rejection) in
  match Server_startup_takeover.lease_file_present root ~base_path with
  | Error rejection -> rejected rejection
  | Ok false -> Ok Held_by_nobody
  | Ok true ->
    (match Server_startup_takeover.lease_run_dir root ~base_path with
     | Error rejection -> rejected rejection
     | Ok run_dir ->
       account_server ~run_dir ~base_path ~port
       |> Result.map (function
         | No_owner -> Held_by_nobody
         | Owner_announces_nothing -> Held_without_announcement
         | Account_server_on_port { pid = (_ : int) } -> Held_by_account_server { port }
         | Account_server_on_another_port { pid = (_ : int); port = announced } ->
           Held_by_account_server { port = announced }))
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
  | Ready_named of int
  | Ready_unnamed
  | Not_ready
type replacement_sighting =
  | Replacement_serves
  | Another_server_answers of { pid : int }
  | Another_process_announces of { pid : int }
  | Nobody_announces
  | Announcement_unreadable of Server_startup_takeover.base_path_lock_rejection
  | No_ready_answer
let replacement_sighting ~child_pid answer ~port_holder =
  match answer with
  | Ready_named pid when pid = child_pid -> Replacement_serves
  | Ready_named pid -> Another_server_answers { pid }
  | Not_ready -> No_ready_answer
  | Ready_unnamed ->
    (match port_holder () with
     | Ok (Some holder) when holder = child_pid -> Replacement_serves
     | Ok (Some holder) -> Another_process_announces { pid = holder }
     | Ok None -> Nobody_announces
     | Error rejection -> Announcement_unreadable rejection)
