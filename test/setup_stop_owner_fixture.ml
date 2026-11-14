(* The owner of a workspace that the setup journey stops (#36877), standing
   in for an older single-user server. It holds the lease of BASE_PATH under
   RUN_DIR, announces a loopback port as its single-user server, and answers
   that port as the server of BASE_PATH at VERSION. The admin route answers
   ADMIN_STATUS to any bearer, so the stop gets the verdict the case names.
   It prints "PORT PID" once it holds the lease, then serves until killed. *)
let rec retrying f =
  match f () with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> retrying f

let header_end = "\r\n\r\n"

let request_path client =
  let buffer = Buffer.create 512 and byte = Bytes.create 1 in
  let rec read () =
    let length = Buffer.length buffer and tail = String.length header_end in
    if not (length >= tail && String.equal (Buffer.sub buffer (length - tail) tail) header_end)
    then
      match retrying (fun () -> Unix.read client byte 0 1) with
      | 0 -> ()
      | (_ : int) -> Buffer.add_bytes buffer byte; read () in
  read ();
  match String.split_on_char ' ' (Buffer.contents buffer) with
  | _ :: path :: _ -> path
  | [] | [ _ ] -> ""

let answer client ~health ~admin_status =
  let status, body =
    match request_path client with
    | path when String.equal path Server_health_paths.full -> "200 OK", health
    | path when String.equal path Server_health_paths.readiness -> "200 OK", {|{"ready":true}|}
    | path when String.equal path "/api/v1/runtime/config/raw" ->
      admin_status ^ " Fixture", {|{"error":"fixture"}|}
    | (_ : string) -> "404 Not Found", "{}" in
  let response =
    Printf.sprintf
      "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\
       Connection: close\r\n\r\n%s" status (String.length body) body in
  ignore (Unix.write_substring client response 0 (String.length response))

(* Kept reachable for the life of the process, so nothing releases the lease
   or the announcement while it serves. *)
let held = ref None

let () =
  match Sys.argv with
  | [| _; base_path; run_dir; version; admin_status |] ->
    let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
    Unix.listen socket 16;
    let port = match Unix.getsockname socket with
      | Unix.ADDR_INET ((_ : Unix.inet_addr), port) -> port
      | Unix.ADDR_UNIX (_ : string) -> failwith "the fixture socket is not on loopback" in
    (match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
     | Server_startup_takeover.Base_path_acquired lease ->
       (match
          Server_startup_takeover.loopback_listener ~address:(Ipaddr.V4 Ipaddr.V4.localhost) ~port
        with
        | Error (_ : Server_startup_takeover.loopback_unreached) -> failwith "no loopback listener"
        | Ok listener ->
          (match
             Server_startup_takeover.announce_single_user_server lease listener ~withdraw_with:ignore
           with
           | Ok () -> held := Some lease
           | Error (_ : Server_startup_takeover.base_path_lock_rejection) ->
             failwith "the port was not announced"))
     | Server_startup_takeover.Base_path_already_owned _
     | Server_startup_takeover.Base_path_rejected _ -> failwith "the lease was not acquired");
    let health =
      Yojson.Safe.to_string
        (`Assoc [ "version", `String version;
                  "paths", `Assoc [ "effective_base_path", `String base_path ] ]) in
    Printf.printf "%d %d\n%!" port (Unix.getpid ());
    while true do
      let client, (_ : Unix.sockaddr) = retrying (fun () -> Unix.accept ~cloexec:true socket) in
      (try answer client ~health ~admin_status with Unix.Unix_error _ -> ());
      Unix.close client
    done
  | _ ->
    prerr_endline "usage: setup_stop_owner_fixture BASE_PATH RUN_DIR VERSION ADMIN_STATUS";
    exit 2
