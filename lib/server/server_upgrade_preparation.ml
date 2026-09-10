type error = Invalid_health | Different_workspace | Admin_required | Owner_unavailable
  | Incumbent_changed | Already_requested | Closed | Port_unavailable
type incumbent = {base_path:string; version:string}
type phase = Prepared | Requested | Released
type t = {incumbent:incumbent; observe:unit -> (string,error) result;
  authorize:unit -> bool; signal:unit -> (unit,error) result; release:unit -> unit;
  lock:Eio.Mutex.t; mutable phase:phase}
let ( let* ) = Result.bind
let decode ~base_path body =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body in
    let actual = json |> member "paths" |> member "effective_base_path" |> to_string |> Unix.realpath in
    let version = json |> member "version" |> to_string in
    if actual <> base_path then Error Different_workspace
    else if String.trim version = "" then Error Invalid_health
    else Ok {base_path;version}
  with Yojson.Json_error _ | Type_error _ | Unix.Unix_error _ -> Error Invalid_health
let prepare_with ~sw ~base_path ~observe ~authorize ~capture =
  let* base_path = try Ok (Unix.realpath base_path) with Unix.Unix_error _ -> Error Different_workspace in
  let* body = observe () in
  let* incumbent = decode ~base_path body in
  if not (authorize ()) then Error Admin_required else
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
      else if not (owner.authorize ()) then Error Admin_required
      else let* () = owner.signal () in owner.phase <- Requested; Ok ())
let close owner = Eio.Mutex.use_rw ~protect:true owner.lock (fun () ->
  if owner.phase <> Released then (owner.release (); owner.phase <- Released))
let prepare ~sw ~clock ~headers ~run_dir ~base_path ~port =
  if port < 1 || port > 65535 then Error Invalid_health else
  let url path = Printf.sprintf "http://127.0.0.1:%d%s" port path in
  let observe () = match Masc_http_client.get_sync ~clock ~url:(url "/health?full=1") ~headers:[] () with
    | Ok (200, body) -> Ok body | Ok _ | Error _ -> Error Invalid_health in
  let authorize () = match Masc_http_client.get_sync ~clock ~url:(url "/api/v1/runtime/config/raw") ~headers () with
    | Ok (200, _) -> true | Ok _ | Error _ -> false in
  let capture () = match Server_startup_takeover.capture_existing_owner ~run_dir ~base_path with
    | Error _ -> Error Owner_unavailable
    | Ok handle -> Ok ((fun () -> Owner_process_identity.request_termination handle
          |> Result.map_error (fun _ -> Owner_unavailable)),
        (fun () -> Owner_process_identity.close handle)) in
  prepare_with ~sw ~base_path ~observe ~authorize ~capture
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
  | Error _ -> Error Owner_unavailable
