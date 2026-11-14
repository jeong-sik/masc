(* Which port gets the bearer of the operator when a command stops the server
   of a single user (#51321). A process stands on a loopback port and answers
   as the server of the workspace, and writes down every request that carries
   an authorization header. The stop is run as the command lines run it:
   the kernel is asked whether the owner of the lease listens on the port,
   and only its answer reaches the function that sends the bearer. *)
module Upgrade = Server_upgrade_preparation

let version = "0.35.2"

(* Not a credential of anything: the fixture only notes that a bearer came. *)
let token = "fixture-bearer"
let agent = "operator"

(* A process that ran an Eio loop keeps the SIGCHLD handler of the posix
   backend, and the end of a child then interrupts the call that waits for it. *)
let rec retrying f =
  match f () with
  | result -> result
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> retrying f

let with_workspace f =
  let root = Filename.temp_file "masc-upgrade-bearer-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let base_path = Filename.concat root "workspace" and run_dir = Filename.concat root "run" in
    Unix.mkdir base_path 0o700; Unix.mkdir run_dir 0o700;
    f ~root ~base_path:(Unix.realpath base_path) ~run_dir)

(* A child that says "r" once [hold] gave it what it must keep, and then
   waits for a signal. [f] gets what one has ended it with, when asked. *)
let with_child ~what ~hold f =
  let ready_read, ready_write = Unix.pipe () in
  let child = Unix.fork () in
  if child = 0 then (
    Unix.close ready_read;
    Sys.set_signal Sys.sigterm Sys.Signal_default;
    let held = hold () in
    ignore (Unix.write_substring ready_write (if held then "r" else "x") 0 1);
    Unix.close ready_write;
    while true do Unix.pause () done);
  Unix.close ready_write;
  let status = ref None in
  let reap () = match !status with
    | Some ended -> ended
    | None ->
      let _, ended = retrying (fun () -> Unix.waitpid [] child) in
      status := Some ended; ended in
  let kill () =
    if Option.is_none !status then (
      (try Unix.kill child Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (reap ())) in
  Fun.protect ~finally:(fun () -> Unix.close ready_read; kill ()) (fun () ->
    let ready = Bytes.create 1 in
    ignore (retrying (fun () -> Unix.read ready_read ready 0 1));
    Alcotest.(check string) what "r" (Bytes.to_string ready);
    f ~reap ~kill)

(* The owner of the lease of [base_path]. It announces [announces] as the
   port of the server of a single user when it is a port; the lock is the
   announcement, so no listener of its own is needed. *)
let with_owner ~run_dir ~base_path ~announces f =
  with_child ~what:"the owner holds the workspace" f ~hold:(fun () ->
    match Server_startup_takeover.acquire_base_path_lock ~run_dir base_path with
    | Server_startup_takeover.Base_path_already_owned _
    | Server_startup_takeover.Base_path_rejected _ -> false
    | Server_startup_takeover.Base_path_acquired lease ->
      (match announces with
       | None -> true
       | Some port ->
         (match
            Server_startup_takeover.loopback_listener ~address:(Ipaddr.V4 Ipaddr.V4.localhost) ~port
          with
          | Error (_ : Server_startup_takeover.loopback_unreached) -> false
          | Ok listener ->
            Result.is_ok
              (Server_startup_takeover.announce_single_user_server lease listener
                 ~withdraw_with:ignore))))

(* A process without the lease locks the byte of [port] on the single-user
   announcement file of the workspace, as any process of this user can. *)
let with_byte_locker ~run_dir ~base_path ~port f =
  let path =
    Server_startup_takeover.For_testing.lease_path
      ~run_dir:(Unix.realpath run_dir) ~canonical_base_path:base_path
    ^ ".single-user-server" in
  with_child ~what:"the other process locked the byte of the port"
    (fun ~reap:_ ~kill:_ -> f ())
    ~hold:(fun () ->
      match
        let fd = Unix.openfile path [Unix.O_RDWR; Unix.O_CREAT] 0o600 in
        ignore (Unix.lseek fd port Unix.SEEK_SET);
        Unix.lockf fd Unix.F_TLOCK 1
      with
      | () -> true
      | exception Unix.Unix_error _ -> false)

let header_end = "\r\n\r\n"

let ends_with_header_end buffer =
  let length = Buffer.length buffer and tail = String.length header_end in
  length >= tail && String.equal (Buffer.sub buffer (length - tail) tail) header_end

(* One request per connection: its path goes to [log] with whether it carried
   an authorization header, and the answer is the one of a server of
   [base_path]. The value of the header is never kept. *)
let answer_one client ~log ~health_body =
  let buffer = Buffer.create 1024 and byte = Bytes.create 1 in
  let rec read () =
    if not (ends_with_header_end buffer) then
      match retrying (fun () -> Unix.read client byte 0 1) with
      | 0 -> ()
      | (_ : int) -> Buffer.add_bytes buffer byte; read () in
  read ();
  match String.split_on_char '\n' (Buffer.contents buffer) with
  | [] -> ()
  | request_line :: headers ->
    let path = match String.split_on_char ' ' request_line with
      | _ :: path :: _ -> path
      | [] | [ _ ] -> "" in
    let carries_bearer =
      List.exists (fun line ->
        String.starts_with ~prefix:"authorization:" (String.lowercase_ascii line)) headers in
    let line = Printf.sprintf "%s\t%s\n" (if carries_bearer then "bearer" else "plain") path in
    ignore (Unix.write_substring log line 0 (String.length line));
    let status, body =
      if String.equal path Server_health_paths.full then "200 OK", health_body
      else if String.equal path "/api/v1/runtime/config/raw" then "200 OK", "{}"
      else "404 Not Found", "{}" in
    let response =
      Printf.sprintf
        "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\
         Connection: close\r\n\r\n%s" status (String.length body) body in
    ignore (Unix.write_substring client response 0 (String.length response))

(* A process that is not the owner of the lease listens on a loopback port
   the kernel chose and answers [/health] as the server of [base_path] at
   [version]. [bearer_paths] reads the paths that were asked with a bearer. *)
let with_port_answering_as_the_workspace ~root ~base_path f =
  let log_path = Filename.concat root "requests.log" in
  let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen socket 16;
  let port = match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> Alcotest.fail "loopback fixture port" in
  let health_body =
    Yojson.Safe.to_string
      (`Assoc ["version", `String version;
         "paths", `Assoc ["effective_base_path", `String base_path]]) in
  let serving = Unix.fork () in
  if serving = 0 then (
    let log = Unix.openfile log_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o600 in
    while true do
      let client, _ = retrying (fun () -> Unix.accept ~cloexec:true socket) in
      (try answer_one client ~log ~health_body with Unix.Unix_error _ -> ());
      Unix.close client
    done);
  Unix.close socket;
  let bearer_paths () =
    match In_channel.with_open_bin log_path In_channel.input_lines with
    | exception Sys_error _ -> []
    | lines ->
      List.filter_map (fun line ->
        match String.split_on_char '\t' line with
        | [ "bearer"; path ] -> Some path
        | _ -> None) lines in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill serving Sys.sigkill with Unix.Unix_error _ -> ());
      ignore (retrying (fun () -> Unix.waitpid [] serving)))
    (fun () -> f ~port ~bearer_paths)

let with_http f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    Eio_context.set_env env; Eio_context.set_switch sw;
    Eio_context.set_net (Eio.Stdenv.net env); Eio_context.set_clock (Eio.Stdenv.clock env);
    Masc_http_client.with_scoped_pool ~sw ~env (fun () -> f sw (Eio.Stdenv.clock env))))

let refusal_label = function
  | Upgrade.No_lease_owner -> "refused: nobody holds the lease"
  | Upgrade.Owner_announces_no_port { pid = (_ : int) } -> "refused: the owner announces no port"
  | Upgrade.Owner_listens_on_another_port { pid = (_ : int); port } ->
    Printf.sprintf "refused: the owner listens on port %d" port
  | Upgrade.Listener_unread unread ->
    "refused, unread: " ^ Server_startup_takeover.owner_capture_error_to_string unread

let error_label = function
  | Upgrade.Invalid_health -> "invalid health"
  | Different_workspace -> "different workspace"
  | Admin_required -> "admin required"
  | Owner_unavailable -> "owner unavailable"
  | Incumbent_changed -> "incumbent changed"
  | Already_requested -> "already requested"
  | Closed -> "closed"
  | Port_unavailable -> "port unavailable"

(* The stop of a command line up to the prepared owner: the kernel is asked,
   and its answer is what [Upgrade.prepare] takes. *)
let prepared ~sw ~clock ~run_dir ~base_path ~port =
  match Upgrade.single_user_listener ~run_dir ~base_path ~port with
  | Error refusal -> Error (refusal_label refusal)
  | Ok listener ->
    Upgrade.prepare ~sw ~clock ~listener ~token ~agent
    |> Result.map_error (fun error -> "not prepared: " ^ error_label error)

let stop ~run_dir ~base_path ~port =
  with_http (fun sw clock ->
    match prepared ~sw ~clock ~run_dir ~base_path ~port with
    | Error label -> label
    | Ok owner ->
      Fun.protect ~finally:(fun () -> Upgrade.close owner) (fun () ->
        match Upgrade.request_termination owner with
        | Ok () -> "asked to stop"
        | Error error -> "not asked to stop: " ^ error_label error))

let check_no_bearer ~bearer_paths message =
  Alcotest.(check (list string)) (message ^ ": requests that carried the bearer") [] (bearer_paths ())

(* The port answers as this workspace and its process is not the owner of
   the lease. Whatever the lease says short of "the owner listens on this
   port", the stop ends before a bearer is sent. *)
let test_a_port_that_only_answers_gets_no_bearer () =
  with_workspace (fun ~root ~base_path ~run_dir ->
    with_port_answering_as_the_workspace ~root ~base_path (fun ~port ~bearer_paths ->
      let check message expected =
        Alcotest.(check string) message expected (stop ~run_dir ~base_path ~port);
        check_no_bearer ~bearer_paths message in
      check "nobody holds the lease" "refused: nobody holds the lease";
      with_owner ~run_dir ~base_path ~announces:None (fun ~reap:_ ~kill:_ ->
        check "the owner announces nothing" "refused: the owner announces no port";
        with_byte_locker ~run_dir ~base_path ~port (fun () ->
          check "another process locked the byte of the port"
            "refused: the owner announces no port"));
      (* A port from 1 through 65535 that is not the one asked about. *)
      let elsewhere = if port = 1 then 2 else port - 1 in
      with_owner ~run_dir ~base_path ~announces:(Some elsewhere) (fun ~reap:_ ~kill:_ ->
        check "the owner announces another port"
          (Printf.sprintf "refused: the owner listens on port %d" elsewhere))))

(* The owner of the lease announces the port: the bearer goes there, and the
   owner is the process the stop signals. *)
let test_the_announced_port_of_the_owner_gets_the_bearer () =
  with_workspace (fun ~root ~base_path ~run_dir ->
    with_port_answering_as_the_workspace ~root ~base_path (fun ~port ~bearer_paths ->
      with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~reap ~kill:_ ->
        Alcotest.(check string) "the stop" "asked to stop" (stop ~run_dir ~base_path ~port);
        Alcotest.(check (list string)) "the bearer went to the admin route, at preparation \
                                        and again before the signal"
          ["/api/v1/runtime/config/raw"; "/api/v1/runtime/config/raw"] (bearer_paths ());
        Alcotest.(check bool) "the owner got SIGTERM" true (reap () = Unix.WSIGNALED Sys.sigterm))))

(* The owner leaves after the preparation and the port goes on answering:
   the request that would carry the bearer a second time is not made. *)
let test_an_owner_that_left_gets_no_second_bearer () =
  with_workspace (fun ~root ~base_path ~run_dir ->
    with_port_answering_as_the_workspace ~root ~base_path (fun ~port ~bearer_paths ->
      with_owner ~run_dir ~base_path ~announces:(Some port) (fun ~reap:_ ~kill ->
        let outcome = with_http (fun sw clock ->
          match prepared ~sw ~clock ~run_dir ~base_path ~port with
          | Error label -> label
          | Ok owner ->
            Fun.protect ~finally:(fun () -> Upgrade.close owner) (fun () ->
              let sent_before = List.length (bearer_paths ()) in
              kill ();
              let answer = match Upgrade.request_termination owner with
                | Ok () -> "asked to stop"
                | Error error -> "not asked to stop: " ^ error_label error in
              Printf.sprintf "%s; bearers after the owner left: %d" answer
                (List.length (bearer_paths ()) - sent_before))) in
        Alcotest.(check string) "the stop after the owner left"
          "not asked to stop: incumbent changed; bearers after the owner left: 0" outcome)))

let () = Alcotest.run "upgrade bearer destination"
  ["the bearer of the operator",
   [Alcotest.test_case "a port that only answers gets no bearer" `Quick
      test_a_port_that_only_answers_gets_no_bearer;
    Alcotest.test_case "the announced port of the owner gets the bearer" `Quick
      test_the_announced_port_of_the_owner_gets_the_bearer;
    Alcotest.test_case "an owner that left gets no second bearer" `Quick
      test_an_owner_that_left_gets_no_second_bearer]]
